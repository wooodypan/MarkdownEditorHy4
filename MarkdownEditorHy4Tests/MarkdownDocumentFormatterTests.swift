//
//  MarkdownDocumentFormatterTests.swift
//  MarkdownEditorHy4Tests
//
//  「格式化文档」的规则测试。
//
//  大白话：把稿子收拾整齐是可以的，但不许改字、不许把格式弄坏。这组测试就是钉这件事。
//
//  ### 最有价值的一条是「整理前后语法树一致」
//  别的用例管某条规则怎么改，那一条管「改完还是同一份文档」。以后再加规则，只要它把内容改坏了，这条会当场红掉。
//

import XCTest
import Markdown
@testable import MarkdownEditorHy4

@MainActor
final class MarkdownDocumentFormatterTests: XCTestCase {

    // MARK: 会整理的部分

    func testConvertsSetextHeadingToATX() throws {
        let source = """
        一级标题
        =======

        二级标题
        -------

        正文。
        """

        let result = try MarkdownDocumentFormatter.format(source)

        // 末尾那个换行是整理时补上的（文件最后一行要有换行符）
        XCTAssertEqual(result, """
        # 一级标题

        ## 二级标题

        正文。
        """ + "\n")
    }

    func testUnifiesThematicBreak() throws {
        let source = """
        ***

        正文一

        ___

        正文二

        - - -

        正文三
        """

        let result = try MarkdownDocumentFormatter.format(source)

        XCTAssertEqual(result.components(separatedBy: "\n").filter { $0 == "---" }.count, 3)
        XCTAssertFalse(result.contains("***"))
        XCTAssertFalse(result.contains("___"))
    }

    func testUnifiesUnorderedListMarker() throws {
        // 全篇只用一种符号时才统一（下面那条测混用的情况）
        let source = """
        * 项目一
        * 项目二
        """

        let result = try MarkdownDocumentFormatter.format(source)

        XCTAssertEqual(result, """
        - 项目一
        - 项目二
        """ + "\n")
    }

    func testKeepsMixedMarkers() throws {
        // 全篇混着用 `*` 和 `+` 时不能统一：中间隔着空行的两个列表本来是两个独立列表（渲染成两段），都改成 `-` 之后会被接成一个，看着像排版，其实结构变了
        let source = """
        * 项目一
        * 项目二

        + 项目三
        """

        let result = try MarkdownDocumentFormatter.format(source)

        // 整理会在末尾补一个换行，其余一个字都不动
        XCTAssertEqual(result, source + "\n")
    }

    func testCollapsesBlankLines() throws {
        let source = "第一段\n\n\n\n\n第二段\n\n\n"

        let result = try MarkdownDocumentFormatter.format(source)

        XCTAssertEqual(result, "第一段\n\n第二段\n")
    }

    func testTrimsTrailingSpacesButKeepsHardBreak() throws {
        // 第一行末尾有三个空格（硬换行只要两个），第二行末尾一个空格
        let source = "第一行   \n第二行 \n第三行\n"

        let result = try MarkdownDocumentFormatter.format(source)

        XCTAssertEqual(result, "第一行  \n第二行\n第三行\n")
    }

    func testNormalizesATXHeadingSpacing() throws {
        let source = "#    标题前面空格太多    \n\n正文\n"

        let result = try MarkdownDocumentFormatter.format(source)

        XCTAssertEqual(result.components(separatedBy: "\n").first, "# 标题前面空格太多")
    }

    func testStripsClosingHeadingHashes() throws {
        let source = "## 标题 ##\n\n正文\n"

        let result = try MarkdownDocumentFormatter.format(source)

        XCTAssertEqual(result.components(separatedBy: "\n").first, "## 标题")
    }

    // MARK: 不许动的部分

    func testKeepsBackslashEscapes() throws {
        let source = """
        \\*不是斜体\\*

        正文。
        """

        let result = try MarkdownDocumentFormatter.format(source)

        XCTAssertTrue(result.contains("\\*不是斜体\\*"), "反斜杠转义被吃掉的话，重新渲染就真成斜体了")
    }

    func testKeepsHTMLEntities() throws {
        let source = """
        &lt;div&gt; 和 &amp; 符号
        """

        let result = try MarkdownDocumentFormatter.format(source)

        XCTAssertTrue(result.contains("&lt;"))
        XCTAssertTrue(result.contains("&amp;"))
    }

    func testKeepsStrikethrough() throws {
        let source = """
        这是 ~~删掉的字~~ 。
        """

        let result = try MarkdownDocumentFormatter.format(source)

        XCTAssertTrue(result.contains("~~删掉的字~~"), "少一个波浪线 GFM 就不认删除线了")
    }

