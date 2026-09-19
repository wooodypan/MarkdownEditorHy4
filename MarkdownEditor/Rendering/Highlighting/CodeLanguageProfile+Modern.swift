//
//  CodeLanguageProfile+Modern.swift
//  MarkdownEditorHy4
//
//  现代系统语言的规则表：Kotlin / Go / Rust
//
//  这三门都能归到「`//` 行注释 + `/* */` 块注释 + `0x` / `0b` / `0o` 进制前缀」这一路，
//  各自真正特别的地方（Go 的原始字符串、Rust 的生命周期标记…）都在下面写了注释。
//

import Foundation

extension CodeLanguageProfile {

    // MARK: Kotlin

    /// Kotlin。
    ///
    /// `Int` / `String` / `List` 这些类型名都是大写开头，「大写开头当类型」那条规则自动就认了，不用在表里重复列一遍。
    static let kotlin = CodeLanguageProfile(
        lineComments: scalarSequences("//"),
        supportsBlockComment: true,
        supportsAtPrefix: true,
        supportsTripleQuotes: true,
        radixPrefixes: scalars("xXbB"),
        keywords: words("""
        abstract actual annotation as break by catch class companion const constructor continue crossinline \
        data delegate do dynamic else enum expect external final finally for fun get if import in infix init \
        inline inner interface internal is lateinit noinline object open operator out override package \
        private protected public reified return sealed set super suspend tailrec this throw try typealias \
        val var vararg when where while
        """),
        literals: words("true false null")
    )

    // MARK: Go

    /// Go。
    ///
    /// ### ⚠️ 刻意关掉了「大写开头当类型」
    /// Go 里大写开头表示**导出**（包外可见），不是类型 —— `fmt.Println` / `http.Client` 这种调用满屏都是，全染成类型色会非常吵，所以关掉它，只认表里那些内置类型。
    static let go = CodeLanguageProfile(
        lineComments: scalarSequences("//"),
        supportsBlockComment: true,
        supportsBacktickString: true,
        radixPrefixes: scalars("xXbBoO"),
        treatsCapitalizedAsType: false,
        keywords: words("""
        break case chan const continue default defer else fallthrough for func go goto if import interface \
        map package range return select struct switch type var
        """),
        typeKeywords: words("""
        any bool byte comparable complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune \
        string uint uint8 uint16 uint32 uint64 uintptr
        """),
        // `iota` 是常量计数器，跟着数字色走比跟着关键字色走更好认
        literals: words("true false nil iota")
    )

    // MARK: Rust

    /// Rust。
    ///
    /// ### ⚠️ 为什么关掉单引号字符串
    /// Rust 里单引号更多是**生命周期标记**（`&'a str`、`fn foo<'a>(...)`）。如果照别的语言那样把 `'` 当字符串开头扫，它会在同一行里一路找到下一个 `'` 才收尾，把中间半行代码都染成字符串色 —— 而生命周期在 Rust 里出现得比字符字面量频繁得多，所以宁可不要字符字面量的颜色。代价只是 `'x'` 这种字符字面量不上色，比满屏乱色划算。
    ///
    /// `self` 在这门语言里是真正的关键字（不是字面量），所以放在关键字表里。
    static let rust = CodeLanguageProfile(
        lineComments: scalarSequences("//"),
        supportsBlockComment: true,
        stringPrefixes: scalars("rb"),
        supportsSingleQuotedString: false,
        radixPrefixes: scalars("xXbBoO"),
        keywords: words("""
        abstract as async await become box break const continue crate do dyn else enum extern final fn for \
        if impl in let loop macro match mod move mut override priv pub ref return self Self static struct \
        super trait try type typeof union unsafe unsized use virtual where while yield
        """),
        typeKeywords: words("""
        bool char f32 f64 i8 i16 i32 i64 i128 isize str u8 u16 u32 u64 u128 usize
        """),
        literals: words("true false")
    )
}
