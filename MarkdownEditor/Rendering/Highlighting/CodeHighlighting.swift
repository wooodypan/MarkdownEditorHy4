//
//  CodeHighlighting.swift
//  MarkdownEditorHy4
//
//  代码高亮的抽象接口：只描述「要什么」，不规定「怎么算」
//

import Foundation

/// 代码高亮器协议。
///
/// ### 为什么要这层协议
/// `MarkupToAttributedRenderer` 只依赖这一个抽象类型，**不认识任何具体的高亮实现**
/// （不 import Tree-sitter / Splash / Highlightr / 任何第三方库）。
/// 想换成别的方案（tree-sitter 精确解析也好、公司内部的也好），
/// 只要写一个遵循本协议的类型塞给 `renderer.codeHighlighter` 就行，
/// 渲染管线和 UI 层一行都不用改。
///
/// ### 为什么 `highlight` 返回 `[HighlightToken]` 而不是 `NSAttributedString`
/// 让高亮器直接产出富文本看起来省事，但那样「代码该长什么颜色」这个决定权
/// 就下放到了高亮库手里 —— 换一个库整套配色就变了，**违背「样式统一由 MarkdownTheme 管」**。
/// 所以这里只让高亮器回答「哪段字符是什么角色」，上色那一步始终在渲染器里用主题完成。
///
/// ### 暂时没做「增量高亮」
/// 方案文档里设计过 `highlightIncrementally(edit:previousState:)`。我们当前的实现是纯手写扫描，整块扫一遍本来就是微秒级（1.9 万字符实测约 6 毫秒），引入 Tree-sitter 的 `Tree` 状态反而要额外内存和生命周期管理 —— 收益不够，先不做。等真的接入解析器型实现时再往协议里加那一条即可。
///
/// ### 支持哪些语言
/// 由具体实现说了算（`SimpleCodeHighlighter` 认 `CodeLanguageProfile` 里列的那一票）。渲染器只问 `supportsLanguage`，不认识就按纯文本显示，不会出错。
protocol CodeHighlighting {
    /// 支不支持某种语言（参数就是 ``` 围栏后面写的那个词，大小写随便）
    func supportsLanguage(_ language: String) -> Bool

    /// 把一段代码切成若干「带角色的区间」。
    ///
    /// 纯函数：同样的输入必须给同样的输出，内部不要留可变状态
    /// （渲染可能被并发重入，无状态最省心）。
    ///
    /// - parameter code:     代码正文（**不含**首尾的 ``` 围栏行）
    /// - parameter language: 语言标识
    /// - returns: 只返回「需要上色」的片段。普通标识符、运算符一概不返回 ——
    ///            少了这些 token，后面给富文本挂属性的次数也跟着少很多
    func highlight(_ code: String, language: String) -> [HighlightToken]
}
