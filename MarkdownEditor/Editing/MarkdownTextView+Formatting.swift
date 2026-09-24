//
//  MarkdownTextView+Formatting.swift
//  MarkdownEditorHy4
//
//  编辑态的 markdown 快捷键：⌘B / ⌘I / ⌘U / ⌘K / ⌘1~⌘6 / ⌘0 / ⌥⌘C / ⌥⌘Q
//
//  ### 这批命令共用两条规矩（改的时候别破）
//  1. **改的是源码，不是渲染出来的富文本。** 所有替换文本都是 markdown 记号本身
//     （`**`、`## `、`> `、``` ），再交给 `applyEdit` 走标准编辑管线 ——
//     撤销 / 重做、局部重解析、目录更新、装饰重摆全都自动跟着生效。
//  2. **每个命令外面套一层 `performUndoableModelEdit`。** 这些编辑不是系统键盘输入，
//     系统不会替我们记撤销，得自己按「整篇源码快照」记一笔（理由见主文件里那个方法的注释）。
//
//  ### 为什么单独一个文件
//  和 `+Search` / `+Outline` 一个道理：主文件已经一千七百多行，
//  这套「选区 → 源码 → 替换 → 落光标」的逻辑自成一坨，挪出来好读也好改。
//

import UIKit

extension MarkdownTextView {

    // MARK: - 快捷键清单

    /// 这套 markdown 快捷键。
    ///
    /// `title` 不是摆设：外接键盘**按住** ⌘ 时系统弹出的快捷键面板上写的就是这几个字，
    /// 用户靠它才知道有这些快捷键。
    ///
    /// ⚠️ 标题级别（⌘1~⌘6 / ⌘0）共用一个 `headingCommand(_:)`：它从 `UIKeyCommand.input`
    /// 里把数字读出来，省掉 7 个长得一模一样的方法。
    static var markdownKeyCommands: [UIKeyCommand] {
        [
            UIKeyCommand(title: "加粗",
                         action: #selector(toggleBoldCommand),
                         input: "b",
                         modifierFlags: .command),
            UIKeyCommand(title: "斜体",
                         action: #selector(toggleItalicCommand),
                         input: "i",
                         modifierFlags: .command),
            UIKeyCommand(title: "下划线",
                         action: #selector(toggleUnderlineCommand),
                         input: "u",
                         modifierFlags: .command),
            UIKeyCommand(title: "插入链接",
                         action: #selector(insertLinkCommand),
                         input: "k",
                         modifierFlags: .command),
            UIKeyCommand(title: "一级标题",
                         action: #selector(headingCommand(_:)),
                         input: "1",
                         modifierFlags: .command),
            UIKeyCommand(title: "二级标题",
                         action: #selector(headingCommand(_:)),
                         input: "2",
                         modifierFlags: .command),
            UIKeyCommand(title: "三级标题",
                         action: #selector(headingCommand(_:)),
                         input: "3",
                         modifierFlags: .command),
            UIKeyCommand(title: "四级标题",
                         action: #selector(headingCommand(_:)),
                         input: "4",
                         modifierFlags: .command),
            UIKeyCommand(title: "五级标题",
                         action: #selector(headingCommand(_:)),
                         input: "5",
                         modifierFlags: .command),
            UIKeyCommand(title: "六级标题",
                         action: #selector(headingCommand(_:)),
                         input: "6",
                         modifierFlags: .command),
            UIKeyCommand(title: "正文",
                         action: #selector(headingCommand(_:)),
                         input: "0",
                         modifierFlags: .command),
            UIKeyCommand(title: "代码块",
                         action: #selector(codeBlockCommand),
                         input: "c",
                         modifierFlags: [.command, .alternate]),
            UIKeyCommand(title: "引用",
                         action: #selector(quoteCommand),
                         input: "q",
                         modifierFlags: [.command, .alternate])
        ]
    }

    // MARK: 快捷键对应的动作

