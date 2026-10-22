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
/// ⚠️ 路径在存之前**必须过一遍 `ExternalDocumentAccess.canonicalPath(for:)`**：从 Finder /「打开方式」进来的文件，系统给的有可能是「文件引用 URL」（长这样 `file:///.file/id=6571367.12345`），它的 `path` 不是真实路径 —— 原样存进去，下次判断「文件还在吗」会一律说不在，于是这条记录在下次启动时被当成「文件已删除」清掉。规范化成真实路径就没事了。
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
            .filter { isAvailable(URL(fileURLWithPath: $0.key)) }
            .sorted { $0.value > $1.value }
            .map { URL(fileURLWithPath: $0.key) }
    }

    /// 最后一次打开这份文档的时间。没记过返回 nil
    func lastOpenedAt(for url: URL) -> Date? {
        openedAt[key(for: url)]
    }

    /// 记一笔「这份文档刚刚被打开过」。
    ///
    /// 已经在记录里的就把时间刷新成现在 —— 于是它会重新排到最前面。
    func record(_ url: URL) {
        openedAt[key(for: url)] = Date()
        pruneIfNeeded()
        save()
    }

    /// 把某份文档从记录里去掉。**只动记录，磁盘上的文件不受影响**
    func remove(_ url: URL) {
        guard openedAt.removeValue(forKey: key(for: url)) != nil else { return }
        // 记录都不要了，对应的外部文件书签也一并清掉
        ExternalDocumentAccess.shared.forgetBookmark(for: url)
        save()
    }

    /// 文件夹改名时，把这些路径前缀下的记录一起搬到新前缀下。
    ///
    /// 记录按完整路径存，文件夹一改名，里面每份文档的 key 都成了「不存在的文件」，下次刷新会被当成垃圾清掉。迁过去比清掉好 —— 用户还能从「最近」点回去。
    ///
    /// - Parameters:
    ///   - fromPrefix: 旧目录的完整路径（结尾不带 `/`）
    ///   - toPrefix: 新目录的完整路径
    func migrate(fromPrefix: String, toPrefix: String) {
        let head = fromPrefix + "/"
        var migrated = openedAt
        var didChange = false
        for (path, date) in openedAt where path.hasPrefix(head) {
            let suffix = String(path.dropFirst(head.count))
            migrated.removeValue(forKey: path)
            migrated[toPrefix + "/" + suffix] = date
            didChange = true
        }
        guard didChange else { return }
        openedAt = migrated
        save()
    }

    /// 文件夹被删掉时，把里面所有文档的记录一起清掉（文件都没了，留着只是白占位置）。
    ///
    /// - Returns: 清掉了几条
    @discardableResult
    func removeAll(underPrefix prefix: String) -> Int {
        let head = prefix + "/"
        let before = openedAt.count
        openedAt = openedAt.filter { !$0.key.hasPrefix(head) }
        guard openedAt.count != before else { return 0 }
        save()
        return before - openedAt.count
    }

    /// 清空全部记录。**只动记录，一份文件都不会删**
    func removeAll() {
        guard !openedAt.isEmpty else { return }
        openedAt.removeAll()
        // 书签只服务于「最近」和重新打开；清空记录时一起清掉，别留下看不见的授权
        ExternalDocumentAccess.shared.forgetAllBookmarks()
        save()
    }

    /// 把「文件已经不在了」的记录剔掉。
    ///
    /// 容器外的文件不能只看 `fileExists`：沙盒没授权时它也返回 false，
    /// 但书签还在，下次仍然能解析出来。所以有书签的容器外记录一律先留着。
    ///
    /// - Returns: 剔掉了几条（启动时弹提示、或者写日志时用得上；没人要就忽略）
    @discardableResult
    func pruneMissingFiles() -> Int {
        let before = openedAt.count
        openedAt = openedAt.filter { isAvailable(URL(fileURLWithPath: $0.key)) }
        guard openedAt.count != before else { return 0 }
        save()
        return before - openedAt.count
    }

    // MARK: 内部

    /// 「最近」的记录按文件的真实路径存。
    ///
    /// Finder 递过来的可能是文件引用 URL，直接存 `path` 会得到 `/.file/id=...`，
    /// 下次判断文件在不在会一律说不在。`ExternalDocumentAccess` 里统一做这层规范化。
    private func key(for url: URL) -> String {
        ExternalDocumentAccess.shared.canonicalPath(for: url)
    }

    /// 这条记录还算不算「文件还在」。
    ///
    /// 容器内的文件直接查磁盘；容器外的文件只要还有书签就先留着 ——
    /// 解析书签、申请访问权是点开时才做的事，列表阶段不该因为没权限就把它删掉。
    private func isAvailable(_ url: URL) -> Bool {
        if ExternalDocumentAccess.shared.isInsideContainer(url) {
            return FileManager.default.fileExists(atPath: url.path)
        }
        if ExternalDocumentAccess.shared.hasBookmark(for: url) {
            return true
        }
        // iOS 上没有书签，能看到的外部记录只可能是这次运行里刚打开过的；
        // 文件真被删了就该清掉
        return FileManager.default.fileExists(atPath: url.path)
    }

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
