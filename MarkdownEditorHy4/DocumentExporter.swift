//
//  DocumentExporter.swift
//  MarkdownEditorHy4
//
//  「把一份文档导出成图片 / HTML / PDF」的公共流程 —— 编辑页的菜单和左栏右键共用这一份。
//

import UIKit

/// 一份待导出的文档：内容 + 名字 + 磁盘位置。
struct DocumentExportSource {
    /// markdown 源码
    var markdown: String
    /// 显示用的名字（不带扩展名）。导出文件按它起名：`笔记` → `笔记.png` / `笔记.html` / `笔记.pdf`
    var displayName: String
    /// 对应的磁盘文件。相对路径的图片按它所在目录解析；确实没有文件时传 nil（会退到 App 的 Documents 目录）
    var fileURL: URL?
    /// 导出成图片时，那张长图从哪儿来。
    ///
    /// - 编辑页传「让编辑器自己画」：它正开着这份文档，画出来就是屏幕上看到的那个样子；
    /// - 左栏右键导出的文档**根本没在编辑器里开着**，传 nil —— 那种情况本类会临时造一台编辑器自己画（见 `renderImage`）。
    var imageRenderer: (() -> UIImage?)?

    init(markdown: String,
         displayName: String,
         fileURL: URL? = nil,
         imageRenderer: (() -> UIImage?)? = nil) {
        self.markdown = markdown
        self.displayName = displayName
        self.fileURL = fileURL
        self.imageRenderer = imageRenderer
    }
}

/// 「导出」这条链路的执行者。
///
/// ### 为什么要单独一个类
/// 两个入口都要导出，而且**必须导得一模一样**：
/// - 编辑页右上角「⋯」菜单里的「导出」；
/// - 左栏对着某份文件右键（iPad 上是长按）→「导出」。
/// 两者的差别只有「内容从哪儿来」——编辑页是编辑器内存里的当前内容（可能还没存盘），左栏是磁盘上的文件；
/// 「问格式 → 问选项 → 落盘 / 分享」整条流程完全一样，所以收成这一份，别再写第二遍。
///
/// ### 谁持有它
/// 调用方拿着它（两个控制器各存一个 `lazy var`）。
/// 这里对 presenter 只**弱**引用 —— 不然就是「控制器 → 导出器 → 控制器」一个圈，控制器放不掉。
///
/// ### 为什么继承 `NSObject`
/// Mac 上落盘走的是系统存储面板（`UIDocumentPickerViewController`），当它的代理必须是个 `NSObject`
/// —— Swift 里没法凭空声明成 `NSObjectProtocol`，只能继承。
@MainActor
final class DocumentExporter: NSObject {

    /// 能导出成什么
    enum Kind: CaseIterable {
        case image
        case html
        case pdf

        /// 菜单上显示的名字
        var title: String {
            switch self {
            case .image: return "图片"
            case .html: return "HTML"
            case .pdf: return "PDF"
            }
        }

        /// 菜单左边那个小图标
        var symbolName: String {
            switch self {
            case .image: return "photo.on.rectangle"
            case .html: return "doc.richtext"
            case .pdf: return "doc.text"
            }
        }
    }

    /// 点菜单那一刻才去要「要导出的内容」。
    ///
    /// ### 为什么是个闭包，而不是建菜单时就把内容传进来
    /// 编辑页的「⋯」菜单是装配时建好的**一个**实例，之后一直用它。
    /// 内容若在建菜单时就定下来，那用户改了半天的稿再点导出，导出的还是打开菜单之前那一版。
    typealias SourceProvider = () -> DocumentExportSource?

    /// 谁来弹面板（存储面板 / 分享面板 / 提示框）
    private weak var presenter: UIViewController?
    /// iPad / Mac 上弹出来的东西要有个锚点（popover 必须知道从哪个视图「长出来」）
    private weak var anchorView: UIView?
    /// 「跟随当前主题」时用哪套主题。用闭包是为了每次导出都取**当时**的主题，而不是装配时那一套
    private let theme: () -> MarkdownTheme
    /// 进度 / 结果的一句话往哪儿报。编辑页写进它自己的状态栏；左栏没有状态栏，就不管（默认空实现）
    private let onStatus: (String) -> Void

