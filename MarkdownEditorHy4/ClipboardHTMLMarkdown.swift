//
//  ClipboardHTMLMarkdown.swift
//  MarkdownEditorHy4
//
//  剪贴板那一步：从 `UIPasteboard` 里取出 HTML，交给 `HTMLToMarkdownConverter` 转成源码。
//
//  ### 为什么要单独一个文件
//  「怎么把 HTML 变成 markdown」和「什么时候该变」是两件事：
//  前者是纯函数（见 `HTMLToMarkdownConverter`），可以脱离 App 单独测；
//  后者要读剪贴板、要看设置开关，是 App 的活。分开之后各自的边界很清楚。
//

import UIKit

/// 剪贴板里的富文本 → markdown 源码。
enum ClipboardHTMLMarkdown {

    /// 剪贴板里 HTML 的那个类型标识（`public.html`）。
    ///
    /// ### 为什么写字符串而不是 `UTType.html.identifier`
    /// 浏览器放进去的就是这个 UTI，`UniformTypeIdentifiers` 在 iOS 14 之前没有，而且这里只是「按名字取一个类型」，用不上 UTType 那套能力。
    private static let htmlType = "public.html"

    /// 试着把剪贴板里的富文本转成 markdown 源码。
    ///
    /// - returns: 转出来的源码；**返回 `nil` 表示这一步不接管**，调用方该退回「按纯文本粘贴」
    ///
    /// ### 什么情况下返回 `nil`
    /// 1. 设置里把开关关了；
    /// 2. 剪贴板里根本没有 HTML（复制的是纯文本、图片…）；
    /// 3. 有 HTML 但一个字都没转出来（多半是整页都是脚本 / 样式表）。
    ///
    /// ⚠️ 「HTML 转出来比纯文本还少」这种情况刻意不管：
    /// 复制网页时浏览器给的纯文本本来就带着菜单、页脚那些噪音，宁可用 HTML 的结构。
    static func markdown(from pasteboard: UIPasteboard,
                         settings: MarkdownEditorSettings = .shared) -> String? {
        guard settings.pastesHTMLAsMarkdown else { return nil }
        guard let html = html(in: pasteboard), !html.isEmpty else { return nil }
        return HTMLToMarkdownConverter.markdown(fromHTML: html)
    }

    /// 取剪贴板里的 HTML 原文。
    ///
    /// ### 编码为什么按 UTF-8 试，失败了再退回 latin1
    /// 网页复制出来的几乎都是 UTF-8；但有些老页面（或者 Word）给的是别的编码，硬解成 UTF-8 会得到 `nil`，整段内容就没了 —— 退回 isoLatin1 至少不会一个字都不剩（中文会乱码，但那也比「粘贴了个空」强）。
    private static func html(in pasteboard: UIPasteboard) -> String? {
        guard let data = pasteboard.data(forPasteboardType: htmlType), !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }
}
