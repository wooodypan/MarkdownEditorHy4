import Foundation
import Markdown
import UIKit

/// 导出 HTML 的顶层入口：**源码字符串进，一个完整网页字符串出**。
///
/// ### 为什么不复用编辑器里那份增量解析
/// 编辑器那套分块缓存是为「每敲一个字都要重排」服务的，用它拼 HTML 会漏掉跨块的内容（脚注定义常被 cmark 并进前一个块）。
/// 导出是点一次才做一次的操作，直接对整篇 `Document(parsing:)` 一遍最稳，慢也慢不到哪儿去（67 KB 的文档实测几十毫秒）。
///
/// ### 一次导出干三件事
/// 1. 把脚注定义从正文里扣出来，单独渲染到文末，正文只剩 `[^id]` 锚点（和编辑器里 `FootnoteIndex` 同一套识别判据）；
/// 2. 可选地把能读到的本地图片编成 base64 内联 —— 不然 `![](sample.png)` 导出到别处就是一张死图；
/// 3. 套上 `<!DOCTYPE html>` 和一份 CSS，产物是一个能直接双击打开的独立文件。
enum MarkdownHTMLExporter {

    // MARK: 选项

    /// 样式从哪儿来
    enum StyleSource {
        /// 内置那套 GitHub 风格，跟编辑器主题无关
        case builtIn
        /// 跟着编辑器当前这套主题配色（深色主题导出就是深色页面）
        case currentTheme(MarkdownTheme)

        var tokens: MarkdownHTMLTokens {
            switch self {
            case .builtIn: return .builtIn
            case .currentTheme(let theme): return MarkdownHTMLTokens.from(theme: theme)
            }
        }
    }

    struct Options {
        var style: StyleSource
        /// 要不要把能读到的本地图片编成 base64 塞进 HTML
        var inlinesLocalImages: Bool
        /// 相对路径的图片相对谁解析（一般传文档所在目录；不知道文档在哪时传 nil，会退到 App 的 Documents 目录）
        var baseDirectory: URL?

        init(style: StyleSource,
             inlinesLocalImages: Bool = false,
             baseDirectory: URL? = nil) {
            self.style = style
            self.inlinesLocalImages = inlinesLocalImages
            self.baseDirectory = baseDirectory
        }
    }

    /// 导出的产物，外加一份「图片内联得怎么样」的账。
    ///
    /// 为什么要带这份账：内联失败时 HTML 里仍然是 `src="./a.png"`，用户看到的是「我明明勾了内联」——之前这一路是**静默**退回原路径的（沙盒里读不到图是常态），不报出来就永远查不到原因。
    struct Result {
        var html: String
        /// 成功编成 base64 的图片张数
        var inlinedImages: Int
        /// 想内联但没读到的图片地址（原文照抄，给用户看是哪个）
        var missedImages: [String]
    }

    // MARK: 导出

    static func export(markdown source: String, title: String, options: Options) -> String {
        exportDocument(markdown: source, title: title, options: options).html
    }

