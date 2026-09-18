//
//  MarkdownBlock.swift
//  MarkdownEditorHy4
//
//  分块模型：一个顶层块（BlockMarkup）的完整状态
//

import UIKit
import Markdown

/// 渲染结果里「一个字符位」对应源码里的哪一段。
///
/// 这是整个编辑器最关键的一张小表：**富文本层看到的东西** 和 **复制出去的东西** 靠它解耦。
///
/// ### 本编辑器的核心约定（改动前先读这段）
/// **展示的一定是源码本身**。图片、列表圆点这类「复杂节点」只是在源码**旁边额外挂一个视觉元素**，
/// 源码字符一个不少地留在文本流里。所以：
/// - 源码 `![a](b.png)` 这 17 个字符 → 17 条真实映射，逐字符对得上；
/// - 图片那一个字符位 → `isAttachmentView = true`，是**额外挂上去**的，
///   复制时它能吐出整段源码（方便只选中图片复制），但光标不会停在上面。
///
/// 三种情况：
/// 1. `sourceStart >= 0, sourceLength == 1`：普通字符，渲染出的第 i 个字符就是源码第 sourceStart 个字符。
/// 2. `sourceStart >= 0, sourceLength >  1`：一个占位符吃掉了多字符源码（`isAttachmentView` 为 true 的那种）。
/// 3. `sourceStart < 0`：纯装饰（源码里根本没有对应字符），复制时直接跳过。
struct CharMapping {
    var sourceStart: Int
    var sourceLength: Int
    /// 这个字符位是「额外挂上去的视觉元素」而不是真正的文本（图片、列表圆点…）。
    /// 它对应的源码由**旁边那段源码文本**真实承载，所以：
    /// - 复制：照样能吐出整段源码（用户只选中图片时也能复制到 `![a](b.png)`）；
    /// - 光标：`renderedCaret` 会跳过它，光标落在真实文本上，绝不停在图片里。
    var isAttachmentView: Bool

    /// 纯装饰：不对应任何源码字符
    static let decoration = CharMapping(sourceStart: -1, sourceLength: 0, isAttachmentView: false)

    /// 普通源码字符
    static func source(start: Int, length: Int) -> CharMapping {
        CharMapping(sourceStart: start, sourceLength: length, isAttachmentView: false)
    }

    /// 附件的视觉占位（图片、圆点）：映射指向源码，但不作为光标落点
    static func attachmentView(start: Int, length: Int) -> CharMapping {
        CharMapping(sourceStart: start, sourceLength: max(1, length), isAttachmentView: true)
    }

    var isDecoration: Bool { sourceStart < 0 }
}

/// 一个顶层块的完整状态。
///
/// ### 块的切分约定（很重要）
/// 每个块的 `sourceText` **包含它自己后面一直到下一个块开头之间的所有内容**（也就是把结尾的换行、空行都吃掉）。
/// 这样所有块的 `sourceText` 首尾相接正好等于整篇源码，不需要额外的分隔符，渲染时直接拼接即可。
///
/// 例：源码 `"a\n\nb"` 切成两个块：`"a\n\n"` 和 `"b"`。
///
final class MarkdownBlock {
    let id: UUID

    /// 该块的 markdown 源码（含结尾换行/空行）
    var sourceText: String

    /// 该块源码在整篇文档中的范围（UTF-16 偏移）
    var sourceRange: NSRange

    /// 该块渲染结果在整篇 attributed string 中的范围（UTF-16 偏移）
    var renderedRange: NSRange

    /// 渲染出来的富文本
    var renderedContent: NSAttributedString

    /// `renderedContent` 里每个字符位对应的源码范围，长度恒等于 `renderedContent.length`
    var charMappings: [CharMapping]

    /// 调试用：这个块是什么语法类型
    var kindDescription: String

    /// 标题层级（1...6）。**不是标题块时为 nil**。
    ///
    /// ### 为什么要在块上留一份，而不是用时再解析
    /// 建块的时候 AST 就在手上（`makeBlock` 的 `ast` 参数），顺手取一次 `Heading.level`
    /// 是零成本的；要是等到画大纲时再回头解析源码，就得为一篇文档多跑一遍解析器。
    ///
    /// 大纲功能（`MarkdownDocumentStore.outlineItems`）读的就是这个字段。
    var headingLevel: Int?

    /// 标题的纯文本（已经去掉 `#`、`**`、`*` 这些语法符号），不是标题块时为 nil。
    ///
    /// 用的是 swift-markdown 内置的 `Heading.plainText`：它会递归拼出所有行内子节点的
    /// 纯文字，天然不带语法符号，不需要我们自己写文本清洗。
    var headingTitle: String?

    /// **只有标题块有这个状态**：这个标题下面那一节是不是被折叠了。
    ///
    /// ### 折叠的范围（按标题层级）
    /// 折叠 H2 时，隐藏的是「从这个 H2 之后，一直到下一个**同级或更高级**标题之前」
    /// 的所有内容 —— 也就是 H2 底下的正文、H3、H4 全部一起收起来。
    /// 展开时把这一节放出来，**里面各标题自己的折叠状态原样恢复**
    /// （之前折了 H3，展开 H2 之后 H3 仍然是折着的）。
    ///
    /// ### 这是**视图状态**，不是源码的一部分
    /// 折叠不会往源码里加任何字符，`sourceText` 一个字都没变，
    /// 所以「全选复制 === 源文件」在折叠状态下仍然成立
    /// （被隐藏的那些块由折叠标题后面那个「⋯」占位符一个字符位全部代表）。
    ///
    /// 块在编辑后会被重新创建（`buildBlocks` 生成新实例），折叠状态由
    /// `MarkdownDocumentStore` 按「源码起点 / 源码文本」匹配着继承下去。
    var isCollapsed: Bool = false

