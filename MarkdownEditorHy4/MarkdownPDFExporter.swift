import UIKit
import WebKit
import CoreGraphics

/// 把一份 HTML 排成多页 PDF。
///
/// ### 为什么走「先转 HTML、再让 WebKit 按纸张排版」这条路
/// 编辑器里那份 `NSAttributedString` 是照着**屏幕**排的（一行多宽取决于窗口多宽），拿它直接画 PDF 等于把窗口切成一页页 —— 换个窗口大小页数就变了。
/// 而 HTML 那边已经有一套干净的版式（`MarkdownHTMLTokens`），交给 WebKit 按 A4 的宽度重新排一次，得到的才是真正的文档分页：
/// 标题、代码块、表格该在哪儿断开由排版引擎决定，导出成 PDF 和导出成 HTML 长得也一致（同一套配色）。
///
/// ### 为什么是异步的
/// WebKit 得先把网页排完版才知道它有多长、要分几页，所以只能等 `didFinish` 那个回调。
/// 这一层是 `makePDF(html:completion:)`：`completion` 一定在主线程给回结果，拿不到（排版失败）给 nil。
enum MarkdownPDFExporter {

    /// 纸张。单位是**点**（1 点 = 1/72 英寸，PDF 的标准单位，和 UIKit 的点在打印上下文里是一致的）。
    struct Page {
        var size: CGSize
        /// 四周留白（页边距）
        var margin: CGFloat

        /// A4（210 × 297 mm）
        static let a4 = Page(size: CGSize(width: 595.28, height: 841.89), margin: 36)
        /// US Letter（北美常用，比 A4 短一点宽一点）
        static let letter = Page(size: CGSize(width: 612, height: 792), margin: 36)

        /// 这一页能排内容的那块矩形（去掉页边距）
        var printableWidth: CGFloat { size.width - margin * 2 }
    }

    /// 排好版的一份 PDF。
    struct PDF {
        var data: Data
        /// 一共几页（状态栏里报「共 3 页」用的）
        var pageCount: Int
    }

    /// 生成 PDF。
    ///
    /// - Parameters:
    ///   - html: 完整的 HTML（一般就是 `MarkdownHTMLExporter` 的产物）
    ///   - title: 写进 PDF 元信息里的标题（在预览器里显示）
    ///   - page: 纸张与页边距
    ///   - completion: 主线程回调；成功给回 PDF，排版失败给 nil
    static func makePDF(html: String, title: String = "", page: Page = .a4,
                        completion: @escaping @MainActor (PDF?) -> Void) {
        // 这个 driver 自己在回调完成前保活（`selfRetain`），调用方不用记着它
        WebLayoutDriver(html: html, title: title, page: page, completion: completion).start()
    }
}

// MARK: - 排版

/// 一次「把网页排到纸上」的过程：建一个看不见的 WKWebView，等它排完，再画成 PDF。
///
/// ### 为什么要自己保活
/// WKWebView 的回调是异步的，而这个对象只被 `makePDF` 里的局部变量指着 —— 方法一返回它就被释放，回调永远来不了。
/// 所以开局把自己存进 `selfRetain`，收尾再放开（这是「一次性异步任务」的常规写法）。
private final class WebLayoutDriver: NSObject, WKNavigationDelegate {

    private let page: MarkdownPDFExporter.Page
    private let title: String
    private let html: String
    private let webView: WKWebView
    private var completion: ((MarkdownPDFExporter.PDF?) -> Void)?
    private var selfRetain: WebLayoutDriver?
    /// 兜底：网页排不完（比如卡在某个加载不出来的资源上）也别让导出一直转
    private static let timeoutSeconds: TimeInterval = 15

    init(html: String, title: String, page: MarkdownPDFExporter.Page,
         completion: @escaping (MarkdownPDFExporter.PDF?) -> Void) {
        self.page = page
        self.title = title
        self.html = html
        self.completion = completion
        // web view 的宽度就是「纸上能用的宽度」：内容按这个宽度排，画出来的字才不会被整体缩放
        self.webView = WKWebView(frame: CGRect(x: 0, y: 0, width: page.printableWidth, height: page.size.height))
        super.init()
    }

