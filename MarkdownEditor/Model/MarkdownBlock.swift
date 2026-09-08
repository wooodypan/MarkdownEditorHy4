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