    init(presenter: UIViewController,
         anchorView: UIView?,
         theme: @escaping () -> MarkdownTheme,
         onStatus: @escaping (String) -> Void = { _ in }) {
        self.presenter = presenter
        self.anchorView = anchorView
        self.theme = theme
        self.onStatus = onStatus
        super.init()
    }

    /// 原因见 `MarkdownBlock` / `OutlineCoordinator` 里 `nonisolated deinit` 的长注释：
    /// 本类不是 UIView（只是 `NSObject`），不写这一行就可能踩 Swift 6.2 运行时的野指针 free。
    nonisolated deinit {}

    // MARK: - 菜单

    /// 「导出」这一组菜单项（图片 / HTML / PDF）。
    ///
    /// 返回的是一个**子菜单**：编辑页的「⋯」和左栏右键都把它整块塞进自己的菜单，于是两个入口看到的选项、顺序、图标永远一致 —— 以后要加「导出成 Word」只改这里一处。
    func exportMenu(source: @escaping SourceProvider) -> UIMenu {
        let actions = Kind.allCases.map { kind in
            UIAction(title: kind.title, image: UIImage(systemName: kind.symbolName)) { [weak self] _ in
                // 内容到这一刻才去要；要不到（空文档 / 文件读不出来）时它自己已经提示过用户了
                guard let self, let source = source() else { return }
                self.export(kind, source: source)
            }
        }
        return UIMenu(title: "导出",
                      image: UIImage(systemName: "square.and.arrow.up"),
                      children: actions)
    }

    /// 不走菜单、直接按指定格式导出。
    ///
    /// 菜单那条路最后也是落到这儿，所以「有没有菜单」跟导出结果无关。
    func export(_ kind: Kind, source: DocumentExportSource) {
        switch kind {
        case .image: exportAsImage(source)
        case .html: askThenExportHTML(source)
        case .pdf: askThenExportPDF(source)
        }
    }

    // MARK: - 图片

    /// 整篇内容 → 一张长图。
    ///
    /// 渲染细节（撑大视口、逐段画文字那些）封装在 `MarkdownTextView.renderFullContentImage()` 里，这里只管「导出到哪」：
    /// - Mac Catalyst：弹系统「存储」面板，落到用户选的本地文件夹；
    /// - iOS：弹系统分享面板（存相册 / AirDrop / 存到「文件」都行）。
    private func exportAsImage(_ source: DocumentExportSource) {
        // 编辑页有现成的编辑器就让它画；左栏那条路没有编辑器，临时造一台（见 renderImage）
        let image = source.imageRenderer?()
            ?? Self.renderImage(markdown: source.markdown,
                                theme: theme(),
                                baseDirectory: source.fileURL?.deletingLastPathComponent(),
                                width: preferredRenderWidth)
        guard let image else {
            showAlert(title: "导出失败", message: "没有可导出的内容。")
            return
        }

        #if targetEnvironment(macCatalyst)
        saveImageToFolder(image, named: source.displayName)
        #else
        onStatus("已生成图片 \(Int(image.size.width))×\(Int(image.size.height))，正在打开分享面板")
        presentShareSheet(for: image)
        #endif
    }

    /// 没在编辑器里开着的那份文档，导出成图片时按多宽排版。
    ///
    /// 取的是**窗口有多宽**：编辑页那条路是「编辑器有多宽就多宽」，这里取同一个意思 ——屏幕大就排得宽，而不是写死一个跟设备无关的数字。窗口还取不到（极早期）就退到 800 点。
    private var preferredRenderWidth: CGFloat {
        let width = presenter?.view.window?.bounds.width ?? 0
        return width > 1 ? width : 800
    }

