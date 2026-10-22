//
//  MarkdownTextView.swift
//  MarkdownEditorHy4
//
//  UI 层：TextKit 2 模式下的 UITextView 子类，整个编辑器的对外门面
//

import UIKit

/// 一个能「所见即所得显示 markdown、但复制出来还是源码」的 UITextView。
///
/// ### 数据流（一次编辑的完整闭环）
/// ```
/// 用户敲键盘
///   → 系统把字符插进 UITextView 的 NSTextStorage
///   → textViewDidChange
///   → 和上一版渲染文本做 diff，找出改动范围
///   → MarkdownDocumentStore.applyEdit（渲染范围 → 源码范围，局部 parse，局部渲染）
///   → 拿到 EditOutcome，局部替换 NSTextStorage
///   → 刷新光标位置
/// ```
///
/// ### 为什么不在 `shouldChangeTextIn` 里拦截？
/// 方案里原本打算在那里拦截并自己接管替换。但那样会绕过系统的输入法（marked text）机制，
/// 中文拼音输入会直接坏掉。所以改成「**先让系统改，改完再 diff 回写**」，
/// 中文输入、自动纠错、听写全都能正常工作。
final class MarkdownTextView: UITextView, MarkdownAttachmentHost {

    // MARK: 核心组件

    let renderer: MarkupToAttributedRenderer
    let documentStore: MarkdownDocumentStore
    private let editController: MarkdownEditController
    /// 不开 `private`：复制 / 剪切 / 粘贴搬到了 `MarkdownTextView+Clipboard.swift`。
    let pasteboardController: MarkdownPasteboardController

    /// 相对路径图片的基准目录（demo 里指向 App 包资源目录）
    var imageBaseURL: URL? {
        get { renderer.imageBaseURL }
        set { renderer.imageBaseURL = newValue }
    }

    /// 正文栏宽的**上限**（点）。`nil`（默认）= 不限，正文铺满整个宽度。
    ///
    /// ### 它是怎么起作用的
    /// 不是去限制 `textContainer` 的宽，而是**把左右内边距对称加宽**：
    /// 可用宽度超上限时，多出来的部分左右平分，正文就居中、两边留白。
    ///
    /// ### 为什么选「改 `textContainerInset`」这条路
    /// 这个编辑器里所有装饰 —— 折叠三角、代码块背景框、引用竖条、任务列表复选框 ——
    /// 都是在算位置时**读 `textContainerInset`** 的。改它一处，整套装饰跟着一起挪，
    /// 不用去每个绘制点挨个加偏移（漏一个就会出现「文字居中了、灰背景还在原处」）。
    var maxContentWidth: CGFloat? {
        didSet {
            guard maxContentWidth != oldValue else { return }
            updateTextContainerInsetIfNeeded()
            // 宽度变了图片 / 表格要重新按新宽度画，交给布局阶段那一趟去重排
            setNeedsLayout()
        }
    }

    // MARK: 大纲（目录）

    /// 大纲事件的出口。
    ///
    /// ### 为什么是协议而不是 `OutlineCoordinator`
    /// 编辑器只需要「把标题列表和光标位置喊出去」，不需要知道外面是谁在听、
    /// 更不需要知道目录长什么样。留这一层协议之后，把目录换成侧边栏、
    /// 底部抽屉、甚至换成往日志里打一份，编辑器都一行不用改。
    ///
    /// 用 `weak`：协调者的生命周期由上层容器（`ViewController`）持有，
    /// 编辑器只是「借用」它来发通知，不参与它的生死。
    weak var outlineEventSink: MarkdownOutlineEventSink?

    /// 光标上报的防抖任务。
    ///
    /// `textViewDidChangeSelection` 在拖光标 / 快速打字时会**高频**触发，
    /// 每次都去通知目录会让高亮跟着手指疯狂跳。这里合并成 120ms 一次的尾部触发：
    /// 目录高亮是「辅助感知」功能，不需要逐字符级别的实时性。
    ///
    /// 状态存在这里、读写发生在 `MarkdownTextView+Outline.swift`，
    /// 所以不能标 `private`（跨文件扩展够不到）—— 它只在本模块内可见，不外泄。
    var outlineCursorWork: DispatchWorkItem?

    /// 光标位置变了之后的回调，参数是**源码**偏移（UTF-16）。
    ///
    /// 编辑器自己不用它，是留给外面「界面上有东西要跟着光标走」的场景 —— 现在唯一的使用方是文档页底部那条状态栏（显示光标在第几行第几列）。
    /// 它和大纲那一路共用同一个防抖和同一套坐标换算，所以两边说的永远是同一个位置。
    var onCaretMoved: ((Int) -> Void)?

    // MARK: 查找 / 替换

    /// 查找事件的出口（同样是协议，理由和大纲那边的完全一致）。
    ///
    /// 编辑器只在「内容被编辑过」时通过它喊一声 —— 命中项记的是源码偏移，一改就要重新算，这条链路缺了就会出现「高亮停在错词上」。
    weak var searchEventSink: MarkdownSearchEventSink?

    /// 查找 / 替换的运行时状态。
    ///
    /// ### 为什么打包成一个结构体而不是五个散装的存储属性
    /// Swift 的 extension 里不能声明存储属性，而查找逻辑打算整个放在 `MarkdownTextView+Search.swift` 里（和大纲分文件的做法一致）。
    /// 这里只声明一个坑位，里面的字段见那个文件里的 `SearchState`。
    var searchState = SearchState()

    /// 命中项的高亮层：一个自己画矩形的 UIView，夹在「引用竖条」和「文字」之间。
    /// 读写发生在 `MarkdownTextView+Search.swift`，所以不能标 `private`。
    let searchHighlightLayer = SearchHighlightLayer()

    /// 脚注跳转的运行时状态（落地高亮的矩形、回跳要去的位置）。
    ///
    /// ### 为什么打包成一个类而不是四个散装的存储属性
    /// Swift 的 extension 里不能声明存储属性，而脚注逻辑整个放在 `MarkdownTextView+Footnote.swift` 里。
    /// 这里只声明一个坑位，里面的字段见那个文件里的 `FootnoteJumpState`。
    var footnoteJumpState = FootnoteJumpState()

    // MARK: 状态

    /// 上一次同步给模型的渲染文本。textView 的实际内容和它 diff，就能定位用户改了哪一段。
    ///
    /// ⚠️ 带 `didSet` 是为了顺手把「行号缓存」作废：凡是给它赋值的地方都是「内容变了」
    /// （整篇替换、整篇重排、增量编辑、折叠切换），行号缓存正好该在这几种时机重算。
    /// 写在这一处，就不用去那四个地方挨个补一行。
    /// 不开 `private`：折叠（`MarkdownTextView+Fold.swift`）也要在换完内容后给它赋值。
    var lastSyncedString = "" {
        didSet { lineNumbersStale = true }
    }

    /// 把「模型认为的渲染文本」按**模型口径**做一次局部替换。
    ///
    /// ### 坐标系为什么对得上
    /// `range` 是**旧**渲染坐标系下的范围（就是 `MarkdownEditOutcome.replacedRange`），而 `lastSyncedString` 里存的正好是编辑前那一份 —— 两边同一个坐标系，替换完就是编辑后的整篇。
    ///
    /// ### 为什么还要夹一下范围
    /// 折叠切换、退格删语法标记这些场合，模型算出来的范围可能越过当前字符串的尾巴，不夹的话 `replacingCharacters` 会抛 NSRangeException，整条编辑管线直接崩。
    private func syncLastSyncedString(replacing range: NSRange, with replacement: String) {
        let old = lastSyncedString as NSString
        let start = min(max(0, range.location), old.length)
        let length = min(max(0, range.length), old.length - start)
        lastSyncedString = old.replacingCharacters(in: NSRange(location: start, length: length),
                                                   with: replacement)
    }

