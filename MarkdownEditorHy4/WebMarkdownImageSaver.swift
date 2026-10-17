//
//  WebMarkdownImageSaver.swift
//  MarkdownEditorHy4
//
//  粘贴网页内容时，把 markdown 里指向网络的图片下载下来存到本地，再把地址换成本地路径。
//
//  ### 为什么单独一个文件
//  `HTMLToMarkdownConverter` 只把 HTML 转成源码，不碰网络也不碰磁盘；
//  `ImageAssetStore` 只按设置把一份字节存进目录。
//  「哪些地址要下载、下完怎么换回正文」这一段两边都不管，就放在这里。
//

import Foundation
import ImageIO

/// 把网页图片存到本地：找地址 → 下载 → 按设置存盘 → 把正文里的地址换成本地路径。
enum WebMarkdownImageSaver {

    /// 一次最多处理多少张不同的图。
    ///
    /// 有的网页复制过来会带几十张缩略图，全下又慢又占空间；超出的部分原样留着网络地址，正文照样能读。
    private static let maxImageCount = 300

    /// 单张图最大多少字节。再大的多半是点到了视频或者整页下载，不当图片处理。
    ///
    /// 它和下面的 `timeout` 标了 `nonisolated`：下载在后台任务里跑，要从那边读这两个值。
    private nonisolated static let maxImageByteCount = 20 * 1024 * 1024

    /// 单张图最多等多久（秒）。等太久不如直接留着网络地址，别让粘贴卡在那儿。
    private nonisolated static let timeout: TimeInterval = 30

    // MARK: 对外

    /// 处理一次粘贴里的网络图片。
    ///
    /// - Parameters:
    ///   - markdown: 刚由 HTML 转出来的源码
    ///   - documentURL: 正在编辑的那份笔记，决定图片存到哪个目录（跟着「插入图片」那一组设置走）
    ///   - onStatus: 中途想在状态栏跟用户说一句话时调它
    ///   - completion: 处理完把改写过的源码交回来，**一定在主线程上调用**
    /// - returns: `true` 表示有网络图片要存、这次交给本方法；`false` 表示没活干，调用方当场插入
    ///
    /// 返回 `false` 的两种情况：设置里把这一项关了、正文里没有要下载的图片地址。
    @discardableResult
    static func localize(_ markdown: String,
                         documentURL: URL?,
                         onStatus: @escaping (String) -> Void = { _ in },
                         completion: @escaping (String) -> Void) -> Bool {
        guard MarkdownEditorSettings.shared.savesWebImagesLocally else { return false }

        let images = remoteImages(in: markdown)
        guard !images.isEmpty else { return false }

        // 同一张图在正文里常出现好几次（页头 logo、分隔线），按地址去重只下一次。
        // 字典顺手做了去重，下载顺序也就不重要了
        var uniqueURLs: [String: URL] = [:]
        for image in images where uniqueURLs[image.url.absoluteString] == nil {
            uniqueURLs[image.url.absoluteString] = image.url
        }
        // 超出上限的那些留在正文里不动，状态栏报「没存下来」时把它们一起算上
        let overflow = max(0, uniqueURLs.count - maxImageCount)
        let jobs = uniqueURLs.values.prefix(maxImageCount).map { url in
            (key: url.absoluteString, url: url)
        }

        onStatus("正在把网页上的 \(jobs.count) 张图片存到本地…")

        Task {
            // 先把字节都拿下来。这一步在后台跑，不占主线程
            let downloaded = await withTaskGroup(of: (String, Data?).self) { group -> [(String, Data?)] in
                for job in jobs {
                    group.addTask { (job.key, await fetchImage(job.url)) }
                }
                var results: [(String, Data?)] = []
                for await result in group { results.append(result) }
                return results
            }

            // 再按设置存盘。存哪儿、叫什么名字全交给 `ImageAssetStore`，
            // 它读的是设置页「插入图片」那一组，和手动粘图的落盘位置完全一致
            var localPaths: [String: String] = [:]
            var failed = 0
            for (key, data) in downloaded {
                guard let data, let remote = uniqueURLs[key] else {
                    failed += 1
                    continue
                }
                // 地址最后那一截当「原始文件名」：选「用原始文件名」时，网页图也能落个看得懂的名字
                let outcome = ImageAssetStore.write(data,
                                                    for: documentURL,
                                                    originalFileName: remote.lastPathComponent)
                guard let path = outcome.path else {
                    failed += 1
                    continue
                }
                localPaths[key] = path
            }

            let rewritten = replacingImageDestinations(in: markdown, with: localPaths)
            let totalFailed = failed + overflow
            if totalFailed > 0 {
                onStatus("有 \(totalFailed) 张网页图片没存下来，正文里还是网络地址")
            }
            completion(rewritten)
        }
        return true
    }

    // MARK: 找地址

