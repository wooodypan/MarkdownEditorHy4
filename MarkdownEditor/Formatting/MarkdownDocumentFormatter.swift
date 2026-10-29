//
//  MarkdownDocumentFormatter.swift
//  MarkdownEditor
//
//  整理 markdown 源码的排版：统一标题写法、统一分隔线、统一列表符号、收拾多余的空白。
//
//  大白话：把一份写得比较随意的稿子收拾整齐——标题一律用 # 开头、分隔线统一成 ---、列表前面的圆点统一成短横线、行尾多打的空格和连成一片的空行都收掉。文字内容一个字都不改。
//
//  ### 为什么没有用 swift-markdown 自带的 MarkupFormatter
//  它确实能把整篇文档重新打印一遍，但是打印的过程会「按它自己的理解重写内容」，实测会改坏这些东西（每一条都有用例）：
//  - 反斜杠转义：`\*不是斜体\*` 变成 `*不是斜体*`，重新渲染就真成斜体了；
//  - HTML 实体：`&lt;` 变成 `<`，重新渲染会被当成标签吃掉；
//  - 删除线：`~~删掉~~` 变成 `~删掉~`（少一个波浪线，GFM 不再认）；
//  - 表格里的竖线转义：`| a \| b |` 变成 `|a | b|`，一格变两格；
//  - 列表项里再嵌列表时缩进丢失，整段结构塌成平铺；
//  - 脚注定义的续行缩进丢失；
//  - 链接的 title 直接丢掉；
//  - 有序列表的起始编号被改成 1。
//
//  所以这里改成另一条路子：只按「块结构」重排，行内的字一个都不碰（源码原样保留）。
//  代价是能整理的东西没那么多（不会帮你把 `_斜体_` 换成 `*斜体*`、不会重排长段落），换来的是「整理前后渲染出来的效果完全一样」。
//
//  ### 最后那道保险
//  整理完会把两份源码各解析一遍，比对整棵语法树的内容。只要有一丁点对不上就整篇放弃、把原因报上去，绝不把改坏的结果交出去。
//

import Foundation
import Markdown

/// 把一份 markdown 源码整理成统一的排版。
///
/// 只在后台线程用：整篇要解析两遍（一次收集结构、一次复核结果），大文档在主线程跑会卡一下。
enum MarkdownDocumentFormatter {

    /// 整理不了的原因。每一条都会原样显示给用户，所以措辞要说人话。
    enum Failure: LocalizedError {
        /// 文档里除了空白什么都没有
        case empty
        /// 开头是 front matter（两条 `---` 中间夹配置），当标题处理会改坏
        case frontMatter
        /// 复核没通过：整理之后语义变了
        case wouldChangeMeaning

        var errorDescription: String? {
            switch self {
            case .empty:
                return "文档是空的，没有可整理的内容。"
            case .frontMatter:
                return "这份文档开头有一段 front matter（两条 --- 中间夹的配置区）。"
                     + "整理它会被当成标题和分隔线改坏，所以这次先跳过。"
            case .wouldChangeMeaning:
                return "整理之后内容的意思会变，安全检查没通过，所以没有动它。"
                     + "文档里大概有些不太常见的写法，可以先把这一段挪开再试一次。"
            }
        }
    }

    /// 整理一份 markdown 源码。
    ///
    /// - Parameter source: 编辑器里的原始内容- Returns: 整理之后的完整内容。原文已经很整齐时原样返回- Throws: ``Failure``
    nonisolated static func format(_ source: String) throws -> String {
        // 换行符先统一：Windows 上编辑过的文件混着 \r\n，不统一的话逐行处理会把 \r 留在行尾
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        guard normalized.contains(where: { !$0.isWhitespace }) else {
            throw Failure.empty
        }
        guard !hasFrontMatter(normalized) else {
            throw Failure.frontMatter
        }

        let facts = gatherFacts(from: Document(parsing: normalized),
                                lines: normalized.components(separatedBy: "\n"))
        let output = rewrite(lines: normalized.components(separatedBy: "\n"), facts: facts)

        // 最后一道保险：整理前后语法树必须描述同一份内容。
        // 不为别的——哪天 swift-markdown 的解析行为变了，或者上面某条规则漏想了一种写法，这里能拦住，而不是等用户发现自己的文档被改坏。
        let before = signature(of: normalized)
        let after = signature(of: output)
        guard before == after else {
            throw Failure.wouldChangeMeaning
        }
        return output
    }