    @objc private func toggleBoldCommand() { toggleBoldMarkdown() }
    @objc private func toggleItalicCommand() { toggleItalicMarkdown() }
    @objc private func toggleUnderlineCommand() { toggleUnderlineMarkdown() }
    @objc private func insertLinkCommand() { insertLinkMarkdown() }
    @objc private func codeBlockCommand() { toggleCodeBlockMarkdown() }
    @objc private func quoteCommand() { toggleQuoteMarkdown() }

    /// ⌘1~⌘6 / ⌘0 都走这里：数字写在 `UIKeyCommand.input` 里，这里读出来当标题级别。
    @objc private func headingCommand(_ sender: UIKeyCommand) {
        // UIKeyCommand.input 是可选的（系统允许不写明按键），这里取不到就什么都不做
        guard let input = sender.input,
              let level = Int(input),
              (0...6).contains(level) else { return }
        setHeadingMarkdown(level: level)
    }

    // MARK: - 对外的命令（菜单、快捷键、单元测试都调这几个）

    /// ⌘B：给选中的文字套上 `**`；再按一次脱掉。
    func toggleBoldMarkdown() {
        toggleInlineMarkup(open: "**", close: "**", actionName: "加粗")
    }

    /// ⌘I：给选中的文字套上 `*`；再按一次脱掉。
    func toggleItalicMarkdown() {
        toggleInlineMarkup(open: "*", close: "*", actionName: "斜体")
    }

    /// ⌘U：给选中的文字套上 `<u>`；再按一次脱掉。
    ///
    /// ### 为什么是 `<u>` 而不是别的
    /// markdown 本身**没有**下划线语法（CommonMark 里没有，`~~删除线~~` 是 GFM 扩展）。
    /// 通行的做法是直接用内联 HTML 的 `<u>`：swift-markdown 会把内联 HTML 原样保留，
    /// 既不会破坏别的语法，Typora / Obsidian 这些编辑器也是这么写的。
    func toggleUnderlineMarkdown() {
        toggleInlineMarkup(open: "<u>", close: "</u>", actionName: "下划线")
    }

    /// ⌘K：插入一个链接。
    ///
    /// 选了文字就当链接文字（`[选中的](url)`），没选就留空（`[](url)`）。
    /// 插入之后 **url 那三个字符是选中状态** —— 用户直接打字就把它换掉了，
    /// 不用先手动删掉占位符。
    func insertLinkMarkdown() {
        guard markedTextRange == nil else { return }
        let target = selectedSourceRange
        let selected = target.length > 0 ? sourceText.substring(with: target) : ""
        let placeholder = "url"
        let head = "[" + selected + "]("
        let text = head + placeholder + ")"

        performUndoableModelEdit(actionName: "插入链接") {
            applyEdit(renderedRange: selectedRange,
                      replacementText: text,
                      alreadyAppliedToTextStorage: false)
        }
        // 选区落在 url 上（源码坐标 → 渲染坐标），用户一打字就替换掉它
        selectSourceRange(NSRange(location: target.location + (head as NSString).length,
                                  length: (placeholder as NSString).length))
    }

    /// 把光标（或选区）所在的那几行设成 `level` 级标题；`level == 0` 表示转回正文。
    ///
    /// - 每一行**先脱掉**原有的 `#`（避免按一次就叠成 `## # 标题`），再套上新的级别；
    /// - 没选东西时只动光标所在那一行，符合「⌘1 把当前行变成一级标题」的预期。
    func setHeadingMarkdown(level: Int) {
        guard markedTextRange == nil, (0...6).contains(level) else { return }
        guard let lines = sourceLinesRange() else { return }

        let marker = level > 0 ? String(repeating: "#", count: level) + " " : ""
        let newText = lines.text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { marker + Self.textWithoutHeadingMarker(String($0)) }
            .joined(separator: "\n")
        guard newText != lines.text else { return }

        let actionName = level > 0 ? "设为 \(level) 级标题" : "转为正文"
        performUndoableModelEdit(actionName: actionName) {
            replaceSourceRange(lines.range, with: newText)
        }
        placeCaret(atSource: lines.range.location + (newText as NSString).length)
    }

