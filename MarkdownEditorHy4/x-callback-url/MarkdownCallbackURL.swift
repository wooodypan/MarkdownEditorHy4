//
//  MarkdownCallbackURL.swift
//  MarkdownEditorHy4
//
//  x-callback-url 的解析：把 `xmark://...` 拆成动作 + 参数 + 两条回调地址，再把 `id` 换算成磁盘上的真实路径。
//
//  ### 为什么不用 URLComponents 直接取 queryItems
//  它会把 `+` 当成空格处理，而协议里 `+` 就是加号本身。手写一遍切分反而更可控，也方便单测（纯字符串进、纯结构出，不碰界面）。
//

import Foundation

/// x-callback-url 的出错信息。`code` 直接就是回调里 `error-code` 的值。
struct MarkdownCallbackError: Error {

    let code: Int
    let message: String

    /// 笔记不存在，或者读不出来
    static func notFound(_ id: String) -> MarkdownCallbackError {
        MarkdownCallbackError(code: -1001, message: "找不到「\(id)」这份笔记")
    }

    /// 参数不对：缺参数、路径越界、枚举值不认识
    static func invalidParam(_ why: String) -> MarkdownCallbackError {
        MarkdownCallbackError(code: -1003, message: why)
    }

    /// 容器外的文件拿不到访问权
    static func permissionDenied(_ why: String) -> MarkdownCallbackError {
        MarkdownCallbackError(code: -1004, message: why)
    }

    /// 笔记正开着且有未保存修改，但这次没法确认
    static func busy(_ why: String) -> MarkdownCallbackError {
        MarkdownCallbackError(code: -1005, message: why)
    }

    /// 写盘失败
    static func writeFailed(_ why: String) -> MarkdownCallbackError {
        MarkdownCallbackError(code: -1006, message: why)
    }

    /// 用户在冲突提示里点了取消
    static func canceled() -> MarkdownCallbackError {
        MarkdownCallbackError(code: -1007, message: "用户取消了这次写入")
    }

    /// 主题没导进来：地址不对、下载失败、拿回来的不是一份主题
    static func importFailed(_ why: String) -> MarkdownCallbackError {
        MarkdownCallbackError(code: -1008, message: why)
    }
}

/// 解析 `xmark://` 地址。
enum MarkdownCallbackURL {

    static let scheme = "xmark"
    static let callbackHost = "x-callback-url"

    /// 拆好的一条请求。
    struct Parsed {
        /// 动作名，原样保留（不认识的动作也要能回一条错误出去）
        let action: String
        /// 动作后面那一段路径，原样留着（没解码）。
        ///
        /// ### 为什么留这么一段
        /// `import-theme` 允许把网址直接接在动作后面（`xmark://x-callback-url/import-theme/https://…/Atom.json`），这种写法最接近用户嘴里说的「路径里带着主题地址」。
        /// 按 `/` 拆开再拼回去会把 `https://` 里的双斜杠吃掉，所以这一段是**整段截下来**的，不参与拆分。
        let pathSuffix: String
        /// 已经 percent 解码过一次的参数
        let parameters: [String: String]
        let successURL: URL?
        let errorURL: URL?

        /// 取一个非空参数
        func value(_ key: String) -> String? {
            guard let raw = parameters[key], !raw.isEmpty else { return nil }
            return raw
        }

        /// 取必填参数，缺了就抛 -1003
        func requires(_ key: String) throws -> String {
            guard let value = value(key) else {
                throw MarkdownCallbackError.invalidParam("缺少参数 \(key)")
            }
            return value
        }

        /// 开关型参数：只有 `yes` 算开
        func flag(_ key: String) -> Bool {
            parameters[key]?.lowercased() == "yes"
        }

        /// `import-theme` 要下载的那份主题在哪儿。
        ///
        /// 两种写法都认，`url=` 参数优先：
        /// - `xmark://x-callback-url/import-theme?url=https%3A%2F%2Fexample.com%2FAtom.json`
        /// - `xmark://x-callback-url/import-theme/https://example.com/Atom.json`
        ///
        /// 只认 http / https：`file://` 之类的一律不收，免得一个链接就能读出 App 里任意一个文件。
        func themeURL() -> URL? {
            if let raw = value("url"), let url = Self.webURL(from: raw) { return url }
            guard !pathSuffix.isEmpty else { return nil }
            return Self.webURL(from: MarkdownCallbackURL.decode(pathSuffix))
        }

