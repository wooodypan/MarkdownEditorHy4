//
//  CodeHighlightingMoreLanguagesTests.swift
//  MarkdownEditorHy4Tests
//
//  代码块语法高亮测试（第二批：C / C++ / Objective-C / Java / C# / Kotlin / Go / Rust /
//  TypeScript / Shell / Ruby / PHP / SQL / JSON）
//
//  第一批（JavaScript / Python / Swift）在 CodeHighlightingTests.swift 里。
//

import XCTest
@testable import MarkdownEditorHy4

@MainActor
final class CodeHighlightingMoreLanguagesTests: XCTestCase {

    // MARK: - 小工具（和第一批那两个一样，测试文件之间互不依赖）

    /// 渲染一个代码块，返回渲染后的富文本和当时的主题
    private func render(_ code: String,
                        language: String,
                        configure: ((inout MarkdownTheme) -> Void)? = nil) -> (text: NSAttributedString, theme: MarkdownTheme) {
        var theme = MarkdownTheme.default
        configure?(&theme)
        let renderer = MarkupToAttributedRenderer(theme: theme, containerWidth: 600)
        let source = "```\(language)\n\(code)\n```\n"
        let (text, _) = renderer.render(blockSource: source)
        return (text, theme)
    }

    /// 把 UIColor 拆成 RGBA 分量。为什么不直接比 UIColor 对象：同一个颜色可能落在不同色彩空间里（sRGB / Display P3），直接 `XCTAssertEqual` 会误判。
    private func rgba(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%.2f,%.2f,%.2f,%.2f", r, g, b, a)
    }

    /// 取渲染结果里某个片段的前景色的 RGBA 字符串。找不到那段文字返回 nil —— 断言时会给出明确失败信息。
    private func colorString(of needle: String, in text: NSAttributedString) -> String? {
        let plain = text.string as NSString
        let range = plain.range(of: needle)
        guard range.location != NSNotFound,
              let color = text.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor else {
            return nil
        }
        return rgba(color)
    }

    /// 一次断言「这段文字应该是某个颜色」，失败信息里带上语言的标签，出问题时一眼知道是哪门语言挂了
    private func assertColor(_ needle: String,
                             _ expected: UIColor,
                             _ label: String,
                             _ reason: String,
                             in text: NSAttributedString,
                             file: StaticString = #filePath,
                             line: UInt = #line) {
        XCTAssertEqual(colorString(of: needle, in: text), rgba(expected),
                       "[\(label)] \(reason)", file: file, line: line)
    }

    // MARK: - C

    func testCKeywordsPreprocessorAndTypesAreColored() {
        let code = """
        #include <stdio.h>

        // 打印一行
        int main(void) {
            char *msg = "hello";
            int n = 0x1F;
            if (n > 0) { return 1; }
            return 0;
        }
        """
        let (text, theme) = render(code, language: "c")
        let c = theme.syntaxColors

        assertColor("#include", c.keyword, "C", "`#` 在行首是预处理指令，整条 `#include` 按关键字上色", in: text)
        assertColor("int", c.type, "C", "`int` 在类型表里，用类型色", in: text)
        assertColor("void", c.type, "C", "`void` 同上", in: text)
        assertColor("// 打印一行", c.comment, "C", "`//` 行注释", in: text)
        assertColor("\"hello\"", c.string, "C", "字符串字面量", in: text)
        assertColor("0x1F", c.number, "C", "十六进制数字整个算一个数", in: text)
        assertColor("return", c.keyword, "C", "`return` 是关键字", in: text)
        assertColor("main", theme.textColor, "C", "普通函数名不上色，保持正文色", in: text)
    }

    /// 预处理指令必须卡「行首」：缩进后面可以，但出现在行中间就不该当指令
    func testCPreprocessorOnlyCountsAtLineStart() {
        let code = """
            #define MAX 10
        int x = a # b;
        """
        let (text, theme) = render(code, language: "c")

        // 前面有缩进的 `#define` 仍然算指令
        assertColor("#define", theme.syntaxColors.keyword, "C", "缩进后面的 `#` 还是行首，算预处理指令", in: text)
        // 行中间的 `#` 不是指令，它后面的词也就不该被染色
        XCTAssertNotEqual(colorString(of: "b", in: text), rgba(theme.syntaxColors.keyword),
                          "[C] 行中间的 `#` 不是预处理指令，后面的词不该被当关键字")
    }

