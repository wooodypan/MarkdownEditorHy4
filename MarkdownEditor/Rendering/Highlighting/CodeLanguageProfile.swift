//
//  CodeLanguageProfile.swift
//  MarkdownEditorHy4
//
//  每种语言的「高亮规则表」：注释怎么开头、字符串有几种写法、哪些词是关键字
//

import Foundation

/// 一门语言的词法规则。
///
/// ### 为什么要用「表驱动」而不是给每种语言写一个函数
/// 扫描逻辑（`SimpleCodeHighlighter`）只有一份，各语言的差别全落在这张表的数据上。
/// 以后加一门语言，只要在这里加一个 `static let`，不用碰扫描器。
///
/// ### 精度取舍
/// 这是**给眼睛看的高亮**，不是给编译器看的。所有不好判、或者判错也无所谓的地方
/// 一律取最省事的写法（比如模板字符串里的 `${}` 不单独着色），详见各处注释。
struct CodeLanguageProfile {
    /// 行注释的开头字符序列：`["#"]`（Python）或 `["/", "/"]`（JS / Swift）。
    /// 空数组 = 这门语言没有行注释。
    var lineComment: [Unicode.Scalar]
    /// 支不支持 `/* … */`。
    ///
    /// ⚠️ 刻意**不处理嵌套**（Swift 的 `/* 外层 /* 内层 */ */` 是合法的）：
    /// 嵌套要多跑一层计数器，而嵌套块注释在真实代码里极少见，
    /// 收尾早一点也只是变色，不影响编辑。
    var supportsBlockComment: Bool
    /// 字符串前缀允许的字母（Python 的 `r""` / `f''` / `b"""`）。空 = 不支持前缀。
    var stringPrefixes: [Unicode.Scalar]
    /// 支不支持三引号跨行字符串（`"""` / `'''`）
    var supportsTripleQuotes: Bool
    /// 支不支持反引号模板字符串（JavaScript）
    var supportsTemplateLiteral: Bool
    /// `0x` / `0b` / `0o` 这种进制前缀里，第二位允许什么字符
    var radixPrefixes: [Unicode.Scalar]
    /// 要不要把「大写字母开头的标识符」当类型名上色
    var treatsCapitalizedAsType: Bool
    /// 关键字
    var keywords: Set<String>
    /// 字面量常量（`true` / `nil` / `None` …），按数字那个色上
    var literals: Set<String>

    // MARK: 按名字取表

    /// 围栏后面写的语言标识 → 规则表。取不到（不支持的语言）返回 nil，调用方走纯文本渲染。
    ///
    /// 参数先 `lowercased()`，` ```Swift ` 和 ` ```swift ` 都能命中。
    static func profile(forLanguage language: String) -> CodeLanguageProfile? {
        switch language.lowercased() {
        case "js", "javascript": return .javaScript
        case "python", "py": return .python
        case "swift": return .swift
        default: return nil
        }
    }

    /// 把字符串字面量摊平成标量表 —— 表在 static 里只会建一次，扫描时不用再拆
    private static func scalars(_ text: String) -> [Unicode.Scalar] {
        Array(text.unicodeScalars)
    }

    private static func words(_ text: String) -> Set<String> {
        Set(text.split(separator: " ").map(String.init))
    }

    // MARK: JavaScript

    static let javaScript = CodeLanguageProfile(
        lineComment: scalars("//"),
        supportsBlockComment: true,
        stringPrefixes: [],
        supportsTripleQuotes: false,
        supportsTemplateLiteral: true,
        radixPrefixes: scalars("xXbBoO"),
        treatsCapitalizedAsType: true,
        keywords: Self.words("""
        async await break case catch class const continue debugger default delete do else \
        export extends finally for from function get if implements import in instanceof let new of \
        return set static super switch this throw try typeof var void while with yield enum package \
        private protected public interface arguments eval yield
        """),
        literals: Self.words("true false null undefined NaN Infinity NaN")
    )

    // MARK: Python

    static let python = CodeLanguageProfile(
        lineComment: scalars("#"),
        supportsBlockComment: false,
        stringPrefixes: scalars("rbfuRBFU"),
        supportsTripleQuotes: true,
        supportsTemplateLiteral: false,
        radixPrefixes: scalars("xXbBoO"),
        treatsCapitalizedAsType: true,
        keywords: Self.words("""
        and as assert async await break class continue def del elif else except finally for from \
        global if import in is lambda nonlocal not or pass raise return try while with yield match case
        """),
        literals: Self.words("True False None self cls NotImplemented Ellipsis")
    )

    // MARK: Swift

    static let swift = CodeLanguageProfile(
        lineComment: scalars("//"),
        supportsBlockComment: true,
        stringPrefixes: [],
        supportsTripleQuotes: true,
        supportsTemplateLiteral: false,
        radixPrefixes: scalars("xXbBoO"),
        treatsCapitalizedAsType: true,
        keywords: Self.words("""
        as associatedtype break case catch class continue convenience default defer deinit didSet do \
        else enum extension fallthrough fileprivate final for func get guard if import in indirect \
        infix init inout internal is lazy let mutating nonmutating open operator override postfix \
        precedence prefix private protocol public repeat required rethrows return set some any static \
        struct subscript super switch self throws throw try typealias unowned var weak where while \
        willSet actor async await nonisolated isolated
        """),
        literals: Self.words("true false nil")
    )
}