    /// 只给单元测试用：增量维护出来的 `lastSyncedString` 和「模型整篇重建」的结果是否一致。
    ///
    /// 局部替换要是漏了某个入口，下一轮 diff 会把这点偏差当成用户输入写回源码 ——症状是「改一个字，别处冒出乱码」，很难复现，所以留这个开关让测试在连续编辑后核一遍。
    var lastSyncedStringMatchesModel: Bool {
        lastSyncedString == documentStore.renderedString
    }
    /// 正在把模型改动写回 textView —— 这段时间内忽略 textViewDidChange，避免递归
    /// 不开 `private(set)`：折叠（`MarkdownTextView+Fold.swift`）替换内容时也要翻这个开关。
    var isApplyingModelChange = false
    /// 上一次渲染时用的容器宽度，窗口尺寸变了要整篇重排
    private var renderedWidth: CGFloat = 0
    /// 程序自己发起的编辑正在进行（比如点复选框）。
    ///
    /// 这种编辑**不是系统记的**，`applyEdit` 里 disable/enable undo 的配对在这种时机
    /// 会踩 `_UITextUndoManager invalid state` 崩溃（和折叠功能是同一个坑，
    /// 详见 toggleCollapse 里的长注释），所以要跳过那对调用。
    /// 不开 `private`：撤销登记（`MarkdownTextView+UndoSupport.swift`）也要在编辑前后翻这个开关。
    var isProgrammaticEdit = false
    /// 有一整篇内容等着写进 textStorage（真正的写入要等到布局阶段）
    private var pendingFullReplace = false
    /// 输入法组合还没结束，等结束（markedTextRange == nil）再补一次排版
    private var needsReconcileAfterComposition = false

    // MARK: 只读模式

    /// 只读模式：**看得见、选得着、复制得出来，但一个字都不许改**（默认 `false`，也就是正常编辑）。
    ///
    /// ### 怎么开：就是 `isEditable = false`
    /// UITextView 有 `isEditable` 和 `isSelectable` **两个**开关，只读要的是「前者关、后者开着」：
    /// `isEditable = false` 之后系统既不弹键盘也不让改，而 `isSelectable`（默认 `true`）不动 —— 能滚、能选、能复制全靠它。
    /// （两个一起关那是「纯展示」，主题页那块预览才是这个设定，不是这里要的。）
    ///
    /// ### 自己还拦了哪几道（`isEditable` 挡不住的那部分）
    /// `isEditable = false` 只挡**系统**的输入（键盘、粘贴、自动纠错）；我们自己发起的编辑不走系统那条路，得自己拦：
    /// 1. `MarkdownEditController.textView(_:shouldChangeTextIn:)` —— 系统想把字符塞进 `textStorage` 时先过这里，返回 `false` 就拦回去（只读下这一道其实轮不到，留着是防止 `isEditable` 被别处改回去）；
    /// 2. `reconcileFromTextChange()` —— 万一有别的地方绕开第 1 道把文本改了，这里也不会把改动写回**源码**；
    /// 3. `applyEdit(...)` —— 我们自己发起的编辑（点复选框、粘贴转 markdown、⌘B 加粗、快速操作面板）全走它，这是最后的总闸。
    ///
    /// 还有一处不在编辑管线上，是交互层的：任务列表的复选框在只读时设成「不可交互」（见 `positionCheckboxes`），点了既不会改源码，也不会把这一下点击从正文手里抢走。
    ///
    /// ### 键盘（iPhone / iPad）
    /// 只读了还立一块键盘在屏幕下方，既碍事又像是「还能输入」。`isEditable = false` 之后系统本来就不会弹，已经弹着的那块由下面那句 `resignFirstResponder()` 当场收掉。
    var isReadOnly = false {
        didSet {
            guard isReadOnly != oldValue else { return }
            // 关门：系统不弹键盘也不让改；`isSelectable` 不动，选中复制照旧
            isEditable = !isReadOnly
            if isReadOnly { resignFirstResponder() }
            // 复选框「能不能点」是摆位那一趟定下来的，改了开关要等下一次布局才生效
            setNeedsLayout()
        }
    }

    // MARK: 打字机模式

    /// 打字机模式：**开着的时候，每输入一个字就把光标拉回屏幕中间**，正文跟着往上滚一行（默认 `false`，也就是普通编辑）。
    ///
    /// ### 它解决什么
    /// 普通模式下光标一路往屏幕底下走，写到最底下那几行时，眼睛得跟着往下瞟，视线在「刚写的字」和「屏幕下方」之间来回跑。
    /// 打开之后光标始终停在中间那条线上，新写的内容在眼前，上面写过的自动往上退 —— 这是长文写作的常见习惯。
    ///
    /// ### 光标走到哪儿，正文就跟到哪儿
    /// 往下打字、按 ↑ 往回走、鼠标点上面那一行，三种都算：光标一离开中线附近就把滚动位置挪过来，视觉上光标像钉在中间那一行。
    /// 只处理「往下越界」的话，按住 ↑ 时屏幕纹丝不动，光标很快就贴到顶栏下面了。
    /// 唯一不跟的是**有选区**的时候 —— 拖选时系统自己会滚，我们再插一脚会两边打架。
    ///
    /// ### 还要给底部留半屏空白
    /// 不留的话，文档最后几行永远滚不到中间（内容就到那儿为止，`UIScrollView` 不给再往下滚）。
    /// 留白由 `applyTypewriterInset()` 维护，跟着视口高度走。
    ///
    /// 开关在文档页「⋯」菜单里（`MarkdownDocumentViewController.typewriterAction`）。
    var isTypewriterMode = false {
        didSet {
            guard isTypewriterMode != oldValue else { return }
            applyTypewriterInset()
            // 打开的那一下就把光标摆到中间，不用等用户敲第一个字才生效。
            // 打开文档时那次赋值不算：那时正文还没进去（`setMarkdown` 排在后面），这时候居中会跟「恢复上次阅读位置」抢滚动位置
            if documentStore.renderedLength > 0 {
                keepCaretNearScreenCenterIfNeeded()
            }
        }
    }

    /// 已经排了一次「下一拍把光标拉回中线」的队。
    ///
    /// 快速打字时每个字符都会来一次，合并成一次就够 —— 每次执行时读的都是**当时**的光标位置，中间那几次没必要各算一遍。读写发生在 `MarkdownTextView+Typewriter.swift`，所以不能标 `private`。
    var typewriterScrollScheduled = false

    // MARK: 代码块装饰（整块背景矩形 + 右上角复制按钮）
    //
    // ⚠️ 这一节的属性都没标 `private`：画它们、算矩形、摆位的代码在 `MarkdownTextView+Decorations.swift` 里，跨文件够不到 `private`。

    /// 背景层：加在最底层，画在文字下面
    /// 不开 `private`：导出长图要直接 render 这一层（见 `MarkdownTextView+Export.swift`）。
    let codeBlockBackgroundLayer = CodeBlockBackgroundLayer()
    /// 控件层：加在最上层，放复制按钮
    let codeBlockControlLayer = CodeBlockControlLayer()
    /// 已经算好的代码块矩形（**文档坐标系**，滚动时只需要整体平移）
    var codeBlockFrames: [(info: CodeBlockInfo, frame: CGRect)] = []
    /// 下一个布局周期要不要重算矩形（文本内容/宽度变了才需要）
    var needsCodeBlockRefresh = false
    /// 上次重算时的「签名」，用来判断内容或宽度有没有变
    var lastCodeBlockSignature = ""
    /// 「等排版收敛」最多重试几轮（只对整篇重算那条路生效，见 refreshCodeBlockDecorations）
    static let maxDecorationRetries = 30
    /// 已经排了几轮重试
    var codeBlockRetryCount = 0
    /// 挂起着的重试任务。新一轮重算开始前一定先取消它 —— 不取消的话快速打字会叠出好几条重试链并行跑，每条都在整篇重算（见 scheduleDecorationRetry）
    var decorationRetryWork: DispatchWorkItem?
    /// 打字停下来之后补的那一次整篇重算（见 scheduleDecorationSettle）
    var decorationSettleWork: DispatchWorkItem?
    /// 上一次「重算视野附近的装饰」时的滚动位置，用来节流（见 refreshDecorationsNearViewport）
    var lastNearViewportRefreshOffset: CGFloat = -.greatestFiniteMagnitude
    /// 上一次重算时的 contentSize 高度。
    ///
    /// contentSize 一变，说明 TextKit 刚修正了屏幕外的高度估算 —— 缓存里那些按估算值算的矩形也跟着过时了。
    /// 光按「滚过 40pt 才重算」节流会漏掉这种修正（详见 refreshDecorationsNearViewport）。
    var lastNearViewportRefreshHeight: CGFloat = -1
    /// 滚动触发的那一轮布局有没有已经排上（一帧最多一次，见 scheduleScrollLayout）
    var scrollLayoutScheduled = false

