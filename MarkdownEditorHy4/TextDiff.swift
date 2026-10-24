//
//  TextDiff.swift
//  MarkdownEditorHy4
//
//  文本对比：把两份纯文本按行比一遍，标出"哪些行是这一版才有的、哪些行是现在才有的"。
//
//  大白话：拿旧稿和新稿对着看，多出来的句子和少掉的句子分别标出来。
//
//  这里只管算，不碰界面、不碰文件，所以可以放到后台线程去跑（几千行的文档在主线程算会卡一下）。
//  显示成什么样由 `DocumentVersionPreviewController` 决定。
//

import Foundation

/// 对比结果里的一行。
struct DiffLine {

    /// 这一行在对比里的身份
    enum Kind {
        /// 两边一模一样
        case same
        /// 只有"选中的那一版"有：恢复之后这行会加进来（绿色）
        case added
        /// 只有"编辑器里现在的内容"有：恢复之后这行会消失（红色）
        case removed
    }

    let kind: Kind
    let text: String

    /// 行内要额外标深的字符位置（按"第几个字"算，不是字节数）。
    ///
    /// 一整段话只改了几个字时，整行绿/红看不出改在哪儿，靠这个把改到的字再压深一点。
    /// 空数组表示不细分（两边差太多，或者这一行太长没算）。
    var highlight: [Range<Int>] = []
}

/// 对比页面上真正显示的一行：要么是一行文字，要么是"中间有 N 行没动"的折叠条。
enum DiffDisplayRow {
    case line(DiffLine)
    /// 收起来的一段：从第 `start` 行开始，一共 `count` 行
    case gap(count: Int, start: Int)
}

/// 按行对比两份文本。
enum TextDiff {

    /// 行内逐字对比最多算这么多个字，超了就只铺整行底色。
    ///
    /// 实测：2000 个字全改要 12 毫秒，20000 个字全改要 1.8 秒。
    /// 一行两万字一般是超长表格行或者被压成一行的内容，那种情况标整行就够了，不值得为它卡一下。
    static let inlineCharacterLimit = 2000

    /// 每处改动前后各留几行没改的当上下文，其余折起来（和 GitHub 一个路子）。
    static let contextLineCount = 3