    // MARK: 结构信息

    /// 从整棵语法树里挑出「哪一行是什么块」。
    ///
    /// 为什么不直接拿正则扫源码：`# 标题` 和「段落里写了一行 # 标题」长得一样，只有问过解析器才知道哪一行真的是标题。表格里的 `-` 也一样，正则分不出它是分隔线还是单元格。
    private nonisolated struct Facts {
        /// 原样照抄的行：代码块、HTML 块、表格。里面的空格和空行都有意义，一个字都不能动
        var verbatimLines: Set<Int> = []
        /// 单行 ATX 标题：行号 → 级别
        var headingLines: [Int: Int] = [:]
        /// 下划线式（Setext）标题的文字行：行号 → 级别
        var setextTextLines: [Int: Int] = [:]
        /// 下划线式标题下面那条 `====` / `----`，要整行删掉
        var setextUnderlineLines: Set<Int> = []
        /// 分隔线所在的行
        var thematicBreakLines: Set<Int> = []
        /// 无序列表每一项的第一行（`*` 和 `+` 要换成 `-`）
        var unorderedItemLines: Set<Int> = []
        /// 全篇用过的无序列表标记（`-` / `*` / `+`）
        var unorderedMarkers: Set<Character> = []

        /// 要不要把无序列表符号统一成 `-`。
        ///
        /// 只在全篇只用一种符号时才动手。混着用的时候不能统一 ——`* 甲` 和 `+ 乙` 中间隔着空行，解析出来是两个独立的列表（渲染成两段）；都改成 `-` 之后它们会被当成同一个列表接起来，看着像排版，其实结构变了。
        var shouldUnifyUnorderedMarker: Bool {
            unorderedMarkers.count == 1 && unorderedMarkers.first != "-"
        }
    }

    private nonisolated static func gatherFacts(from document: Document, lines: [String]) -> Facts {
        var facts = Facts()
        collect(document, lines: lines, into: &facts)
        return facts
    }

    private nonisolated static func collect(_ markup: Markup, lines: [String], into facts: inout Facts) {
        switch markup {
        case let codeBlock as CodeBlock:
            protect(codeBlock.range, into: &facts)
            return
        case let htmlBlock as HTMLBlock:
            protect(htmlBlock.range, into: &facts)
            return
        case let table as Table:
            // 表格整块不动：列宽对齐是另一件事，动它容易把 `\|` 这种转义弄坏
            protect(table.range, into: &facts)
            return
        case let heading as Heading:
            if let range = heading.range {
                let lines = lineRange(of: range)
                // 跨两行的是下划线式标题。跨三行以上说明标题文字本身折了行，合成一行得自己决定怎么接（中文之间加不加空格），不值得冒险，保持原样
                if lines.count == 2 {
                    facts.setextTextLines[lines.lowerBound] = heading.level
                    facts.setextUnderlineLines.insert(lines.upperBound)
                } else if lines.count == 1 {
                    facts.headingLines[lines.lowerBound] = heading.level
                }
            }
        case let thematicBreak as ThematicBreak:
            if let range = thematicBreak.range {
                facts.thematicBreakLines.insert(lineRange(of: range).lowerBound)
            }
        case let list as UnorderedList:
            for item in list.listItems {
                guard let range = item.range else { continue }
                let lineNumber = lineRange(of: range).lowerBound
                facts.unorderedItemLines.insert(lineNumber)
                if let marker = markerCharacter(lines: lines, lineNumber: lineNumber) {
                    facts.unorderedMarkers.insert(marker)
                }
            }
        default:
            break
        }
        for child in markup.children {
            collect(child, lines: lines, into: &facts)
        }
    }

    /// 读某一行的列表标记（`-` / `*` / `+`）。
    ///
    /// 语法树里不存标记字符，只能回源码里看；引号、缩进这些前缀先切掉再认。
    private nonisolated static func markerCharacter(lines: [String], lineNumber: Int) -> Character? {
        guard lineNumber >= 1, lineNumber <= lines.count else { return nil }
        let body = splitBlockPrefix(lines[lineNumber - 1]).body
        guard let first = body.first, first == "-" || first == "*" || first == "+" else { return nil }
        return first
    }

    private nonisolated static func protect(_ range: SourceRange?, into facts: inout Facts) {
        guard let range else { return }
        for line in lineRange(of: range) {
            facts.verbatimLines.insert(line)
        }
    }

