//
//  FootnoteIndex.swift
//  MarkdownEditorHy4
//
//  脚注（GFM 的 `[^1]` 引用 / `[^1]: 说明` 定义）的识别与查表。
//
//  ### 为什么是自己扫源码，而不是靠 swift-markdown
//  本工程锁的 swift-markdown 0.8.0 **没有**脚注节点 —— 仓库里根本查不到 `FootnoteReference` / `FootnoteDefinition`， cmark 会把 `[^1]` 当成普通文字、`[^1]: 说明` 当成一个普通段落递给我们。
//  好在脚注正好是「不用改字符、只换样式」的那类语法：引用标记那几个字符一个不动，只是画成上标并换个颜色，所以**认出它们**就够了，不需要 AST 节点。
//
//  ### 为什么没有照方案那样维护一张「随解析增量更新」的索引表
//  方案里设计的是 `definitionsByID` + `referenceOrder` 两张表，跟着块的重建一起更新。这里没这么做，有两条理由：
//  1. **编号用不上**：引用显示的就是源码里那几个字符（`[^1]` 本身就写着 1），本编辑器「展示的一定是源码本身」，
//     不需要另外算「这是第几个脚注」—— 省掉了 `referenceOrder`，也就省掉了「按引用顺序重排编号」带来的跨块重渲染；
//  2. **要跨块回答的只剩两个问题**：「这个 ID 有没有定义」「定义在哪儿」。整篇源码里 `[^` 根本没几处，
//     现扫一遍就能答（代价和扫几个字符一样），比维护一份「编辑完记得同步」的状态更不容易出错 ——少同步一处就是「改了定义，正文里引用的颜色却不变」这种玄学 bug。
//

import Foundation

/// 源码里认出来的一处脚注标记（`[^1]` 这几个字符本身）。
struct FootnoteMatch {
    /// 脚注 ID（`[^1]` 里的那个 `1`）
    let id: String
    /// 这段标记在**被扫描的那段文本**里的 UTF-16 范围
    let range: NSRange
}

/// 脚注的识别与查表。
///
/// 全是纯函数（只认字符串），不持有任何状态 —— 也就没有「状态过期」这回事。
enum FootnoteIndex {

    // MARK: 引用

    /// 在一段文本里找出所有脚注引用（`[^1]`）。
    ///
    /// ### 认到什么程度算数
    /// `[^` 开头、同一行内能找到配对的 `]`、中间至少有一个字符。**不判断**有没有对应的定义 ——那是调用方拿着 `definitions(in:)` 的结果去比的事（没有定义 = 悬空引用，画成断链的颜色）。
    static func references(in text: String) -> [FootnoteMatch] {
        let ns = text as NSString
        var result: [FootnoteMatch] = []
        var from = 0

        while from + 1 < ns.length {
            let found = ns.range(of: "[^", options: [], range: NSRange(location: from, length: ns.length - from))
            guard found.location != NSNotFound else { break }
            // 认不出完整标记（比如 `[^` 后面到行尾都没有 `]`）也要继续往后找，不能停在原地死循环
            guard let match = marker(in: ns, startingAt: found.location) else {
                from = found.location + 2
                continue
            }
            result.append(match)
            from = NSMaxRange(match.range)
        }
        return result
    }

    // MARK: 定义

    /// 一段文本**开头**是不是脚注定义（`[^1]:`）。返回的 `range` **含**末尾那个冒号。
    ///
    /// ### 为什么只看开头
    /// 「定义」和「引用」用的是同一串字符，区别只在位置：写在行首、后面紧跟冒号的是定义，出现在正文中间的是引用。所以这个函数只认开头那一段（前面的空行 / 缩进要跳过 ——块源码开头常常带着上一块留下的换行）。
    static func definitionMarker(in text: String) -> FootnoteMatch? {
        let ns = text as NSString

        // 跳过开头的空白和换行，找到第一个真正的字符
        var index = 0
        while index < ns.length {
            let character = ns.character(at: index)
            if isWhitespaceOrBreak(character) { index += 1 } else { break }
        }
        guard index + 1 < ns.length,
              ns.character(at: index) == 0x5B /* [ */,
              ns.character(at: index + 1) == 0x5E /* ^ */,
              let match = marker(in: ns, startingAt: index) else { return nil }

        // 标记后面必须紧跟冒号 —— 那才是定义
        let after = NSMaxRange(match.range)
        guard after < ns.length, ns.character(at: after) == 0x3A /* : */ else { return nil }

        return FootnoteMatch(id: match.id,
                             range: NSRange(location: match.range.location,
                                            length: match.range.length + 1))
    }