    /// 临时造一台编辑器，把一份**没在编辑器里开着**的文档画成一张长图。
    ///
    /// ### 为什么非要有这一条路
    /// 导出图片靠的是编辑器那套自绘（撑大视口 + 逐段 draw），而左栏右键导出的文档压根没被打开过 ——没有别的办法能画出「和编辑页一模一样」的图，所以只能临时造一台。
    ///
    /// ### 这台编辑器不进视图树
    /// `renderFullContentImage()` 是纯绘制：它自己按 `bounds` 排完版、用 `UIGraphicsImageRenderer` 画，最后画的是各图层和 layout fragment，不依赖「屏幕上真的显示着」。
    /// 所以这里给个宽度、`layoutIfNeeded()` 一下就够了，不需要窗口。
    ///
    /// - Parameters:
    ///   - width: 排版宽度（点）。宽度不同排版结果不同，这个值决定图的宽窄
    ///   - baseDirectory: 相对路径的图片按它解析，不传就退到 App 的 Documents 目录
    static func renderImage(markdown: String,
                            theme: MarkdownTheme,
                            baseDirectory: URL?,
                            width: CGFloat) -> UIImage? {
        let editor = MarkdownTextView()
        // ⚠️ 顺序有讲究：**先把主题写进去，再装内容**。
        // 反过来就是「用默认主题渲一遍、再用真主题重渲一遍」—— 同一份内容白渲染两次
        editor.renderer.theme = theme
        editor.applyThemeChrome()
        editor.imageBaseURL = baseDirectory
        // 宽度必须在 setMarkdown 之前给：内容按容器宽度排版，宽度为 0 的话什么都排不出来
        editor.frame = CGRect(x: 0, y: 0, width: max(width, 120), height: 100)
        editor.setMarkdown(markdown)
        // 不主动抢第一响应者：没人聚焦就不画光标，导出的图里不会多一条竖线
        editor.layoutIfNeeded()
        return editor.renderFullContentImage()
    }

    // MARK: - HTML

    /// 「导出成 HTML」：先问配色 / 图片怎么处理，再落到文件系统。
    ///
    /// ### 为什么要中间插一页
    /// 配色（跟主题 / 固定内置）和图片（保留路径 / base64 内联）都得用户自己拿主意 ——默认值给不出「对所有人最优」，所以把选择权交给用户，顺便记住上次的选择。
    private func askThenExportHTML(_ source: DocumentExportSource) {
        let controller = HTMLExportOptionsController(kind: .html)
        controller.onExport = { [weak self] choice in
            self?.exportHTML(source, choice: choice)
        }
        presentOptions(controller)
    }

    private func exportHTML(_ source: DocumentExportSource, choice: HTMLExportChoice) {
        let result = makeHTML(source, choice: choice, inlinesLocalImages: choice.inlinesLocalImages)
        let summary = imageInlineSummary(result)

        #if targetEnvironment(macCatalyst)
        saveHTMLToFolder(result.html, named: source.displayName, summary: summary)
        #else
        // 默认文件名跟文档同名：notes.md → notes.html
        let suggestedName = (source.displayName as NSString).deletingPathExtension + ".html"
        guard let url = temporaryFileURL(for: Data(result.html.utf8), named: suggestedName) else { return }
        onStatus("已生成 HTML（\(result.html.utf8.count / 1024) KB）\(summary)，正在打开分享面板")
        presentShareSheet(forFile: url)
        #endif
    }

    // MARK: - PDF

    /// 「导出成 PDF」的选项页：和 HTML 那一页是同一个面板，只是 PDF 不提供「图片保留原路径」这个选项。
    private func askThenExportPDF(_ source: DocumentExportSource) {
        let controller = HTMLExportOptionsController(kind: .pdf)
        controller.onExport = { [weak self] choice in
            self?.exportPDF(source, choice: choice)
        }
        presentOptions(controller)
    }

