//
//  PreviewProvider.swift
//  MarkdownQuicklookHy4
//
//  Created by pan on 2026/10/13.
//

import QuickLook
import UniformTypeIdentifiers

/// 数据型快速查看扩展的入口。
///
/// 「数据型」是说：我们只负责产出一份数据（这里是纯文本，以后换成 HTML），至于预览窗口长什么样、标题栏怎么排、怎么滚动，全交给系统的 Quick Look 自己画。
/// 另一种「视图型」是自己写一个 UIViewController 交出去，只有确实需要摆原生控件时才值得那么做。
class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    /// 系统每要一次预览就调这个方法一次（Finder 里按一下空格 = 调一次）。
    ///
    /// 这一版故意什么都不解析，原样回一句 "Hello world" —— 目的只有一个：验证 Finder 按空格能不能把我们这个扩展叫起来。
    /// 只要屏幕上出现 Hello world，就说明「装进去了 + 系统认出了我们 + 被启用了」这三件事全通了。
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {

        // 告诉系统「我回给你的是一段纯文本」，它会拿一个能显示文本的窗口来接。
        // 等真要渲染 markdown 时，这里换成 UTType.html，再把拼好的整页 HTML 塞进去。
        let contentType = UTType.plainText

        // 第三个参数是个闭包，它不会现在执行 —— 等系统真的来取数据时才跑，这叫「延迟执行」。
        // 好处是：文件很大、解析很慢的时候，系统还可以先把窗口摆好再等我们。
        let reply = QLPreviewReply(dataOfContentType: contentType,
                                   contentSize: CGSize(width: 800, height: 800)) { (replyToUpdate: QLPreviewReply) in

            // 纯文本按 UTF-8 编码，中文才不会变成乱码。
            replyToUpdate.stringEncoding = .utf8

            // 这里就是最终交给系统的内容。以后要渲染 markdown，就把这一行换成拼好的 HTML。
            return Data("Hello world".utf8)
        }

        return reply
    }

}
