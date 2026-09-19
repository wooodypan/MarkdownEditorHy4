//
//  PlainTextSearcher.swift
//  MarkdownEditorHy4
//
//  默认的查找实现：朴素的子串匹配（支持「区分大小写」「全字匹配」两个开关）
//

import Foundation

/// 最朴素的查找器：在全文里顺序找子串。
///
/// ### 为什么它现在够用（顺带回答「要不要放后台线程」）
/// 几千字符的文档做一轮全文子串查找是**几十微秒**的量级，而真正花时间的是后面「把命中位置换算成渲染坐标再画出来」那一步，而且那一步必须在主线程碰 TextKit。
/// 所以这里既不做索引、也不上后台队列 —— 只需要在使用侧加个防抖（见 `SearchCoordinator`）。
///
/// ### 以后要支持正则怎么办
/// 新写一个 `RegexSearcher: MarkdownSearching`，装配时换一行就行，和 `SimpleCodeHighlighter` 的接法一模一样，编辑器那边一行都不用改。
struct PlainTextSearcher: MarkdownSearching {

    func find(query: String, in source: String, options: SearchOptions) -> [NSRange] {
        // 空串不查：`NSString.range(of:)` 对空串的行为没有意义，而且会让下面的游标停在原地转圈
        guard !query.isEmpty else { return [] }

        let text = source as NSString
        let length = text.length
        // 区分大小写时用 `.literal`「逐字节比」，不用 `.caseInsensitive` 里的那套折叠规则：
        // 后者会把一些在其它语言里算「同一个字母」的字符也当成相等，用户会觉得「明明不一样却命中了」
        let compareOptions: NSString.CompareOptions = options.caseSensitive ? [.literal] : [.caseInsensitive]

        var results: [NSRange] = []
        var cursor = 0

        while cursor < length {
            let remaining = NSRange(location: cursor, length: length - cursor)
            let found = text.range(of: query, options: compareOptions, range: remaining)
            guard found.location != NSNotFound else { break }

            if !options.wholeWord || Self.isWholeWord(found, in: text) {
                results.append(found)
            }

            // 至少往前挪一格：既跳过「重叠命中」（比如搜 aa 命中 aaa 一次就够了），也保证不会出现「找到却在原地」的死循环
            cursor = found.location + max(1, found.length)
        }
        return results
    }

    // MARK: - 全字匹配

    /// 命中处的左右两边是不是都落在「单词」外面（单词 = 连续的字母 / 数字 / 下划线）。
    ///
    /// ### 判据用 `CharacterSet.alphanumerics` 的理由
    /// 它同时覆盖中英文字符：中文汉字也算 letter。于是「搜 `的` 不会命中 `目的`」
    /// 和「搜 `mark` 不会命中 `markdown`」用的是同一条规则，不用为两种语言写两套。
    ///
    /// ### emoji 这类字符
    /// 它们在 UTF-16 里是一对「代理单元」，单独取一个半字建不出 `UnicodeScalar`，这里一律当**分隔符**（也就是「单词外」）处理 —— 搜过的词贴着 emoji 时会更容易命中，属于可接受的小偏差，总比崩溃或者跳过整段强。
    private static func isWholeWord(_ range: NSRange, in text: NSString) -> Bool {
        let beforeOK = range.location == 0 || !isWordUnit(text.character(at: range.location - 1))
        let after = NSMaxRange(range)
        let afterOK = after >= text.length || !isWordUnit(text.character(at: after))
        return beforeOK && afterOK
    }

    private static func isWordUnit(_ unit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(unit) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
    }
}
