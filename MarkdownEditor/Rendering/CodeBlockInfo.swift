//
//  CodeBlockInfo.swift
//  MarkdownEditorHy4
//
//  代码块的信息载体：渲染时挂在字符上，UI 层扫出来画背景矩形和复制按钮
//

import UIKit

/// 一个「围栏代码块」（``` 包起来的那种）的信息。
///
/// ### 它怎么流转
/// 1. `MarkupToAttributedRenderer.visitCodeBlock` 渲染时，把本对象作为一个**自定义属性**
///    挂到代码块那一段字符上；
/// 2. `MarkdownTextView` 扫描 textStorage 找出这些区间，用 TextKit 算出它们占的矩形；
/// 3. 在矩形位置铺一个背景 view，右上角放复制按钮，点一下把 `code` 放进剪贴板。
///
/// ### 为什么用「自定义属性」而不是另建一份索引
/// 用属性挂在字符上，文本增删改时范围由 `NSTextStorage` 自动维护，
/// 不用自己同步一份「代码块位置表」——不会出现两套数据对不上的情况。
final class CodeBlockInfo: NSObject {
    /// 代码正文（**不含**首尾的 ``` 围栏）。复制按钮复制的就是它
    let code: String
    /// 围栏后面写的语言标识，比如 ```swift 里的 "swift"（没写就是 nil）
    let language: String?

    init(code: String, language: String?) {
        self.code = code
        self.language = language
        super.init()
    }

    /// 原因见 `MarkdownBlock` 里 `nonisolated deinit` 的注释：
    /// 隔离 deinit 一旦嵌套就会踩 Swift 6.2 运行时的野指针 free。
    nonisolated deinit {}

    // MARK: 相等性

    /// `NSAttributedString` 会把「相邻且值相等」的属性合并成一段，
    /// 合并时调的就是 `isEqual`。这里按**对象地址**比较：同一个代码块才是同一段，
    /// 两个内容一模一样的代码块也必须是两个独立矩形。
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? CodeBlockInfo else { return false }
        return other === self
    }

    override var hash: Int { ObjectIdentifier(self).hashValue }
}

extension NSAttributedString.Key {
    /// 标记「这段字符属于一个代码块」的自定义属性，值类型是 `CodeBlockInfo`。
    ///
    /// 用自定义 key 而不是系统 key，是因为它不参与真正的排版，
    /// 只是给 UI 层留的一个标记；渲染成纯文本（比如复制出去）时会被自动忽略。
    static let markdownCodeBlock = NSAttributedString.Key("com.markdowneditor.codeBlock")
}