    /// 这个块是不是「某个已折叠标题的下属内容」（不参与渲染）。
    ///
    /// 折叠 H2 时，它下面直到下一个同级/更高级标题之间的**每个块**都会被标成 hidden：
    /// 渲染结果里一个字符都不出现（它们整段由折叠标题后面那个「⋯」占位符代表）。
    ///
    /// ⚠️ 块本身**仍然留在 `MarkdownDocumentStore.blocks` 里**，源码、映射、折叠状态全都在，
    /// 只是不进渲染结果 —— 目录大纲照样能列出里面的标题，展开时也能原样恢复。
    /// 这个字段由 `updateHiddenStates()` 统一算出来，不要在外面手改。
    var isHidden: Bool = false

    /// 当前的 `renderedContent` 是不是「隐藏态」（空字符串）。
    ///
    /// 用来判断「隐藏状态变了之后要不要重新渲染」：
    /// 隐藏 → 清空渲染内容（省内存、也免得坐标换算算到看不见的字符上）；
    /// 重新显示 → 从源码重新渲染一遍。`true` 时 `renderedContent` 是空的。
    var renderedAsHidden: Bool = false

    /// 当前的 `renderedContent` 是不是「折叠态」（标题文字 + 「⋯」占位符）。
    /// 和 `isCollapsed` 的区别：后者是**用户意图**，这是**渲染出来的实际样子**，
    /// 两者可能暂时不一致（比如在折叠状态下编辑了标题，要等下一次刷新才重画）。
    var renderedIsCollapsed: Bool = false

    /// 当前的 `renderedContent` 里有没有打折叠锚点（决定要不要重画）。
    ///
    /// ### 为什么需要它
    /// 「这个标题有没有三角」取决于它下面有没有内容，而这件事要等**所有块都建好**
    /// 才知道（`makeBlock` 建块时后面的块还没生成）。所以锚点是刷新阶段补打的，
    /// 用这个标记记住「现在这份渲染内容有没有打过」，避免每敲一个字都重画所有标题。
    var hasFoldAnchor: Bool = false

    /// ### 为什么这里要显式写 `nonisolated deinit`（很重要，别删）
    ///
    /// app target 开了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，
    /// 于是本文件里所有成员（连隐式的 deinit 也算）默认都跑在主线程上。
    /// 对「actor 隔离的 deinit」，Swift 运行时的处理是：释放时先切回 MainActor 执行器
    /// （`swift_task_deinitOnExecutorImpl`），而这个函数会维护一个 task-local 作用域
    /// （`swift::TaskLocal::StopLookupScope`）。
    ///
    /// 问题在于：**一旦出现「隔离对象里套着另一个隔离对象」的嵌套释放**，
    /// 就会有两层 `swift_task_deinitOnExecutorImpl` 叠在一起，
    /// 内层的 task-local 作用域析构时会 free 一个野指针，直接
    /// `malloc: pointer being freed was not allocated` 崩掉（Swift 6.2 运行时的坑）。
    /// 典型触发链：`MarkdownDocumentStore` 释放 → 释放 `MarkupToAttributedRenderer` → 崩。
    ///
    /// 这些类全都只是纯数据容器（字符串 / 数组 / 富文本），销毁时不需要任何主线程状态，
    /// 所以把 deinit 显式声明成 `nonisolated`，不走执行器切换，从根上避免嵌套。
    nonisolated deinit {}

    init(id: UUID = UUID(),
         sourceText: String,
         sourceRange: NSRange,
         renderedContent: NSAttributedString,
         charMappings: [CharMapping],
         kindDescription: String) {
        self.id = id
        self.sourceText = sourceText
        self.sourceRange = sourceRange
        self.renderedRange = NSRange(location: 0, length: 0)
        self.renderedContent = renderedContent
        self.charMappings = charMappings
        self.kindDescription = kindDescription
    }

    /// 渲染结果的长度，等于 `charMappings.count`
    var renderedLength: Int { renderedContent.length }

    /// 取渲染文本里第 `index` 个字符位的映射（越界时返回 nil）
    func mapping(at index: Int) -> CharMapping? {
        guard index >= 0, index < charMappings.count else { return nil }
        return charMappings[index]
    }
}

// MARK: - 描述输出（调试时看分块结果很方便）

extension MarkdownBlock: CustomStringConvertible {
    var description: String {
        let preview = sourceText.replacingOccurrences(of: "\n", with: "\\n")
        let shown = preview.count > 40 ? String(preview.prefix(40)) + "…" : preview
        return "<\(kindDescription) src=\(sourceRange) render=\(renderedRange) \"\(shown)\">"
    }
}

extension MarkdownBlock {
    /// 给任意 AST 节点起一个人类可读的名字，调试用
    static func describe(_ markup: Markup) -> String {
        String(describing: type(of: markup))
    }
}
