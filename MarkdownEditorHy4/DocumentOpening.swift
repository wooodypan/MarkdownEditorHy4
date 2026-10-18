//
//  DocumentOpening.swift
//  MarkdownEditorHy4
//
//  「打开一份文档」这一件事的唯一入口 —— 左栏两页（文档 / 最近）都走它。
//

import UIKit
import MultiTabController

/// 打开文档。
///
/// ### 为什么要单拎出来
/// 「文档」那一页和「最近」那一页都要打开文档，而且**必须打开得一模一样**：
/// 先读内容、再记一笔「最近打开」、最后交给路由送到右侧。写成两份迟早会不一样
/// （比如有一边忘了记那一笔），所以这里收成一个入口，两边都调它。
///
/// ### 为什么「记最近打开」放在这里，而不是在列表页点的时候记
/// 只有**真的读出来**了才算「打开过」。读不出来（文件被删了、没权限）时这一笔就不记 ——
/// 否则「最近」里会躺着一条点开就报错的记录，用户还得手动删。
enum DocumentOpening {

    /// 打开一份磁盘上的文档。
    ///
    /// 内容**当场就读出来**塞给右侧，不让编辑页自己去读：这样「读失败」在这里就拦住了，
    /// 不会出现「编辑页拿到空内容 → 一保存就把用户的原文件清空」这种事故。
    ///
    /// - Parameters:
    ///   - url: 要打开的文件
    ///   - mode: 怎么开（iPhone 上是 push，iPad / Mac 上是预览槽位还是新 Tab）
    ///   - router: 把内容送到右侧的那条路由
    /// - Returns: 打开成功时回**实际使用的 URL**（书签可能把文件解析到改名后的新位置）；
    ///   读不出来回 `nil`（由调用方提示用户）
    @discardableResult
    static func open(_ url: URL, mode: PPContentOpenMode, using router: PPContentRouting?) -> URL? {
        let canonical = ExternalDocumentAccess.shared.canonicalURL(for: url)

        // 容器外的文件先拿访问权：这一步可能解析书签、也可能申请一次临时授权。
        // ⚠️ 传**原始 URL**，别传 canonical —— 通行证是附在原始地址上的
        guard let readableURL = ExternalDocumentAccess.shared.readableURL(for: url) else {
            return nil
        }

        // 读不出来就当没打开过：既不送右侧，也不记「最近打开」
        guard let text = DocumentsWorkspace.read(readableURL) else { return nil }

        let readableCanonical = ExternalDocumentAccess.shared.canonicalURL(for: readableURL)

        // 书签把文件解析到了新位置（比如用户在 Finder 里改过名），
        // 旧路径那条「最近」记录已经没用了，换成新的
        if readableCanonical.path != canonical.path {
            RecentDocumentsStore.shared.remove(canonical)
        }
        RecentDocumentsStore.shared.record(readableURL)

        // id 用规范化后的路径：左栏列表存的就是规范化路径，高亮要靠它俩对上
        let item = PPContentItem(id: readableCanonical.path,
                                 title: DocumentsWorkspace.displayName(for: readableURL),
                                 body: text,
                                 // 左栏是个平铺列表，用不上分组。留着这个字段是为了
                                 // 以后要按子目录 / 标签分组时不用改协议
                                 category: "Documents")
        router?.open(item, mode: mode)
        return readableURL
    }
}
