//
//  ImageLoader.swift
//  MarkdownEditorHy4
//
//  图片加载：本地同步拿尺寸，网络异步加载
//

import UIKit

/// attachment 需要宿主（也就是 UITextView 那一层）帮忙刷新布局时走这个协议。
///
/// 图片是异步加载的，加载完才知道真实宽高，此时 attachment 的 `bounds` 变了，
/// 必须通知 TextKit「这一块重新排版」，否则布局会停在占位尺寸上。
protocol MarkdownAttachmentHost: AnyObject {
    func invalidateLayout(for attachment: NSTextAttachment)
}

/// 图片加载器：带内存缓存，本地图片同步返回（渲染时就能拿到真实尺寸，避免布局跳动）。
final class ImageLoader {
    static let shared = ImageLoader()

    private let memoryCache = NSCache<NSURL, UIImage>()
    /// 同一个 URL 只发一次请求，后到的回调排队等
    private var pending: [URL: [(UIImage?) -> Void]] = [:]

    /// 原因见 `MarkdownBlock` 里 `nonisolated deinit` 的注释：
    /// 隔离 deinit 一旦嵌套就会踩 Swift 6.2 运行时的野指针 free。
    nonisolated deinit {}

    private init() {
        memoryCache.countLimit = 100
    }

    // MARK: 地址解析

    /// 把 markdown 里的图片地址解析成可用的 URL。
    ///
    /// 支持三种写法：
    /// 1. 网络地址 `https://…`
    /// 2. 相对路径 `sample.png`（相对 `baseURL` 找，找不到再去 App 包里找）
    /// 3. 文件地址 `file:///…`
    static func resolve(source: String?, baseURL: URL?) -> URL? {
        guard var raw = source?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }

        // 去掉 `<…>` 包裹：`![a](<my image.png>)`
        if raw.hasPrefix("<"), raw.hasSuffix(">") {
            raw = String(raw.dropFirst().dropLast())
        }
        // 去掉标题部分：`![a](b.png "标题")`
        if let spaceIndex = raw.firstIndex(where: { $0 == " " }),
           raw[raw.startIndex..<spaceIndex].range(of: "://") == nil {
            // 只在没有协议头的时候才按「空格后面是标题」处理，避免误伤带空格的网络地址
            let candidate = String(raw[raw.startIndex..<spaceIndex])
            if !candidate.hasPrefix("/") && !candidate.hasPrefix("file:") {
                raw = candidate
            }
        }
        guard !raw.isEmpty else { return nil }

        // 带协议头的（http / https / file …）直接当 URL 用
        if let url = URL(string: raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw),
           url.scheme != nil {
            return url
        }

        // 相对路径：先按 baseURL 找
        if let baseURL {
            let candidate = baseURL.appendingPathComponent(raw)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }

        // 再按 App 包里的资源找（demo 的 sample.png 就是这么找到的）
        let nsName = raw as NSString
        let name = nsName.deletingPathExtension
        let ext = nsName.pathExtension
        if let path = Bundle.main.path(forResource: name, ofType: ext.isEmpty ? "png" : ext) {
            return URL(fileURLWithPath: path)
        }

        // 最后兜底：当成绝对路径
        if FileManager.default.fileExists(atPath: raw) {
            return URL(fileURLWithPath: raw)
        }
        return nil
    }

    // MARK: 加载

    /// 同步加载。只有本地文件和已缓存图片能命中，用于渲染时立刻拿到真实尺寸。
    func loadSynchronously(_ url: URL) -> UIImage? {
        if let cached = memoryCache.object(forKey: url as NSURL) { return cached }
        guard url.isFileURL,
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else { return nil }
        memoryCache.setObject(image, forKey: url as NSURL)
        return image
    }

    /// 异步加载。本地文件会立刻回调（其实走的是同步路径），网络图片在后台线程下载。
    /// - parameter completion: 一定在主线程回调，方便直接改 UI
    func load(_ url: URL, completion: @escaping @MainActor (UIImage?) -> Void) {
        if let cached = memoryCache.object(forKey: url as NSURL) {
            completion(cached)
            return
        }
        if url.isFileURL {
            completion(loadSynchronously(url))
            return
        }

        // 已经有请求在飞了，只排队
        if pending[url] != nil {
            pending[url]?.append(completion)
            return
        }
        pending[url] = [completion]

        // 网络请求丢到后台线程，别卡住打字
        ImageLoader.download(url) { [weak self] image in
            DispatchQueue.main.async {
                guard let self else { return }
                if let image { self.memoryCache.setObject(image, forKey: url as NSURL) }
                let callbacks = self.pending.removeValue(forKey: url) ?? []
                for callback in callbacks { callback(image) }
            }
        }
    }

    /// 标记为 `nonisolated`：本文件整体跑在主线程（MainActor），网络请求必须显式脱离主线程。
    private nonisolated static func download(_ url: URL, completion: @escaping (UIImage?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
                completion(nil)
                return
            }
            completion(image)
        }
    }
}
