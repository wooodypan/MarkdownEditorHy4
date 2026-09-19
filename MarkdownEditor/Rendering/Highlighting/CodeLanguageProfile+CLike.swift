//
//  CodeLanguageProfile+CLike.swift
//  MarkdownEditorHy4
//
//  C 系语言的规则表：C / C++ / Objective-C / Java / C#
//
//  这一票语言的「长相」是一样的，所以放在一个文件里对照着看：
//  `//` 行注释 + `/* */` 块注释 + `#` 开头的预处理指令 + `0x` / `0b` / `0o` 进制前缀。
//  真正有差别的地方都写了注释（比如 Objective-C 的 `@interface`、C# 的 `$"…"`）。
//

import Foundation

extension CodeLanguageProfile {

    // MARK: C

    /// C（C89 / C99 / C11）。
    ///
    /// ⚠️ 「类型」和「关键字」分两张表，是有意的：`int` / `void` 用类型色（青），`if` / `return` 用关键字色（紫），屏幕上更好认。C 里没有真正的「类型关键字」（`int` 严格说是关键字），但按类型上色明显更符合大家对代码的直觉。
    static let c = CodeLanguageProfile(
        lineComments: scalarSequences("//"),
        supportsBlockComment: true,
        preprocessorPrefix: "#",
        radixPrefixes: scalars("xXbB"),
        keywords: words("""
        _Alignas _Alignof _Atomic _Bool _Complex _Generic _Imaginary _Noreturn _Static_assert _Thread_local \
        asm auto break case const continue default do else enum extern for goto if inline register restrict \
        return sizeof static struct switch typedef union volatile while
        """),
        // `size_t` / `int32_t` 这些严格说是 typedef 来的，不是关键字 —— 但按类型上色才对眼睛友好
        typeKeywords: words("""
        bool char double float int int8_t int16_t int32_t int64_t long ptrdiff_t short signed size_t \
        ssize_t uint8_t uint16_t uint32_t uint64_t unsigned void
        """),
        literals: words("NULL true false")
    )

    // MARK: C++

    /// C++（含 C++11 / 14 / 17 / 20 常用的一批）。
    ///
    /// ⚠️ `true` / `false` / `nullptr` 刻意**不放在关键字表里**，而是放进字面量表 —— 它们和数字是一类东西，按数字色上更好认，也避免两张表出现重复项。
    static let cpp = CodeLanguageProfile(
        lineComments: scalarSequences("//"),
        supportsBlockComment: true,
        preprocessorPrefix: "#",
        radixPrefixes: scalars("xXbB"),
        keywords: words("""
        alignas alignof and and_eq asm auto bitand bitor break case catch class compl concept const \
        const_cast consteval constexpr constinit continue co_await co_return co_yield decltype default \
        delete do dynamic_cast else enum explicit export extern for friend goto if inline mutable namespace \
        new noexcept not not_eq operator or or_eq override private protected public register \
        reinterpret_cast requires return sizeof static static_assert static_cast struct switch template this \
        thread_local throw try typedef typeid typename union using virtual volatile while xor xor_eq
        """),
        typeKeywords: words("""
        bool char char8_t char16_t char32_t double float int int8_t int16_t int32_t int64_t long ptrdiff_t \
        short signed size_t ssize_t uint8_t uint16_t uint32_t uint64_t unsigned void wchar_t
        """),
        literals: words("NULL true false nullptr")
    )

    // MARK: Objective-C

    /// Objective-C。
    ///
    /// ### 两个特别的地方
    /// 1. `@interface` / `@property` / `@end` 这些带 `@` 的词整词放进关键字表 —— 扫描器会把 `@` 和后面的标识符连起来查表（见 `supportsAtPrefix`）；
    /// 2. `@"字符串"` 是 Objective-C 才有的字面量，`@` 也要算字符串的一部分，否则屏幕上会孤零零留一个 `@`。
    static let objectiveC = CodeLanguageProfile(
        lineComments: scalarSequences("//"),
        supportsBlockComment: true,
        preprocessorPrefix: "#",
        supportsAtPrefix: true,
        radixPrefixes: scalars("xXbB"),
        keywords: words("""
        asm auto break case const continue default do else enum extern for goto if inline register return \
        sizeof static struct switch typedef union volatile while \
        @autoreleasepool @available @catch @class @defs @dynamic @encode @end @finally @implementation \
        @import @interface @optional @package @private @property @protected @protocol @public @required \
        @selector @synchronize @synthesize @throw @try
        """),
        // `id` / `instancetype` 是小写的类型名（大写的那批 `NSString` / `BOOL` 靠「大写开头当类型」那条规则自动认出来）
        typeKeywords: words("""
        char double float id instancetype int long short signed size_t unsigned void
        """),
        literals: words("nil Nil NULL YES NO self super true false")
    )

    // MARK: Java

    /// Java（含 Java 8 之后陆续加的 `var` / `record` / `sealed` / `yield`）。
    ///
    /// `@Override` / `@Nullable` 这类**注解**走的是「`@` + 标识符」那条路：不在关键字表里，会被当作类型名上类型色。注解本来就跟类型是一类东西，这个落点是对的。
    static let java = CodeLanguageProfile(
        lineComments: scalarSequences("//"),
        supportsBlockComment: true,
        supportsAtPrefix: true,
        supportsTripleQuotes: true,
        radixPrefixes: scalars("xXbB"),
        keywords: words("""
        abstract assert break case catch class const continue default do else enum extends final finally for \
        goto if implements import instanceof interface native new package permits private protected public \
        record return sealed static strictfp super switch synchronized this throw throws transient try \
        volatile while yield
        """),
        typeKeywords: words("""
        boolean byte char double float int long short var void
        """),
        literals: words("true false null")
    )

    // MARK: C#

    /// C#。
    ///
    /// ### 两个特别的地方
    /// 1. `$"…"` 是插值字符串、`@"…"` 是逐字字符串，两种前缀都要能连着字符串一起上色；
    /// 2. `#region` / `#if` 也是预处理指令，和 C 系共用同一套处理。
    static let cSharp = CodeLanguageProfile(
        lineComments: scalarSequences("//"),
        supportsBlockComment: true,
        preprocessorPrefix: "#",
        supportsAtPrefix: true,
        stringPrefixes: scalars("$"),
        supportsTripleQuotes: true,
        radixPrefixes: scalars("xXbB"),
        keywords: words("""
        abstract as async await base break case catch checked class const continue default delegate do else \
        event explicit extern finally fixed for foreach get goto if implicit in interface internal is lock \
        namespace new operator out override params partial private protected public readonly ref required \
        return sealed set sizeof stackalloc static struct switch this throw try typeof unchecked unsafe \
        using value virtual volatile when where while with yield
        """),
        typeKeywords: words("""
        bool byte char decimal double dynamic float int long nint nuint object sbyte short string uint ulong \
        ushort var void
        """),
        literals: words("true false null")
    )
}