        private static func webURL(from raw: String) -> URL? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else { return nil }
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
            return url
        }
    }

    /// 这个 URL 是不是本 App 的 x-callback 协议。
    ///
    /// 只看 scheme，不管后面写得对不对 —— 内容写错也要认领下来回一条错误，而不是当成普通文件 URL 丢给 `MarkdownDocumentOpener`。
    static func isCallbackURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme
    }

    /// 拆开一条回调地址。拆不出来（没有动作名）时返回 nil。
    static func parse(_ url: URL) -> Parsed? {
        guard isCallbackURL(url) else { return nil }

        let text = url.absoluteString
        guard let schemeRange = text.range(of: "://") else { return nil }

        // fragment 不属于参数，先砍掉
        let afterScheme = text[schemeRange.upperBound...]
        let withoutFragment = afterScheme.prefix { $0 != "#" }

        let pieces = withoutFragment.split(separator: "?",
                                           maxSplits: 1,
                                           omittingEmptySubsequences: false)
        let pathPart = String(pieces[0])
        let queryPart = pieces.count > 1 ? String(pieces[1]) : ""

        // 标准写法是 /x-callback-url/<动作>；也接受直接 /<动作> 的简写。
        // ⚠️ 只切两刀：第三段往后要**原样**留着 —— 主题导入会把一个完整网址塞在路径里，多切一刀就把它剁碎了
        let segments = pathPart.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard let first = segments.first else { return nil }
        let action: String?
        let pathSuffix: String
        if first.lowercased() == callbackHost {
            action = segments.count > 1 ? segments[1] : nil
            pathSuffix = segments.count > 2 ? segments[2] : ""
        } else {
            action = first
            pathSuffix = segments.count > 1 ? segments[1] : ""
        }
        guard let action, !action.isEmpty else { return nil }

        var parameters: [String: String] = [:]
        for pair in queryPart.split(separator: "&", omittingEmptySubsequences: true) {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawKey = kv.first else { continue }
            let key = decode(String(rawKey))
            let value = kv.count > 1 ? decode(String(kv[1])) : ""
            parameters[key] = value
        }

        // x-success / x-error 在参数里同样是编码过的地址，解码之后再当 URL 用
        return Parsed(action: action,
                      pathSuffix: pathSuffix,
                      parameters: parameters,
                      successURL: parameters["x-success"].flatMap { URL(string: $0) },
                      errorURL: parameters["x-error"].flatMap { URL(string: $0) })
    }

    /// 解码一次。不是合法编码就原样返回，别把整条请求判死
    fileprivate static func decode(_ raw: String) -> String {
        guard raw.contains("%") else { return raw }
        return raw.removingPercentEncoding ?? raw
    }
}

/// `id` 和磁盘路径之间的换算。
enum MarkdownCallbackPaths {

    /// 认得出的文档扩展名，和 `DocumentsWorkspace` 保持一致
    static let documentExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "mdwn", "mdtext", "mdtxt", "txt"
    ]

    /// 把 `id` 换算成文档路径。
    ///
    /// 只认相对路径，而且必须落在文档目录里面 —— 这条是防止外部调用方拿到 App 的任意读写能力（`../../Library/...` 这种写法一律拒绝）。
    ///
    /// - Throws: `MarkdownCallbackError.invalidParam`（参数越界或扩展名不认）
    static func documentURL(forID rawID: String) throws -> URL {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw MarkdownCallbackError.invalidParam("id 不能是空的")
        }
        guard !id.hasPrefix("/") else {
            throw MarkdownCallbackError.invalidParam("id 必须是相对文档目录的路径，不能以 / 开头")
        }

        for part in id.split(separator: "/", omittingEmptySubsequences: false) {
            let name = String(part)
            guard !name.isEmpty else {
                throw MarkdownCallbackError.invalidParam("id 里有空的路径段")
            }
            guard name != ".", name != ".." else {
                throw MarkdownCallbackError.invalidParam("id 里不能出现 . 或 ..")
            }
        }

        var relative = id
        let ext = (id as NSString).pathExtension.lowercased()
        if ext.isEmpty {
            relative += ".md"
        } else if !documentExtensions.contains(ext) {
            throw MarkdownCallbackError.invalidParam("只认 markdown 文档，收到的是 .\(ext)")
        }

        let root = DocumentsWorkspace.folderURL
        let candidate = URL(fileURLWithPath: relative, relativeTo: root).standardizedFileURL
        guard isInside(root, candidate) else {
            throw MarkdownCallbackError.invalidParam("id 跑到了文档目录外面")
        }
        return candidate
    }

    /// `id` 里的 `folder` 参数换算成目录路径（不存在也没关系，调用方自己建）。
    ///
    /// 每一段都过一遍 `sanitizedFolderName`，`/` `:` 和开头的点都会被换掉。
    static func folderURL(forRelative raw: String?) throws -> URL {
        let root = DocumentsWorkspace.folderURL
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return root
        }

        var current = root
        for part in raw.split(separator: "/", omittingEmptySubsequences: false) {
            let name = String(part)
            guard !name.isEmpty else { continue }
            guard name != ".", name != ".." else {
                throw MarkdownCallbackError.invalidParam("folder 里不能出现 . 或 ..")
            }
            let sanitized = DocumentsWorkspace.sanitizedFolderName(name)
            guard !sanitized.isEmpty else {
                throw MarkdownCallbackError.invalidParam("folder 里有一段名字是空的")
            }
            current.appendPathComponent(sanitized, isDirectory: true)
        }

        let folder = current.standardizedFileURL
        guard isInside(root, folder) else {
            throw MarkdownCallbackError.invalidParam("folder 跑到了文档目录外面")
        }
        return folder
    }

    /// 绝对路径换算回 `identifier`（相对文档目录）。
    static func identifier(for url: URL) -> String {
        DocumentsWorkspace.relativePath(of: url, in: DocumentsWorkspace.folderURL)
    }

    /// `url` 在不在 `root` 里面。
    ///
    /// 两边都走 `canonicalPath`：`/var` 和 `/private/var` 是同一个地方，直接比字符串会把它们当成两个目录。
    static func isInside(_ root: URL, _ url: URL) -> Bool {
        let rootPath = ExternalDocumentAccess.shared.canonicalPath(for: root)
        let target = ExternalDocumentAccess.shared.canonicalPath(for: url)
        return target == rootPath || target.hasPrefix(rootPath + "/")
    }
}
