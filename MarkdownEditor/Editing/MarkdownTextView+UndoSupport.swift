//
//  MarkdownTextView+UndoSupport.swift
//  MarkdownEditorHy4
//
//  撤销：把「我们自己发起的编辑」记成**源码坐标**的一段替换，并挂上撤销 / 重做。
//
//  ### 为什么单独一个文件
//  撤销是「两套记账混着用」的地方（键盘输入系统记、命令类编辑我们记），坑最多、注释最密，自成一坨；而且它算的是**源码坐标**，和只管渲染的编辑管线职责不同，混在一起最容易改坏。
//

import UIKit

/// 一次编辑在**源码**里改了哪一段：撤销 = 把这段换回 `oldText`，重做 = 换回 `newText`。
///
/// ### 为什么记「源码里改了哪一段」，而不是「整篇源码快照」（撤销链断裂的根因，别改回去）
/// 编辑器的撤销栈是**两套记账混着用**的：
/// 1. 键盘输入由 UITextView 自己记账，记的是「在某个范围上做了一次替换」；
/// 2. 列表续写 / 粘贴 / 剪切这些是我们自己发起的，以前是按**整篇源码快照**记的
///    （撤销 = `setMarkdown` 把整篇文本重建一遍）。
///
/// 混在一根撤销链上时，两边的记录是**交替**执行的：撤销完我们那笔，下一个就该轮到系统的那笔。
/// 可系统那笔账的前提是「文本从它记账那一刻起是一步步变过来的」——中间只要插进来一次整篇重建，这个前提就没了，系统那笔再也接不上，撤销链当场断在半路（用户的话：第一次 ⌘Z 正常，之后怎么按都回不到最初那段）。
///
/// 改成只记**这一段**的改动，撤销时做一次普普通通的局部替换、让编辑管线照常跑一遍（局部 parse → 局部渲染 → 局部回写）。
/// 在系统看来这就是一次再正常不过的文本编辑，两条路于是能严丝合缝地交错执行。
///
/// ### 为什么必须是源码文本，不能是渲染文本（踩过的坑，别改回去）
/// 渲染串里那些圆点、复选框占位符（`￼`）在源码里**根本不存在**，拿渲染文本去走编辑管线，映射表上查不到它，就会被原样写进源码 ——撤销几次之后源码里凭空冒出 `￼- 1\n￼- 2`，文档直接废掉。
private struct SourceEditUndo {
    /// 改动起点的源码偏移
    let location: Int
    /// 编辑前那一段的源码
    let oldText: String
    /// 编辑后那一段的源码
    let newText: String
    /// 编辑前的光标（**源码**坐标）
    let caretBefore: Int
    /// 编辑后的光标（**源码**坐标）
    let caretAfter: Int
    /// 编辑前的整篇源码（局部替换要是没换对，就整篇恢复到这儿 —— 正确性优先于「不断链」）
    let sourceBefore: String
    /// 编辑后的整篇源码（重做的目标）
    let sourceAfter: String

    /// 比一比编辑前后的整篇源码，揪出**真正变了的那一小段**。
    ///
    /// 公共前缀 + 公共后缀，夹在中间的就是改动 —— 和 `reconcileFromTextChange` 用的是同一招。
    ///
    /// - returns: 改动集中在一处时返回记录；源码没变、或者变得七零八落（比如「替换全部」改了多处）时返回 `nil`，
    ///   让调用方退回整篇源码快照。
    static func diff(before: String, after: String, caretBefore: Int, caretAfter: Int) -> SourceEditUndo? {
        let old = before as NSString
        let new = after as NSString
        guard old.length != new.length || !old.isEqual(to: after) else { return nil }   // 一个字都没改

        var prefix = 0
        let maxPrefix = min(old.length, new.length)
        while prefix < maxPrefix, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }

        var suffix = 0
        let maxSuffix = min(old.length, new.length) - prefix
        while suffix < maxSuffix,
              old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) {
            suffix += 1
        }

        let oldText = old.substring(with: NSRange(location: prefix, length: old.length - prefix - suffix))
        let newText = new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix))
        return SourceEditUndo(location: prefix,
                              oldText: oldText,
                              newText: newText,
                              caretBefore: caretBefore,
                              caretAfter: caretAfter,
                              sourceBefore: before,
                              sourceAfter: after)
    }
}

