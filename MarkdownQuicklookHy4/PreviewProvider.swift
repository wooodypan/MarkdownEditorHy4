//
//  PreviewProvider.swift
//  MarkdownQuicklookHy4
//
//  Created by pan on 2026/10/13.
//

import OSLog
import QuickLook
import UniformTypeIdentifiers

/// 「数据型」快速查看的入口 —— 只产出一份数据（一整页 HTML），预览窗口长什么样、怎么滚动，全交给系统的 Quick Look 自己画。
///
/// ⚠️ **当前没被用到**：Info.plist 指向的是 `PreviewViewController`（视图型，用编辑器自己的渲染器画）。
/// 两条路只能走一条，同时开着的时候系统按 plist 里的键决定用谁，很容易出现「改了半天这边不生效」的迷惑场面。
/// 留着当备选：哪天真想换成 HTML 那份排版，就把 plist 的 `NSExtensionPrincipalClass` 改回 `PreviewProvider`，并加上 `QLIsDataBasedPreview`。
class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    /// 排查问题时用：`log stream --predicate 'subsystem == "com.yijian.mirror.MarkdownQuicklookHy4"'` 能看到下面这些记录。
    private let log = Logger(subsystem: "com.yijian.mirror.MarkdownQuicklookHy4", category: "preview")

    /// 本类不是 UIView（只是 NSObject 子类），按项目规矩补一个空 deinit：默认 @MainActor 隔离的类要是让编译器自动生成 deinit，会在非隔离上下文里出野指针。
    nonisolated deinit {}

    /// 系统每要一次预览就调这个方法一次（Finder 里按一下空格 = 调一次）。
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {

        let url = request.fileURL
        let html = renderPage(for: url)
        log.info("生成预览：\(url.lastPathComponent, privacy: .public)，HTML \(html.utf8.count) 字节")

        // 第三个参数是个闭包，它不会现在执行 —— 等系统真的来取数据时才跑，这叫「延迟执行」。
        let reply = QLPreviewReply(dataOfContentType: .html,
                                   contentSize: CGSize(width: 900, height: 1000)) { (replyToUpdate: QLPreviewReply) in

            // 按 UTF-8 编码，中文才不会变成乱码。
            replyToUpdate.stringEncoding = .utf8

            return Data(html.utf8)
        }

        return reply
    }

    // MARK: 渲染

    /// 读文件 → 渲染成一整页 HTML。
    ///
    /// 读不出来（没权限、编码奇怪）也回一页说明，**不抛异常** —— 抛出去的话 Quick Look 那边就是一片空白，用户看不出发生了什么。
    private func renderPage(for url: URL) -> String {
        guard let source = readSource(at: url) else {
            log.error("读不到文件内容：\(url.path, privacy: .public)")
            return errorPage(title: url.lastPathComponent,
                             detail: "读不到这个文件的内容。可能是扩展没有读它的权限，或者文件不是 UTF-8 / UTF-16 编码。")
        }

        return MarkdownHTMLExporter.export(
            markdown: source,
            title: url.deletingPathExtension().lastPathComponent,
            options: MarkdownHTMLExporter.Options(
                // 用内置那套 GitHub 风格：它不依赖编辑器设置，扩展里拿不到用户主题（那要走 App Group 共享，现在还没配）
                style: .builtIn,
                // 尽量把本地图片编成 base64 塞进去 —— 沙箱里让网页自己去读相对路径的图是读不到的
                inlinesLocalImages: true,
                // 相对路径的图相对「这份 md 所在的目录」找，和编辑器里一致
                baseDirectory: url.deletingLastPathComponent()
            )
        )
    }

    /// 把文件读成字符串。**不假设它是 UTF-8** —— 中文 markdown 里 GB18030 / UTF-16 都见过。
    private func readSource(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let text = String(data: data, encoding: .utf8) { return text }
        // 不是合法 UTF-8 就按 UTF-16 试一把（带 BOM 的文件多半是它）
        if let text = String(data: data, encoding: .utf16) { return text }
        return nil
    }

    /// 出错时给用户看的那一页。故意写得朴素：这里再出问题就没救了，别引入任何依赖。
    private func errorPage(title: String, detail: String) -> String {
        let safeTitle = MarkdownHTMLRenderer.escape(title)
        let safeDetail = MarkdownHTMLRenderer.escape(detail)
        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <title>\(safeTitle)</title>
        <style>
        body { font: 14px -apple-system, BlinkMacSystemFont, sans-serif; margin: 40px; color: #555; }
        h1 { font-size: 16px; color: #111; margin-bottom: 8px; }
        </style>
        </head>
        <body>
        <h1>\(safeTitle)</h1>
        <p>\(safeDetail)</p>
        </body>
        </html>
        """
    }
}