    // MARK: - C++

    func testCPPClassesTemplatesAndLiteralsAreColored() {
        let code = """
        #pragma once
        class Widget {
        public:
            explicit Widget(int size);
            template <typename T> T *get() { return nullptr; }
        private:
            bool ready = false;
        };
        """
        let (text, theme) = render(code, language: "cpp")
        let c = theme.syntaxColors

        assertColor("#pragma", c.keyword, "C++", "预处理指令", in: text)
        assertColor("class", c.keyword, "C++", "`class` 是关键字", in: text)
        assertColor("template", c.keyword, "C++", "`template` 是关键字", in: text)
        assertColor("int", c.type, "C++", "`int` 是类型", in: text)
        assertColor("bool", c.type, "C++", "`bool` 是类型", in: text)
        assertColor("Widget", c.type, "C++", "大写开头的类名按类型上色", in: text)
        assertColor("nullptr", c.number, "C++", "`nullptr` 是字面量，跟着数字色走（不在关键字表里）", in: text)
        assertColor("false", c.number, "C++", "`false` 同上", in: text)
    }

    // MARK: - Objective-C

    func testObjectiveCAtPrefixesAndStringLiteralAreColored() {
        let code = """
        #import <Foundation/Foundation.h>

        @interface Person : NSObject
        @property (nonatomic, copy) NSString *name;
        - (NSString *)greet { return @"hi"; }
        @end
        """
        let (text, theme) = render(code, language: "objc")
        let c = theme.syntaxColors

        assertColor("#import", c.keyword, "Objective-C", "`#import` 是预处理指令", in: text)
        assertColor("@interface", c.keyword, "Objective-C", "`@` 和后面的词合起来查表，`@interface` 是关键字", in: text)
        assertColor("@property", c.keyword, "Objective-C", "`@property` 同理", in: text)
        assertColor("@end", c.keyword, "Objective-C", "`@end` 同理", in: text)
        // ⚠️ 这条最容易被写漏：`@` 必须算字符串的一部分，否则屏幕上会孤零零留一个没上色的 `@`
        assertColor("@\"hi\"", c.string, "Objective-C", "`@\"…\"` 整段（含 `@`）都是字符串色", in: text)
        assertColor("NSObject", c.type, "Objective-C", "大写开头的类名按类型上色", in: text)
    }

    // MARK: - Java

    func testJavaAnnotationsAndPrimitiveTypesAreColored() {
        let code = """
        @Override
        public void run() {
            int count = 1;
            String name = "x";
            var list = List.of(name);
        }
        """
        let (text, theme) = render(code, language: "java")
        let c = theme.syntaxColors

        // 注解不在关键字表里，走「`@` + 标识符」那条路会被当成类型名 —— 注解跟类型本来就是一类的
        assertColor("@Override", c.type, "Java", "注解按类型色上", in: text)
        assertColor("public", c.keyword, "Java", "`public` 是关键字", in: text)
        assertColor("void", c.type, "Java", "`void` 是类型", in: text)
        assertColor("int", c.type, "Java", "`int` 是类型", in: text)
        assertColor("String", c.type, "Java", "`String` 是大写开头，按类型上色", in: text)
        assertColor("var", c.type, "Java", "`var` 写在类型表里", in: text)
        assertColor("\"x\"", c.string, "Java", "字符串字面量", in: text)
    }

    // MARK: - C#

    func testCSharpInterpolatedStringAndRegionAreColored() {
        let code = """
        #region 初始化
        public class Counter {
            private int _n = 0;
            public string Label => $"count is {_n}";
        }
        #endregion
        """
        let (text, theme) = render(code, language: "csharp")
        let c = theme.syntaxColors

        assertColor("#region", c.keyword, "C#", "`#region` 是预处理指令", in: text)
        assertColor("class", c.keyword, "C#", "`class` 是关键字", in: text)
        assertColor("int", c.type, "C#", "`int` 是类型", in: text)
        // `$` 是插值字符串的前缀，必须和字符串一起上色（和 Python 的 f"" 是同一回事）
        assertColor("$\"count is {_n}\"", c.string, "C#", "`$\"…\"` 的 `$` 也要算字符串的一部分", in: text)
    }

