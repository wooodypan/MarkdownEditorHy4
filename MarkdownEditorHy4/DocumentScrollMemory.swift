//
//  DocumentScrollMemory.swift
//  MarkdownEditorHy4
//
//  「上次读到哪儿」：按文件记住文档的滚动位置，下次打开同一个文件回到原处
//

import Foundation

/// 每份文档「上次读到哪儿」的记忆。
///
/// ### 记的是源码偏移，不是滚动像素
/// 存 `contentOffset.y` 是最容易想到的做法，但它不可靠：同一个文件在 iPhone 竖屏和
/// Mac Catalyst 宽窗口里，每行折行数完全不同，第 3000 点可能是文档 1/3 处，
/// 也可能已经是 2/3 处 —— 换个窗口大小就跳错地方。
///
/// 存「屏幕最上面那一行对应的**源码偏移**」（UTF-16 单位）就没有这个问题：
/// 它是文档自身的位置，跟窗口多宽、字体多大都无关。恢复时再用编辑器现成的
/// 「源码偏移 → 渲染位置」映射表滚过去。
///
/// ### 落盘位置
/// 和设置同一处：`Library/Caches/MarkdownEditorHy4/document-scroll.json`。
/// 被系统回收的后果只是「下次打开回到文档开头」，不影响使用。
final class DocumentScrollMemory {

    /// App 里用这个；单元测试自己 new 一个指向临时目录的
    static let shared = DocumentScrollMemory()

    /// 最多记多少份文档。超了就把最久没用到的丢掉，避免这个文件无限变大
    private static let maximumEntries = 200

    /// 一条记录：读到哪儿 + 什么时候读的（用来淘汰最久不用的）
    private struct Entry: Codable {
        var sourceOffset: Int
        var updatedAt: Date
    }

    private let fileURL: URL
    private var entries: [String: Entry]

    static var defaultFileURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches
            .appendingPathComponent("MarkdownEditorHy4", isDirectory: true)
            .appendingPathComponent("document-scroll.json")
    }

    init(fileURL: URL = DocumentScrollMemory.defaultFileURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            self.entries = decoded
        } else {
            self.entries = [:]
        }
    }

    /// 原因见 `MarkdownBlock` / `OutlineCoordinator` 里 `nonisolated deinit` 的长注释。
    /// 本类只有值类型成员，nonisolated deinit 完全安全。
    nonisolated deinit {}

    // MARK: 对外

    /// 这份文档上次读到哪个源码偏移。没记录过、或者记的是文档开头，返回 nil
    func sourceOffset(for key: String) -> Int? {
        guard let entry = entries[key], entry.sourceOffset > 0 else { return nil }
        return entry.sourceOffset
    }

    /// 记下「这份文档现在读到哪儿」。
    ///
    /// 偏移为 0（还在文档最上面）时把记录删掉而不是存个 0：
    /// 那样下次打开「恢复到开头」和「没有记录」结果一样，留着只是白占地方。
    func remember(sourceOffset: Int, for key: String) {
        guard sourceOffset > 0 else {
            forget(key: key)
            return
        }
        entries[key] = Entry(sourceOffset: sourceOffset, updatedAt: Date())
        pruneIfNeeded()
        save()
    }

    /// 删掉某份文档的记录（文件被删了、或者用户把开关关掉时清理用）
    func forget(key: String) {
        guard entries.removeValue(forKey: key) != nil else { return }
        save()
    }

    /// 清空全部记录
    func forgetAll() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        save()
    }

    // MARK: 内部

    /// 记录条数超过上限时，按「最久没更新」淘汰，只留最新的那些
    private func pruneIfNeeded() {
        guard entries.count > Self.maximumEntries else { return }
        let sorted = entries.sorted { $0.value.updatedAt > $1.value.updatedAt }
        entries = Dictionary(uniqueKeysWithValues: sorted.prefix(Self.maximumEntries).map { ($0.key, $0.value) })
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // 同上：写不进去就算了，记忆丢了最多下次打开回到文档开头
        }
    }
}