    // MARK: 折叠三角（顶层块左侧，浮在正文左边的装订线里）
    //
    // ⚠️ 同代码块那节：三角的摆位和折叠逻辑在 `MarkdownTextView+Fold.swift` 里。

    /// 三角所在的控件层，加在最上层，只让按钮吃点击
    let foldControlLayer = FoldControlLayer()
    /// 滚动停下之后补一次重画的定时任务（TextKit 排版比滚动事件慢半拍，见 positionFoldControls）
    var foldRedrawWork: DispatchWorkItem?
    /// 监听滚动：滚动只改位置，不重算布局
    var contentOffsetObservation: NSKeyValueObservation?

    // MARK: 引用块竖条（每层嵌套一条，画在文字下面）
    //
    // ⚠️ 同代码块那节：竖条的算与画在 `MarkdownTextView+Decorations.swift` 里。

    /// 引用内容底色所在的层：加在**最底层**（比代码块背景还低），画在文字下面
    ///
    /// 为什么比代码块背景还低：引用里可以嵌代码块，代码块的灰底是不透明的，
    /// 引用那层淡底要是压在它上面，代码块那一片会被染上引用色。让它在下面，谁先画谁在后，互不干扰。
    /// 不开 `private`：导出长图要直接 render 这一层（见 `MarkdownTextView+Export.swift`）。
    let quoteBackgroundLayer = UIView()
    /// 竖条所在的层：加在代码块背景之上、文字之下（引用里可以嵌代码块）
    /// 不开 `private`：导出长图要直接 render 这一层（见 `MarkdownTextView+Export.swift`）。
    let quoteBarLayer = UIView()
    /// 已经算好的竖条矩形（**文档坐标系**，滚动时只需整体平移）
    /// `id` 是引用层的唯一标识，`level` 是嵌套深度（0 = 最外层）
    var quoteBarFrames: [(id: Int, level: Int, frame: CGRect)] = []

    // MARK: 行号（画在正文左边的装订线里，默认关闭）

    /// 要不要显示行号。由 App 层的设置项（`MarkdownEditorSettings.showsLineNumbers`）驱动。
    ///
    /// ### 为什么开关放在这里、样式放在主题里
    /// 「显不显示」是用户偏好（App 层的事），「画出来多宽、什么颜色」是样式（主题的活）。
    /// 打开时它会把 `lineNumberGutterWidth` 加进 `textContainerInset.left`，
    /// 正文整体右移，行号落在让出来的那条带子里 —— 不占正文的字符位。
    var showsLineNumbers: Bool = false {
        didSet {
            guard showsLineNumbers != oldValue else { return }
            updateTextContainerInsetIfNeeded()
            // 关掉的瞬间要把号码清掉：不然会有一帧号码留在屏幕上
            if !showsLineNumbers { lineNumberGutter.entries = [] }
            setNeedsLayout()
        }
    }

    /// 行号画在这一层上：和引用竖条同一层（在文字下面、不吃点击）。
    ///
    /// 不开 `private`：绘制逻辑在 `MarkdownTextView+LineNumbers.swift` 里，跨文件够不到 `private`
    var lineNumberGutter = LineNumberGutterView()
    /// 「每一行开头的字符偏移」的缓存。内容没变就一直复用（见 `lineStartOffsetsIfNeeded`）
    var lineStartOffsets: [Int]?
    /// 行号缓存是不是过期了（内容一变就要重算）。作废的时机见 `lastSyncedString` 的 `didSet`
    var lineNumbersStale = true

    // MARK: 任务列表复选框（浮在 `[x]` / `[ ]` 旁边）
    //
    // ⚠️ 同代码块那节：复选框的算与画在 `MarkdownTextView+Decorations.swift` 里。

    /// 复选框所在的控件层，加在最上层，只让按钮吃点击
    /// 不开 `private`：导出长图要直接 render 这一层（见 `MarkdownTextView+Export.swift`）。
    let checkboxLayer = CheckboxLayer()
    /// 已经算好的 `[x]` / `[ ]` 三个字符的矩形（**文档坐标系**，滚动时只需整体平移）
    var checkboxFrames: [(info: CheckboxInfo, frame: CGRect)] = []

    // MARK: 宽表格横向滚动（列多到最小列宽都放不下时浮一层可横滚的表格，见 MarkdownTextView+Table.swift）

    /// 滚动容器所在的最上层：只有表格那几块吃点击，其余一律穿透（和 `CheckboxLayer` 同一套机制）
    let tableScrollLayer = MarkdownTableScrollLayer()
    /// 已经算好的「可横滚表格」矩形（**文档坐标系**，滚动时只需整体平移）
    var tableScrollFrames: [(attachment: MarkdownTableAttachment, frame: CGRect)] = []
    /// 复用池：按 attachment 的身份存。
    /// ⚠️ 滚动时**不能**每次重建：一重建，用户横滑出来的位置就回到最左边了
    var tableScrollPool: [ObjectIdentifier: MarkdownTableScrollView] = [:]
    /// 全篇扫出来的「可横滚表格」各占哪几个字符位。
    /// 只在内容变了才重扫（`refreshTableScrollMarks`），滚动时复用 —— 否则每滚 40pt 就要扫一遍整篇富文本
    var tableScrollMarks: [(range: NSRange, attachment: MarkdownTableAttachment)] = []

    // MARK: 大纲跳转（见 MarkdownTextView+Outline.swift）

    /// 当前正在进行的那次「滚到某个位置」的序号。
    ///
    /// 跳转要分好几轮滚动才能收敛（原因见 `MarkdownTextView+Outline.swift` 里的说明），
    /// 而这期间用户可能又点了别的标题、或者在查找里按了「下一个」—— 用序号把上一轮的残余步骤作废，免得两个目标互相拉扯。
    ///
    /// ### 为什么目录跳转和查找跳转共用这一个序号
    /// 它们滚动的是**同一个 textView**，目标只能有一个。共用一个序号意味着「点了标题」会自动作废上一次「查找下一个」的滚动，反之亦然 —— 正是想要的效果。
    var jumpToken = 0

    /// 最近一次「程序化滚动」发生的时刻（`CACurrentMediaTime()`）。
    ///
    /// 程序化滚动 = 目录跳转 / 查找下一个 / 脚注跳转 / 恢复阅读位置，它们都靠 `jumpStep` 一轮一轮滚。
    /// 每滚一轮就刷新这个时刻（见 `MarkdownTextView+Outline.swift` 里 `jumpStep` 的开头）。
    ///
    /// ### 谁读它
    /// 打字机居中（`MarkdownTextView+Typewriter.swift` 的 `centerCaretIfNeeded`）：它和程序化滚动改的是**同一个 `contentOffset`**，
    /// 两条路同时跑会互相拉扯、画面来回跳。所以居中前先看看这个时刻，刚滚过就避让一会儿（见 `typewriterProgrammaticScrollCooldown`）。
    ///
    /// 读写都在别的文件里，所以不能标 `private`。初值用 `-infinity` 是为了「从没滚过」时冷却判断一定通过。
    var lastProgrammaticScrollTime: CFTimeInterval = -.infinity

