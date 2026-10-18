//
//  DocumentTextDiff.swift
//  MarkdownEditorHy4
//
//  两段文本「哪儿不一样」的一句话说明，给「校验」那个功能用。
//
//  它是纯函数：输入两段字符串，输出一句人话，跟界面没关系。留在编辑器控制器里不好读，
//  也没法单独测。从 `MarkdownDocumentViewController` 原样搬过来的。
//

import Foundation

enum DocumentTextDiff {

    /// 找出两段文本第一处不同的位置，拼一句能看懂的说明。
    ///
    /// 相同位置不同字符时，给出这个位置前后 15 个字符的片段；
    /// 前面全一样、只是长度不同时，直接说两边各多少字符。
    ///
    /// - Parameters:
    ///   - source: 文档源码（「应该是什么」）
    ///   - copied: 全选复制出来再读回来的文本（「实际是什么」）
    static func firstDifferenceDescription(_ source: String, _ copied: String) -> String {
        // 按字符（而非 UTF-16）比较：中文、emoji 都算一个，位置号读起来才和用户数的一致
        let sourceChars = Array(source)
        let copiedChars = Array(copied)
        for index in 0..<min(sourceChars.count, copiedChars.count) where sourceChars[index] != copiedChars[index] {
            // 往前多带 15 个字符，前文有上下文才看得出差在哪儿
            let start = max(0, index - 15)
            let sourceSnippet = String(sourceChars[start..<min(sourceChars.count, index + 15)])
            let copiedSnippet = String(copiedChars[start..<min(copiedChars.count, index + 15)])
            return "第 \(index) 个字符不同\n\n源码: …\(sourceSnippet)…\n复制: …\(copiedSnippet)…"
        }
        return "长度不同：源码 \(sourceChars.count) 字符，复制出来 \(copiedChars.count) 字符"
    }
}