extension MarkdownTextView {

    // MARK: 撤销栈上限 / 清栈

    /// 撤销栈最多留多少步（**0 = 无限**，那是系统默认值）。
    ///
    /// ### 为什么不能让它无限
    /// 一条撤销记录不只存「改了哪几个字符」：改动跨块记不下来时会退回**整篇源码快照**，一条就存两份整篇源码（改动前 + 改动后）。大文档上连续 ⌘B / 替换全部，几百条轻松堆到上百 MB —— 而用户几乎不可能撤到那么早。设了上限之后系统自动丢最旧的那条，内存有界，用户能撤的步数一点没少（见下面的取值理由）。
    ///
    /// ### 为什么是 100 而不是 20
    /// 连续打字时系统是按「事件」分组的，一口气打两屏字也就占几组；
    /// 真正吃内存的是命令类编辑（替换全部、整篇格式化），那种操作用户撤几十步已经绰绰有余。
    private static let maxUndoLevels = 100

    /// 把「撤销栈最多几步」这件事落到当前的 UndoManager 上。
    ///
    /// ### 为什么放在编辑流程里设，不在 view 挂载时（`didMoveToWindow`）设
    /// `undoManager` 是沿响应者链找的，view 正在挂到 window 的那个时刻响应者链还没稳定，拿到的未必是最后真正用的那个实例。放在编辑流程里设就没有这个问题 ——那时 `undoManager` 一定已经就位，而且吃内存的那批记录（整篇快照）**全都来自命令类编辑**，正好覆盖得到。
    private func applyUndoLimitIfNeeded() {
        undoManager?.levelsOfUndo = Self.maxUndoLevels
    }

    /// 把撤销栈里的记录全部作废 —— 换文档、折叠这类「旧账已经对不上号」的时刻调用。
    ///
    /// ### 什么时候必须调用
    /// 栈里的记录是按**记账那一刻的文本**记的（范围、长度、整篇快照都是），文本被整个换掉之后它们就再也套不上：撤销它们会把别的文档的内容灌进当前编辑器。
    /// 换文档是其中最彻底的一种 —— 不清栈的话，在新文档里按 ⌘Z 会把上一份文档的旧账翻出来。
    ///
    /// ⚠️ **不能**挪进 `setMarkdown` 里：撤销 / 重做自己也靠 `setMarkdown` 整篇恢复，挪进去等于每撤销一次就把剩下的栈清空（表现就是「第一次 ⌘Z 有反应，之后怎么按都没用」）。
    func resetUndoHistory() {
        undoManager?.removeAllActions()
    }

    // MARK: 撤销登记（源码坐标的局部替换）

