//
//  ExternalDocumentAccess.swift
//  MarkdownEditorHy4
//
//  容器外文件的访问权限：申请 security scope、保存 / 恢复书签。
//

import Foundation

/// 管 App 沙盒**外面**那些文档的访问权限。
///
/// ### 为什么需要它
/// 开了 App Sandbox 之后，App 只能自由读写自己的容器。用户从打开面板、
/// Finder「打开方式」递进来的文件带一张**临时通行证**，读完就还，重启也没了。
/// 想在下一次启动后还能打开，必须把这张通行证存成 security-scoped bookmark。
///
/// ### 两种平台的行为不一样
/// - **Mac Catalyst**：书签 API 可用。第一次打开时存一份，之后从「最近」
///   点开先解析书签、重新拿到访问权，再读内容。
/// - **iOS**：`withSecurityScope` 不可用，书签没法跨启动保住权限。
///   所以 iOS 的界面会先问「复制到 App 里吗」，工作的是容器里的副本。
///
/// ### 访问权什么时候还
/// 现在统一保持到 App 退出（`stopAccessingAll()`）。一份文档可能一直开着、
/// 用户随时会按 ⌘S，中途释放的话保存就会失败；等到退出再一起还最省事。
final class ExternalDocumentAccess {

    static let shared = ExternalDocumentAccess()

    /// 书签按文件的真实路径存。放 Application Support，不放 Caches —— Caches 会被系统清掉。
    private let bookmarkFileURL: URL

    /// key = 文件真实路径，value = security-scoped bookmark
    private var bookmarks: [String: Data]

    /// 已经申请到访问权的 URL。key 同样是真实路径，value 是**实际拿来读写**的 URL
    private var activeURLs: [String: URL] = [:]

    /// 当初调 `startAccessingSecurityScopedResource()` 的那个 URL。
    ///
    /// 归还权限必须还给**同一个 URL 对象所代表的资源**：申请时用的是原始地址
    /// （可能是文件引用 URL），读写时用的是转成真实路径的 `activeURLs` 里的那个 ——
    /// 两者路径往往一样，但「通行证挂在哪个 URL 上」不一样，归还时不能混。
    private var scopedURLs: [String: URL] = [:]