    func testKeepsTableVerbatim() throws {
        // 单元格里的竖线靠反斜杠转义，被吃掉的话一格会变成两格
        let source = """
        | 列一 | 列二 |
        | --- | --- |
        | a \\| b | c |
        """

        let result = try MarkdownDocumentFormatter.format(source)

        XCTAssertTrue(result.contains("a \\| b"))
    }

    func testKeepsCodeBlockContentVerbatim() throws {
        // 代码块里那行 `* 项目` 看着像列表，实际是代码，一个字符都不能改
        let source = """
        ```markdown
        * 项目

        ###### 也不是标题
        ```
        """

        let result = try MarkdownDocumentFormatter.format(source)

        XCTAssertTrue(result.contains("* 项目"))
        XCTAssertTrue(result.contains("###### 也不是标题"))
    }

    func testKeepsOrderedListNumbers() throws {
        let source = """
        3. 第一步
        4. 第二步
        5. 第三步
        """

        let result = try MarkdownDocumentFormatter.format(source)

        // 末尾那个换行是整理补上的
        XCTAssertEqual(result, source + "\n", "有序列表的编号是用户自己排的，改了意思就变了")
    }

    func testKeepsFootnoteDefinitionIndent() throws {
        let source = """
        正文里有个脚注[^1]。

        [^1]: 靠这四格缩进续上一行
            这是脚注的第二行。
        """

        let result = try MarkdownDocumentFormatter.format(source)

        XCTAssertTrue(result.contains("    这是脚注的第二行"))
    }

    func testKeepsNestedListIndent() throws {
        let source = """
        - 父项
          - 子项
            - 孙项
        """

        let result = try MarkdownDocumentFormatter.format(source)

        // 整理会在末尾补一个换行
        XCTAssertEqual(result, source + "\n")
    }

    // MARK: 幂等与语义

    func testFormattingTwiceChangesNothing() throws {
        let source = """
        * 项目一
        * 项目二

        标题
        ===


        正文还有   行尾空格   
        """

        let once = try MarkdownDocumentFormatter.format(source)
        let twice = try MarkdownDocumentFormatter.format(once)

        XCTAssertEqual(once, twice, "整理两遍的结果不一样，说明规则自己跟自己打架")
    }

    func testPreservesParseTree() throws {
        // 一份把各种写法都塞进去的文档：整理完之后语法树必须还是同一棵树
        let source = """
        # 标题

        正文 `行内代码` 和 **加粗** 还有 ~~删除线~~。

        > 引用里有 *斜体*
        > 第二行

        * 列表项
          * 嵌套项

        3. 有序
        4. 列表

        | a | b |
        | --- | --- |
        | 1 | 2 |

        ```swift
        let a = 1
        ```

            indented code
            second line

        脚注[^1]

        [^1]: 脚注内容
        """

        let result = try MarkdownDocumentFormatter.format(source)

        XCTAssertEqual(tree(of: source), tree(of: result),
                       "整理之后语法树变了，说明有内容被改坏")
    }

    // MARK: 不该硬来的时候

    func testRefusesFrontMatter() {
        let source = """
        ---
        title: 我的笔记
        tags: [a, b]
        ---

        正文
        """

        XCTAssertThrowsError(try MarkdownDocumentFormatter.format(source)) { error in
            XCTAssertTrue(error is MarkdownDocumentFormatter.Failure)
        }
    }

    func testRefusesEmptyDocument() {
        XCTAssertThrowsError(try MarkdownDocumentFormatter.format("   \n\n  "))
    }

    func testAlreadyTidyDocumentIsUntouched() throws {
        let source = """
        # 标题

        - 项目一
        - 项目二

        正文。
        """

        XCTAssertEqual(try MarkdownDocumentFormatter.format(source), source + "\n")
    }

    // MARK: 辅助

    /// 把语法树摊平成「节点类型 + 文字」，用来判断两份源码是不是同一份内容。
    private func tree(of source: String) -> [String] {
        var lines: [String] = []

        func walk(_ markup: Markup) {
            var label = "\(type(of: markup))"
            switch markup {
            case let text as Text: label += ":\(text.string)"
            case let code as InlineCode: label += ":\(code.code)"
            case let codeBlock as CodeBlock: label += ":\(codeBlock.code)"
            case let heading as Heading: label += ":\(heading.level)"
            case let link as Link: label += ":\(link.destination ?? "-")"
            case let image as Image: label += ":\(image.source ?? "-")"
            default: break
            }
            lines.append(label)
            for child in markup.children { walk(child) }
        }

        walk(Document(parsing: source))
        return lines
    }
}