    /// 完整的一次导出（比 `export` 多返回一份图片内联的账）。
    static func exportDocument(markdown source: String, title: String, options: Options) -> Result {
        let notes = footnoteDefinitions(in: source)
        let bodySource = removing(notes, from: source)

        // 计数放在闭包外面攒：渲染器是「遇到一张图问我一次」，它自己不知道总共几张
        var inlinedCount = 0
        var missed: [String] = []

        var renderer = MarkdownHTMLRenderer()
        renderer.footnoteIDs = Set(notes.map(\.id))
        renderer.footnoteNumbers = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0.index) })
        renderer.imageSourceResolver = options.inlinesLocalImages
            ? { reference in
                if let inlined = inlinedImageSource(for: reference, baseDirectory: options.baseDirectory) {
                    inlinedCount += 1
                    return inlined
                }
                missed.append(reference)
                return reference
            }
            : nil

        let body = renderer.visit(Document(parsing: bodySource))
        let footnotes = footnoteSection(notes, renderer: &renderer)

        return Result(html: page(body: body, footnotes: footnotes, title: title, tokens: options.style.tokens),
                      inlinedImages: inlinedCount,
                      missedImages: missed)
    }

    /// 拼外壳：`<!DOCTYPE html>` + meta + CSS + 正文。
    ///
    /// `<meta charset="utf-8">` 不能省：不带它，中文打开就是乱码 —— 浏览器会按本地编码猜，猜错就一页问号。
    private static func page(body: String, footnotes: String, title: String, tokens: MarkdownHTMLTokens) -> String {
        let escapedTitle = MarkdownHTMLRenderer.escape(title)
        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="generator" content="MarkdownEditorHy4">
        <title>\(escapedTitle)</title>
        <style>
        \(tokens.css())
        </style>
        </head>
        <body>
        <main class="markdown-body">
        \(body)\(footnotes)</main>
        </body>
        </html>
        """
    }

    // MARK: 脚注

    /// 一条已经从正文里扣出来的脚注定义。
    private struct Note {
        let id: String
        /// 在文末列表里的序号（第一条是 1）
        let index: Int
        /// 定义正文（已经剥掉 `[^id]:`、也已经去掉续行的缩进）
        let body: String
        /// 整条定义在源码里占的范围（含 `[^id]:` 和所有续行）
        let range: NSRange
    }

    /// 找出源码里所有的脚注定义。同一个 ID 定义了多次的以**先出现的那份**为准（`FootnoteIndex` 里的规矩）。
    private static func footnoteDefinitions(in source: String) -> [Note] {
        let ns = source as NSString
        var seenIDs: Set<String> = []
        var result: [Note] = []

        for marker in FootnoteIndex.definitionMarkers(in: source) {
            guard seenIDs.insert(marker.id).inserted,
                  let block = FootnoteIndex.definitionBlockRange(for: marker.id, in: source) else { continue }
            // `definitionBlockRange` 保证不越界，这里再夹一次是为了防止 NSRange 算术翻车导致 `substring(with:)` 崩溃
            let range = NSRange(location: block.location,
                                length: min(block.length, ns.length - block.location))
            guard range.length > 0 else { continue }

            let whole = ns.substring(with: range)
            // 剥掉开头的 `[^id]:`（`marker.range` 的长度正好含那几个字符，含冒号）
            let withoutMarker = String(whole.dropFirst(min(marker.range.length, whole.utf16.count)))
            result.append(Note(id: marker.id,
                               index: result.count + 1,
                               body: dedent(withoutMarker),
                               range: range))
        }
        return result
    }

    /// 把脚注定义从源码里扣掉，剩下的才是正文。
    ///
    /// ### 为什么要 replacement 成空段落而不是直接删
    /// 定义常常是紧挨着某段正文的（中间没空行，cmark 会把它并进前一个块），直接把那几行的字符删掉的话，定义前后的两行会粘成一句。补一对换行等于「这里断掉」，跟写作者本来的排版最接近。
    private static func removing(_ notes: [Note], from source: String) -> String {
        let ns = source as NSString
        var output = ""
        var cursor = 0

        for note in notes.sorted(by: { $0.range.location < $1.range.location }) {
            let location = note.range.location
            guard location >= cursor else { continue }
            output += ns.substring(with: NSRange(location: cursor, length: location - cursor))
            output += "\n\n"
            cursor = NSMaxRange(note.range)
        }
        guard cursor < ns.length else { return output }
        return output + ns.substring(from: cursor)
    }

    /// 文末那一块脚注列表。每条带一个 `↩` 回跳到正文里**它那一处引用**。
    ///
    /// ### `id` / `href` 为什么都带上序号
    /// 同一个脚注可以在正文里被引用好几次（`[^1]` 出现三处），锚点必须每条回跳对一处—— 所以正文那边的 `id` 是 `fnref-<id>-<第几次>`，这里按下标回跳到对应的那一个。
    private static func footnoteSection(_ notes: [Note], renderer: inout MarkdownHTMLRenderer) -> String {
        guard !notes.isEmpty else { return "" }

        var output = "<section class=\"footnotes\">\n<hr>\n<ol>\n"
        for note in notes {
            let fragment = MarkdownHTMLRenderer.fragment(forFootnote: note.id)
            let content = renderer.visit(Document(parsing: note.body))
            output += "<li id=\"fn-\(fragment)\">\(content)"
                + "<a href=\"#fnref-\(fragment)-\(note.index)\" class=\"footnote-backref\">↩</a></li>\n"
        }
        return output + "</ol>\n</section>\n"
    }

    /// 去掉脚注续行的缩进。
    ///
    /// GFM 里一条脚注写多段时，后面的段必须缩进（通常是 4 个空格）。直接把这段源码交给 cmark 的话，它会按自己的规矩把「缩进的行」当成**代码块** —— 脚注里第二段会莫名其妙变成等宽字体。
    /// 所以每行最多剥掉 4 个空格或制表符再喂给解析器（业界通用做法），剥完续行就还原成普通正文了。
    private static func dedent(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count > 1 else { return text }

        for index in 1..<lines.count {
            var consume = 0
            for character in lines[index] {
                guard character == " " || character == "\t", consume < 4 else { break }
                consume += 1
            }
            guard consume > 0 else { continue }
            lines[index] = String(lines[index].dropFirst(consume))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: 图片

    /// 一张图最多内联多大。**超过 2 MB 就保留原路径**：内联之后 HTML 会比图本身还难分享，得不偿失。
    private static let maxInlineImageBytes = 2 * 1024 * 1024

    /// 把一张本地图片编成 `data:` 形式的地址。
    ///
    /// ### 为什么不只拼「文档目录 + 原路径」就完事
    /// 老写法只试这一个地址，试不到就**静默**留原路径 —— 实测最常见的失败正是这一处：
    /// App 是开了沙盒的，用「打开」面板挑进来的那份 md 只给自己发了通行证，**同目录的 png 读不到**；
    /// 而编辑器里那张图却是能显示的，因为它走的是 `ImageLoader` 那条「文档目录 → App 包 → 绝对路径」的兜底链。
    /// 于是用户看到的是「图明明在，导出却没内联」。所以这里把候选地址铺开，跟编辑器认同一张图。
    ///
    /// - Returns: 内联后的 `data:` 地址；不是本地图 / 一个候选都读不到时返回 nil（调用方保留原路径）
    static func inlinedImageSource(for reference: String, baseDirectory: URL?) -> String? {
        guard let path = localPath(forImageReference: reference) else { return nil }

        for url in candidateURLs(forImagePath: path, baseDirectory: baseDirectory) {
            // ⚠️ 不再先用 `isReadableFile` 问一遍：沙盒下它给的答案是不可信的（会把能读的说成读不到），直接读一次才是真的。读失败（没权限 / 不是文件）自然走到下一个候选。
            guard let data = try? Data(contentsOf: url),
                  !data.isEmpty,
                  data.count <= maxInlineImageBytes,
                  let mime = mimeType(for: url, data: data) else { continue }

            return "data:\(mime);base64,\(data.base64EncodedString())"
        }
        return nil
    }

    /// 把 markdown 里的图片地址洗成一个干净的文件路径；不是本地文件（网络图、`data:`）返回 nil。
    ///
    /// 要处理的几种写法：`![](./a.png)`、`![](<my image.png>)`、`![](a.png "标题")`、`![](a%20b.png)`。
    private static func localPath(forImageReference reference: String) -> String? {
        var raw = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        // `<…>` 包裹（地址里有空格时的标准写法）
        if raw.hasPrefix("<"), raw.hasSuffix(">") { raw = String(raw.dropFirst().dropLast()) }
        // 标题：`![a](b.png "标题")`。只在**看得出有标题**（带引号）时才切 —— 不然 `my image.png` 这种带空格的文件名会被切成 `my`。
        // 带协议头的（网络地址里可能有空格）也不按这个切
        if (raw.contains("\"") || raw.contains("'")),
           let space = raw.firstIndex(of: " "),
           raw[raw.startIndex..<space].range(of: "://") == nil {
            raw = String(raw[raw.startIndex..<space])
        }
        guard !raw.isEmpty else { return nil }
        // 网络图 / `data:` 开头的直接排除：它们本来就不该去磁盘上找
        guard raw.hasPrefix("/") || looksLikeRelativePath(raw) else { return nil }

        // `![](my%20photo.png)` 是有可能的，先把百分号编码还原成真的文件名
        let decoded = raw.removingPercentEncoding ?? raw
        return normalizingDotSegments(decoded)
    }

    /// 候选地址，按「最可能是作者指的那张」往后排。
    ///
    /// 顺序和编辑器那条链一致（见 `ImageLoader.resolve`）：文档目录 → 绝对路径 → App 包资源。
    /// 排在后面的都是兜底，只有前面的真不存在才会用到 —— 保证「编辑器里显示的是哪张，导出就是哪张」。
    static func candidateURLs(forImagePath path: String, baseDirectory: URL?) -> [URL] {
        var urls: [URL] = []
        let append = { (url: URL?) in
            guard let url, !urls.contains(url) else { return }
            urls.append(url)
        }

        // ① 相对文档所在目录（绝大多数情况）
        if let baseDirectory { append(baseDirectory.appendingPathComponent(path)) }
        // 找不到文档在哪时（还没保存过）退到 App 的 Documents —— 粘贴进来的图片都存那儿
        if baseDirectory == nil { append(DocumentsWorkspace.folderURL.appendingPathComponent(path)) }
        // ② 源码里写的就是绝对路径
        if path.hasPrefix("/") { append(URL(fileURLWithPath: path)) }
        // ③ App 包里的资源：演示文档（sample.md 里的 sample.png）常常只存在于包里
        append(bundleURL(forImagePath: path))

        return urls
    }

    /// 去 App 包里找这张图。包里是平铺的，所以「路径里那几层目录」和「只剩文件名」都试一遍。
    private static func bundleURL(forImagePath path: String) -> URL? {
        let full = path as NSString
        let bare = full.lastPathComponent as NSString
        for (name, fileExtension) in [(full.deletingPathExtension, full.pathExtension),
                                      (bare.deletingPathExtension, bare.pathExtension)] {
            guard !name.isEmpty else { continue }
            // 扩展名为空时按 png 试（老写法就是这么兜的）
            let lookup = fileExtension.isEmpty ? "png" : fileExtension
            if let url = Bundle.main.url(forResource: name, withExtension: lookup) { return url }
        }
        return nil
    }

    /// 去掉路径里的 `.` 段并解开 `..`（`./sample.png` → `sample.png`）。
    ///
    /// 留着 `.` 不影响读文件，但会让「去 App 包里按名字找」那一步对不上号（包里不会有个叫 `./sample` 的资源）。
    private static func normalizingDotSegments(_ path: String) -> String {
        guard path.contains(".") else { return path }
        var stack: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: false) {
            switch part {
            case ".", "": continue          // 开头的 `/` 会拆出一个空段，跳过它（下面单独补回来）
            case "..": if !stack.isEmpty { stack.removeLast() }
            default: stack.append(String(part))
            }
        }
        let joined = stack.joined(separator: "/")
        return path.hasPrefix("/") ? "/" + joined : joined
    }

    /// 是不是本地相对路径（`sample.png`、`sub/a.jpg`）。带协议、`//cdn/...`、绝对 http 地址都不是。
    private static func looksLikeRelativePath(_ text: String) -> Bool {
        guard !text.isEmpty, !text.hasPrefix("//") else { return false }
        let colon = text.firstIndex(of: ":")
        guard let colon else { return true }
        // `a/b.png` 里如果有 `/`，冒号必须出现在它之后才算相对路径（`http://x` 的冒号在最前面）
        guard let slash = text.firstIndex(of: "/") else { return false }
        return colon > slash
    }

    /// 扩展名 → MIME，认不出来再按文件头的几个字节猜（`IMG_1234` 这种没有扩展名的图也能内联）。
    /// 都猜不出来返回 nil（宁可保留原路径，也别编出一个打不开的 `data:` URL）。
    private static func mimeType(for url: URL, data: Data) -> String? {
        if let byExtension = mimeType(forExtension: url.pathExtension) { return byExtension }
        return sniffedMimeType(data)
    }

    private static func mimeType(forExtension extension: String) -> String? {
        switch `extension`.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "bmp": return "image/bmp"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "tif", "tiff": return "image/tiff"
        case "ico": return "image/x-icon"
        default: return nil
        }
    }

    /// 按文件头猜格式。每种图的头几个字节是固定的（PNG 是 `‰PNG`，JPEG 是 `FF D8 FF`），比扩展名可靠。
    private static func sniffedMimeType(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        guard bytes.count >= 4 else { return nil }

        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF { return "image/jpeg" }
        if bytes.starts(with: Array("GIF8".utf8)) { return "image/gif" }
        if bytes[0] == 0x42, bytes[1] == 0x4D { return "image/bmp" }
        // TIFF：`II*\0`（小端）/ `MM\0*`（大端）
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00]) || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            return "image/tiff"
        }
        // WEBP / HEIC 都是 `….ftyp` / `RIFF….WEBP` 这种「盒子」结构，品牌名在第 4～12 字节里
        if bytes.starts(with: Array("RIFF".utf8)), bytes.count >= 12,
           Array(bytes[8..<12]) == Array("WEBP".utf8) { return "image/webp" }
        if bytes.count >= 12, Array(bytes[4..<8]) == Array("ftyp".utf8) {
            let brand = String(bytes: bytes[8..<12], encoding: .ascii) ?? ""
            // heic / heix / hevc / mif1（HEIF 的通用品牌）都能被浏览器当 HEIC 解
            if ["heic", "heix", "hevc", "hevx", "mif1", "msf1"].contains(brand) { return "image/heic" }
        }
        return nil
    }
}
