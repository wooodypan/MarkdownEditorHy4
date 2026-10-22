//
//  DocumentListRowCache.swift
//  MarkdownEditorHy4
//
//  左栏列表行上那两行附加信息（副标题 + 日期）的缓存与后台读取。
//

import Foundation

/// 给左栏列表行提供「副标题 + 日期」的小仓库。
///
/// ### 为什么要它
/// 一行里的首行预览是**真读盘**（开文件、读 4KB、解码），文件夹那行的「N 份文档」还得把子目录整层列一遍。
/// 这些活儿要是在 `cellForRowAt` 里同步做，每滚出一个新单元格就是好几次系统调用，主线程直接被拖住。
/// 所以这里把「读」挪到后台线程，主线程只查已经读好的结果。
///
/// ### 缓存什么时候失效
/// 每次重扫目录（`invalidate(against:)`）都拿新扫出来的修改时间跟缓存里记的那一份比，对不上就丢掉。
/// 比对用的时间本来就是扫描时顺手读到的，不额外花钱；没变的行照旧直接用，切回左栏时不会整片重新闪一遍。
///
/// ⚠️ 缓存和「正在读」这张表**只在主线程读写**（`cellForRowAt`、后台读完回来的回调都在主线程），所以不加锁。
final class DocumentListRowCache {

    /// 一行要显示的东西
    struct Info: Equatable {
        /// 名字。容器外文件被书签解析到改名后的位置时，这里跟 `Entry.name` 会不一样
        let name: String
        /// 副标题：文档是首行预览，文件夹是「N 份文档 · M 个文件夹」
        let preview: String
        /// 修改时间
        let date: Date?
        /// 读这份信息时那一层目录扫出来的修改时间，用来判断缓存还算不算数
        let stamp: Date?
    }

    /// 读好的行，key 是文件路径
    private var cache: [String: Info] = [:]

    /// 正在后台读的路径：同一行连着要两次时别派两趟
    private var loading: Set<String> = []

    /// 重扫一次目录就加一。后台读完回来时对不上，说明那是上一批数据的结果，直接丢掉
    private var generation = 0

    /// 读盘用的队列。
    ///
    /// 要读的是好几份互不相干的文件，排成一列反而慢，所以用并发队列（同时最多几份由系统按 CPU 和 IO 自己定）。
    private let queue = DispatchQueue(label: "MarkdownEditorHy4.document-list-row-cache",
                                      qos: .userInitiated,
                                      attributes: .concurrent)

    // MARK: - 查

    /// 已经读好的那一行；还没读过就是 nil
    func cached(for url: URL) -> Info? {
        cache[url.path]
    }

    // MARK: - 读

    /// 让后台读一行，读完在**主线程**回调。
    ///
    /// 已经有缓存、或者已经有一趟在路上时**不回调**：前一种调用方自己会先查 `cached(for:)`，后一种等那一趟读完会自己回填，没必要让同一行来回刷两遍。
    ///
    /// - Parameter completion: 只在「这一趟真的读到了新结果」时调，参数是读好的那一行
    func request(for entry: DocumentsWorkspace.Entry, completion: @escaping (Info) -> Void) {
        let path = entry.url.path
        guard cache[path] == nil, !loading.contains(path) else { return }
        loading.insert(path)

        let generation = self.generation
        queue.async { [weak self] in
            let info = DocumentListRowCache.load(entry)
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading.remove(path)
                // 中途重扫过目录：这份结果对的是上一批数据，丢掉
                guard generation == self.generation else { return }
                self.cache[path] = info
                completion(info)
            }
        }
    }

    // MARK: - 失效

    /// 重扫完目录后调：修改时间变了的行丢掉，目录里已经没有的行也丢掉。
    ///
    /// - Parameter entries: 刚扫出来的那一整层。只需要它带的 `modifiedDate`，不碰盘
    func invalidate(against entries: [DocumentsWorkspace.Entry]) {
        var stamps: [String: Date?] = [:]
        stamps.reserveCapacity(entries.count)
        for entry in entries {
            stamps[entry.url.path] = entry.modifiedDate
        }

        cache = cache.filter { path, info in
            // 目录里已经没有它了（被删 / 改名 / 换了目录）
            guard let stamp = stamps[path] else { return false }
            return stamp == info.stamp
        }

        // 在路上那几趟的结果全部作废，让新的视图重新要一遍
        generation += 1
        loading.removeAll()
    }

    // MARK: - 真正读盘（后台）

    /// 读一行的附加信息。⚠️ 这个方法**必须**在后台线程跑：开文件、列目录、路径规范化都在里面
    private static func load(_ entry: DocumentsWorkspace.Entry) -> Info {
        if entry.isDirectory {
            return Info(name: entry.name,
                        preview: folderSummary(for: entry.url),
                        date: entry.modifiedDate,
                        stamp: entry.modifiedDate)
        }

        // 容器外文件要先拿访问权。这一步里还带着「路径规范化」（会逐个路径分量查盘），一次就是好几下系统调用 —— 这也是它不能留在 `cellForRowAt` 里的主要原因
        guard let readableURL = ExternalDocumentAccess.shared.readableURL(for: entry.url) else {
            // 没有访问权时要说清楚，别让那一行显示成「空文档」——用户会以为文件里真的没内容
            return Info(name: entry.name, preview: "需要重新授权", date: nil, stamp: entry.modifiedDate)
        }

        return Info(name: DocumentsWorkspace.displayName(for: readableURL),
                    preview: DocumentsWorkspace.previewText(of: readableURL),
                    // 书签可能把文件解析到改名后的新位置，那里的时间扫描时没读到，才补一次
                    date: entry.modifiedDate ?? DocumentsWorkspace.modificationDate(of: readableURL),
                    stamp: entry.modifiedDate)
    }

    /// 文件夹那一行的副标题：`3 份文档 · 1 个文件夹`。
    ///
    /// 只数**这一层**：递归数在很多文档的目录上会明显卡顿，而这一行只是个提示 —— 用户想知道的是「里面有没有东西」，不是精确总数。
    private static func folderSummary(for directory: URL) -> String {
        let summary = DocumentsWorkspace.summary(ofDirectory: directory)
        var parts: [String] = []
        if summary.documents > 0 { parts.append("\(summary.documents) 份文档") }
        if summary.folders > 0 { parts.append("\(summary.folders) 个文件夹") }
        // 空文件夹交给 cell 的占位文字（「空文件夹」），这里返回空串就够了
        return parts.joined(separator: " · ")
    }
}
