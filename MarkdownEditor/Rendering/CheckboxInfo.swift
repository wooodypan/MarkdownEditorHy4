//
//  CheckboxInfo.swift
//  MarkdownEditorHy4
//
//  任务列表项里 `[x]` / `[ ]` 的信息载体：渲染时挂在这三个字符上，
//  UI 层扫出来后在旁边（或上面）放一个原生的复选框按钮
//

import UIKit

/// 一个任务列表复选框的信息。
///
/// ### 它怎么流转
/// 1. `MarkupToAttributedRenderer.renderListItem` 渲染列表项时，把本对象作为**自定义属性**
///    挂在 `[x]` / `[ ]` 这三个字符上（这三个字符是源码提示文字的一部分，本来就显示着）；
/// 2. `MarkdownTextView` 扫描 textStorage 找出这些区间，用 TextKit 算出它们占的矩形；
/// 3. 在矩形旁边铺一个原生 `UIButton`（复选框），点一下把源码里的 `[x]` 换成 `[ ]`（或反过来）。
///
/// ### 为什么不按数组下标定位要改哪一行
/// 增量渲染、折叠都可能让列表项挪位置。这里存的是 **`[` 在整篇源码里的偏移**，
/// 点的时候按源码位置算回渲染位置，永远指得准。
final class CheckboxInfo: NSObject {
    /// `[` 在**整篇源码**里的 UTF-16 偏移（三个字符 `[`、`x`/空格、`]` 的起点）
    let sourceStart: Int
    /// 当前是不是勾选状态（`[x]` / `[X]` 为 true，`[ ]` 为 false）
    let isChecked: Bool

    init(sourceStart: Int, isChecked: Bool) {
        self.sourceStart = sourceStart
        self.isChecked = isChecked
        super.init()
    }

    /// 原因见 `MarkdownBlock` 里 `nonisolated deinit` 的注释：
    /// 隔离 deinit 一旦嵌套就会踩 Swift 6.2 运行时的野指针 free。
    nonisolated deinit {}

    // MARK: 相等性

    /// 按**对象地址**比较：同一个复选框才是同一段，
    /// 两个内容一样的 `[ ]` 也必须是两个独立的按钮（同 `CodeBlockInfo` 的做法）。
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? CheckboxInfo else { return false }
        return other === self
    }

    override var hash: Int { ObjectIdentifier(self).hashValue }
}

extension NSAttributedString.Key {
    /// 标记「这三个字符是一个任务列表的 `[x]` / `[ ]`」的自定义属性，值类型是 `CheckboxInfo`。
    static let markdownCheckbox = NSAttributedString.Key("com.markdowneditor.checkbox")
}
