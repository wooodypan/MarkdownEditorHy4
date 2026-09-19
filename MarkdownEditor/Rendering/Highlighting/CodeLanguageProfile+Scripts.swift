//
//  CodeLanguageProfile+Scripts.swift
//  MarkdownEditorHy4
//
//  脚本 / 查询 / 数据格式的规则表：Shell / Ruby / PHP / SQL / JSON
//

import Foundation

extension CodeLanguageProfile {

    // MARK: Shell

    /// Shell（sh / bash / zsh）。
    ///
    /// ### 表里放了哪些词
    /// 只放**语言自己的东西**（`if` / `then` / `fi` / `source`…）和几乎每个脚本都会用的内建命令（`echo` / `printf` / `read` / `cd`…）。像 `docker` / `git` 这种外部命令不往表里塞 —— 那等于把「用户装了哪些工具」当语法，迟早错得离谱。
    ///
    /// ⚠️ `#!/bin/bash` 这种 shebang 走的是行注释那条路（`#` 在行首），整行会按注释色显示，正好符合直觉。
    static let shell = CodeLanguageProfile(
        lineComments: scalarSequences("#"),
        radixPrefixes: scalars("xX"),
        keywords: words("""
        alias break case continue declare do done echo elif esac eval exec exit export fi for function if in \
        local printf pwd read readonly return set shift source test then trap typeset unalias unset until \
        while
        """),
        literals: words("true false")
    )

    // MARK: Ruby

    /// Ruby。
    ///
    /// ⚠️ `=begin` / `=end` 这种块注释**没做** —— 它要求 `=begin` 顶格、还要独占一行，为它单独加一条规则不太值。行注释 `#` 才是 Ruby 里 99% 的场景。
    static let ruby = CodeLanguageProfile(
        lineComments: scalarSequences("#"),
        radixPrefixes: scalars("xXbB"),
        keywords: words("""
        alias and attr_accessor attr_reader attr_writer begin break case class def do else elsif end ensure \
        extend for if in include lambda loop module next or print proc puts raise redo require \
        require_relative rescue retry return self super then undef unless until when while yield
        """),
        literals: words("true false nil")
    )

    // MARK: PHP

    /// PHP。
    ///
    /// ### 两种行注释
    /// PHP 里 `//` 和 `#` **都是**行注释，所以这两条都写进表里（扫描器会把它们逐个试一遍）。
    ///
    /// ⚠️ `$variable` 不会上色：扫描器为了省时间**不给普通标识符生成片段**（这是刻意的性能取舍），而 `$` 在这里只是变量名的开头。关键字、字符串、注释、数字照样有色，整体已经够看。
    static let php = CodeLanguageProfile(
        lineComments: scalarSequences("//", "#"),
        supportsBlockComment: true,
        radixPrefixes: scalars("xXbB"),
        keywords: words("""
        abstract and array as break callable case catch class clone const continue declare default do echo \
        else elseif empty enddeclare endfor endforeach endif endswitch endwhile enum eval exit extends final \
        finally fn for foreach function global goto if implements include include_once instanceof insteadof \
        interface isset list match namespace new or print private protected public readonly require \
        require_once return static switch throw trait try unset use var while xor yield
        """),
        typeKeywords: words("""
        bool boolean double float int integer iterable mixed object string void
        """),
        literals: words("true false null")
    )

    // MARK: SQL

    /// SQL（MySQL / PostgreSQL / SQLite / SQL Server 的公共部分）。
    ///
    /// ### ⚠️ 唯一一门需要「不分大小写」的语言
    /// SQL 里 `SELECT` 和 `select` 是一回事，所以打开了 `isCaseInsensitive`（详见那个字段的注释）。表里的词一律写**小写**，扫描时把代码里的词折成小写再查。
    ///
    /// ### ⚠️ 为什么关掉「大写开头当类型」
    /// SQL 里的标识符经常大写（`USER_ID` 这种列名一大片），当类型名上色会满屏是颜色，反而看不清真正的关键字。
    ///
    /// ### 刻意的取舍
    /// 1. 行注释只认 `--`，**不认 `#`** —— `#temp` 在 SQL Server 里是临时表名，认了 `#` 会把整行后半截染成注释；
    /// 2. 双引号在标准 SQL 里是「带引号的标识符」而不是字符串，但这里照样按字符串上色 —— 反正它出现在代码里的样子就是一段被引起来的东西，看着不违和。
    static let sql = CodeLanguageProfile(
        lineComments: scalarSequences("--"),
        supportsBlockComment: true,
        treatsCapitalizedAsType: false,
        isCaseInsensitive: true,
        keywords: words("""
        add all alter and any as asc auto_increment begin between by case cast check column commit \
        constraint convert create cross database default delete desc distinct drop else end exists explain \
        foreign from full grant group having if ifnull in index inner insert into isnull join key left like \
        limit not nullif offset on or order outer over partition primary procedure references replace \
        returning revoke right rollback row_number select set table then top transaction trigger truncate \
        union unique update using values view when where with
        """),
        typeKeywords: words("""
        bigint binary bit blob boolean char date datetime decimal double float int integer json numeric real \
        serial smallint text time timestamp tinyint uuid varchar
        """),
        literals: words("true false null")
    )

    // MARK: JSON

    /// JSON。
    ///
    /// 没有注释、没有关键字，能上色的就三样：字符串（键和值都是）、数字、`true` / `false` / `null`。
    /// ⚠️ `treatsCapitalizedAsType` 也关掉 —— JSON 里不该出现类型名的概念。
    static let json = CodeLanguageProfile(
        treatsCapitalizedAsType: false,
        literals: words("true false null")
    )

    /// JSONC（带注释的 JSON，很多配置文件用这个方言）。
    ///
    /// 和 JSON 只差注释这一项 —— 但它差得很关键：配置文件的注释密度通常很高，能上色区别很大。
    static let jsonWithComments = CodeLanguageProfile(
        lineComments: scalarSequences("//"),
        supportsBlockComment: true,
        treatsCapitalizedAsType: false,
        literals: words("true false null")
    )
}