    /// 把语法树给的范围换算成「第几行到第几行」。
    ///
    /// 坑在这儿：`range.upperBound` 指的是「结束位置之后」，所以它常常落在下一行的第 1 列。
    /// 那种情况下真正的最后一行要往前退一行，否则代码块会把紧跟其后的正文也当成自己人。
    private nonisolated static func lineRange(of range: SourceRange) -> ClosedRange<Int> {
        let start = range.lowerBound.line
        let end = range.upperBound.column == 1 ? range.upperBound.line - 1 : range.upperBound.line
        return start...max(start, end)
    }

    // MARK: 逐行重排

    private nonisolated static func rewrite(lines: [String], facts: Facts) -> String {
        var output: [(text: String, verbatim: Bool)] = []

        for (index, raw) in lines.enumerated() {
            let lineNumber = index + 1

            if facts.verbatimLines.contains(lineNumber) {
                output.append((raw, true))
            } else if facts.setextUnderlineLines.contains(lineNumber) {
                // 下划线式标题改成 # 开头之后，那条 ===== 就没用了
                continue
            } else if let level = facts.setextTextLines[lineNumber] {
                let (prefix, body) = splitBlockPrefix(raw)
                output.append((prefix + String(repeating: "#", count: level) + " "
                               + body.trimmingCharacters(in: .whitespaces), false))
            } else if let level = facts.headingLines[lineNumber] {
                output.append((normalizeATXHeading(raw, level: level), false))
            } else if facts.thematicBreakLines.contains(lineNumber) {
                let (prefix, _) = splitBlockPrefix(raw)
                output.append((prefix + "---", false))
            } else if facts.unorderedItemLines.contains(lineNumber), facts.shouldUnifyUnorderedMarker {
                output.append((normalizeUnorderedMarker(raw), false))
            } else {
                output.append((trimTrailingWhitespace(raw), false))
            }
        }

        return join(output)
    }

    /// 把行首的「引用符号 + 缩进」切出来，剩下的才是这一行的正文。
    ///
    /// 例：`> > - 列表项` 切出来是前缀 `> > `、正文 `- 列表项`。
    /// 换标记的时候前缀要原样留住，不然引用块里的列表会被拽到外面去。
    private nonisolated static func splitBlockPrefix(_ line: String) -> (prefix: String, body: String) {
        var consumed = line.startIndex
        var index = line.startIndex

        while index < line.endIndex {
            let character = line[index]
            if character == " " || character == "\t" {
                index = line.index(after: index)
                consumed = index
            } else if character == ">" {
                index = line.index(after: index)
                consumed = index
                // `>` 后面紧跟的那个空格也算前缀，不然正文会多出前导空格
                if index < line.endIndex, line[index] == " " {
                    index = line.index(after: index)
                    consumed = index
                }
            } else {
                break
            }
        }
        return (String(line[line.startIndex..<consumed]), String(line[consumed...]))
    }

    /// 把 `### 标题 ###` 收拾成 `### 标题`。
    ///
    /// 只改「# 的个数对不对」、「# 后面有没有一个空格」、「行尾的闭合 # 要不要去掉」这三件事，标题文字一个字符都不动。
    private nonisolated static func normalizeATXHeading(_ line: String, level: Int) -> String {
        let (prefix, body) = splitBlockPrefix(line)

        // 数一下开头到底有几个 #
        var hashEnd = body.startIndex
        while hashEnd < body.endIndex, body[hashEnd] == "#" {
            hashEnd = body.index(after: hashEnd)
        }
        guard hashEnd > body.startIndex else { return line }

        var content = String(body[hashEnd...]).trimmingCharacters(in: .whitespaces)
        // 行尾「空格 + 一串 #」是闭合标记，去掉；`### C#` 里的 # 紧贴着字，是内容，留着
        if let lastSpace = content.lastIndex(where: { $0 == " " || $0 == "\t" }) {
            let tail = content[content.index(after: lastSpace)...]
            if !tail.isEmpty, tail.allSatisfy({ $0 == "#" }) {
                content = String(content[..<lastSpace])
            }
        }

        let marker = String(repeating: "#", count: level)
        return content.isEmpty ? prefix + marker : prefix + marker + " " + content
    }

