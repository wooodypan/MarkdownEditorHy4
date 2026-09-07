//
//  MarkdownPasteboardController.swift
//  MarkdownEditorHy4
//
//  剪贴板层：拦截 copy / cut / paste
//
//  ### 核心原则
//  **渲染出来的 NSAttributedString 和「复制时应该产出的文本」是两套独立数据。**
//  永远不要指望从 attributed string 反推源码，一律查 `MarkdownDocumentStore` 的源码映射表。
//

import UIKit

/// 剪贴板控制器。
final class MarkdownPasteboardController {

    weak var textView: MarkdownTextView?

    // MARK: 复制

    /// 把选区对应的 **markdown 源码** 放进剪贴板。
    /// - returns: `true` 表示已经接管，`false` 表示没接管（交给系统默认行为）
    @discardableResult
    func handleCopy() -> Bool {
        guard let textView else { return false }

        let range = textView.selectedRange
        guard range.length > 0 else { return false }

        // 查映射表还原源码：
        // - 图片占位符 → 还原成 ![alt](url)
        // - 列表圆点   → 还原成源码里的 `- `
        // - 纯装饰字符 → 直接跳过
        let source = textView.documentStore.sourceText(forRenderedRange: range)
        guard !source.isEmpty else { return false }

        // 只放纯文本，不放富文本。
        // 这样粘到任何编辑器（VS Code、微信、备忘录…）拿到的都是 markdown 源码，
        // 不会出现「粘过去变成一张图」的情况。
        UIPasteboard.general.string = source
        return true
    }

    // MARK: 粘贴

    /// 剪贴板里是图片时，存成本地文件并插入 `![](路径)` 源码。
    /// - returns: `true` 表示已处理
    @discardableResult
    func handlePasteImage() -> Bool {
        guard let textView, let image = UIPasteboard.general.image else { return false }
        guard let directory = attachmentsDirectory() else { return false }

        let fileName = "pasted-\(UUID().uuidString).png"
        let fileURL = directory.appendingPathComponent(fileName)
        guard let data = image.pngData() else { return false }

        do {
            try data.write(to: fileURL)
        } catch {
            return false
        }

        textView.insertMarkdownSource("![粘贴的图片](attachments/\(fileName))")
        return true
    }

    /// 图片存放目录：`Documents/attachments`
    private func attachmentsDirectory() -> URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = documents.appendingPathComponent("attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