    /// markdown 里一张指向网络的图片。
    private struct RemoteImage {
        /// 地址在源码里的范围。只框地址本身，不含 `![说明](` 和结尾的 `)`
        var range: Range<String.Index>
        var url: URL
    }

    /// 扫出正文里所有指向网络的图片地址。
    ///
    /// ### 为什么自己扫，不引一个 markdown 解析器
    /// 这些源码刚刚由我们自己转出来，格式是确定的（`![说明](地址)` 或 `![说明](<地址>)`）；
    /// 为了它去拉一个解析器，还得把「改哪一段」的坐标重新对回去，不划算。
    private static func remoteImages(in markdown: String) -> [RemoteImage] {
        var found: [RemoteImage] = []
        var searchStart = markdown.startIndex

        while let bang = markdown.range(of: "![", range: searchStart..<markdown.endIndex) {
            // 说明文字里可能出现 `]`，所以直接找紧跟着左括号的那个 `](`
            guard let opener = markdown.range(of: "](", range: bang.upperBound..<markdown.endIndex) else {
                break
            }
            var cursor = opener.upperBound
            // `](` 后面可能有一两个空格，跳过它们才是地址
            while cursor < markdown.endIndex, markdown[cursor] == " " {
                cursor = markdown.index(after: cursor)
            }
            guard cursor < markdown.endIndex else { break }

            var start = cursor
            var end: String.Index
            if markdown[cursor] == "<" {
                // 地址带尖括号：里面的空格和括号都是地址的一部分，一直到 `>` 为止
                start = markdown.index(after: cursor)
                guard let close = markdown[start...].firstIndex(of: ">") else { break }
                end = close
            } else {
                // 不带尖括号：地址到空白或者 `)` 为止（后面可能还跟着一个标题）
                var probe = cursor
                while probe < markdown.endIndex,
                      markdown[probe] != " ",
                      markdown[probe] != ")",
                      markdown[probe] != "\n" {
                    probe = markdown.index(after: probe)
                }
                end = probe
            }

            if let url = remoteURL(String(markdown[start..<end])) {
                found.append(RemoteImage(range: start..<end, url: url))
            }
            // 从这里继续往下找，别回到这一张图的地址中间，否则会原地打转
            searchStart = end
        }
        return found
    }

    /// 把地址文本认成一个能发出去的网络地址。返回 `nil` 表示这张不用下（本地路径、`data:` 内嵌图都跳过）。
    private static func remoteURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // 网页里很常见 `//example.com/a.png` 这种省掉协议的写法，补个 https 才发得出去
        let normalized = trimmed.hasPrefix("//") ? "https:" + trimmed : trimmed
        guard let url = URL(string: normalized),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return nil
        }
        return url
    }

    // MARK: 改写

    /// 把正文里的网络地址换成下好的本地路径。
    ///
    /// 拼一份新字符串，原文从头到尾不动：每张图只把「上一处结尾到这张图开头」那段原样抄过来，再补上新地址。
    /// 原文没被改过，手里每个 `String.Index` 都还成立，替换长短不一会错位的问题也就不存在。
    private static func replacingImageDestinations(in markdown: String,
                                                   with localPaths: [String: String]) -> String {
        var result = ""
        var cursor = markdown.startIndex
        for image in remoteImages(in: markdown) {
            guard let path = localPaths[image.url.absoluteString] else { continue }
            result += markdown[cursor..<image.range.lowerBound]
            result += destination(path)
            cursor = image.range.upperBound
        }
        result += markdown[cursor...]
        return result
    }

    /// 本地路径写成 markdown 地址时要不要加尖括号。
    ///
    /// 规则和转换器那边一致：地址里只要有空格或者括号，就得用 `<…>` 包起来，
    /// 否则解析器会把空格后面那截当成标题（「图片存到指定文件夹」时最可能碰上带空格的目录名）。
    private static func destination(_ path: String) -> String {
        let needsBrackets = path.contains(" ") || path.contains("(") || path.contains(")")
        return needsBrackets ? "<" + path + ">" : path
    }

    // MARK: 下载

    /// 下载一张图。
    ///
    /// 标 `nonisolated` 是为了能在后台任务里调：这里只碰网络，不碰界面，也没读任何共享状态。
    ///
    /// 三道关：HTTP 状态是成功、字节数没超上限、最后还能当图片解出来。
    /// 最后这一关最要紧：防盗链的站点常返回 200 的 HTML 错误页，只看状态码会把整个网页当图存进笔记。
    private nonisolated static func fetchImage(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        // 有些图床看 UA 决定给不给图，带上一个常见的浏览器 UA
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
                         forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return nil
        }
        guard data.count <= maxImageByteCount else { return nil }
        // 用 ImageIO 问一句「你是什么格式」：答不出来就不是图。
        // 只调 `CGImageSourceCreateWithData` 不够，它对任何非空字节都先给个对象（懒解析）
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) != nil else {
            return nil
        }
        return data
    }
}