    /// ⌥⌘C：多行代码块。
    ///
    /// - **没选东西**：在当前行后面新开一个空代码块（光标停在 ``` 中间那行）；
    ///   当前行是空行时直接把空行换成代码块，不留多余空行。
    /// - **选中了文字**：把选中的那些行整段包进 ``` 围栏里。
    /// - **已经是代码块**：再按一次把围栏两行去掉（回到普通文字）。
    func toggleCodeBlockMarkdown() {
        guard markedTextRange == nil else { return }
        guard let lines = sourceLinesRange() else { return }
        let fence = "```"
        let pieces = lines.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // ① 已经包着围栏 → 脱掉首尾两行
        if pieces.count >= 3,
           pieces[0].hasPrefix(fence),
           pieces[pieces.count - 1].hasPrefix(fence) {
            let inner = pieces.dropFirst().dropLast().joined(separator: "\n")
            performUndoableModelEdit(actionName: "取消代码块") {
                replaceSourceRange(lines.range, with: inner)
            }
            placeCaret(atSource: lines.range.location + (inner as NSString).length)
            return
        }

        // ② 没选东西：新建空代码块。空行就地替换；非空行则在它后面另起一段
        if selectedSourceRange.length == 0 {
            let isBlank = lines.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let head = isBlank ? "" : lines.text + "\n\n"
            let text = head + fence + "\n\n" + fence
            performUndoableModelEdit(actionName: "插入代码块") {
                replaceSourceRange(lines.range, with: text)
            }
            // 光标停在两个围栏中间那一行（"```\n" 是 4 个字符）
            placeCaret(atSource: lines.range.location + (head + fence + "\n").utf16Count)
            return
        }

        // ③ 选中了文字：整段包起来
        let text = fence + "\n" + lines.text + "\n" + fence
        performUndoableModelEdit(actionName: "转为代码块") {
            replaceSourceRange(lines.range, with: text)
        }
        placeCaret(atSource: lines.range.location + (text as NSString).length)
    }

    /// ⌥⌘Q：引用块。给光标（或选区）所在的那几行加上 `> `；再按一次去掉。
    func toggleQuoteMarkdown() {
        guard markedTextRange == nil else { return }
        guard let lines = sourceLinesRange() else { return }

        let prefix = "> "
        let pieces = lines.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // 空行不算「没加引用」—— 引用块里的空行本来就是允许的，别因为它把判定带偏
        let alreadyQuoted = pieces.allSatisfy {
            $0.trimmingCharacters(in: .whitespaces).isEmpty || $0.hasPrefix(prefix)
        }
        let newText = pieces
            .map { line -> String in
                if alreadyQuoted {
                    return line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : line
                }
                return prefix + line
            }
            .joined(separator: "\n")
        guard newText != lines.text else { return }

        performUndoableModelEdit(actionName: alreadyQuoted ? "取消引用" : "转为引用") {
            replaceSourceRange(lines.range, with: newText)
        }
        placeCaret(atSource: lines.range.location + (newText as NSString).length)
    }

    // MARK: - 行内标记（粗体 / 斜体 / 下划线共用一套）