    // MARK: 初始化

    init(markdown: String = "") {
        let renderer = MarkupToAttributedRenderer(theme: .default, containerWidth: 600)
        let store = MarkdownDocumentStore(renderer: renderer)
        self.renderer = renderer
        self.documentStore = store
        self.editController = MarkdownEditController()
        self.pasteboardController = MarkdownPasteboardController()

        // 用 TextKit 2 的标准配置：UITextView 自己会创建 NSTextLayoutManager + NSTextContentStorage
        super.init(frame: .zero, textContainer: nil)

        editController.textView = self
        pasteboardController.textView = self
        delegate = editController
        renderer.attachmentHost = self
        imageBaseURL = Bundle.main.resourceURL

        configureTextView()
        setupCodeBlockDecorations()
        setupLineNumbers()
        setupSearchDecorations()
        setupFootnoteDecorations()
        setupFoldDecorations()
        setMarkdown(markdown)
    }

    required init?(coder: NSCoder) {
        // demo 全部用代码搭建界面，不走 storyboard
        fatalError("MarkdownTextView 不支持从 coder 解档")
    }

    private func configureTextView() {
        font = renderer.theme.bodyFont
        textColor = renderer.theme.textColor
        backgroundColor = renderer.theme.editorBackground
        alwaysBounceVertical = true
        syncLinkTextAttributes()
        // 左右内边距（含给折叠三角留的那条装订线）见 updateTextContainerInsetIfNeeded：
        // 它会按「行宽上限」动态算，所以初始也走同一个口，别在这儿再写一份
        updateTextContainerInsetIfNeeded()

        // 下面几项很关键：markdown 编辑器必须拿到「用户原始输入的字符」，
        // 否则系统会把引号变成弯引号、粘贴时自动补空格，源码就和用户输入对不上了
        smartDashesType = .no
        smartQuotesType = .no
        smartInsertDeleteType = .no
        autocapitalizationType = .none

        setupImageTapGesture()
        // 脚注：⌘ + 点正文里的 `[^1]` 跳到它的定义处（手势和处理都在 `MarkdownTextView+Footnote.swift`）
        setupFootnoteTapGesture()
    }

    // MARK: 查找命中的高亮层

    /// 铺查找高亮层。绘制逻辑本身在 `MarkdownTextView+Search.swift`，这里只管插队秩序。
    ///
    /// ### 为什么必须夹在引用竖条上面、文字下面
    /// - 插到最底层的话，命中落在代码块里时会被那块**不透明**的灰背景整块盖住，看着像没命中；
    /// - 加在最上层的话又会压住文字。
    /// 所以它排在 `quoteBarLayer`（引用竖条）之后 —— 竖条和代码块背景都在它下面，文字仍在它上面。
    private func setupSearchDecorations() {
        searchHighlightLayer.isUserInteractionEnabled = false
        insertSubview(searchHighlightLayer, aboveSubview: quoteBarLayer)
    }

    /// 铺行号那一层：夹在引用竖条下面、代码块背景上面，纯粹是陪衬，不许抢点击。
    ///
    /// 绘制和定位都在 `MarkdownTextView+LineNumbers.swift` 里，这里只管插队秩序
    private func setupLineNumbers() {
        lineNumberGutter.isUserInteractionEnabled = false
        insertSubview(lineNumberGutter, aboveSubview: codeBlockBackgroundLayer)
    }

    // MARK: 点图片预览

    /// 点中了某张图片时的回调，参数是那个图片的 attachment。
    ///
    /// ### 为什么用闭包，而不是 textView 自己弹预览窗
    /// 预览要用 `QLPreviewController`，它是 `UIViewController`，得有人 `present` 它 ——
    /// 而 textView 只是个 view，没有 present 的能力。所以这里只负责「认出点到了哪张图」，
    /// 弹窗交给外面（内容页）去做。
    var onImageTapped: ((ImageAttachment) -> Void)?

