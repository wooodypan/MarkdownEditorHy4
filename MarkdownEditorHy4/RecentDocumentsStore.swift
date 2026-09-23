//
//  RecentDocumentsStore.swift
//  MarkdownEditorHy4
//
//  「最近打开过哪些文档」：按文件记一笔，左栏的「最近」那一页就是照它列的。
//

import Foundation

/// 最近打开过的文档记录。
///
/// ### 记的是「文件路径」，不是文件本身
/// 和「上次读到哪儿」（`DocumentScrollMemory`）用的是同一套 key —— 文件的**完整路径**。
/// 好处是「这份文档还是不是原来那份」的判断永远准确：文件被改名、被移走，
/// 路径就变了，老记录自然对不上（改名后的那份会重新记一笔）。
///
/// ⚠️ **这份记录只记「打开过」，不碰文件本身**：
/// 「从最近里删掉」删的是这一行记录，磁盘上的文件还在（真要删文件请去「文档」那一页）。
/// 这一点在界面上是写清楚的，免得用户以为点了删除文件就没了。
///
/// ### 文件被删了怎么办
/// 用户在 Finder /「文件」App 里把 `.md` 删掉，这边是收不到通知的，
/// 所以每次启动（`init`）都会扫一遍：**文件已经不在了的记录，直接剔除**。
/// 列表页每次列的时候也会再过滤一次 —— 那是「正在用的时候被删掉」的情况，只过滤不落盘。
final class RecentDocumentsStore {

    /// App 里用这个；单元测试自己 new 一个指向临时目录的
    static let shared = RecentDocumentsStore()

    /// 最多记多少份。超了就把最久没打开的丢掉，免得这个文件越攒越大
    private static let maximumEntries = 50

    private let fileURL: URL
    /// key = 文件完整路径，value = 最后一次打开的时间
    private var openedAt: [String: Date]

    static var defaultFileURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches
            .appendingPathComponent("MarkdownEditorHy4", isDirectory: true)
            .appendingPathComponent("recent-documents.json")
    }

    init(fileURL: URL = RecentDocumentsStore.defaultFileURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Date].self, from: data) {
            self.openedAt = decoded
        } else {
            self.openedAt = [:]
        }
        // 启动就查一次：上次用完 App 之后，用户可能已经在 Finder 里把某份文档删了
        pruneMissingFiles()
    }

    /// 原因见 `MarkdownBlock` / `OutlineCoordinator` 里 `nonisolated deinit` 的长注释。
    /// 本类只有值类型成员，nonisolated deinit 完全安全。
    nonisolated deinit {}

    // MARK: 对外

    /// 最近打开过的文档，**文件还在的**才算，按「最近打开」排在最前面。
    ///
    /// 这里每次都现查一遍文件在不在（不落盘）：正在用的时候被删掉的那份，
    /// 下一次刷新列表就会自己消失。真正的清理（把记录从磁盘上抹掉）在 `pruneMissingFiles()`。
    func recentURLs() -> [URL] {
        openedAt
            .filter { FileManager.default.fileExists(atPath: $0.key) }
            .sorted { $0.value > $1.value }
            .map { URL(fileURLWithPath: $0.key) }
    }

    /// 最后一次打开这份文档的时间。没记过返回 nil
    func lastOpenedAt(for url: URL) -> Date? {
        openedAt[url.path]
    }

    /// 记一笔「这份文档刚刚被打开过」。
    ///
    /// 已经在记录里的就把时间刷新成现在 —— 于是它会重新排到最前面。
    func record(_ url: URL) {
        openedAt[url.path] = Date()
        pruneIfNeeded()
        save()
    }

    /// 把某份文档从记录里去掉。**只动记录，磁盘上的文件不受影响**
    func remove(_ url: URL) {
        guard openedAt.removeValue(forKey: url.path) != nil else { return }
        save()
    }

    /// 清空全部记录。**只动记录，一份文件都不会删**
    func removeAll() {
        guard !openedAt.isEmpty else { return }
        openedAt.removeAll()
        save()
    }

    /// 把「文件已经不在了」的记录剔掉。
    ///
    /// - Returns: 剔掉了几条（启动时弹提示、或者写日志时用得上；没人要就忽略）
    @discardableResult
    func pruneMissingFiles() -> Int {
        let before = openedAt.count
        openedAt = openedAt.filter { FileManager.default.fileExists(atPath: $0.key) }
        guard openedAt.count != before else { return 0 }
        save()
        return before - openedAt.count
    }

    // MARK: 内部

    /// 条数超上限时，按「最久没打开」淘汰，只留最新的那些
    private func pruneIfNeeded() {
        guard openedAt.count > Self.maximumEntries else { return }
        let sorted = openedAt.sorted { $0.value > $1.value }
        openedAt = Dictionary(uniqueKeysWithValues: sorted.prefix(Self.maximumEntries).map { ($0.key, $0.value) })
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(openedAt) else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // 写不进去就算了：最坏的结果是「最近打开」这份列表下次少几行，不影响编辑
        }
    }
}