    /// 给选中的文字套上 `open` / `close` 这一对标记；已经套着就脱掉。
    ///
    /// ### 没选中文字时怎么办
    /// 插入一对**空标记**，光标停在两个标记中间 —— 用户接着打字就落在 `**|**` 里，
    /// 不用先打标记再回头把光标挪进去。
    private func toggleInlineMarkup(open: String, close: String, actionName: String) {
        guard markedTextRange == nil else { return }
        let source = sourceText
        let target = selectedSourceRange
        let openLength = (open as NSString).length
        let closeLength = (close as NSString).length

        // ① 已经套着这对标记 → 把标记一起删掉（再按一次回到原样）
        if target.length > 0,
           target.location >= openLength,
           NSMaxRange(target) + closeLength <= source.length,
           source.substring(with: NSRange(location: target.location - openLength, length: openLength)) == open,
           source.substring(with: NSRange(location: NSMaxRange(target), length: closeLength)) == close {
            let inner = source.substring(with: target)
            let outer = NSRange(location: target.location - openLength,
                                length: target.length + openLength + closeLength)
            performUndoableModelEdit(actionName: actionName) {
                replaceSourceRange(outer, with: inner)
            }
            selectSourceRange(NSRange(location: target.location - openLength,
                                      length: (inner as NSString).length))
            return
        }

        // ② 没套着：套上去。注意替换文本用的是**源码原文**，不是屏幕上看到的富文本
        let inner = target.length > 0 ? source.substring(with: target) : ""
        let text = open + inner + close
        performUndoableModelEdit(actionName: actionName) {
            applyEdit(renderedRange: selectedRange,
                      replacementText: text,
                      alreadyAppliedToTextStorage: false)
        }

        if target.length == 0 {
            // 没选东西：光标停在两个标记中间
            placeCaret(atSource: target.location + openLength)
        } else {
            // 选了东西：套完之后仍然选着原来那段文字（不含标记），方便接着按 ⌘I 叠斜体
            selectSourceRange(NSRange(location: target.location + openLength,
                                      length: (inner as NSString).length))
        }
    }

    // MARK: - 源码范围的小工具

    /// 整篇源码（快捷方式，省得到处写 `documentStore.fullSource as NSString`）
    private var sourceText: NSString { documentStore.fullSource as NSString }

    /// 当前选区（渲染坐标）对应的**源码范围**；没选东西时是光标位置、长度 0。
    private var selectedSourceRange: NSRange {
        let start = documentStore.sourceCaret(forRenderedOffset: selectedRange.location)
        guard selectedRange.length > 0 else { return NSRange(location: start, length: 0) }
        let end = documentStore.sourceCaret(forRenderedOffset: NSMaxRange(selectedRange))
        return NSRange(location: start, length: max(0, end - start))
    }

    /// 光标（或选区）覆盖到的那几行在源码里的范围，**不含**行尾的换行。
    ///
    /// - returns: `range` 是源码范围、`text` 是这几行的原文（**包含**中间的换行）。
    private func sourceLinesRange() -> (range: NSRange, text: String)? {
        let source = sourceText
        guard source.length > 0 else { return nil }
        let selection = selectedSourceRange
        let startProbe = min(max(0, selection.location), source.length - 1)
        let firstLine = source.lineRange(for: NSRange(location: startProbe, length: 0))
        // 选区终点退一个字符：选到「行尾的换行」时不该把下一行也算进来
        let endProbe = min(max(0, NSMaxRange(selection) - (selection.length > 0 ? 1 : 0)),
                           source.length - 1)
        let lastLine = source.lineRange(for: NSRange(location: endProbe, length: 0))

        var range = NSRange(location: firstLine.location,
                            length: max(0, NSMaxRange(lastLine) - firstLine.location))
        // 掐掉行尾的换行：块与块之间那些换行在渲染里是被「吃掉」的（见分块规则），
        // 替换文本里带上它反而会让映射对不上
        while range.length > 0 {
            let last = source.character(at: NSMaxRange(range) - 1)
            if last == 0x0A || last == 0x0D { range.length -= 1 } else { break }
        }
        return (range, source.substring(with: range))
    }

