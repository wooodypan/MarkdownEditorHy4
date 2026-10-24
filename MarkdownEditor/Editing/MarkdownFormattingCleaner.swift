//
//  MarkdownFormattingCleaner.swift
//  MarkdownEditorHy4
//
//  「清除文本格式」的纯文本处理：只删标记符，文字一个都不动。
//

import Foundation

/// 把一段 markdown 源码里成对的标记符脱掉。
///
/// ### 支持哪几种
/// - 成对的 `*`：`*斜体*`、`**粗体**`、`***粗斜体***`，按「同样长度的连续段」配对；
/// - 成对的 `_`：`_斜体_`、`__粗体__`，但夹在字母 / 数字中间的不算（`snake_case` 里的下划线是名字的一部分）；
/// - 成对的 `~~`：删除线（单个 `~` 不算标记，`约~5个` 这种写法原样留着）；
/// - 成对的 1~2 个反引号：行内代码，包括 `` ``a`b`` `` 这种多反引号写法；
/// - 成对的 `<u>` / `</u>`：下划线（⌘U 插的就是这一对）；
/// - 行首的 `#` 加空格：1~6 级标题。
///
/// 配不上的单个标记一律不删 —— 用户要的是「成对出现的标记符」，把落单的星号也删掉就是改文字了。
///
/// ### 为什么不用正则
/// `**` 和 `*` 会互相打架：先跑斜体规则会把粗体拆坏，先跑粗体又管不了 `*斜体*`。
/// 更要紧的是「成对」得看整段选区的配对情况 —— 选区边上只剩半个 `**` 时不能删，正则逐条替换表达不了这件事。
/// 所以这里扫成「等长的连续标记段」，同一种字符、同样长度才算一对。
///
/// ### 代码块不进来
/// 调用方会先把代码块从选区里剔出去（见 `MarkdownTextView+Formatting.swift` 的 `clearFormattingTarget`），
/// 这里拿到的都是正文，不用再判断围栏。
enum MarkdownFormattingCleaner {

    /// 清一遍标记符。
    ///
    /// - parameter startsAtLineStart: 这段文字是不是从一行的开头开始。
    ///   右键选区常常从一行中间起头，那种情况下开头的 `#` 不是标题标记，不能删。
    /// - parameter precededByWord: 这段文字左边挨着的那个字符算不算「单词字符」（字母 / 数字）。
    ///   选区可能刚好切在 `snake_case_name` 中间，光看段落内部判断不出左边的邻居，得由调用方补进来。
    /// - parameter followedByWord: 同理，右边挨着的那个字符算不算单词字符。
    /// - returns: 清完的文字。和入参相同就说明这段里没有能清的标记。
    static func stripped(_ source: String,
                         startsAtLineStart: Bool = true,
                         precededByWord: Bool = false,
                         followedByWord: Bool = false) -> String {
        guard !source.isEmpty else { return source }
        // 快速放行：一个标记字符都没有就别往下走。全选一篇大文档时，这一步能省掉整段转 Array 的开销
        guard source.contains("*") || source.contains("_") || source.contains("~")
            || source.contains("`") || source.contains("#") || source.contains("<") else {
            return source
        }

        let characters = Array(source)
        // true 表示这个位置是标记符，拼结果时跳过
        var removed = [Bool](repeating: false, count: characters.count)

        markHeadingMarkers(in: characters, startsAtLineStart: startsAtLineStart, removed: &removed)
        markUnderlineTags(in: characters, removed: &removed)
        markPairedMarkers(in: characters,
                          startsAtLineStart: startsAtLineStart,
                          precededByWord: precededByWord,
                          followedByWord: followedByWord,
                          removed: &removed)

        guard removed.contains(true) else { return source }

        var result = ""
        result.reserveCapacity(source.count)
        for (index, character) in characters.enumerated() where !removed[index] {
            result.append(character)
        }
        return result
    }

    // MARK: - 行首标题标记