    func start() {
        selfRetain = self
        webView.navigationDelegate = self

        // ⚠️ 不在视图树里的 WKWebView 有可能根本不排版（画出来是空白页）。
        // 所以只要拿得到窗口，就把它透明地塞进去：`alpha` 极低 + 关掉交互，用户看不见也点不到。
        if let window = Self.keyWindow {
            webView.alpha = 0.01
            webView.isUserInteractionEnabled = false
            window.addSubview(webView)
        }

        webView.loadHTMLString(html, baseURL: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeoutSeconds) { [weak self] in
            self?.finish()
        }
    }

    /// 排完了（或超时了 / 失败了）→ 画 PDF → 回调 → 放开自己。
    ///
    /// `completion` 取出来就置 nil，保证 `didFinish` 和超时那一路**只会有一次**真的往下走。
    private func finish() {
        guard let completion else { return }
        self.completion = nil

        let pdf = Self.renderPDF(from: webView, title: title, page: page)
        webView.removeFromSuperview()
        selfRetain = nil
        completion(pdf)
    }

    // MARK: 画 PDF

    /// 把排好的网页按页画进一份 PDF 数据。
    private static func renderPDF(from webView: WKWebView, title: String,
                                  page: MarkdownPDFExporter.Page) -> MarkdownPDFExporter.PDF? {
        let renderer = PageRenderer(page: page)
        let formatter = webView.viewPrintFormatter()
        // 告诉排版器「内容最宽就这么宽」，不然它可能按 web view 自己的宽度排，再整体缩放到纸上
        formatter.maximumContentWidth = page.printableWidth
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)

        let pageCount = renderer.numberOfPages
        guard pageCount > 0 else { return nil }

        let data = NSMutableData()
        // 元信息：预览器 / 访达里显示的标题，顺带标一下是谁生成的
        let metadata: [String: Any] = [kCGPDFContextTitle as String: title,
                                       kCGPDFContextCreator as String: "MarkdownEditorHy4"]
        UIGraphicsBeginPDFContextToData(data, renderer.paperRect, metadata)
        for index in 0..<pageCount {
            UIGraphicsBeginPDFPage()
            // `UIGraphicsGetPDFContextBounds()` 就是上面那个 paperRect —— 打印器自己会按 printableRect 留出页边距
            renderer.drawPage(at: index, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()

        guard data.length > 0 else { return nil }
        return MarkdownPDFExporter.PDF(data: data as Data, pageCount: pageCount)
    }

    /// 当前的活动窗口（用来把那个透明的 web view 挂上去）
    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }

    // MARK: WKNavigationDelegate

    /// WebKit 的回调不在 Swift 的 actor 体系里（协议没标 `@MainActor`），但 WebKit 保证它一定在主线程调 —— 所以这里直接 `assumeIsolated` 切回去，不用绕一次 `Task`。
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { self.finish() }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        MainActor.assumeIsolated { self.finish() }
    }

    /// 原因见 `MarkdownBlock` 里 `nonisolated deinit` 的注释：隔离 deinit 一旦嵌套就会踩 Swift 6.2 运行时的野指针 free。
    nonisolated deinit {}
}

/// 一个「知道纸多大」的打印器。
///
/// `UIPrintPageRenderer` 的 `paperRect` / `printableRect` 都是只读的，想改只能子类化重写（外面那些用 KVC 硬塞 `setValue(_:forKey:)` 的写法能跑，但那是靠私有键名，系统一改就崩）。
private final class PageRenderer: UIPrintPageRenderer {

    private let pageSize: CGSize
    private let margin: CGFloat

    init(page: MarkdownPDFExporter.Page) {
        self.pageSize = page.size
        self.margin = page.margin
        super.init()
    }

    /// 整张纸
    override var paperRect: CGRect { CGRect(origin: .zero, size: pageSize) }
    /// 纸上能印内容的那块（去掉页边距）
    override var printableRect: CGRect { paperRect.insetBy(dx: margin, dy: margin) }

    nonisolated deinit {}
}
