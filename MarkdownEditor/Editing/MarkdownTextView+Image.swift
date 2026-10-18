//
//  MarkdownTextView+Image.swift
//  MarkdownEditorHy4
//
//  插入图片：组件只把 `![alt](path)` 写进正文。
//
//  组件不提供图片选择器。相册、文件、拍照都是使用方的界面和权限，
//  组件只接收图片路径；图片从哪来、存到哪由 App 决定
//  （本仓库见 `MarkdownDocumentViewController.chooseImageToInsert`）。
//

import UIKit

extension MarkdownTextView {

    /// 在光标（或选区）处插入一张图片的 markdown 源码，这次插入可撤销。
    ///
    /// 调用方先把图片存成文件，拿到正文要写的路径，再交给这里。
    /// 这里不读磁盘、不弹选择器，也不认识图库 API。
    ///
    /// - Parameters:
    ///   - path: `![](...)` 圆括号里的图片地址（相对路径 / 绝对路径 / 网络地址都行）
    ///   - alt: 方括号里的替代文字；传空串表示不写文字
    /// - Returns: 有没有真的插进去（只读、路径为空、或者正在输入法组字时返回 false）
    @discardableResult
    func insertImageMarkdown(path: String, alt: String = "图片") -> Bool {
        // 只读时 `applyEdit` 也会拦，这里提前返回，调用方才能知道没插成
        guard !isReadOnly, markedTextRange == nil else { return false }
        let destination = Self.markdownImageDestination(path)
        guard !destination.isEmpty else { return false }

        let altText = Self.markdownImageAlt(alt)
        insertMarkdownSourceUndoably("![\(altText)](\(destination))", actionName: "插入图片")
        return true
    }

    // MARK: - 源码拼装

    /// 整理图片路径，使它能够安全地放进 `![](...)`。
    ///
    /// markdown 的图片地址默认不允许空格：`![](my photo.png)` 会把地址解析成 `my`，图不显示。
    /// 自定义图片目录（Mac 上可以选任意文件夹）很容易带空格；路径里的括号也会提前截断 `(...)`。
    /// 出现空白或括号时把整段路径包进 `<…>`，这是 CommonMark 提供的写法，
    /// `ImageLoader.resolve` 会先剥掉外层尖括号。
    ///
    /// - Returns: 整理后的地址；空路径返回空串
    private static func markdownImageDestination(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // 调用方已经自己包好了就别包第二层
        if trimmed.hasPrefix("<"), trimmed.hasSuffix(">") { return trimmed }

        let needsWrapping = trimmed.contains { $0.isWhitespace || $0 == "(" || $0 == ")" }
        return needsWrapping ? "<\(trimmed)>" : trimmed
    }

    /// 整理 `![...]` 里的替代文字。
    ///
    /// 方括号会截断 `![…]`（`![a]b](x.png)` 会解析成一段文字加坏语法），直接去掉；
    /// 两头的空白也去掉，避免写出一对只有空格的方括号。
    private static func markdownImageAlt(_ alt: String) -> String {
        String(alt.filter { $0 != "[" && $0 != "]" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