    /// 把每一行开头的 `#` 和它后面的空格标成「删掉」。
    private static func markHeadingMarkers(in characters: [Character],
                                           startsAtLineStart: Bool,
                                           removed: inout [Bool]) {
        var lineStart = 0
        var isFirstLine = true

        while lineStart < characters.count {
            var lineEnd = lineStart
            while lineEnd < characters.count, !isLineBreak(characters[lineEnd]) {
                lineEnd += 1
            }

            // 第一行可能是从半行开始选的，它前面没有换行，按「非行首」处理
            if !isFirstLine || startsAtLineStart {
                markHeadingPrefix(in: characters, from: lineStart, to: lineEnd, removed: &removed)
            }
            isFirstLine = false

            // 跳过行尾的换行（`\r\n` 在 Swift 里算一个 Character，这里一次盖住）
            var next = lineEnd
            while next < characters.count, isLineBreak(characters[next]) {
                next += 1
            }
            lineStart = next
        }
    }

    /// 这个字符是不是换行符。
    ///
    /// 只认 markdown 认的那几种：`\n`、`\r`、`\r\n`。Swift 的 `isNewline` 还会把 U+2028 这类也算进来，
    /// 而编辑器其它地方（`isLineStart`）只认 `\r` / `\n`，两边对齐才不会在段尾算错行。
    private static func isLineBreak(_ character: Character) -> Bool {
        character == "\n" || character == "\r" || character == "\r\n"
    }

    /// 一行开头的 `# ` 到 `###### `。
    ///
    /// 只认第一列：`  # 标题` 前面有空格，就不算「行首标记」，原样留着。
    private static func markHeadingPrefix(in characters: [Character],
                                          from start: Int,
                                          to end: Int,
                                          removed: inout [Bool]) {
        var index = start
        while index < end, characters[index] == "#" {
            index += 1
        }
        let level = index - start
        // 超过六级不是标题；`#` 后面没空格也不是标题（`#话题` 只是普通文字）
        guard (1...6).contains(level), index < end, characters[index] == " " else { return }

        for position in start..<index {
            removed[position] = true
        }
        // `#   标题` 这种多打的空格一起收掉，不然行首会剩一段空白
        while index < end, characters[index] == " " {
            removed[index] = true
            index += 1
        }
    }

    // MARK: - 成对的行内标记

    /// 一段连续的同类标记字符（比如 `**` 是两个字符的一连）
    private struct MarkerRun {
        let start: Int
        let length: Int
    }

    /// 配对用的键：同一种字符、同样长度才可能成一对
    private struct MarkerKey: Hashable {
        let character: Character
        let length: Int
    }

    /// 哪些字符算行内标记，各自允许几连。
    ///
    /// `*` 和 `_` 都允许 1~3 连（斜体 / 粗体 / 粗斜体），`~` 只认 2 连（删除线），反引号允许 1~2 连（行内代码）。
    /// 更长的连续段多半是三连反引号那种代码围栏，不碰。
    private static func allowedLengths(of character: Character) -> [Int] {
        switch character {
        case "*", "_": return [1, 2, 3]
        case "~": return [2]
        case "`": return [1, 2]
        default: return []
        }
    }

    /// 找出成对的标记段，把它们标成「删掉」。
    private static func markPairedMarkers(in characters: [Character],
                                          startsAtLineStart: Bool,
                                          precededByWord: Bool,
                                          followedByWord: Bool,
                                          removed: inout [Bool]) {
        // 每种「字符 + 长度」各一条待配对栈：`**a**` 和它里面嵌的 `*b*` 互不干扰
        var pending: [MarkerKey: [MarkerRun]] = [:]

        var index = 0
        while index < characters.count {
            let character = characters[index]
            let allowed = allowedLengths(of: character)
            guard !allowed.isEmpty else {
                index += 1
                continue
            }

            var end = index + 1
            while end < characters.count, characters[end] == character {
                end += 1
            }
            let length = end - index

            // 行首的 `* ` 是列表符号，不是强调标记：用户要求保留列表，不能拿去配对
            let isBullet = character == "*"
                && isBulletMarker(in: characters, at: index, runLength: length, startsAtLineStart: startsAtLineStart)

            // 词内的下划线不算标记：`snake_case` / `foo_bar` 里的下划线是名字的一部分，删了就把变量名毁了
            let isIntraword = character == "_"
                && isIntrawordUnderscore(in: characters,
                                         at: index,
                                         runLength: length,
                                         precededByWord: precededByWord,
                                         followedByWord: followedByWord)

            guard allowed.contains(length), !isBullet, !isIntraword else {
                index = end
                continue
            }

            let key = MarkerKey(character: character, length: length)
            var stack = pending[key] ?? []
            if let opener = stack.last {
                // 配上了：开头那段和这一段一起删
                for position in opener.start..<(opener.start + opener.length) {
                    removed[position] = true
                }
                for position in index..<end {
                    removed[position] = true
                }
                stack.removeLast()
            } else {
                stack.append(MarkerRun(start: index, length: length))
            }
            pending[key] = stack
            index = end
        }
    }