    /// 把源码里的 `range` 换成 `text`（走标准编辑管线，撤销 / 重解析自动生效）。
    ///
    /// ### 为什么要先翻译回渲染坐标再校验一遍
    /// 编辑管线 `applyEdit` 只认渲染坐标，而「源码范围 → 渲染范围」这一步
    /// 在跨块时是不精确的（一段源码可能被切进好几个块，中间夹着被吃掉的换行）。
    /// 所以这里翻译完再翻译回去对一遍：**对不上就说明这一步会改错地方**，
    /// 退化成「整篇重建」—— 宁可慢一点，也不能把文字插到错的位置上。
    private func replaceSourceRange(_ sourceRange: NSRange, with text: String) {
        guard sourceRange.length > 0 else {
            // 空范围 = 纯插入：渲染文本里没有对应的字符位，按「光标」插进去
            let caret = documentStore.renderedCaret(forSourceOffset: sourceRange.location)
            applyEdit(renderedRange: NSRange(location: caret, length: 0),
                      replacementText: text,
                      alreadyAppliedToTextStorage: false)
            return
        }

        let pieces = documentStore.renderedRanges(forSourceRange: sourceRange)
        guard let first = pieces.first, let last = pieces.last else {
            replaceWholeSource(replacingRange: sourceRange, with: text)
            return
        }
        let union = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        let translatedStart = documentStore.sourceCaret(forRenderedOffset: union.location)
        let translatedEnd = documentStore.sourceCaret(forRenderedOffset: NSMaxRange(union))
        guard translatedStart == sourceRange.location, translatedEnd == NSMaxRange(sourceRange) else {
            replaceWholeSource(replacingRange: sourceRange, with: text)
            return
        }
        applyEdit(renderedRange: union, replacementText: text, alreadyAppliedToTextStorage: false)
    }

    /// 兜底：整篇重建（跨块翻译不准时才走这条路，代价是整篇重排一次）。
    private func replaceWholeSource(replacingRange range: NSRange, with text: String) {
        let newSource = sourceText.replacingCharacters(in: range, with: text)
        let caret = documentStore.renderedCaret(forSourceOffset: range.location + (text as NSString).length)
        restoreDocument(source: newSource, caret: caret)
    }

    /// 去掉一行开头的 `#` 标题标记（连它后面的空格一起）。
    ///
    /// ### 什么情况**不算**标题标记
    /// - 一个 `#` 都没有；
    /// - 超过 6 个（markdown 只到六级）；
    /// - `#` 后面没跟空格 —— CommonMark 规定 `#` 后必须有空格才是标题，
    ///   `#话题` 只是普通文字，不该被当成标题给「降级」了。
    private static func textWithoutHeadingMarker(_ line: String) -> String {
        var index = line.startIndex
        var sharps = 0
        while index < line.endIndex, line[index] == "#" {
            sharps += 1
            index = line.index(after: index)
        }
        guard (1...6).contains(sharps), index < line.endIndex, line[index] == " " else { return line }
        // 吃掉 `#` 后面多余的空格（`#   标题` 也该正常降级）
        while index < line.endIndex, line[index] == " " { index = line.index(after: index) }
        return String(line[index...])
    }

    /// 把光标放到源码的 `offset` 处（内部会换算成渲染坐标）。
    private func placeCaret(atSource offset: Int) {
        let rendered = documentStore.renderedCaret(forSourceOffset: offset)
        selectedRange = NSRange(location: min(rendered, (text as NSString).length), length: 0)
    }

    /// 选中源码的 `range` 这一段（换算成渲染坐标后写到 `selectedRange`）。
    private func selectSourceRange(_ range: NSRange) {
        guard let rendered = documentStore.renderedRange(forSourceRange: range) else {
            placeCaret(atSource: range.location)
            return
        }
        let length = (text as NSString).length
        let location = min(rendered.location, length)
        selectedRange = NSRange(location: location,
                                length: min(rendered.length, length - location))
    }
}

// MARK: - String 的小工具

private extension String {

    /// UTF-16 长度（`NSString.length` 那一套，和 NSRange 配套用）
    var utf16Count: Int { (self as NSString).length }
}
