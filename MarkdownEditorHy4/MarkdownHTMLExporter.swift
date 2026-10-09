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
        /// 相对路径的图片相对谁解析（一般传文档所在目录）
        var baseDirectory: URL?

        init(style: StyleSource,
             inlinesLocalImages: Bool = false,
             baseDirectory: URL? = nil) {
            self.style = style
            self.inlinesLocalImages = inlinesLocalImages
            self.baseDirectory = baseDirectory
        }
    }

    // MARK: 导出

    static func export(markdown source: String, title: String, options: Options) -> String {
        let notes = footnoteDefinitions(in: source)
        let bodySource = removing(notes, from: source)

        var renderer = MarkdownHTMLRenderer()
        renderer.footnoteIDs = Set(notes.map(\.id))
        renderer.footnoteNumbers = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0.index) })
        renderer.imageSourceResolver = options.inlinesLocalImages
            ? { imageSource(for: $0, baseDirectory: options.baseDirectory) }
            : nil

        let body = renderer.visit(Document(parsing: bodySource))
        let footnotes = footnoteSection(notes, renderer: &renderer)

        return page(body: body, footnotes: footnotes, title: title, tokens: options.style.tokens)
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

    /// 图片地址最终怎么写进 `src`。内联不了的情况（网络图、读不到、太大、不认识的格式）一律原样返回。
    private static func imageSource(for reference: String, baseDirectory: URL?) -> String {
        guard looksLikeRelativePath(reference),
              let url = fileURL(for: reference, baseDirectory: baseDirectory),
              FileManager.default.isReadableFile(atPath: url.path),
              let data = try? Data(contentsOf: url),
              !data.isEmpty,
              data.count <= maxInlineImageBytes,
              let mime = mimeType(forExtension: url.pathExtension) else { return reference }

        return "data:\(mime);base64,\(data.base64EncodedString())"
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

    private static func fileURL(for reference: String, baseDirectory: URL?) -> URL? {
        // 源码里写 `![](my%20photo.png)` 是有可能的，先把百分号编码还原成真的文件名
        let path = reference.removingPercentEncoding ?? reference
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        guard let baseDirectory else { return nil }
        return baseDirectory.appendingPathComponent(path)
    }

    /// 扩展名 → MIME。认不出来的返回 nil（宁可保留原路径，也别编出一个打不开的 `data:` URL）
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
}