    /// 整篇源码里所有的脚注定义：ID → 定义块起点的**绝对偏移**（UTF-16，相对整篇开头）。
    ///
    /// 同一个 ID 定义了两次时以**先出现的那份**为准 —— 后一份是重复的，跳过去没意义。
    static func definitions(in source: String) -> [String: Int] {
        let ns = source as NSString
        var result: [String: Int] = [:]
        var from = 0

        while from + 1 < ns.length {
            let found = ns.range(of: "[^", options: [], range: NSRange(location: from, length: ns.length - from))
            guard found.location != NSNotFound else { break }
            from = found.location + 2

            // 必须顶在行首（允许缩进）：正文中间的 `[^1]` 是引用，不是定义
            guard isLineStart(ns, found.location),
                  let match = marker(in: ns, startingAt: found.location) else { continue }
            let after = NSMaxRange(match.range)
            guard after < ns.length, ns.character(at: after) == 0x3A /* : */ else { continue }

            if result[match.id] == nil { result[match.id] = match.range.location }
        }
        return result
    }

    /// 某个 ID 的定义在哪儿（绝对偏移）；没定义过返回 `nil`。点正文里的引用跳转时用。
    static func definitionOffset(for id: String, in source: String) -> Int? {
        definitions(in: source)[id]
    }

    /// 整篇源码里已经定义了哪些 ID。渲染器拿它判断「这个引用是不是悬空」。
    static func definitionIDs(in source: String) -> Set<String> {
        Set(definitions(in: source).keys)
    }

    /// 某个 ID 的定义**整块**占的源码范围：从 `[^1]:` 那个 `[` 起，到下一个定义（或文档末尾）为止，尾巴上的空行不算。
    ///
    /// 跳转落地时靠它决定「高亮哪一段」—— 只高亮 `[^1]:` 那几个字符太不起眼，整条定义亮一下才看得出「我跳到这儿了」。
    static func definitionBlockRange(for id: String, in source: String) -> NSRange? {
        let ns = source as NSString
        let all = definitions(in: source)
        guard let start = all[id] else { return nil }

        // 终点：下一个定义的起点；没有下一个就到文档末尾
        var end = all.values.filter { $0 > start }.min() ?? ns.length
        // 尾巴上的空行 / 空段落不属于这条脚注，去掉（但至少留一个字符，免得算出空范围）
        while end - 1 > start {
            guard isWhitespaceOrBreak(ns.character(at: end - 1)) else { break }
            end -= 1
        }
        return NSRange(location: start, length: max(1, end - start))
    }

    // MARK: 回跳

    /// 某个 ID 在**正文**里出现的所有位置（`[^1]` 这几个字符的范围），按出现顺序排。
    ///
    /// ### 为什么要排掉定义块开头那个
    /// `[^1]:` 和 `[^1]` 用的是同一串字符，扫的时候两个都会命中。回跳要的是「正文里提到它的地方」，把定义自己算进去就会出现「点定义跳到定义」的怪事 —— 所以凡是顶在行首、后面紧跟冒号的，一律不算引用。
    static func referenceRanges(for id: String, in source: String) -> [NSRange] {
        let ns = source as NSString

        return references(in: source).compactMap { match in
            guard match.id == id else { return nil }
            let after = NSMaxRange(match.range)
            let isDefinitionMarker = isLineStart(ns, match.range.location)
                && after < ns.length
                && ns.character(at: after) == 0x3A /* : */
            return isDefinitionMarker ? nil : match.range
        }
    }

    /// 某个 ID 在正文里第一次出现的位置。点定义回跳时用它当落脚点（没有引用就返回 nil，跳不动）。
    static func firstReferenceOffset(for id: String, in source: String) -> Int? {
        referenceRanges(for: id, in: source).first?.location
    }

    // MARK: 内部

    /// 从 `start` 处那个 `[^` 开始，认出一个完整的 `[^id]`（找不到配对的 `]` 就返回 nil）。
    private static func marker(in ns: NSString, startingAt start: Int) -> FootnoteMatch? {
        var index = start + 2
        while index < ns.length {
            let character = ns.character(at: index)
            if character == 0x5D /* ] */ {
                let idLength = index - (start + 2)
                // `[]` 中间一个字符都没有不算脚注（用户刚敲完 `[^]` 那半个状态）
                guard idLength > 0 else { return nil }
                return FootnoteMatch(id: ns.substring(with: NSRange(location: start + 2, length: idLength)),
                                     range: NSRange(location: start, length: index - start + 1))
            }
            // 换行就放弃：脚注标记不能跨行（跨行的 `]` 八成是别的内容的收尾）
            if character == 0x0A || character == 0x0D { return nil }
            index += 1
        }
        return nil
    }

    /// `location` 前面是不是只有空格 / tab（也就是它顶在行首，允许缩进）
    private static func isLineStart(_ ns: NSString, _ location: Int) -> Bool {
        var index = location - 1
        while index >= 0 {
            let character = ns.character(at: index)
            if character == 0x0A || character == 0x0D { return true }
            if character == 0x20 || character == 0x09 { index -= 1; continue }
            return false
        }
        return true     // 一直退到文档开头，也算行首
    }

    private static func isWhitespaceOrBreak(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09 || character == 0x0A || character == 0x0D
    }
}
