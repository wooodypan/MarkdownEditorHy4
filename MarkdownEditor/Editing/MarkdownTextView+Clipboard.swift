//
//  MarkdownTextView+Clipboard.swift
//  MarkdownEditorHy4
//
//  剪贴板：复制 / 剪切 / 粘贴，进出剪贴板的都是 **markdown 源码**，不是渲染出来的富文本。
//
//  ### 为什么单独一个文件
//  「复制出来还是源码」是这个编辑器的铁律，进出剪贴板的这套转换 + 撤销登记自成一坨；挪出来之后 `MarkdownPasteboardController` 的全部接触面也一眼可见。
//

import UIKit

extension MarkdownTextView {

    // MARK: - 剪贴板

    /// 把选区对应的 **markdown 源码** 放进剪贴板
    @discardableResult
    func copyMarkdownSourceToPasteboard() -> Bool {
        pasteboardController.handleCopy()
    }

    override func copy(_ sender: Any?) {
        // 接管复制：放进去的是源码文本，不是渲染出来的富文本
        if pasteboardController.handleCopy() { return }
        super.copy(sender)
    }

    override func cut(_ sender: Any?) {
        guard pasteboardController.handleCopy(), selectedRange.length > 0 else {
            super.cut(sender)
            return
        }
        // 复制成功后删掉选区，走同一套增量管线（保证源码和渲染同时更新）。
        // 外面套一层「可撤销」：剪切是我们自己做的，系统没替我们记过账，不补这一笔的话，Cmd+Z 会去弹更早的一条记录，而那条记录的范围早就失效了
        performUndoableModelEdit(actionName: "剪切") {
            applyEdit(renderedRange: selectedRange, replacementText: "", alreadyAppliedToTextStorage: false)
        }
    }

    /// 剪贴板里**只有图片、没有文字**时，也要让「粘贴」这一项能按下去。
    ///
    /// ### ⚠️ 为什么必须自己补这一句（这是「微信截屏的图粘不进来」的根因，别删）
    /// 系统默认的判据是「剪贴板里有没有**文字**」，`hasStrings` 为假时，
    /// 不管里面装的是多完整的一张图，`paste:` 一律判为不可用：
    ///
    /// - Edit 菜单里的「粘贴」变灰、⌘V 按下去一点反应都没有（弹不出任何东西）；
    /// - 而下面的 `paste(_:)` 本来就能处理这张图，图进不来只因为菜单项是灰的。
    ///
    /// 实测（2026-10-15，Catalyst，用真剪贴板分别喂两种内容）：
    /// ```
    /// 剪贴板里只有文字 → canPerformAction(paste:) = true
    /// 剪贴板里只有图片 → canPerformAction(paste:) = false   ← 图永远进不来
    /// ```
    ///
    /// ### 为什么以前没暴露
    /// 从 Finder 里 ⌘C 复制图片时，剪贴板里**同时**放着一串文件地址（`public.file-url`），
    /// 那串地址在系统眼里就是「文字」，`hasStrings` 于是为真、粘贴照样可用，这是一条歪打正着的路。
    /// 微信截屏（以及 macOS 自带的 ⇧⌃⌘4 截屏）只往剪贴板里放图片、**一个字都不放**，
    /// 正好踩在这个判据上。
    ///
    /// ### 出处
    /// 「拿 `hasImages` 把 `paste:` 点亮」这一手不是自己想出来的，抄的是 MiaoYan（妙言）iOS 端编辑器 `MiaoYanMobile/Views/MarkdownEditorView.swift`，它在同一个位置覆写了 `canPerformAction`。
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        // 1) 剪贴板里是图片：存成本地文件，插入 ![](路径) 源码
        if pasteboardController.handlePasteImage() { return }
        // 2) 网页复制来的富文本（剪贴板里带 HTML）：转成 markdown 源码再插进来。
        //    这一步由 App 注入的转换器决定要不要接管（见 `MarkdownPasteboardController.richTextConverter`）
        if let markdown = pasteboardController.markdownFromRichText() {
            // 正文里还挂着网络图片时，先让 App 层把图下载下来存到本地，存完再由它回调插入；
            // 没有要下的图（或者设置里关着）就当场插入，跟以前完全一样
            if pasteboardController.localizingWebImages(in: markdown) { return }
            insertMarkdownSourceUndoably(markdown)
            return
        }
        // 3) 纯文本：走下面那个「可撤销插入」。
        //    ⚠️ 千万别退回 `super.paste(sender)`，系统的撤销记录按**源码长度**记账，而这段文本会被渲染成另一个长度，撤销就会残留尾巴（详见下面方法的注释）
        if let text = pasteboardController.pasteboardText() {
            insertMarkdownSourceUndoably(text)
            return
        }
        super.paste(sender)
    }

    /// 供 PasteboardController 调用：把一段 markdown 源码插到光标处。
    ///
    /// 只负责插入、不注册撤销。要能撤销请用 `insertMarkdownSourceUndoably(_:)`。
    func insertMarkdownSource(_ source: String) {
        applyEdit(renderedRange: selectedRange, replacementText: source, alreadyAppliedToTextStorage: false)
    }

    /// 把一段 markdown 源码插到光标处，**并且这次插入可以安全撤销**。
    ///
    /// ### 为什么粘贴必须自己接管撤销（这是「撤销残留」bug 的根因，别改回去）
    /// 编辑器存进 textStorage 的是**渲染文本**，它和源码的长度不一定相等。
    /// 无序列表每行开头会多一个圆点占位符（`U+FFFC`），实测粘贴这两行：
    /// ```
    /// - [x] 已完成      ← 源码 19 个 UTF-16 单元
    /// - [ ] 未完成      ← 渲染出来是 21 个（每行行首多一个 ￼）
    /// ```
    /// 系统的撤销是**按插入时的长度记账**的：插进去 19 个字符，它就记成「撤销 = 删掉 19 个字符」。可插入之后我们又把这 19 个字符重渲染成了 21 个（而且那次替换特意不注册撤销，免得栈里多记一笔），这条账就彻底对不上了。Cmd+Z 时从 21 个字符里删掉 19 个，末尾正好剩下「完成」两个字。
    ///
    /// ### 改成了什么
    /// 我们自己按**源码里改了哪一段**登记一笔（`SourceEditUndo`），撤销时做一次局部替换。
    /// ⚠️ 系统那边还会**照常**替这次替换再记一笔（按渲染坐标），这笔不用管：
    /// `performUndoableModelEdit` 会把两笔包进同一个撤销组，⌘Z 一次整体退掉，不会出现「一次粘贴要按两次 ⌘Z」。
    func insertMarkdownSourceUndoably(_ source: String) {
        performUndoableModelEdit(actionName: "粘贴") {
            insertMarkdownSource(source)
        }
    }
}