    /// 装一个「透明」的点击手势：认出点击位置，但不拦下这次触摸。
    ///
    /// `cancelsTouchesInView = false` 是关键 —— 编辑器还得靠这次触摸去放光标、
    /// 选中文字。设成 false 之后两边各做各的：光标照常落下去，我们也在同一时刻
    /// 收到回调。再配合 `shouldRecognizeSimultaneouslyWith` 返回 true，
    /// 不会和系统自己的手势互相取消。
    private func setupImageTapGesture() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleImageTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    @objc private func handleImageTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let point = gesture.location(in: self)
        guard let attachment = imageAttachment(at: point) else { return }
        onImageTapped?(attachment)
    }

    /// 找出屏幕坐标 `point` 上盖着的是哪张图片。
    ///
    /// ### 怎么定位的
    /// 图片在文本流里只占 1 个字符位，所以要先把点换算到 TextKit 的
    /// **fragment 坐标系**，再逐个 fragment 问「你包含这个点吗」，
    /// 命中之后在那个 fragment 覆盖的字符范围里找 `ImageAttachment`。
    ///
    /// ### 坐标系换算（⚠️ 这里**不要**再加 `contentOffset`）
    /// - `layoutFragmentFrame` 的原点是 textContainer 左上角，**不含** `textContainerInset`；
    /// - `point` 走的是 textView 自己的坐标，也就是手势 `location(in: self)` 给的那一套；
    /// - 而滚动视图的坐标原点就是 `bounds.origin`（等于 `contentOffset`），所以这一套里**已经含了滚动偏移**。
    ///
    /// 因此换算只剩「减掉 inset」这一步。曾经这里还减了一次 `contentOffset`，等于把滚动量算了两遍：
    /// 手指点在图片正中，问出去的却是「滚动量那么多点**下方**」的位置。
    /// 表现见 `bugHistory.md`：「文档滚过一段之后点图片没反应，点图片上方一屏处的文字反而弹出图片预览」。
    func imageAttachment(at point: CGPoint) -> ImageAttachment? {
        guard let textLayoutManager,
              let contentStorage = textLayoutManager.textContentManager as? NSTextContentStorage,
              bounds.width > 1 else { return nil }

        let target = CGPoint(x: point.x - textContainerInset.left,
                             y: point.y - textContainerInset.top)

        let documentStart = contentStorage.documentRange.location
        var found: ImageAttachment?

        textLayoutManager.enumerateTextLayoutFragments(from: documentStart,
                                                       options: [.ensuresLayout]) { fragment in
            guard fragment.layoutFragmentFrame.contains(target) else { return true }

            // 这个 fragment 覆盖了哪几个字符（NSTextContentStorage 用的是 UTF-16 偏移，
            // 和 NSRange.location 同一套坐标）
            let start = contentStorage.offset(from: documentStart, to: fragment.rangeInElement.location)
            let length = contentStorage.offset(from: fragment.rangeInElement.location,
                                               to: fragment.rangeInElement.endLocation)
            let range = NSRange(location: start, length: max(0, length))
            guard range.location >= 0, NSMaxRange(range) <= textStorage.length else { return true }

            textStorage.enumerateAttribute(.attachment, in: range, options: []) { value, _, _ in
                if let attachment = value as? ImageAttachment { found = attachment }
            }
            // 图片自己独占一行，命中这个 fragment 就不用再看后面的了
            return false
        }
        return found
    }

    /// 把主题里的链接样式同步给 `UITextView` 自己。
    ///
    /// ### 为什么非得有这一步（踩过的坑，别删）
    /// 富文本里给链接文字挂上 `.link` 之后，**UITextView 画图时会拿自己的
    /// `linkTextAttributes` 盖在那一段上**，默认值是系统蓝（实测
    /// `[NSColor = 0.00,0.53,1.00,1.00]`）。所以哪怕富文本里的 `foregroundColor`
    /// 已经是 `theme.linkColor`，屏幕上照样是蓝的 —— 表现就是
    /// 「在 `MarkdownTheme` 里改 `linkColor` 一点反应都没有」。
    ///
    /// 更阴的是：**UITextView 不会改你给它的字符串**，从 `attributedText` 里
    /// 把颜色读回来还是红的。也就是说只查富文本永远看不出问题，必须看屏幕。
    ///
    /// 出处仍然只有 `theme.linkAttributes` 一份，不在这儿另写颜色。
    private func syncLinkTextAttributes() {
        linkTextAttributes = renderer.theme.linkAttributes
    }

    // MARK: 对外接口

    // 撤销栈上限 / 清栈已挪到 `MarkdownTextView+UndoSupport.swift`。

    /// 整篇替换内容
    func setMarkdown(_ markdown: String) {
        // ⚠️ 先把左右内边距按**当前**主题和设置算一遍，再去读可用宽度。
        // 不这么做的话，主题刚改过（字号 / 行号 / 行宽上限）时读到的还是上一套内边距算出来的宽度，图片和表格会按错的宽度渲染；紧接着那一轮布局发现宽度变了，又整篇重排一遍 —— 等于白渲染一次。
        updateTextContainerInsetIfNeeded()
        documentStore.load(markdown: markdown, containerWidth: currentContainerWidth)
        renderedWidth = currentContainerWidth
        lastSyncedString = documentStore.renderedString

        // 真正的 storage 写入推迟到布局阶段做（原因见 applyPendingFullReplace 的注释）。
        // 这里立刻跑一次 layoutIfNeeded，保证 setMarkdown 返回后内容就已经就位。
        pendingFullReplace = true
        setNeedsLayout()
        layoutIfNeeded()
        // 兜底：view 还没挂到 window 上（比如 init 刚结束）时 layoutSubviews 不会来，这里补一次
        if pendingFullReplace { applyPendingFullReplace() }

        // 整篇换掉了，标题列表一定变了；光标也被重置。这两件事一起告诉目录
        publishOutlineItems()
        publishOutlineCursor()
        // 整篇换过之后，上一次查找记的源码偏移全都不作数了，直接收摊（不试图保留：换文档 / 撤销这类场景下「接着上一次那个词继续查」没有意义）
        clearSearchHighlight()
    }

    /// 把模型里的渲染结果整篇写进 textStorage。
    ///
    /// ### 为什么必须放在 `layoutSubviews` 里做（TextKit 2 的坑，别删）
    /// 在按钮事件里同步整篇替换，TextKit 2 会把所有 attachment 的 view 从视图树里摘掉，
    /// 却**不会**为新的 attachment 建 view —— 于是「图片和圆点全部消失，滚一下才回来」。
    /// 只有放在布局阶段做，TextKit 才会跟着重建 view。
    ///
    /// 试过但**都无效**的绕法（别再试一遍了）：
    /// `invalidateLayout(for:)`、`ensureLayout(for:)`、`textViewportLayoutController.layoutViewport()`、
    /// 抖动 `textContainer.size`、把 `attributedText` 清空再赋值、拆成「先清空再回填」两步、
    /// 让「源码没变的块」复用旧的 attachment 实例。
    private func applyPendingFullReplace() {
        pendingFullReplace = false
        isApplyingModelChange = true
        replaceWholeStorage(with: documentStore.attributedDocument)
        // ⚠️ 整篇换内容时光标必须归零，不能留着上一份文档的位置。
        // `replaceCharacters` 只会把旧的 `selectedRange` 夹进新文本长度里，不会自己清掉。
        // 于是换文档后光标还停在上一份文档那个偏移上（在新文档里就是随机一个位置）。
        // 用户滚到文末按回车时，换行就插进了文档中间，看起来像「光标突然跳过去」。
        // 撤销的整篇恢复不受影响：`restoreDocument` 在这之后会自己把光标设到该去的地方。
        selectedRange = NSRange(location: 0, length: 0)
        isApplyingModelChange = false
    }

    /// 整篇替换 backingStorage 的内容（包在编辑事务里，确保 TextKit 收到「内容变了」的通知）
    private func replaceWholeStorage(with attributed: NSAttributedString) {
        let whole = NSRange(location: 0, length: backingStorage.length)
        if let contentStorage = textLayoutManager?.textContentManager as? NSTextContentStorage {
            contentStorage.performEditingTransaction {
                backingStorage.replaceCharacters(in: whole, with: attributed)
            }
        } else {
            backingStorage.replaceCharacters(in: whole, with: attributed)
        }
    }

    /// 当前源码（和「全选复制」出来的内容完全一致）
    var markdownSource: String { documentStore.fullSource }

    /// 容器可用宽度（图片、分隔线按它算尺寸）
    var currentContainerWidth: CGFloat {
        let width = bounds.width - textContainerInset.left - textContainerInset.right
        return max(120, width - textContainer.lineFragmentPadding * 2)
    }

    /// 把主题里那几个**存在 view 自己身上**的属性搬过来（编辑区字号、链接样式、底色）。
    ///
    /// 🚨 单拆出来是给「打开文档」那条路用的：那边必须在 `setMarkdown` **之前**先把它调一次，这样文档那一次渲染出来就是最终效果。
    /// 顺序反过来（先 `setMarkdown` 再 `refreshTheme()`）会先用默认主题整篇渲一遍、紧接着再用真主题整篇重渲一遍 —— 同一份内容白渲染两次，实测各 ~155 ms（2026-10-11 的 Time Profiler）。
    func applyThemeChrome() {
        // textView 自己的 font 只影响「没被富文本属性覆盖的地方」（比如光标高度、
        // 打新字时的临时样式），但既然字号换了，这里也一起对齐
        font = renderer.theme.bodyFont
        // 主题可能换了（配色联动时），链接颜色和整片底色都得跟着换 ——
        // 底色不在富文本里，是 view 自己的属性，只能在这儿手动搬一次
        syncLinkTextAttributes()
        backgroundColor = renderer.theme.editorBackground
    }

    /// 主题改过（字号 / 行高 / 段间距 / 首行缩进）之后，按新样式把整篇重排一遍。
    ///
    /// ### 为什么必须有这个入口
    /// 这几个参数不是「画的时候读一下」，而是**渲染那一刻就烙进**字体和
    /// `NSParagraphStyle` 里了。只改 `renderer.theme` 不动画面，屏幕上一点变化都没有。
    ///
    /// 重排会保着光标停在原来的源码位置（见 `reRenderPreservingCaret`），
    /// 所以设置页上拖滑块时不会每动一下就跳回文首。
    func refreshTheme() {
        applyThemeChrome()
        reRenderPreservingCaret()
    }

    /// 按「行宽上限」和主题里的装订线宽度，重算左右内边距。
    ///
    /// ### 三条边距的来历
    /// - 左：基础留白 + 折叠三角要占的那条「装订线」（三角浮在带子里，不占正文字符位，
    ///   多行文字的左边缘才对得齐）；
    /// - 右：基础留白；
    /// - 上下：上边留一点呼吸，下边多留一截，好让最后一行能滚到舒服的位置。
    ///
    /// 有「行宽上限」且当前可用宽度超过它时，把超出的部分**左右平分**加进去，
    /// 正文就居中、两边留白，一行不会拉得太长。
    ///
    /// ⚠️ 只在结果真的变了才赋值。这个方法会在每次 `layoutSubviews` 里被调到，
    /// 而设置 `textContainerInset` 会再触发一轮布局 —— 不判等就是死循环。
    private func updateTextContainerInsetIfNeeded() {
        let base: CGFloat = 16
        // 左边两条装订线：行号（开着才占地方）+ 折叠三角（一直占）
        var left = base + renderer.theme.foldGutterWidth
            + (showsLineNumbers ? renderer.theme.lineNumberGutterWidth : 0)
        var right = base

        if let limit = maxContentWidth {
            // ⚠️ 别用 `bounds.width - left - right` 当可用宽度：正文真正能排字的宽度
            // 还要再扣掉 `textContainer` 自己的行内边距（`lineFragmentPadding` 左右各一份，
            // 和 `currentContainerWidth` 的算法保持一致）。不扣的话用户在设置页填 400，
            // 实际只会得到 390 —— 差得不多，但「我设的数」和「看到的宽度」对不上很难解释。
            let padding = textContainer.lineFragmentPadding * 2
            let available = bounds.width - left - right - padding
            if available > limit {
                let extra = (available - limit) / 2
                left += extra
                right += extra
            }
        }

        let target = UIEdgeInsets(top: base, left: left, bottom: 32, right: right)
        guard target != textContainerInset else { return }
        textContainerInset = target
    }

    // MARK: 布局

    override func layoutSubviews() {
        super.layoutSubviews()

        // 第一件事就是把左右内边距按当前宽度定下来 —— 下面算代码块背景、折叠三角、
        // 图片宽度全都要读它，晚一步就会有一帧画在旧位置
        updateTextContainerInsetIfNeeded()

        // 打字机模式的底部留白按视口高度算（半屏）：转屏、拉窗口之后这个数要跟着变
        applyTypewriterInset()

        // 有整篇内容等着写入：现在就写（这一步必须在布局阶段做，见 applyPendingFullReplace 的注释）
        if pendingFullReplace { applyPendingFullReplace() }

        // 代码块背景矩形跟着布局走（内容或宽度变了会重算，纯滚动只平移）
        updateCodeBlockDecorationsIfNeeded()
        // 折叠三角 / 「⋯」热区同理，只是它每次都按 fragment 的当前位置重摆
        positionFoldControls()
        // 查找命中的黄块：只有当某一处滚进视野附近时才去 TextKit 那儿量它的矩形
        updateSearchHighlightsIfNeeded()
        // 行号：按当前视口里排好版的那几行重画（关着的时候这里几乎不干事）
        positionLineNumbers()

        // 容器宽度变了（转屏、Catalyst 拉窗口）→ 图片尺寸要跟着变，整篇重排一次
        let width = currentContainerWidth
        guard abs(width - renderedWidth) > 1, !isApplyingModelChange, markedTextRange == nil else { return }
        renderedWidth = width
        reRenderPreservingCaret()
    }

    /// 整篇重新渲染，但保持光标停在原来的源码位置
    private func reRenderPreservingCaret() {
        let sourceCaret = documentStore.sourceCaret(forRenderedOffset: selectedRange.location)
        documentStore.load(markdown: documentStore.fullSource, containerWidth: renderedWidth)

        isApplyingModelChange = true
        replaceWholeStorage(with: documentStore.attributedDocument)
        isApplyingModelChange = false

        lastSyncedString = documentStore.renderedString
        needsCodeBlockRefresh = true

        let caret = min(documentStore.renderedCaret(forSourceOffset: sourceCaret), (text as NSString).length)
        selectedRange = NSRange(location: caret, length: 0)

        // 整篇重排会重建所有块（UUID 也跟着全换新），目录那边必须整份换掉，
        // 否则它会拿着一批已经不存在的旧 id 去做高亮
        publishOutlineItems()
    }

    // MARK: 光标

    /// 把光标高度夹回「行高倍数没生效时的样子」，不让它跟着行高一起变长。
    ///
    /// ### 为什么需要
    /// 行高倍数（`lineHeightMultiple`）在 TextKit 里是把多出来的行距**全堆在文字上方**：
    /// 1.7 倍时一行 34 点的行盒里，字形只占最下面约 20 点（见 `textGlyphVerticalBounds` 的注释）。
    /// 系统默认的光标按**整个行盒**画，于是行高调大以后光标被拉得老长，
    /// 上端戳进上一行、看着像一根竖杠压住了上面的字。
    ///
    /// ### 怎么夹
    /// 多出来的那段行距 = `(倍数 − 1) × 字体自然行高`，它整段落在光标**顶部**。
    /// 把这段从光标高度里减掉、**底边不动**（字形本来就贴着行盒底），
    /// 得到的光标就和「行高倍数没生效时」逐像素一致 —— 高度、以及相对字形的上下位置都不变。
    ///
    /// ### 为什么读段落样式里的倍数，而不是主题里的全局值
    /// 图片、公式块这些段落样式**主动把倍数清成了 0**（见 `MarkupToAttributedRenderer` 里的
    /// `blockAttachmentParagraphStyle`、`mathBlockParagraphStyle`）—— 它们本来就没吃行高、
    /// 光标也没被拉长。要是照主题的全局值去减，这些行的光标会被无端削矮。按每段**实际生效**的倍数来算才对。
    ///
    /// ### 为什么用「减去多出来的量」而不是「夹到 font.lineHeight」
    /// 系统默认光标比 `font.lineHeight` 略高（含基线下方一点 padding）。直接夹到 `font.lineHeight`
    /// 会让高行高下的光标反而比默认状态**更矮、且整体下沉**，两种行高之间不一致。
    /// 减去多出来的量则保证任何行高下光标都和默认状态一模一样。
    override func caretRect(for position: UITextPosition) -> CGRect {
        let rect = super.caretRect(for: position)
        guard textStorage.length > 0 else { return rect }

        let offset = self.offset(from: beginningOfDocument, to: position)
        let attributeIndex = max(0, min(offset, textStorage.length - 1))

        // 这一段实际生效的行高倍数（≤ 1 表示没吃行高，光标不用动）
        guard let style = textStorage.attribute(.paragraphStyle, at: attributeIndex, effectiveRange: nil) as? NSParagraphStyle,
              style.lineHeightMultiple > 1 else { return rect }

        // 按这个位置自己的字体（正文 / 代码 / 标题各不同）算多出来的量
        let font = (textStorage.attribute(.font, at: attributeIndex, effectiveRange: nil) as? UIFont)
            ?? renderer.theme.bodyFont

        // 行高倍数比自然行高多撑出来的那一段，全落在光标顶部
        let extraLeading = (style.lineHeightMultiple - 1) * font.lineHeight
        var clamped = rect
        let bottom = rect.maxY                          // 底边不动（字形贴着行盒底）
        clamped.size.height = max(1, rect.height - extraLeading)
        clamped.origin.y = bottom - clamped.height      // 顶边往下收，收掉那段空白
        return clamped
    }

    // MARK: - 编辑管线

    /// 系统已经把文本改完了（用户敲键、自动纠错、粘贴…），我们 diff 出改动范围再回写给模型。
    func reconcileFromTextChange() {
        guard !isApplyingModelChange, !isReadOnly else { return }

        // 输入法还在组合：先不动，等 unmarkText 之后再补
        guard markedTextRange == nil else {
            needsReconcileAfterComposition = true
            return
        }

        let current = text as NSString
        let previous = lastSyncedString as NSString
        guard current.length != previous.length || !current.isEqual(to: lastSyncedString) else { return }

        // 公共前缀 + 公共后缀，中间那段就是真正变了的
        let prefix = MarkdownTextView.commonPrefixLength(previous, current)
        let maxSuffix = min(previous.length, current.length) - prefix
        let suffix = MarkdownTextView.commonSuffixLength(previous, current, maxSuffix: maxSuffix)

        var changedRange = NSRange(location: prefix, length: max(0, previous.length - prefix - suffix))
        let replacement = current.substring(with: NSRange(location: prefix,
                                                          length: max(0, current.length - prefix - suffix)))

        // 用光标位置校正插入点 —— 纯字符串 diff 遇到「插入重复字符」会算错位置。
        //
        // ### 踩过的坑（按回车多跳两行，别删）
        // 光标停在 `# 标题一⏎|⏎这是` 按回车，文本从 `# 标题一⏎⏎` 变成 `# 标题一⏎⏎⏎`。
        // 公共前缀算法一路匹配到 offset 7（三个换行长得一模一样），于是认为插入发生在
        // **最后一个换行之后** —— 源码确实只多了一个换行看起来没问题，
        // 但光标被算到了正文开头，用户看到的就是「按一下回车跳了三行」。
        //
        // 光标不会说谎：变化之后它一定停在刚插入的内容后面，
        // 所以「光标位置 − 插入长度」就是真正的插入点。
        // 只有光标处的内容确实等于 diff 出来的替换内容时才采信，防止异常场景改坏。
        let inserted = (replacement as NSString).length
        let inferred = selectedRange.location - inserted
        if inferred >= 0,
           inferred + inserted <= current.length,
           current.substring(with: NSRange(location: inferred, length: inserted)) == replacement {
            changedRange.location = inferred
        }

        applyEdit(renderedRange: changedRange, replacementText: replacement, alreadyAppliedToTextStorage: true)
    }

    /// 输入法确认输入后会走到这里
    override func unmarkText() {
        super.unmarkText()
        needsReconcileAfterComposition = true
    }

    /// 供 EditController 在光标变动时调用：输入法结束后补排版
    func reconcileIfNeededAfterComposition() {
        guard needsReconcileAfterComposition, markedTextRange == nil else { return }
        needsReconcileAfterComposition = false
        reconcileFromTextChange()
    }

    /// 走一遍「模型增量编辑 → 局部回写 textView」的管线。
    ///
    /// - parameter renderedRange:              改动发生在渲染文本的哪个范围（**旧**坐标系）
    /// - parameter replacementText:            改成了什么
    /// - parameter alreadyAppliedToTextStorage: textView 里是不是已经改好了。
    ///   用户敲键盘时为 true（系统已经插进去了），我们自己发起的删除（cut）时为 false。
    func applyEdit(renderedRange: NSRange,
                   replacementText: String,
                   alreadyAppliedToTextStorage: Bool) {
        // 只读模式下什么都不许改 —— 这是最后一道总闸，见 isReadOnly 的注释
        guard !isReadOnly else { return }
        let outcome = documentStore.applyEdit(inRenderedRange: renderedRange,
                                              replacementText: replacementText,
                                              containerWidth: currentContainerWidth)

        // 如果 textView 里已经改好了，旧范围要按增删量伸缩，才能对上当前文本的坐标
        let delta = alreadyAppliedToTextStorage ? (replacementText as NSString).length - renderedRange.length : 0
        let rawRange = NSRange(location: outcome.replacedRange.location,
                               length: max(0, outcome.replacedRange.length + delta))
        let storageLength = (text as NSString).length
        let targetRange = NSRange(location: min(rawRange.location, storageLength),
                                  length: min(rawRange.length, storageLength - min(rawRange.location, storageLength)))

        isApplyingModelChange = true
        // 键盘输入时系统已经替这次输入记过账了，这里只是把「模型算出来的渲染结果」写回去，不能再记一笔（一次编辑两笔账 = 撤销一次退两步）。
        //
        // ⚠️ 程序自己发起的编辑**反过来**：它连 disable/enable 都不能碰 ——那个时机不属于「系统刚发起的编辑」，_UITextUndoManager 会直接抛 `enableUndoRegistration may only be invoked with matching call to disableUndoRegistration`
        // （实测崩溃，别再改回去）。那种编辑交给系统照常记账 —— 这一点是**实证过**的，不是猜测：
        // 系统确实会替程序性替换记一笔（见 `MarkdownUndoDocumentSwitchTests.testSystemAlsoRecordsProgrammaticReplacement`），
        // 那笔账不用管，它会和我们的那笔被 `performUndoableModelEdit` 包进同一个撤销组，⌘Z 一次一起退掉。
        if !isProgrammaticEdit {
            undoManager?.disableUndoRegistration()
        }

        if let contentStorage = textLayoutManager?.textContentManager as? NSTextContentStorage {
            // TextKit 2 的事务接口：一次提交，TextKit 自己算最小失效区域做增量重排
            contentStorage.performEditingTransaction {
                backingStorage.replaceCharacters(in: targetRange, with: outcome.newContent)
            }
        } else {
            backingStorage.replaceCharacters(in: targetRange, with: outcome.newContent)
        }

        if !isProgrammaticEdit {
            undoManager?.enableUndoRegistration()
        }
        isApplyingModelChange = false

        // 同步「模型认为的渲染文本」：以前是 `documentStore.renderedString`，那要遍历**每一个块**、把每个块的 NSAttributedString 都转成纯文本再拼起来 —— 每敲一个字就把整篇誊一遍。
        // 但这次编辑模型只动了 `[replacedRange]` 这一段，替换结果就在 `outcome.newContent` 里，就地替换同样一段即可，代价只跟改动长度有关（长文档连续打字的提速全在这一行）。
        syncLastSyncedString(replacing: outcome.replacedRange, with: outcome.newContent.string)
        needsCodeBlockRefresh = true

        let caret = min(outcome.caretRenderedOffset, (text as NSString).length)
        if selectedRange.location != caret || selectedRange.length != 0 {
            selectedRange = NSRange(location: caret, length: 0)
        }

        // 这次编辑如果让目录「对不上号」了，就重新抓一份标题列表给它。
        //
        // 什么叫对不上号？两种：标题本身被增删改，或者标题的位置被上面的正文顶移了。
        // 只有「在文档最末尾（所有标题后面）的正文里打字」才不算 ——
        // 那时候标题一个都没动，目录不用白跑一趟，长文档连续打字也就不会被拖慢。
        if outcome.headingsChanged { publishOutlineItems() }

        // 内容一改，查找命中记的那批源码偏移就可能整体平移，通知外面（查找协调者）重新查一遍。
        // 只有真的有人在听时才发 —— 没开查找框时不该为这个付任何代价。
        if searchEventSink != nil, !searchState.suppressesChangeNotice {
            searchEventSink?.editorContentDidChange()
        }

        // 内容变了，装饰层（复选框按钮、代码块背景、引用竖条、折叠三角）可能整体失效，要**马上**重算一遍。
        //
        // 为什么不能只靠 `needsCodeBlockRefresh = true`：装饰层平时只挂在 `layoutSubviews` 里刷新，而我们用的是 TextKit 2 的 `performEditingTransaction` 改文本 —— 它会让 TextKit 的排版失效，但**不保证**系统会给 textView 排一次布局。实测：删掉文档里最后一个任务项后，渲染文本里座位已经没了，屏幕上那个复选框按钮却一直留在原地，要等下一次滚动（那时才走 layout）才消失。
        setNeedsLayout()
        // ⚠️ 量坐标之前必须先走这一步：刚改完文本，TextKit 只是记了「待会儿要重排」，此刻问它 fragment 在哪儿，答的是回车之前的旧坐标（详见 flushPendingTextKitLayout 的注释）
        flushPendingTextKitLayout()
        // 只重算视野附近那一圈：一次编辑改动的是改动点附近，屏幕外的块位置没变、沿用缓存即可。
        // 以前这里走的是整篇重算（还带最多 30 轮 60ms 重试），长文档上每敲一个字都要把全文重排一遍。
        updateCodeBlockDecorationsIfNeeded(nearViewportOnly: true)
        // 屏幕外那些块只是沿用了缓存，一次大改动（删掉一整段）会把它们平移一大截 ——
        // 等打字停下来补一次整篇重算校正掉
        scheduleDecorationSettle()
    }

    /// 真正用来改内容的 NSTextStorage
    /// 不开 `private`：折叠（`MarkdownTextView+Fold.swift`）替换那一节内容时也要用它。
    var backingStorage: NSTextStorage {
        if let contentStorage = textLayoutManager?.textContentManager as? NSTextStorageObserving,
           let storage = contentStorage.textStorage {
            return storage
        }
        return textStorage
    }

    /// 一次从 NSString 里取多少个字符来比（见下面两条的注释）
    private static let diffChunkSize = 1024

    /// 求两个字符串的公共前缀长度（按 UTF-16 单元算）
    ///
    /// ### 为什么要分批取，而不是 `character(at:)` 一个一个数
    /// 在长文档**尾部**打字时，前缀要一路匹配到改动点才停 —— 一篇 10 万字符的文档在末尾敲一个字，就是 10 万次 `character(at:)`（每次都是一次 ObjC 消息派发），而每敲一个字都要付一遍。
    /// 改成「一次取一批（1024 个 unichar）再在数组里比」，循环次数降到 1/1024，语义完全不变。
    private static func commonPrefixLength(_ a: NSString, _ b: NSString) -> Int {
        let max = min(a.length, b.length)
        var index = 0
        var bufferA = [unichar](repeating: 0, count: diffChunkSize)
        var bufferB = [unichar](repeating: 0, count: diffChunkSize)

        while index < max {
            let chunk = min(diffChunkSize, max - index)
            a.getCharacters(&bufferA, range: NSRange(location: index, length: chunk))
            b.getCharacters(&bufferB, range: NSRange(location: index, length: chunk))

            var matched = 0
            while matched < chunk, bufferA[matched] == bufferB[matched] { matched += 1 }
            index += matched
            // 这一批里出现了第一个不同的字符：前缀到此为止
            if matched < chunk { break }
        }
        return index
    }

    /// 求两个字符串的公共后缀长度（从尾部往前比，按 UTF-16 单元算），最长不超过 `maxSuffix`。
    ///
    /// 分批取的理由同 `commonPrefixLength`：在长文档**开头**编辑时，后缀会一路匹配到文档头。
    private static func commonSuffixLength(_ a: NSString, _ b: NSString, maxSuffix: Int) -> Int {
        guard maxSuffix > 0 else { return 0 }

        var suffix = 0
        var bufferA = [unichar](repeating: 0, count: diffChunkSize)
        var bufferB = [unichar](repeating: 0, count: diffChunkSize)

        while suffix < maxSuffix {
            let chunk = min(diffChunkSize, maxSuffix - suffix)
            a.getCharacters(&bufferA, range: NSRange(location: a.length - suffix - chunk, length: chunk))
            b.getCharacters(&bufferB, range: NSRange(location: b.length - suffix - chunk, length: chunk))

            var matched = 0
            while matched < chunk, bufferA[chunk - 1 - matched] == bufferB[chunk - 1 - matched] { matched += 1 }
            suffix += matched
            if matched < chunk { break }
        }
        return suffix
    }

    // 剪贴板 / 撤销记账已挪到 `MarkdownTextView+Clipboard.swift` 与 `MarkdownTextView+UndoSupport.swift`。

    // MARK: - 键盘快捷键（markdown 语法）

    /// 快捷键清单。真正去改源码的那些方法在 `MarkdownTextView+Formatting.swift`。
    ///
    /// ### 为什么挂在 textView 上，而不是挂在内容页（ViewController）
    /// 这些快捷键改的是**编辑器里的文字**：编辑器自己就够得着源码、光标和渲染管线，
    /// 挂在外面反而要内容页反过来问它「你现在选了什么」。挂在这里还有个好处 ——
    /// 这个组件被别的项目拿去用时，这套快捷键是自带的。
    ///
    /// ⚠️ 要带上 `super.keyCommands`：UITextView 自己也可能挂了一批快捷键，
    /// 只返回自己的数组会把系统那批挤掉。
    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + Self.markdownKeyCommands
    }

    /// ⌘B 在 UITextView 里的默认动作是「给富文本加粗」—— 改的是渲染属性，不是 markdown 源码。
    ///
    /// markdown 的粗体是源码里的 `**`，所以这里把它接过来（系统的 Edit 菜单、
    /// 富文本快捷键那条路也会走到这儿），改成往源码里插 `**`。
    override func toggleBoldface(_ sender: Any?) { toggleBoldMarkdown() }
    /// 同 `toggleBoldface`：⌘I → `*斜体*`
    override func toggleItalics(_ sender: Any?) { toggleItalicMarkdown() }
    /// 同 `toggleBoldface`：⌘U → `<u>下划线</u>`
    override func toggleUnderline(_ sender: Any?) { toggleUnderlineMarkdown() }

    /// ⌥↑ / ⌥↓ 的**兜底**：`UIKeyCommand` 那条路万一没接住，这里再拦一道。
    ///
    /// ### 为什么还要兜一层
    /// `markdownKeyCommands` 里那两条已经开了 `wantsPriorityOverSystemBehavior`（理由写在那儿）。
    /// 但「系统把 ⌥↑ 当成文本编辑命令」这件事发生的位置比 `UIKeyCommand` 更早，不同 macOS 版本上这个开关的生效范围也不一样 —— 万一它没兜住，用户看到的就是「按了没反应」。
    /// `pressesBegan` 是按键真正落到响应者手里的那一站，比它更早的只有 AppKit 那一层（Catalyst 里 `NSEvent` 编译期不可见，要拿只能运行时按名字找，代价大得多）。
    ///
    /// ### 为什么「搬成了才吞」
    /// 搬不动（已经在首行 / 只读）时照样调 `super`，把按键还给系统 —— 用户按下去至少还有系统那套「跳到上一段」，而不是一个死键。
    ///
    /// ⚠️ 只会少走一次 `super`，不会重复搬：`UIKeyCommand` 命中时 UIKit 根本不会把这次按键往下派发，所以两条路是「谁先接住算谁的」，不会各搬一次。
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key, performMoveLineIfMatched(key) else { continue }
            return
        }
        super.pressesBegan(presses, with: event)
    }

    // MARK: - MarkdownAttachmentHost

    /// 图片异步加载完尺寸变了，通知 TextKit 重新排版这一个小范围
    func invalidateLayout(for attachment: NSTextAttachment) {
        var found: NSRange?
        let full = NSRange(location: 0, length: backingStorage.length)
        backingStorage.enumerateAttribute(.attachment, in: full, options: []) { value, range, stop in
            guard let candidate = value as? NSTextAttachment else { return }
            if candidate === attachment {
                found = range
                stop.pointee = true
            }
        }
        guard let range = found else { return }
        invalidateLayout(forRenderedRange: range)
    }

    private func invalidateLayout(forRenderedRange range: NSRange) {
        guard let layoutManager = textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage else { return }

        // NSTextContentStorage 的 location 是「textStorage 里的 UTF-16 偏移」，
        // 和 NSRange.location 是同一套坐标，所以可以直接用 range.location 去偏移。
        // 注意 documentRange.location 不是可选值，别写 guard let。
        let documentStart = contentStorage.documentRange.location
        guard let start = contentStorage.location(documentStart, offsetBy: range.location),
              let end = contentStorage.location(start, offsetBy: max(1, range.length)),
              let textRange = NSTextRange(location: start, end: end) else { return }

        layoutManager.invalidateLayout(for: textRange)
    }

    // 导出长图已挪到 `MarkdownTextView+Export.swift`。
}

// MARK: - 手势共存

extension MarkdownTextView: UIGestureRecognizerDelegate {

    /// 我们那个「认图片」的点击手势要和系统自己的手势**同时**生效。
    ///
    /// 不写这个的话，UITextView 内部的手势（放光标、选中、长按菜单…）会把我们这个
    /// 手势挤掉，结果是「点了图片没反应 —— 但偶尔滚一下又能弹出来」，非常难查。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer)
        -> Bool {
        true
    }
}