    /// 跑一次「会改到文档内容」的命令类编辑，并登记一条整篇快照式的撤销。
    ///
    /// ### 只给谁用
    /// 粘贴、剪切、插入图片、列表续写 —— 它们的共同点是**不经过系统的文本输入**：
    /// 系统不会替我们记撤销，所以我们得自己补。
    ///
    /// ### 撤销这笔账由谁记
    /// **我们自己记**：程序发起的编辑系统不会替我们记账（实测：撤销栈里根本没有它），不补一笔的话 ⌘Z 会去弹更早的一条记录，而那条记录的范围早就对不上了。
    ///
    /// ### 记成什么（撤销链断裂的根因，别改回去）
    /// 尽量记成「源码里改了哪一段」（`SourceEditUndo`）——和 UITextView 替键盘输入记的那种账**同构**，撤销链上两边的记录要交替执行，只有记法一致才接得上。
    ///
    /// 以前这里记的是**整篇源码快照**（撤销 = `setMarkdown` 把整篇重建一遍），结果撤销链会断：
    /// 系统记的那些账是按「文本从记账那一刻起一步步变过来」算的，中间插一次整篇重建，它们就再也接不上 —— 用户的说法是「第一次 ⌘Z 正常，之后怎么按都回不到最初」。
    ///
    /// 记不下来时（这次命令改了不止一处，或者压根没走 `applyEdit`）才退回整篇快照。
    ///
    /// - parameter actionName: 撤销菜单上显示的名字（Edit 菜单会显示「撤销 粘贴」）
    ///
    /// 不开 `private` 是因为查找 / 替换也算「命令类编辑」，要用同一套登记方式（见 `MarkdownTextView+Search.swift`）。
    func performUndoableModelEdit(actionName: String, _ edit: () -> Void) {
        // ⚠️ 整次编辑必须包进**一个**撤销组（别删这对调用，理由见下）。
        //
        // 实证过的行为（`MarkdownUndoDocumentSwitchTests.testSystemAlsoRecordsProgrammaticReplacement`）：我们自己发起的 storage 替换，**系统也会照常替它记一笔账**（按渲染坐标记）。
        // 也就是说一次粘贴天然是两笔账 —— 系统一笔（渲染坐标）+ 我们一笔（源码坐标），两笔的坐标系和记账方式都不一样。不包起来的话：用户得按两次 ⌘Z 才退掉一次粘贴，而且两笔分开执行时，先跑的那笔会把文本改到另一笔预设的范围之外，互相污染。
        // 包成一组之后它们变成一步：撤销时我们先按源码把内容换回去，系统那笔再把渲染文本换成同一份内容（等幂，等于什么都没做）—— ⌘Z 一次退一步，不会「一步退两步」。
        // 顺带这也解决了「记账时机」：`_UITextUndoManager` 在没有打开撤销组时登记会直接抛`must begin a group before registering undo`（实测），自己开组就不必看系统的脸色。
        // 顺手把撤销栈的上限钉上（键盘输入那种小额记录系统自己会管，这里管的是会存整篇快照的那批）
        applyUndoLimitIfNeeded()
        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping() }

        // 整篇源码快照：只在「改动的不是连续一段」时当兜底用
        let previousSource = documentStore.sourceDocument
        let previousCaretSource = documentStore.sourceCaret(forRenderedOffset: selectedRange.location)

        // 标记成「程序自己发起的编辑」：这样 applyEdit 会跳过 disable/enable 那对调用（那对调用只在「系统刚替我们记过账」的时机才合法，别的时候会抛 invalid state）
        let wasProgrammatic = isProgrammaticEdit
        isProgrammaticEdit = true
        edit()
        isProgrammaticEdit = wasProgrammatic

        let currentSource = documentStore.sourceDocument
        let currentCaretSource = documentStore.sourceCaret(forRenderedOffset: selectedRange.location)