    // MARK: - Kotlin

    func testKotlinTripleQuotedStringSwallowsKeywords() {
        // 用 Swift 的「原始多行字符串」写这段测试数据，免得 Kotlin 的三引号和 Swift 的定界符打架
        let code = #"""
        val raw = """
        fun 不是关键字
        """
        val n = 1
        """#
        let (text, theme) = render(code, language: "kotlin")
        let c = theme.syntaxColors

        assertColor("fun", c.string, "Kotlin", "三引号字符串里的 `fun` 属于字符串内容，不该当关键字", in: text)
        assertColor("val", c.keyword, "Kotlin", "三引号外面的 `val` 还是正常关键字色", in: text)
    }

    // MARK: - Go

    func testGoRawStringSpansLinesAndCapitalizedIsNotAType() {
        let code = #"""
        func sum(xs []int) int {
        raw := `func 不是关键字
        跨行`
        fmt.Println(raw)
        return 0
        }
        """#
        let (text, theme) = render(code, language: "go")
        let c = theme.syntaxColors

        assertColor("func", c.keyword, "Go", "`func` 是关键字", in: text)
        assertColor("int", c.type, "Go", "`int` 是内置类型", in: text)
        assertColor("return", c.keyword, "Go", "`return` 是关键字", in: text)
        // 跨行是反引号字符串和普通字符串的关键差别（Go 的原始字符串就是拿来多行写 SQL / JSON 的）
        assertColor("`func 不是关键字\n跨行`", c.string, "Go", "反引号原始字符串可以跨行，中间的关键字不上色", in: text)
        // ⚠️ Go 里大写开头表示「导出」，不是类型 —— 这条断言锁住那个刻意的决定
        assertColor("Println", theme.textColor, "Go", "大写开头在 Go 里是「导出」不是类型，不该上类型色", in: text)
    }

    // MARK: - Rust

    /// Rust 最要小心的一条：`'` 在这门语言里多半是**生命周期标记**，不是字符串开头。
    /// 一旦当成字符串扫，它会一路吃到同一行里下一个 `'`，把中间半行代码都染红。
    func testRustLifetimeMarkersAreNotTreatedAsStrings() {
        let code = """
        fn first<'a>(text: &'a str) -> &'a str {
            let n: u8 = 1;
            // 取第一个字符
            text
        }
        """
        let (text, theme) = render(code, language: "rust")
        let c = theme.syntaxColors

        assertColor("'a str", theme.textColor, "Rust", "`'a` 是生命周期标记，整段（含后面的 str 之前那截）都不该是字符串色", in: text)
        assertColor("str", c.type, "Rust", "`str` 是内置类型 —— 生命周期要是被当成字符串，这里会变成字符串色", in: text)
        assertColor("u8", c.type, "Rust", "`u8` 是内置类型", in: text)
        assertColor("fn", c.keyword, "Rust", "`fn` 是关键字", in: text)
        assertColor("// 取第一个字符", c.comment, "Rust", "行注释", in: text)
    }

    // MARK: - TypeScript

    func testTypeScriptTypesAndKeywordsAreColored() {
        let code = """
        interface User { name: string; age: number }
        const u: User = { name: "a", age: 1 };
        """
        let (text, theme) = render(code, language: "ts")
        let c = theme.syntaxColors

        assertColor("interface", c.keyword, "TypeScript", "`interface` 是 TS 的关键字", in: text)
        assertColor("const", c.keyword, "TypeScript", "`const` 是关键字", in: text)
        assertColor("string", c.type, "TypeScript", "`string` 是小写的类型名，靠类型表认出来", in: text)
        assertColor("number", c.type, "TypeScript", "`number` 同上", in: text)
        assertColor("User", c.type, "TypeScript", "大写开头的接口名按类型上色", in: text)
        assertColor("\"a\"", c.string, "TypeScript", "字符串字面量", in: text)
    }

    // MARK: - Shell

    func testShellShebangAndHashCommentAreColored() {
        let code = """
        #!/bin/bash
        # 部署脚本
        if [ -f "$FILE" ]; then
            echo "ok"
        fi
        """
        let (text, theme) = render(code, language: "bash")
        let c = theme.syntaxColors

        assertColor("#!/bin/bash", c.comment, "Shell", "shebang 也是 `#` 开头，按注释色走正好符合直觉", in: text)
        assertColor("# 部署脚本", c.comment, "Shell", "`#` 行注释", in: text)
        assertColor("if", c.keyword, "Shell", "`if` 是关键字", in: text)
        assertColor("echo", c.keyword, "Shell", "`echo` 是内建命令，在关键字表里", in: text)
        assertColor("\"ok\"", c.string, "Shell", "双引号字符串", in: text)
    }

    // MARK: - Ruby

    func testRubyKeywordsAndHashInterpolationAreColored() {
        let code = """
        # 打招呼
        class Greeter
          def hello(name)
            puts "hi #{name}"
          end
        end
        """
        let (text, theme) = render(code, language: "ruby")
        let c = theme.syntaxColors

        assertColor("# 打招呼", c.comment, "Ruby", "`#` 行注释", in: text)
        assertColor("class", c.keyword, "Ruby", "`class` 是关键字", in: text)
        assertColor("def", c.keyword, "Ruby", "`def` 是关键字", in: text)
        assertColor("puts", c.keyword, "Ruby", "`puts` 在关键字表里", in: text)
        assertColor("Greeter", c.type, "Ruby", "大写开头的类名按类型上色", in: text)
        // 字符串插值里的 `#` 不能被当成行注释 —— 整段字符串是一个 token，扫描器压根看不到里面那个 `#`
        assertColor("\"hi #{name}\"", c.string, "Ruby", "`#{…}` 插值整段都算字符串", in: text)
    }

    // MARK: - PHP

    /// PHP 是「一门语言认两种行注释」的典型，这条同时验证多前缀那套机制
    func testPHPBothCommentStylesAreColored() {
        let code = """
        <?php
        // 行注释
        # 也是行注释
        function greet($name) {
            echo "hi $name";
        }
        """
        let (text, theme) = render(code, language: "php")
        let c = theme.syntaxColors

        assertColor("// 行注释", c.comment, "PHP", "`//` 是行注释", in: text)
        assertColor("# 也是行注释", c.comment, "PHP", "`#` 也是行注释（表里写了两种前缀）", in: text)
        assertColor("function", c.keyword, "PHP", "`function` 是关键字", in: text)
        assertColor("echo", c.keyword, "PHP", "`echo` 是关键字", in: text)
        assertColor("\"hi $name\"", c.string, "PHP", "字符串里的 `$name` 属于字符串内容", in: text)
    }

    // MARK: - SQL

    /// SQL 唯一一门「关键字不分大小写」的语言，`SELECT` 和 `select` 必须同样上色
    func testSQLKeywordsAreCaseInsensitive() {
        let code = """
        -- 查活跃用户
        SELECT id, name FROM users WHERE age > 18;

        select count(*) from orders where status = 'paid';
        create table report (id int, title varchar(20));
        """
        let (text, theme) = render(code, language: "sql")
        let c = theme.syntaxColors

        assertColor("-- 查活跃用户", c.comment, "SQL", "`--` 是行注释", in: text)
        // 大写
        assertColor("SELECT", c.keyword, "SQL", "大写的关键字", in: text)
        assertColor("WHERE", c.keyword, "SQL", "大写的关键字", in: text)
        // 小写 —— 这几条才是「不分大小写」的关键
        assertColor("select", c.keyword, "SQL", "小写的 `select` 也要当关键字", in: text)
        assertColor("from", c.keyword, "SQL", "小写的 `from` 也要当关键字", in: text)
        // 类型名同样不分大小写
        assertColor("int", c.type, "SQL", "`int` 是类型", in: text)
        assertColor("varchar", c.type, "SQL", "小写的 `varchar` 也要当类型", in: text)

        assertColor("'paid'", c.string, "SQL", "单引号字符串", in: text)
        assertColor("18", c.number, "SQL", "数字字面量", in: text)
        // ⚠️ 关掉「大写开头当类型」是刻意的：SQL 里大写的列名/表名一大片，全染色会盖过真正的关键字
        assertColor("users", theme.textColor, "SQL", "普通表名不上色", in: text)
        assertColor("report", theme.textColor, "SQL", "普通表名不上色（SQL 关掉了「大写开头当类型」）", in: text)
    }

    // MARK: - JSON

    func testJSONLiteralsAndStringsAreColored() {
        let code = """
        {
          "name": "hy4",
          "count": 3,
          "ok": true,
          "extra": null
        }
        """
        let (text, theme) = render(code, language: "json")
        let c = theme.syntaxColors

        assertColor("\"name\"", c.string, "JSON", "键也是字符串", in: text)
        assertColor("3", c.number, "JSON", "数字", in: text)
        assertColor("true", c.number, "JSON", "`true` 是字面量，跟数字色", in: text)
        assertColor("null", c.number, "JSON", "`null` 是字面量，跟数字色", in: text)
    }

    /// JSONC（带注释的 JSON）比 JSON 只多一项注释，但配置文件里那一项很关键
    func testJSONCAllowsComments() {
        let code = """
        {
          // 说明
          "a": 1
        }
        """
        let (text, theme) = render(code, language: "jsonc")

        assertColor("// 说明", theme.syntaxColors.comment, "JSONC", "JSONC 才认 `//` 行注释", in: text)
    }

    // MARK: - 语言名路由

    /// 同一个语言的各种写法都要认 —— 用户不该为了「颜色对了」去猜该写哪个词
    func testLanguageAliasesRouteToTheSameTable() {
        let highlighter = SimpleCodeHighlighter()
        let aliases: [[String]] = [
            ["c", "h"],
            ["cpp", "c++", "cxx", "cc", "C++"],
            ["objc", "objective-c", "objectivec", "m"],
            ["java"],
            ["csharp", "c#", "cs"],
            ["kotlin", "kt"],
            ["go", "golang"],
            ["rust", "rs"],
            ["swift"],
            ["js", "javascript", "mjs"],
            ["ts", "typescript"],
            ["python", "py"],
            ["ruby", "rb"],
            ["php"],
            ["sh", "bash", "shell", "zsh"],
            ["sql", "mysql", "postgres", "postgresql", "sqlite"],
            ["json", "jsonc"]
        ]

        for group in aliases {
            for name in group {
                XCTAssertTrue(highlighter.supportsLanguage(name), "`\(name)` 应该被认出来")
            }
        }

        // 不认识的语言要老实返回 false，不能瞎高亮（HTML / CSS / YAML 是刻意没做的）
        for name in ["html", "css", "yaml", "xml", "makefile", "brainfuck", ""] {
            XCTAssertFalse(highlighter.supportsLanguage(name), "`\(name)` 不在支持列表里，不该被认成某种语言")
        }
    }

    // MARK: - 规则表体检

    /// 手写的表一大把，这条专门用来抓「填表时手滑」：三张表之间不该有重复的词，非 JSON 的语言也不该有空的关键字表。
    ///
    /// 为什么重复项是问题：一个词同时出现在两张表里，最终颜色就取决于扫描器查表的先后顺序 —— 哪天调一下顺序，颜色就变了，是个埋着的雷。
    func testEveryProfileIsWellFormed() {
        let languages = ["c", "cpp", "objc", "java", "csharp", "kotlin", "go", "rust", "swift",
                         "js", "ts", "python", "ruby", "php", "sh", "sql", "json", "jsonc"]

        for name in languages {
            guard let profile = CodeLanguageProfile.profile(forLanguage: name) else {
                XCTFail("`\(name)` 应该有规则表")
                continue
            }

            XCTAssertTrue(profile.keywords.isDisjoint(with: profile.typeKeywords),
                          "[\(name)] 有词同时出现在关键字表和类型表里")
            XCTAssertTrue(profile.keywords.isDisjoint(with: profile.literals),
                          "[\(name)] 有词同时出现在关键字表和字面量表里")
            XCTAssertTrue(profile.typeKeywords.isDisjoint(with: profile.literals),
                          "[\(name)] 有词同时出现在类型表和字面量表里")

            // JSON 只有字面量，别的语言至少得有关键字（空表八成是忘了填）
            if name != "json", name != "jsonc" {
                XCTAssertFalse(profile.keywords.isEmpty, "[\(name)] 关键字表是空的，八成忘了填")
            }
        }
    }
}