    /// 生成 PDF 并导出。
    ///
    /// 走的是 HTML 那条管线：同样先转成一份完整的 HTML（配色、脚注、转义全都复用），再交给 WebKit 按 A4 重新排版 —— 这样 PDF 和 HTML 两个产物长得一致，也不用再写一遍「markdown → 版式」。
    private func exportPDF(_ source: DocumentExportSource, choice: HTMLExportChoice) {
        // PDF 一定内联图片：它是自包含的单文件，留原路径等于丢图
        let result = makeHTML(source, choice: choice, inlinesLocalImages: true)
        onStatus("正在排版 PDF…")

        MarkdownPDFExporter.makePDF(html: result.html, title: source.displayName) { [weak self] pdf in
            guard let self else { return }
            guard let pdf else {
                self.showAlert(title: "导出失败", message: "PDF 排版失败，请重试。")
                return
            }
            let summary = self.imageInlineSummary(result)
            let pages = "（\(pdf.pageCount) 页）"

            #if targetEnvironment(macCatalyst)
            self.savePDFToFolder(pdf.data, named: source.displayName, pages: pages, summary: summary)
            #else
            // 默认文件名跟文档同名：notes.md → notes.pdf
            let suggestedName = (source.displayName as NSString).deletingPathExtension + ".pdf"
            guard let url = self.temporaryFileURL(for: pdf.data, named: suggestedName) else { return }
            self.onStatus("已生成 PDF\(pages)（\(pdf.data.count / 1024) KB）\(summary)，正在打开分享面板")
            self.presentShareSheet(forFile: url)
            #endif
        }
    }

    // MARK: - 生成 HTML（HTML 和 PDF 共用）

    /// 导出用的那套选项（配色按用户选的，图片基准目录按文档所在目录）。
    ///
    /// `inlinesLocalImages` 由调用方定：HTML 跟着用户的选择，PDF 恒为 true（理由见 `exportPDF`）。
    private func makeHTML(_ source: DocumentExportSource,
                          choice: HTMLExportChoice,
                          inlinesLocalImages: Bool) -> MarkdownHTMLExporter.Result {
        MarkdownHTMLExporter.exportDocument(
            markdown: source.markdown,
            title: source.displayName,
            options: MarkdownHTMLExporter.Options(
                style: choice.usesThemeColors ? .currentTheme(theme()) : .builtIn,
                inlinesLocalImages: inlinesLocalImages,
                baseDirectory: source.fileURL?.deletingLastPathComponent()
            )
        )
    }

    /// 图片内联这一趟的结果怎么说给用户听。
    ///
    /// 内联这事儿是**静默**的：成功了没人注意，失败了也只是在 HTML 里留下一行 `src="./a.png"`。
    /// 读不到图（沙盒里很常见）时一声不吭，用户只会觉得「这个开关是坏的」—— 所以把张数和读不到的那几个名字报出来。
    private func imageInlineSummary(_ result: MarkdownHTMLExporter.Result) -> String {
        guard result.inlinedImages > 0 || !result.missedImages.isEmpty else { return "" }
        let text = "，内联 \(result.inlinedImages) 张图"
        guard !result.missedImages.isEmpty else { return text }
        let names = result.missedImages.prefix(3).joined(separator: "、")
        let more = result.missedImages.count > 3 ? " 等 \(result.missedImages.count) 张" : ""
        return text + "（读不到：\(names)\(more)，已保留原路径）"
    }

    // MARK: - 落盘（Mac）

    #if targetEnvironment(macCatalyst)
    /// Mac 专属：把长图存成 PNG，落到用户选的本地文件夹。
    ///
    /// ### 为什么不用 NSSavePanel
    /// Catalyst 把它标记成 unavailable（Swift 编译器直接拦）。等效替代是 `UIDocumentPickerViewController(forExporting:asCopy:)` —— 项目里「另存为」用的同一块面板，在 Mac 上呈现的就是原生风格的存储对话框（选文件夹 + 改文件名）。
    private func saveImageToFolder(_ image: UIImage, named displayName: String) {
        guard let pngData = image.pngData() else {
            showAlert(title: "导出失败", message: "图片编码成 PNG 失败。")
            return
        }
        onStatus("已生成图片 \(Int(image.size.width))×\(Int(image.size.height))，请选择存储位置")
        // 默认文件名跟文档同名：notes.md → notes.png
        let suggestedName = (displayName as NSString).deletingPathExtension + ".png"
        guard let url = temporaryFileURL(for: pngData, named: suggestedName) else { return }
        presentExportPicker(for: url)
    }

