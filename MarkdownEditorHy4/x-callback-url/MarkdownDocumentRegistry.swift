//
//  MarkdownDocumentRegistry.swift
//  MarkdownEditorHy4
//
//  「现在开着哪些文档」的登记表：按文件路径找回那个编辑页。
//
//  ### 为什么需要它
//  x-callback-url 要干两件宿主没提供能力的事：
//  1. 判断「这份笔记是不是正开着、编辑器里有没有没保存的修改」；
//  2. 写盘之后把新内容刷进那个已经开着的编辑器。
//
//  `DetailHostViewController` 只公开了「当前选中项」，没有「按 id 取控制器」的接口。
//  要么去改本地包（会波及别的工程），要么自己记一份。选后者。
//
//  ### 为什么不用 deinit 注销
//  存的是弱引用：编辑页被回收时条目自己就变成 nil，读的时候顺手清掉。
//  走 deinit 反而要处理「deinit 里能不能碰 MainActor 状态」这一串麻烦事。
//

import Foundation

/// 「打开中的编辑器」弱引用表。
final class MarkdownDocumentRegistry {

    static let shared = MarkdownDocumentRegistry()

    private struct Entry {
        /// 弱引用：Tab 关掉、页面释放之后这里自动变 nil
        weak var controller: MarkdownDocumentViewController?
    }

    /// key = 规范化路径（`ExternalDocumentAccess.canonicalPath`）
    private var entries: [String: Entry] = [:]

    private init() {}

    /// 登记：这一页现在编的是哪份文件。
    ///
    /// 同一份文件被开在两个 Tab 里时后登记的覆盖前面的 —— 追加内容只需要刷到其中一个，另一个会在用户切过去时按磁盘内容重新装载不动。覆盖比维护数组简单，也够用。
    func register(_ controller: MarkdownDocumentViewController, for url: URL) {
        prune()
        entries[ExternalDocumentAccess.shared.canonicalPath(for: url)] = Entry(controller: controller)
    }

    /// 按文件路径找那个编辑页。文件没开着、或者页面已经释放，返回 nil。
    func controller(for url: URL) -> MarkdownDocumentViewController? {
        entries[ExternalDocumentAccess.shared.canonicalPath(for: url)]?.controller
    }

    /// 清掉那些已经被回收的条目。
    private func prune() {
        entries = entries.filter { $0.value.controller != nil }
    }

    /// 和本工程其它非 UI 的 class 一样：必须显式写一行 nonisolated 的 deinit，否则 Swift 6 运行时在特定释放时机可能去 free 一个野指针直接崩。
    nonisolated deinit {}
}
