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
/// 扫描逻辑（`SimpleCodeHighlighter`）只有一份，各语言的差别全落在这张表的数据上。以后加一门语言，只要加一个 `static let`（表按语系放在 `CodeLanguageProfile+CLike.swift` 和 `CodeLanguageProfile+Scripts.swift` 里），扫描器一行都不用碰。
///
/// ### 字段大多数都带默认值
/// 默认值取的是「大多数语言都这样」的那个值（`//` 行注释、支持 `/* */`、认 `0x` 进制前缀、大写开头当类型名…）。所以每张表只用写出**和默认值不一样**的那几项，一眼扫过去就知道这门语言特别在哪。
///
/// ### 精度取舍
/// 这是**给眼睛看的高亮**，不是给编译器看的。所有不好判、或者判错也无所谓的地方一律取最省事的写法（比如模板字符串里的 `${}` 不单独着色），详见各处注释。
struct CodeLanguageProfile {
    /// 行注释的开头字符序列，**可以有好几种**：`["//"]`（C 系）、`["--"]`（SQL）、`["//", "#"]`（PHP 两种都认）。空数组 = 这门语言没有行注释（比如 JSON）。
    var lineComments: [[Unicode.Scalar]] = []
    /// 支不支持 `/* … */`。
    ///
    /// ⚠️ 刻意**不处理嵌套**（Swift 的 `/* 外层 /* 内层 */ */` 是合法的）：嵌套要多跑一层计数器，而嵌套块注释在真实代码里极少见，收尾早一点也只是变色，不影响编辑。
    var supportsBlockComment: Bool = false
    /// 预处理指令的引导符（C 系的 `#include`、C# 的 `#region`）。
    ///
    /// 只有出现在**行首**（前面允许有空白）才当指令 —— 别处的它另有含义（比如 SQL Server 的临时表名 `#temp`）。`nil` = 这门语言没有预处理指令。
    var preprocessorPrefix: Unicode.Scalar?
    /// 认不认 `@` 开头的词：Objective-C 的 `@interface`、Java / Kotlin 的 `@Override`、Swift 的 `@State`、C# 的 `@"..."`。
    ///
    /// 打开之后：`@` + 标识符 → 在关键字表里就当关键字，不在就当类型名；`@"…"` → 连着 `@` 一起算字符串（Objective-C 的字符串字面量就长这样）。
    var supportsAtPrefix: Bool = false
    /// 字符串前缀允许的字母（Python 的 `r""` / `f''`、Rust 的 `b"…"`、C# 的 `$"…"`）。空 = 不支持前缀。
    var stringPrefixes: [Unicode.Scalar] = []
    /// 认不认单引号字符串（`'abc'`）。
    ///
    /// 现在只有 Rust 关掉它 —— Rust 里单引号更多是**生命周期标记**（`&'a str`），当成字符串扫会把后面半行都染红。
    var supportsSingleQuotedString: Bool = true
    /// 支不支持三引号跨行字符串（Python / Swift / Kotlin / Java 15+ 的 `"""`）
    var supportsTripleQuotes: Bool = false
    /// 支不支持反引号字符串：JavaScript 的模板字符串、Go 的原始字符串。这类字符串**可以跨行**，一直扫到收尾的反引号为止。
    var supportsBacktickString: Bool = false
    /// `0x` / `0b` / `0o` 这种进制前缀里，第二位允许什么字符。空 = 这门语言不认这类字面量。
    var radixPrefixes: [Unicode.Scalar] = []
    /// 要不要把「大写字母开头的标识符」当类型名上色。
    ///
    /// 大多数语言这么判是准的（类名都大写开头）；Go 是例外 —— 它的大写开头表示「导出」，不是类型，所以那门语言关掉。
    var treatsCapitalizedAsType: Bool = true
    /// 关键字 / 类型名 / 字面量要不要**不分大小写**地匹配（SQL 是这一类：`SELECT` 和 `select` 一样）。
    ///
    /// ⚠️ 打开之后，每个「原样没命中」的词都要多做一次小写转换（一次短字符串分配）。现在只有 SQL 开着，别的语言零成本。
    var isCaseInsensitive: Bool = false
    /// 关键字
    var keywords: Set<String> = []
    /// 可以当「类型」看的词：`int` / `void` 这类。
    ///
    /// 单独列一张表是为了让它们用**类型色**而不是关键字色，看着更清爽。大写开头的类型名（`NSString` / `List`）不用写在这里，扫描器会自动认出来。
    var typeKeywords: Set<String> = []
    /// 字面量常量（`true` / `nil` / `None` …），按数字那个色上
    var literals: Set<String> = []

    // MARK: 按名字取表