    /// Mac 专属：把 HTML 字符串落到用户选的本地文件夹（notes.md → notes.html）。
    private func saveHTMLToFolder(_ html: String, named displayName: String, summary: String) {
        guard let data = html.data(using: .utf8) else {
            showAlert(title: "导出失败", message: "HTML 编码成 UTF-8 失败。")
            return
        }
        onStatus("已生成 HTML（\(data.count / 1024) KB）\(summary)，请选择存储位置")
        let suggestedName = (displayName as NSString).deletingPathExtension + ".html"
        guard let url = temporaryFileURL(for: data, named: suggestedName) else { return }
        presentExportPicker(for: url)
    }

    /// Mac 专属：把 PDF 落到用户选的本地文件夹（notes.md → notes.pdf）。
    private func savePDFToFolder(_ data: Data, named displayName: String, pages: String, summary: String) {
        onStatus("已生成 PDF\(pages)（\(data.count / 1024) KB）\(summary)，请选择存储位置")
        let suggestedName = (displayName as NSString).deletingPathExtension + ".pdf"
        guard let url = temporaryFileURL(for: data, named: suggestedName) else { return }
        presentExportPicker(for: url)
    }

    /// 弹导出面板。用户挑完位置之后由本类的代理回调收尾（见下面的 `UIDocumentPickerDelegate`）
    private func presentExportPicker(for tempURL: URL) {
        let picker = UIDocumentPickerViewController(forExporting: [tempURL], asCopy: true)
        picker.delegate = self
        presenter?.present(picker, animated: true)
    }
    #else
    /// iOS：系统分享面板，存相册 / AirDrop / 存到「文件」都走这里。
    ///
    /// 图片直接给 `UIImage`；HTML / PDF 给文件 URL —— 字符串在系统眼里只是「一段文字」，给字符串的话 AirDrop 过去对方收到的是纯文本、「存储到文件」也只会存成 `.txt`。
    private func presentShareSheet(for image: UIImage) {
        let activity = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        anchorPopover(activity)
        presenter?.present(activity, animated: true)
    }

    /// iOS：分享一个已经落在临时目录里的文件 URL
    private func presentShareSheet(forFile tempURL: URL) {
        let activity = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
        anchorPopover(activity)
        presenter?.present(activity, animated: true)
    }

    /// iPad 上分享面板必须以 popover 形式出现，得给个锚点；iPhone 用不上这条，留着不碍事
    private func anchorPopover(_ activity: UIActivityViewController) {
        guard let popover = activity.popoverPresentationController,
              let anchor = anchorView else { return }
        popover.sourceView = anchor
        popover.sourceRect = anchor.bounds
    }
    #endif

    /// 把导出内容先写成一份临时文件 —— 两个平台的系统面板**都只认文件 URL**，不认内存里的数据。
    private func temporaryFileURL(for data: Data, named suggestedName: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(suggestedName)
        do {
            try data.write(to: url)
        } catch {
            showAlert(title: "导出失败", message: error.localizedDescription)
            return nil
        }
        return url
    }

    // MARK: - 小工具

    private func presentOptions(_ controller: HTMLExportOptionsController) {
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .formSheet
        presenter?.present(navigation, animated: true)
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        presenter?.present(alert, animated: true)
    }
}

// MARK: - 存储面板回调

extension DocumentExporter: UIDocumentPickerDelegate {

    /// 用户挑完了存放位置：系统已经把副本复制过去了，提示一句就完事
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        onStatus("已存储到 \(url.deletingLastPathComponent().path)")
    }
}