    /// 把 `* 项目` / `+ 项目` 的标记换成 `-`。
    ///
    /// 只换那一个字符，标记后面的空格照原样留着 —— 多打几个空格时，后面的嵌套列表是照着那个宽度缩进的，改了会让层级错位。
    private nonisolated static func normalizeUnorderedMarker(_ line: String) -> String {
        let (prefix, body) = splitBlockPrefix(line)
        guard let marker = body.first, marker == "*" || marker == "+" else { return line }

        let afterMarker = body.index(after: body.startIndex)
        // 标记后面必须跟空白，否则 `**加粗**` 这种也会被当成列表标记
        guard afterMarker < body.endIndex,
              body[afterMarker] == " " || body[afterMarker] == "\t" else { return line }

        return prefix + "-" + String(body[afterMarker...])
    }

    /// 收掉行尾多余的空白，但保留「两个空格」这个硬换行标记。
    ///
    /// markdown 里行尾两个空格表示「这里强制换行」，删掉它两行会被粘成一行，所以必须留着。
    /// 只留一个空格的话什么也不表示，一并收掉。
    private nonisolated static func trimTrailingWhitespace(_ line: String) -> String {
        let trailing = line.reversed().prefix(while: { $0 == " " || $0 == "\t" })
        guard !trailing.isEmpty else { return line }

        let isAllSpaces = trailing.allSatisfy { $0 == " " }
        if isAllSpaces && trailing.count >= 2 {
            return String(line.dropLast(trailing.count - 2))
        }
        return String(line.dropLast(trailing.count))
    }

    /// 拼回去：顺手把连续空行压成一个、去掉开头和结尾的空行。
    ///
    /// 连续两个空行和三个空行渲染出来一模一样（都只是段落之间的一个间隔），压成一个纯粹是让源码看着舒服。代码块里的空行不算（`verbatim` 的行照原样走）。
    private nonisolated static func join(_ lines: [(text: String, verbatim: Bool)]) -> String {
        var result: [String] = []
        var blankRun = 0

        for line in lines {
            let isBlank = !line.verbatim && line.text.allSatisfy { $0 == " " || $0 == "\t" }
            guard isBlank else {
                blankRun = 0
                result.append(line.text)
                continue
            }
            blankRun += 1
            // 开头的空行不要；连着第二个以后的空行也不要
            if result.isEmpty || blankRun > 1 { continue }
            result.append("")
        }

        while let last = result.last, last.allSatisfy({ $0 == " " || $0 == "\t" }) {
            result.removeLast()
        }
        guard !result.isEmpty else { return "" }
        return result.joined(separator: "\n") + "\n"
    }

    // MARK: 复核

    /// 给整棵语法树算一个指纹：节点类型 + 文字内容 + 几个关键属性。
    ///
    /// 两棵树指纹一样，就说明整理前后是同一份内容。用 FNV-1a 而不是 `Hasher`，是因为 `Hasher` 每次启动的种子不一样，出了问题没法复现。
    private nonisolated static func signature(of text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325

        func mix(_ string: String) {
            for byte in string.utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
            }
            // 加个分隔符，免得 ["ab", "c"] 和 ["a", "bc"] 算出一个数
            hash = (hash ^ 0x1F) &* 0x0000_0100_0000_01b3
        }

        func walk(_ markup: Markup) {
            mix(String(describing: type(of: markup)))
            switch markup {
            case let text as Text:
                mix(text.string)
            case let code as InlineCode:
                mix(code.code)
            case let codeBlock as CodeBlock:
                mix(codeBlock.code)
                mix(codeBlock.language ?? "-")
            case let heading as Heading:
                mix(String(heading.level))
            case let link as Link:
                mix(link.destination ?? "-")
            case let image as Image:
                mix(image.source ?? "-")
            case let item as ListItem:
                mix(item.checkbox.map { String(describing: $0) } ?? "-")
            default:
                break
            }
            for child in markup.children {
                walk(child)
            }
        }

        walk(Document(parsing: text))
        return hash
    }

    // MARK: 前置检查

    /// 文档开头是不是一段 front matter。
    ///
    /// 判断办法：第一行就是 `---`，往后几十行内还能再找到一条 `---`。
    /// 真遇到了直接放弃——解析器会把第一条 `---` 当分隔线、把中间的 `title: xxx` 当成下划线式标题，整理一遍等于把它拆了。
    private nonisolated static func hasFrontMatter(_ text: String) -> Bool {
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first,
              first.trimmingCharacters(in: .whitespaces) == "---" else { return false }

        for line in lines.dropFirst().prefix(60) {
            if line.trimmingCharacters(in: .whitespaces) == "---" { return true }
        }
        return false
    }
}