        if let record = SourceEditUndo.diff(before: previousSource,
                                            after: currentSource,
                                            caretBefore: previousCaretSource,
                                            caretAfter: currentCaretSource) {
            registerSourceUndo(record, actionName: actionName, undoing: true)
        } else {
            // 改动不止连续一段（比如「替换全部」），一段记不下 —— 退回整篇快照
            registerRestore(toSource: previousSource, caret: selectedRange.location, actionName: actionName)
        }
    }

    /// 登记一条「把源码里那一段换回去」的撤销，顺便把重做也挂上。
    ///
    /// - parameter undoing: 这一笔是当「撤销」用还是当「重做」用。
    ///   在撤销过程中再 `registerUndo`，NSUndoManager 会把它记进**重做**栈（标准用法），撤销和重做因此可以来回走 —— 两边共用同一个 `record`，只是换的方向不一样。
    private func registerSourceUndo(_ record: SourceEditUndo, actionName: String, undoing: Bool) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            target.registerSourceUndo(record, actionName: actionName, undoing: !undoing)
            target.applySourceUndo(record, undo: undoing)
        }
        // 让 Edit 菜单显示「撤销 粘贴」而不是干巴巴一个「撤销」
        undoManager.setActionName(actionName)
    }

    /// 执行一条撤销 / 重做：把源码里那一段换回旧（或新）内容，再让编辑管线照常跑一遍。
    ///
    /// 走 `applyEdit` 而不是自己动手改 textStorage：管线负责「源码范围 → 渲染范围」的换算、局部 parse 和局部重渲染，改动因此是一次**局部替换** ——系统不会觉得「文本被整个重建了」，撤销栈里更早的记录也就还能接着用。
    private func applySourceUndo(_ record: SourceEditUndo, undo: Bool) {
        let replaced = undo ? record.newText : record.oldText
        let backTo = undo ? record.oldText : record.newText

        let source = documentStore.sourceDocument as NSString
        let location = min(max(0, record.location), source.length)
        let span = min((replaced as NSString).length, source.length - location)

        // 编辑管线只认渲染坐标，先把源码范围翻译过去.
        // 优先用 `renderedRange`（它对「一块里的小改动」最准）；
        // 跨块时它可能给不出范围（比如粘进来的两行列表项横跨多个块），那就退一步：两端各换算一次光标位置，中间那段就是要动的范围。
        // ⚠️ 千万别退化成长度 0 —— 那会变成「纯插入」，撤销时一点东西都删不掉。
        let sourceRange = NSRange(location: location, length: span)
        let start = documentStore.renderedCaret(forSourceOffset: location)
        let end = documentStore.renderedCaret(forSourceOffset: NSMaxRange(sourceRange))
        let rendered = documentStore.renderedRange(forSourceRange: sourceRange)
            ?? NSRange(location: start, length: max(0, end - start))

        // 撤销 / 重做本身不该再记一笔账（重做那笔由 registerSourceUndo 负责）
        let wasProgrammatic = isProgrammaticEdit
        isProgrammaticEdit = true
        applyEdit(renderedRange: rendered, replacementText: backTo, alreadyAppliedToTextStorage: false)
        isProgrammaticEdit = wasProgrammatic

        // ⚠️ 兜底：**正确性优先于「撤销链不断」**。
        // 「渲染范围 → 源码范围」在跨块时是不精确的（一段渲染文本可能被切进好几个块），上面那次局部替换有可能只改掉了一部分 —— 实测撤销一段跨块粘贴时会残留尾巴。
        // 所以替换完比对一下整篇源码，对不上就整篇恢复到快照：
        // 代价是这一次撤销会整篇重建（撤销链在这儿断一下），但用户看到的内容一定是对的。
        let expected = undo ? record.sourceBefore : record.sourceAfter
        if documentStore.sourceDocument != expected {
            restoreDocument(source: expected, caret: documentStore.renderedCaret(forSourceOffset: undo ? record.caretBefore : record.caretAfter))
            return
        }

        let caretSource = undo ? record.caretBefore : record.caretAfter
        let caret = documentStore.renderedCaret(forSourceOffset: caretSource)
        selectedRange = NSRange(location: min(max(0, caret), (text as NSString).length), length: 0)
    }

    /// 登记一条撤销：「把整篇源码恢复成 `source`，光标回到 `caret`」。
    ///
    /// ⚠️ 只在「一次命令改了不止一处、范围替换记不下来」时兜底用。
    /// 能用 `registerSourceUndo` 就别用这个 —— 整篇重建会打断撤销链（理由见 `SourceEditUndo`）。
    ///
    /// 顺便把**重做**也挂上：撤销和重做共用同一个 UndoManager，在撤销过程中再 `registerUndo` 会被记进重做栈（NSUndoManager 的标准用法），所以撤销、重做可以来回走。
    private func registerRestore(toSource source: String, caret: Int, actionName: String) {
        guard let undoManager else { return }

        // 记下「现在」的样子 —— 撤销之后要拿它当重做的目标
        let currentSource = documentStore.sourceDocument
        let currentCaret = selectedRange.location

        undoManager.registerUndo(withTarget: self) { target in
            target.registerRestore(toSource: currentSource, caret: currentCaret, actionName: actionName)
            target.restoreDocument(source: source, caret: caret)
        }
        // 让 Edit 菜单显示「撤销 粘贴」而不是干巴巴一个「撤销」
        undoManager.setActionName(actionName)
    }

    /// 整篇恢复到某个源码快照 —— 撤销和重做都走这里。
    ///
    /// 用 `setMarkdown` 而不是逐块替换：快照存的就是整篇源码，整篇重建最省心，而且渲染结果和当初逐字符一致（`setMarkdown` 只动 storage，完全不会碰撤销栈，见 `replaceWholeStorage`）。
    ///
    /// 不开 `private`：替换也需要这个「整篇回到某个源码快照」的动作。
    func restoreDocument(source: String, caret: Int) {
        setMarkdown(source)
        let length = (text as NSString).length
        selectedRange = NSRange(location: min(max(0, caret), length), length: 0)
    }
}