    static var defaultBookmarkFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("MarkdownEditorHy4", isDirectory: true)
            .appendingPathComponent("external-file-bookmarks.json")
    }

    init(bookmarkFileURL: URL = ExternalDocumentAccess.defaultBookmarkFileURL) {
        self.bookmarkFileURL = bookmarkFileURL
        if let data = try? Data(contentsOf: bookmarkFileURL),
           let decoded = try? JSONDecoder().decode([String: Data].self, from: data) {
            self.bookmarks = decoded
        } else {
            self.bookmarks = [:]
        }
    }

    // MARK: - 路径

    /// 把 Finder 递过来的「文件引用 URL」换成真实路径，并把符号链接、相对路径收干净。
    ///
    /// 文件引用 URL 长这样 `file:///.file/id=6571367.12345`，它的 `path` 不是真实路径。
    /// 原样存进「最近」或书签里，下次会一律对不上。
    func canonicalURL(for url: URL) -> URL {
        let pathURL = (url as NSURL).filePathURL ?? url
        return pathURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    func canonicalPath(for url: URL) -> String {
        canonicalURL(for: url).path
    }

    /// 真正拿来读写的 URL。
    ///
    /// 和 `canonicalURL` 的区别是**不解析符号链接**：符号链接解到目标之后，
    /// 打开面板给的那张通行证可能就不在目标路径上了。身份判断用 canonical，
    /// 读写用这个更稳。
    func accessURL(for url: URL) -> URL {
        (url as NSURL).filePathURL?.standardizedFileURL ?? url.standardizedFileURL
    }

    /// 这份文件在不在 App 自己的容器里。
    ///
    /// 容器里的文件不需要任何授权，读写都随便。
    func isInsideContainer(_ url: URL) -> Bool {
        let home = canonicalPath(for: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
        let path = canonicalPath(for: url)
        return path == home || path.hasPrefix(home + "/")
    }

    // MARK: - 访问

    /// 确保现在能读写这份文件，并返回真正要使用的 URL。
    ///
    /// - 容器内文件直接放行；
    /// - 容器外文件先看这次是不是已经申请过；
    /// - 再看有没有以前存下的书签，有就解析出来；
    /// - 都没有就调用 `startAccessingSecurityScopedResource()`（打开面板 / Finder
    ///   刚递过来的 URL 靠这一步拿权限）；
    /// - 最后读一次文件。Finder 打开事件有时会让 `startAccessing` 返回 false，
    ///   但系统其实已经给了权限，这一步能把这种情况分辨出来。
    ///
    /// - Returns: 能访问时返回实际读写的 URL（书签可能把文件解析到改名后的新位置）；不能访问返回 nil。
    func readableURL(for url: URL) -> URL? {
        let canonical = canonicalURL(for: url)
        let access = accessURL(for: url)
        if isInsideContainer(canonical) { return access }

        let key = canonical.path
        if let active = activeURLs[key] { return active }

        #if targetEnvironment(macCatalyst)
        if let resolved = resolveBookmark(forKey: key) {
            return resolved
        }
        #endif

        // ⚠️ 通行证要附在**原始 URL** 上申请。`canonical` 解开过符号链接，
        // 沙盒扩展不认解析后的路径；`access` 也可能已经从文件引用 URL 转过一道手。
        // 对这两个调 startAccessing 都可能白跑一趟。
        if url.startAccessingSecurityScopedResource() {
            keepAccess(startedURL: url, accessURL: access, forKey: key)
            rememberBookmark(for: url)
            return access
        }

        // 没有沙盒时，或者从 Finder 双击进来的文件，系统可能已经把权限给足了，
        // 但 startAccessing 仍返回 false。读一次文件才判断得准。
        if FileManager.default.isReadableFile(atPath: access.path) {
            // 没申请到 scope，但文件确实能读：只记 IO 地址，退出时不用归还
            activeURLs[key] = access
            rememberBookmark(for: url)
            return access
        }
        return nil
    }

    /// 这次运行期间已经拿到过访问权的 URL
    func isAccessActive(for url: URL) -> Bool {
        activeURLs[canonicalPath(for: url)] != nil
    }

    /// 退出时把这一轮申请过的授权全还回去。
    func stopAccessingAll() {
        // 只还 `scopedURLs` 里那些真正申请过的；能读但没申请过的 URL 还了反而会少一次计数
        for url in scopedURLs.values {
            url.stopAccessingSecurityScopedResource()
        }
        scopedURLs.removeAll()
        activeURLs.removeAll()
    }

    /// 记下「谁申请的、读写用哪个」，两个字典的 key 永远一起出现、一起清。
    private func keepAccess(startedURL: URL, accessURL: URL, forKey key: String) {
        activeURLs[key] = accessURL
        scopedURLs[key] = startedURL
    }

    // MARK: - 书签

    /// 有没有为这份文件存过书签。没有书签的容器外文件，重启后是打不开的。
    func hasBookmark(for url: URL) -> Bool {
        #if targetEnvironment(macCatalyst)
        return bookmarks[canonicalPath(for: url)] != nil
        #else
        return false
        #endif
    }

    /// 用户把这份文件从「最近」里去掉、或删掉文件时，把书签也清掉，免得越攒越多。
    func forgetBookmark(for url: URL) {
        #if targetEnvironment(macCatalyst)
        guard bookmarks.removeValue(forKey: canonicalPath(for: url)) != nil else { return }
        saveBookmarks()
        #endif
    }

    func forgetAllBookmarks() {
        #if targetEnvironment(macCatalyst)
        guard !bookmarks.isEmpty else { return }
        bookmarks.removeAll()
        saveBookmarks()
        #endif
    }

    // MARK: - 内部

    #if targetEnvironment(macCatalyst)
    /// 第一次拿到访问权时存一份书签，下次启动还能用。
    ///
    /// 存不下来不弹提示：这一次仍然能正常编辑，只是下次打开可能需要重新授权。
    private func rememberBookmark(for url: URL) {
        guard let data = try? url.bookmarkData(options: [.withSecurityScope],
                                               includingResourceValuesForKeys: nil,
                                               relativeTo: nil) else { return }
        bookmarks[canonicalPath(for: url)] = data
        saveBookmarks()
    }

    /// 解析书签并申请访问权。
    ///
    /// 书签过期（文件被移动、重命名过）时重新生成一份，把旧 key 换成新路径。
    private func resolveBookmark(forKey key: String) -> URL? {
        guard let data = bookmarks[key] else { return nil }

        var isStale = false
        guard let resolved = try? URL(resolvingBookmarkData: data,
                                      options: [.withSecurityScope],
                                      relativeTo: nil,
                                      bookmarkDataIsStale: &isStale) else {
            return nil
        }

        // 同样别先解析符号链接：书签给的通行证对应的是 `resolved` 这个原始地址
        let access = accessURL(for: resolved)
        let resolvedKey = canonicalURL(for: resolved).path

        if resolved.startAccessingSecurityScopedResource() {
            keepAccess(startedURL: resolved, accessURL: access, forKey: resolvedKey)
        } else if FileManager.default.isReadableFile(atPath: access.path) {
            // 和 readableURL 里同样的道理：返回 false 不一定真没权限
            activeURLs[resolvedKey] = access
        } else {
            return nil
        }

        // 书签过期（文件被移动、重命名过）时趁现在有权限重新生成一份，
        // 把旧 key 换成新路径
        if isStale,
           let freshData = try? resolved.bookmarkData(options: [.withSecurityScope],
                                                      includingResourceValuesForKeys: nil,
                                                      relativeTo: nil) {
            bookmarks[resolvedKey] = freshData
            // 旧路径也留一份。界面上的「最近」还挂着旧路径那一行，
            // 下次刷新时还要靠它再解析到新位置；等这份文档真正打开后，
            // `DocumentOpening` 会把旧记录换成新路径，旧书签也会跟着清掉。
            bookmarks[key] = freshData
            saveBookmarks()
        } else if bookmarks[resolvedKey] == nil {
            // 书签没过期，但文件确实被移动过，解析结果换了路径。
            // 同一份数据在新路径下依然有效，先挂过去 —— 否则 `DocumentOpening`
            // 清掉旧记录之后，新路径没有书签，下次启动会被当成外部未授权文件过滤掉。
            bookmarks[resolvedKey] = data
            saveBookmarks()
        }
        return access
    }
    #else
    /// iOS 上没有 security-scoped bookmark。这里留个空实现，
    /// 让 `readableURL` 里的调用两边共用一套代码；iOS 的持久化靠「复制进 App」。
    private func rememberBookmark(for url: URL) {}
    #endif

    private func saveBookmarks() {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        do {
            try FileManager.default.createDirectory(at: bookmarkFileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: bookmarkFileURL, options: .atomic)
        } catch {
            // 写不进去就算了：最坏的结果是下次打开容器外文件时再授权一次
        }
    }
}