    /// 这个 `*` 连续段是不是行首的列表符号（`* 项目`，允许前面最多三个空格缩进）。
    private static func isBulletMarker(in characters: [Character],
                                       at start: Int,
                                       runLength: Int,
                                       startsAtLineStart: Bool) -> Bool {
        guard runLength == 1, start + 1 < characters.count, characters[start + 1] == " " else {
            return false
        }

        var probe = start
        var spaces = 0
        while probe > 0, characters[probe - 1] == " ", spaces < 3 {
            probe -= 1
            spaces += 1
        }
        if probe == 0 { return startsAtLineStart }
        return isLineBreak(characters[probe - 1])
    }

    /// 这个 `_` 连续段是不是被字母 / 数字夹在中间（`snake_case`、`foo_bar` 那种）。
    ///
    /// ### 为什么要单独判一下
    /// CommonMark 本来就不把词内下划线当强调标记，渲染出来就是普通的 `_`。
    /// 清除格式要是把 `snake_case_name` 变成 `snakecasename`，那是在删用户的文字，不是去格式。
    /// 两边都是字母 / 数字时跳过这一段；只要有一边是空格、标点或行首行尾，就照常参与配对。
    ///
    /// 选区边上的那一个字符不在 `characters` 里，用调用方传进来的 `precededByWord` / `followedByWord` 补。
    private static func isIntrawordUnderscore(in characters: [Character],
                                              at start: Int,
                                              runLength: Int,
                                              precededByWord: Bool,
                                              followedByWord: Bool) -> Bool {
        let end = start + runLength
        let beforeIsWord = start > 0 ? isWordCharacter(characters[start - 1]) : precededByWord
        let afterIsWord = end < characters.count ? isWordCharacter(characters[end]) : followedByWord
        return beforeIsWord && afterIsWord
    }

    /// 算不算「单词里的字符」。中文也算字母（`isLetter` 为真），跟渲染器那边的判断保持一致。
    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    // MARK: - 下划线标签 `<u>`

    /// 把成对的 `<u>` 和 `</u>` 标成「删掉」。
    ///
    /// ### 为什么单独扫一遍
    /// 这是 HTML 标签，不是单个标记字符，塞不进上面那套「等长连续段」的配对逻辑。
    /// 用栈记还没闭合的开标签，遇到 `</u>` 就把它和最近那个 `<u>` 一起删掉。
    /// 落单的开标签或闭标签一律不动 —— 删了会剩下一个看不见的标签，比留着更糟。
    ///
    /// 标签名按 HTML 的规矩不分大小写（`<U>` 也认）；`<u >` 这种带空格的写法不认 —— ⌘U 插的永远是 `<u>`，够用。
    private static func markUnderlineTags(in characters: [Character], removed: inout [Bool]) {
        // 存开标签的位置和长度，配对时两段一起删
        var openTags: [(start: Int, length: Int)] = []

        var index = 0
        while index < characters.count {
            guard characters[index] == "<" else {
                index += 1
                continue
            }

            if let length = underlineTagLength(in: characters, at: index, isClosing: false) {
                openTags.append((start: index, length: length))
                index += length
                continue
            }
            if let length = underlineTagLength(in: characters, at: index, isClosing: true) {
                if let opener = openTags.popLast() {
                    for position in opener.start..<(opener.start + opener.length) {
                        removed[position] = true
                    }
                    for position in index..<(index + length) {
                        removed[position] = true
                    }
                }
                index += length
                continue
            }
            index += 1
        }
    }

    /// 从 `start` 开始是不是一个 `<u>` 或 `</u>`；是的话返回它的长度（3 或 4）。
    private static func underlineTagLength(in characters: [Character],
                                           at start: Int,
                                           isClosing: Bool) -> Int? {
        var index = start + 1
        if isClosing {
            guard index < characters.count, characters[index] == "/" else { return nil }
            index += 1
        }
        guard index < characters.count, characters[index] == "u" || characters[index] == "U" else { return nil }
        index += 1
        guard index < characters.count, characters[index] == ">" else { return nil }
        return index + 1 - start
    }
}