    /// 按行切开。
    ///
    /// `\r\n` 和单独的 `\r` 都当成换行：不同平台编辑过的文件混在一起时，不统一的话整篇都会被算成"改了"。
    nonisolated static func lines(in text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    /// 比两份文本，按"编辑器里的顺序"排好。
    ///
    /// - Parameters:
    ///   - current: 编辑器里现在的内容，也就是恢复时会被覆盖掉的那一份（红色那一侧）
    ///   - version: 选中的历史版本（绿色那一侧）
    /// - Returns: 一行一条，改动的行夹在没改的行中间，顺序和原文一致
    nonisolated static func diff(current: String, version: String) -> [DiffLine] {
        let currentLines = lines(in: current)
        let versionLines = lines(in: version)

        // Foundation 自带的 Myers 实现：告诉你新数组里哪几个位置是插进来的、旧数组里哪几个位置是删掉的。
        // 注意两个 offset 各算各的：remove 的下标在 currentLines 里，insert 的下标在 versionLines 里。
        let changes = versionLines.difference(from: currentLines)
        var removedOffsets = Set<Int>()
        var insertedOffsets = Set<Int>()
        for change in changes {
            switch change {
            case .remove(let offset, _, _): removedOffsets.insert(offset)
            case .insert(let offset, _, _): insertedOffsets.insert(offset)
            }
        }

        // 两个下标一起往前走，把"删了哪些、加了哪些"重新拼成一条完整的时间线。
        // 同一处改动会先排完删掉的行、再排加进来的行，下面的行内对比就靠这个顺序配对。
        var result: [DiffLine] = []
        result.reserveCapacity(max(currentLines.count, versionLines.count))
        var i = 0
        var j = 0
        while i < currentLines.count || j < versionLines.count {
            if i < currentLines.count, removedOffsets.contains(i) {
                result.append(DiffLine(kind: .removed, text: currentLines[i]))
                i += 1
            } else if j < versionLines.count, insertedOffsets.contains(j) {
                result.append(DiffLine(kind: .added, text: versionLines[j]))
                j += 1
            } else if j < versionLines.count {
                result.append(DiffLine(kind: .same, text: versionLines[j]))
                i += 1
                j += 1
            } else {
                // 理论上走不到这儿：删的行前面已经排完了。
                // 真走到了说明 diff 的结果对不上，宁可少显示一行也别越界崩掉。
                break
            }
        }

        applyInlineHighlights(to: &result)
        return result
    }

    /// 给"删一行 + 加一行"这种成对的改动算行内差异，标到字上。
    ///
    /// 一整段 markdown 通常就是一行，不细到字的话，"改两个字"和"整段重写"看起来一模一样。
    nonisolated private static func applyInlineHighlights(to lines: inout [DiffLine]) {
        var index = 0
        while index < lines.count {
            guard lines[index].kind != .same else {
                index += 1
                continue
            }
            // 找出连在一起的一段改动（中间没有没改的行）
            var end = index
            while end < lines.count, lines[end].kind != .same { end += 1 }

            let removedIndices = (index..<end).filter { lines[$0].kind == .removed }
            let addedIndices = (index..<end).filter { lines[$0].kind == .added }
            // 按顺序一一配对：第 1 行删的配第 1 行加的，配不上的（多出来的行）就不做行内标记
            for (oldIndex, newIndex) in zip(removedIndices, addedIndices) {
                let ranges = characterChanges(old: lines[oldIndex].text, new: lines[newIndex].text)
                lines[oldIndex].highlight = ranges.old
                lines[newIndex].highlight = ranges.new
            }
            index = end
        }
    }

    /// 一行字里，哪几个字变了。
    ///
    /// 先把开头和结尾一样的字砍掉，只在中间那段逐字比 —— 大部分改动都发生在中间一小块，砍完再比能省下大量计算。中文没有空格分词，按"字"比正合适。
    nonisolated static func characterChanges(old: String, new: String) -> (old: [Range<Int>], new: [Range<Int>]) {
        let oldCharacters = Array(old)
        let newCharacters = Array(new)

        var prefix = 0
        while prefix < oldCharacters.count,
              prefix < newCharacters.count,
              oldCharacters[prefix] == newCharacters[prefix] {
            prefix += 1
        }

        var suffix = 0
        while suffix < oldCharacters.count - prefix,
              suffix < newCharacters.count - prefix,
              oldCharacters[oldCharacters.count - 1 - suffix] == newCharacters[newCharacters.count - 1 - suffix] {
            suffix += 1
        }

        let oldMiddle = Array(oldCharacters[prefix..<(oldCharacters.count - suffix)])
        let newMiddle = Array(newCharacters[prefix..<(newCharacters.count - suffix)])
        guard oldMiddle.count + newMiddle.count <= inlineCharacterLimit else { return ([], []) }

        var oldOffsets: [Int] = []
        var newOffsets: [Int] = []
        for change in newMiddle.difference(from: oldMiddle) {
            switch change {
            case .remove(let offset, _, _): oldOffsets.append(prefix + offset)
            case .insert(let offset, _, _): newOffsets.append(prefix + offset)
            }
        }
        return (mergeIntoRanges(oldOffsets), mergeIntoRanges(newOffsets))
    }

    /// 把一个个单独的下标并成连续区间：3、4、5 变成 3..<6。
    ///
    /// 逐字标色时一段连续改动只需要标一次，区间越少后面给文字上色越快。
    nonisolated private static func mergeIntoRanges(_ offsets: [Int]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        for offset in offsets.sorted() {
            if let last = ranges.last, last.upperBound == offset {
                ranges[ranges.count - 1] = last.lowerBound..<(offset + 1)
            } else {
                ranges.append(offset..<(offset + 1))
            }
        }
        return ranges
    }

    /// 把完整对比结果折成"改动附近看得见、其余收起来"的一串行。
    ///
    /// - Parameter expandedGaps: 用户点开过的折叠段（记的是那一段第一行的下标）
    nonisolated static func displayRows(_ lines: [DiffLine], expandedGaps: Set<Int>) -> [DiffDisplayRow] {
        guard !lines.isEmpty else { return [] }

        // 先把"要露出来"的行号圈出来：每处改动前后各留 contextLineCount 行
        var visible = Set<Int>()
        for (index, line) in lines.enumerated() where line.kind != .same {
            let lower = max(0, index - contextLineCount)
            let upper = min(lines.count - 1, index + contextLineCount)
            for candidate in lower...upper {
                visible.insert(candidate)
            }
        }

        var rows: [DiffDisplayRow] = []
        var index = 0
        while index < lines.count {
            if visible.contains(index) {
                rows.append(.line(lines[index]))
                index += 1
                continue
            }
            var end = index
            while end < lines.count, !visible.contains(end) { end += 1 }
            if expandedGaps.contains(index) {
                for hidden in index..<end {
                    rows.append(.line(lines[hidden]))
                }
            } else {
                rows.append(.gap(count: end - index, start: index))
            }
            index = end
        }
        return rows
    }
}