    /// 围栏后面写的语言标识 → 规则表。取不到（不认识的语言）返回 nil，调用方按纯文本渲染。
    ///
    /// ### 为什么要收这么多别名
    /// 同一个语言，围栏里写什么的都有：```C++```、```cpp```、```cxx``` 是同一门语言，`objc` 和 `objective-c` 也一样。用户不该为了「颜色对上」去猜该写哪个词，所以能想到的写法都收进来。大小写也随便（先 `lowercased()` 再查）。
    ///
    /// ⚠️ HTML / CSS / YAML 这些**刻意没做**：它们的结构和这里「按字符一趟扫过去」的做法不搭（HTML 要认标签和属性、YAML 靠缩进定层级），硬套只会得到满屏乱色，不如老实按纯文本显示。
    static func profile(forLanguage language: String) -> CodeLanguageProfile? {
        switch language.lowercased() {
        // —— 脚本 / 动态语言 ——
        case "js", "javascript", "mjs", "cjs", "node": return .javaScript
        case "ts", "typescript": return .typeScript
        case "python", "py", "python3": return .python
        case "ruby", "rb": return .ruby
        case "php": return .php
        case "sh", "shell", "bash", "zsh", "console", "terminal": return .shell
        // —— C 系 ——
        case "c", "h": return .c
        case "cpp", "c++", "cxx", "cc", "hpp", "hxx", "h++": return .cpp
        case "objective-c", "objectivec", "objc", "obj-c", "m", "mm": return .objectiveC
        case "java": return .java
        case "csharp", "c#", "cs": return .cSharp
        case "kotlin", "kt", "kts": return .kotlin
        case "go", "golang": return .go
        case "rust", "rs": return .rust
        case "swift": return .swift
        // —— 查询 / 数据格式 ——
        case "sql", "mysql", "postgresql", "postgres", "sqlite", "tsql", "plsql": return .sql
        case "json": return .json
        case "jsonc": return .jsonWithComments
        default: return nil
        }
    }

    // MARK: 写表用的助手

    /// 把字符串摊平成标量表。表在 `static` 里只会建一次，扫描时不用再拆。
    static func scalars(_ text: String) -> [Unicode.Scalar] {
        Array(text.unicodeScalars)
    }

    /// 一次摊平好几个字符串 —— `["//", "#"]` 这种多前缀写法（一门语言认两种行注释）用得上。
    static func scalarSequences(_ texts: String...) -> [[Unicode.Scalar]] {
        texts.map { Array($0.unicodeScalars) }
    }

    /// 空格分隔的词表 → 集合。用 `\` 续行的多行字符串写法，写表时不用关心换行。
    static func words(_ text: String) -> Set<String> {
        Set(text.split(separator: " ").map(String.init))
    }

    // MARK: JavaScript / TypeScript

    static let javaScript = CodeLanguageProfile(
        lineComments: scalarSequences("//"),
        supportsBlockComment: true,
        supportsBacktickString: true,
        radixPrefixes: scalars("xXbBoO"),
        keywords: words("""
        arguments async await break case catch class const continue debugger default delete do else enum \
        eval export extends finally for from function get if implements import in instanceof interface let \
        new of package private protected public return set static super switch this throw try typeof var \
        void while with yield
        """),
        literals: words("true false null undefined NaN Infinity")
    )

    /// TypeScript = JavaScript 的关键字 + 类型系统那一套。
    ///
    /// ⚠️ `void` 只写在类型表里（`function f(): void` 里的它就是个类型），别在关键字表里重复写 —— 两个表都不该有重复项，测试里有一条专门体检这个。
    static let typeScript = CodeLanguageProfile(
        lineComments: scalarSequences("//"),
        supportsBlockComment: true,
        supportsBacktickString: true,
        radixPrefixes: scalars("xXbBoO"),
        keywords: words("""
        abstract as asserts async await break case catch class const continue declare default delete do \
        else enum export extends finally for from function get if implements import in infer instanceof \
        interface is keyof let module namespace new of override readonly return satisfies set static \
        super switch this throw try type typeof var while with yield
        """),
        typeKeywords: words("any bigint boolean never number object string symbol unknown"),
        literals: words("true false null undefined NaN Infinity")
    )

    // MARK: Python

    static let python = CodeLanguageProfile(
        lineComments: scalarSequences("#"),
        stringPrefixes: scalars("rbfuRBFU"),
        supportsTripleQuotes: true,
        radixPrefixes: scalars("xXbBoO"),
        keywords: words("""
        and as assert async await break class continue def del elif else except finally for from global if \
        import in is lambda match case nonlocal not or pass raise return try while with yield
        """),
        literals: words("True False None self cls NotImplemented Ellipsis")
    )

    // MARK: Swift

    static let swift = CodeLanguageProfile(
        lineComments: scalarSequences("//"),
        supportsBlockComment: true,
        supportsAtPrefix: true,
        supportsTripleQuotes: true,
        radixPrefixes: scalars("xXbBoO"),
        keywords: words("""
        actor any as associatedtype async await break case catch class continue convenience default defer \
        deinit didSet do else enum extension fallthrough fileprivate final for func get guard if import in \
        indirect infix init inout internal is isolated lazy let mutating nonisolated nonmutating open \
        operator override postfix precedence prefix private protocol public repeat required rethrows return \
        self set some static struct subscript super switch throw throws try typealias unowned var weak where \
        while willSet
        """),
        literals: words("true false nil")
    )
}
