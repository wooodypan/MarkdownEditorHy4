//
//  MarkdownDocumentViewController+ImagePreview.swift
//  MarkdownEditorHy4
//
//  点正文里的图片弹 QuickLook 预览，以及它需要的「预览项」小模型。
//
//  ⚠️ 从 `MarkdownDocumentViewController.swift` 拆出来的：代码原样搬过来，只去掉了 `private`
//  （Swift 的 private 只在本文件可见，跨文件就调不到）。
//

import UIKit
import QuickLook

extension MarkdownDocumentViewController {

    /// 弹出 QuickLook 预览。
    ///
    /// ### 为什么要先落到文件
    /// `QLPreviewController` 只认文件 URL，不认内存里的 `UIImage`。
    /// 本地图片本来就有文件，直接把地址给它；网络图片先把已经下载好的图写成一份临时 png，再给地址。
    func previewImage(_ attachment: ImageAttachment) {
        guard let url = previewFileURL(for: attachment) else { return }
        previewItem = ImagePreviewItem(url: url, title: attachment.previewTitle)

        let controller = QLPreviewController()
        controller.dataSource = self
        present(controller, animated: true)
    }

    /// 给预览准备一个文件地址。
    func previewFileURL(for attachment: ImageAttachment) -> URL? {
        // 本地图片直接用原文件，不动它
        if attachment.imageURL.isFileURL,
           FileManager.default.fileExists(atPath: attachment.imageURL.path) {
            return attachment.imageURL
        }
        // 网络图片（或者原文件已经不在了）：用已经加载好的那张图写一份临时文件
        guard let data = attachment.loadedImage?.pngData() else { return nil }
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("preview-\(UUID().uuidString).png")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}

// MARK: - QuickLook 数据源

/// QuickLook 预览窗里的「一项」：一个文件地址 + 标题栏上显示的名字。
///
/// 为什么单独建这个类而不复用 `ImageAttachment`：attachment 是渲染层的东西，
/// 还带着源码映射那些职责，而 QuickLook 只想要一个 URL，让两者互相认识没必要。
final class ImagePreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL, title: String) {
        self.previewItemURL = url
        self.previewItemTitle = title
        super.init()
    }

    /// 原因见 `MarkdownBlock` 里 `nonisolated deinit` 的注释：
    /// 隔离 deinit 会踩 Swift 6.2 运行时的野指针 free
    nonisolated deinit {}
}

extension MarkdownDocumentViewController: QLPreviewControllerDataSource {

    /// 一次只预览一张图，就是用户点的那张
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        previewItem == nil ? 0 : 1
    }

    func previewController(_ controller: QLPreviewController,
                           previewItemAt index: Int) -> QLPreviewItem {
        // 上面报了 1，走到这儿 `previewItem` 必然有值。
        // 万一真的没有（时序异常），给个空壳也比强解包崩掉好
        previewItem ?? ImagePreviewItem(url: URL(fileURLWithPath: NSTemporaryDirectory()),
                                        title: "图片")
    }
}

