//
//  PreviewViewController.swift
//  MarkdownQuicklookHy4
//
//  视图型快速查看扩展：用编辑器自己的 MarkdownTextView 渲染 .md
//

import OSLog
import QuickLook
import UIKit

/// 视图型快速查看扩展的入口 —— Finder 里按下空格后，交出去的那个界面就是这里搭的。
///
/// ### 为什么是「视图型」而不是「数据型」
/// 数据型（`PreviewProvider` 那条路）只能交一整页 HTML 出去，拿到的是 HTML 那套排版，跟编辑页里看到的东西不是同一份代码画的。
/// 视图型是自己交一个 `UIViewController`，于是可以直接摆一台 `MarkdownTextView` —— 预览和编辑页共用同一个渲染器。
///
/// ### 为什么 UIKit 的控制器能跑在 macOS 的快速查看里
/// Mac Catalyst 工程里的扩展本质上就是 iOS 版扩展（`UIViewController` + `QLPreviewingController`），系统会按 UIKit-on-Mac 的方式加载它。
/// 证据就在 Apple 自己的文档里：`QLPreviewingController` 上那条「For Catalyst compatibility…」的注意事项，专门交代了怎么避免和 macOS 预览自带的操作打架。
/// 要是不加载 Catalyst 扩展，这条注意事项根本没必要写。
final class PreviewViewController: UIViewController, QLPreviewingController {

    /// 排查问题时用：`log stream --predicate 'subsystem == "com.yijian.mirror.MarkdownQuicklookHy4"'` 能看到下面这些记录。
    private let log = Logger(subsystem: "com.yijian.mirror.MarkdownQuicklookHy4", category: "preview")

    /// 正文就是这个编辑器组件，一行都没改 —— 预览和编辑页的排版因此天然一致。
    private let editor = MarkdownTextView()

    /// 读不到文件时垫在中间的说明文字。
    /// **不抛异常**：抛出去系统只给一片空白，用户看不出到底发生了什么。
    private let messageLabel = UILabel()

    /// 底部署名区的容器，把分隔线和那行字兜在一起好整块贴底。
    private let footerView = UIView()

    /// 署名区顶上那条细线，用来和正文拉开层次。
    private let footerSeparator = UIView()

    /// 署名文字，内容形如 `powered by MarkdownEditorHy4`。
    private let footerLabel = UILabel()

    // MARK: 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        // 编辑器底色本身就是 `.systemBackground`，容器跟着一起走，深浅色切换时边上不会留一条缝
        view.backgroundColor = .systemBackground
        // ⚠️ footer 必须排在 editor 之前：editor 的底边约束是钉在 footerView 上的，被约束的两个视图得先有共同祖先
        setupFooter()
        setupEditor()
        setupMessageLabel()
        // 给容器一个建议尺寸：不设的话有些场合会给一个很窄的小窗，长文读起来要频繁横向挤
        preferredContentSize = CGSize(width: 860, height: 900)
    }

    /// 系统外观变了（浅色 ↔ 深色）就换一套配色重排一遍，免得深色面板上留着浅色的正文色。
    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        guard let previous, previous.userInterfaceStyle != traitCollection.userInterfaceStyle else { return }
        editor.renderer.theme = makeTheme()
        editor.refreshTheme()
    }

    // MARK: 系统入口

    /// 系统每要一次预览就调这个方法一次（Finder 里按一下空格 = 调一次）。
    func preparePreviewOfFile(at url: URL) async throws {
        // 这个方法有可能在视图加载之前就被调到，先逼一次加载，保证 editor 已经在视图树里（排版要靠它）
        loadViewIfNeeded()

        guard let source = readSource(at: url) else {
            log.error("读不到文件内容：\(url.path, privacy: .public)")
            showMessage(title: url.lastPathComponent,
                        detail: "读不到这个文件的内容。可能是扩展没有读它的权限，或者它不是 UTF-8 / UTF-16 编码。")
            return
        }

        // 相对路径的图片按「这份 md 所在的目录」找，和编辑器里一致
        editor.imageBaseURL = url.deletingLastPathComponent()
        // ⚠️ 顺序有讲究：**先把主题装好，再装内容**。
        // 反过来就是先用默认主题整篇渲一遍、再用真主题重渲一遍，同一份内容白渲染两次
        editor.renderer.theme = makeTheme()
        editor.applyThemeChrome()
        editor.setMarkdown(source)

        log.info("已渲染预览：\(url.lastPathComponent, privacy: .public)，源码 \(source.count) 字")
    }

    // MARK: 搭建视图

    /// 只读地摆一台编辑器：能滚动、能选中复制，但不给编辑。
    private func setupEditor() {
        editor.translatesAutoresizingMaskIntoConstraints = false
        // 预览不该能改文件
        editor.isEditable = false
        // 能选中、能复制 —— 这是预览该有的能力，别一起关掉
        editor.isSelectable = true
        // 行号是「编辑时帮忙定位」的辅助，预览里没有意义
        editor.showsLineNumbers = false
        view.addSubview(editor)
        NSLayoutConstraint.activate([
            editor.topAnchor.constraint(equalTo: view.topAnchor),
            // 底边让给署名区 —— 正文滚到头以后，署名始终钉在窗口最下面
            editor.bottomAnchor.constraint(equalTo: footerView.topAnchor),
            editor.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    /// 底部署名：一条细线 + 一行小字。
    ///
    /// 名字**不写死**，从宿主 App 的 Info.plist 现读，哪天把 App 改名了这里跟着变。
    private func setupFooter() {
        footerView.translatesAutoresizingMaskIntoConstraints = false
        footerSeparator.translatesAutoresizingMaskIntoConstraints = false
        footerLabel.translatesAutoresizingMaskIntoConstraints = false

        // `.separator` / `.secondaryLabel` 都是语义色，深色模式下自动换成深色面板上的那一档，不用自己判断
        footerSeparator.backgroundColor = .separator
        footerLabel.text = "powered by \(hostAppName)"
        footerLabel.font = .preferredFont(forTextStyle: .caption1)
        footerLabel.textColor = .secondaryLabel
        footerLabel.textAlignment = .center
        // App 名很长时宁可折行，也别截成省略号
        footerLabel.numberOfLines = 0

        footerView.addSubview(footerSeparator)
        footerView.addSubview(footerLabel)
        view.addSubview(footerView)

        // 细线要的是 1 个物理像素，屏幕缩放是 2x 就写 0.5、3x 就写 1/3；直接写 1 会变成一条肉眼可见的粗线
        let hairline = 1.0 / max(traitCollection.displayScale, 1)
        // 顺手记一笔读到的名字，万一署名里冒出兜底值（说明宿主 App 的 Info.plist 没读到）好定位
        log.info("署名行取到：powered by \(self.hostAppName, privacy: .public)")

        NSLayoutConstraint.activate([
            footerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            footerSeparator.topAnchor.constraint(equalTo: footerView.topAnchor),
            footerSeparator.leadingAnchor.constraint(equalTo: footerView.leadingAnchor),
            footerSeparator.trailingAnchor.constraint(equalTo: footerView.trailingAnchor),
            footerSeparator.heightAnchor.constraint(equalToConstant: hairline),

            footerLabel.topAnchor.constraint(equalTo: footerView.topAnchor, constant: 6),
            footerLabel.leadingAnchor.constraint(equalTo: footerView.leadingAnchor, constant: 12),
            footerLabel.trailingAnchor.constraint(equalTo: footerView.trailingAnchor, constant: -12),
            footerLabel.bottomAnchor.constraint(equalTo: footerView.bottomAnchor, constant: -6)
        ])
    }

    /// 署名里那个 App 名，从宿主 App 的 Info.plist 现读。
    ///
    /// ⚠️ `Bundle.main` 在扩展里指的是**扩展自己**（`MarkdownQuicklookHy4.appex`），读它只会得到「MarkdownQuicklookHy4」。
    /// 宿主 App 在 bundle 树的上层 —— Catalyst / macOS 是 `App.app/Contents/PlugIns/扩展.appex`，iOS 少一层 `Contents` —— 所以顺着路径往上找第一个 `.app`，再读它的 Info.plist。
    /// 取值顺序和系统的习惯一致：先 `CFBundleDisplayName`（桌面和程序坞上给用户看的名字），没有再退回 `CFBundleName`。
    private var hostAppName: String {
        var url = Bundle.main.bundleURL
        while url.pathExtension != "app" && url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
        }
        if url.pathExtension == "app", let host = Bundle(url: url) {
            let display = host.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            let name = host.object(forInfoDictionaryKey: "CFBundleName") as? String
            if let display, !display.isEmpty { return display }
            if let name, !name.isEmpty { return name }
        }
        // 兜底只在「扩展被单独拷出去、找不到宿主 App」这种极端情况才会走到，正常用不上
        return "MarkdownEditor"
    }

    /// 失败说明用的那行字：平时藏着，只在读文件失败时露出来。
    private func setupMessageLabel() {
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center
        messageLabel.textColor = .secondaryLabel
        messageLabel.font = .preferredFont(forTextStyle: .callout)
        messageLabel.isHidden = true
        view.addSubview(messageLabel)
        NSLayoutConstraint.activate([
            messageLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            messageLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.7)
        ])
    }

    /// 读文件失败时改画一页说明。
    private func showMessage(title: String, detail: String) {
        editor.isHidden = true
        messageLabel.text = "\(title)\n\n\(detail)"
        messageLabel.isHidden = false
    }

    // MARK: 配色

    /// 预览用哪套配色。
    ///
    /// 扩展里**拿不到用户在 App 里选的配色** —— 那是 App 自己 UserDefaults 域里的东西，扩展读不到，要共享得配 App Group。
    /// 所以这里只按系统的明暗外观挑一套内置的：浅色用编辑器的默认色，深色换成 Vue Dark。
    /// 深色下不能留着默认色不管：默认正文是深灰（0.27）、代码块底色是近白，摆在深色面板上根本看不清。
    private func makeTheme() -> MarkdownTheme {
        var theme = MarkdownTheme.default
        if traitCollection.userInterfaceStyle == .dark {
            theme.applyColorPalette(MarkdownColorTheme.vueDark.palette)
        }
        return theme
    }

    // MARK: 读文件

    /// 把文件读成字符串。
    /// **不假设它是 UTF-8** —— 中文 markdown 里 UTF-16（带 BOM）也见过。
    private func readSource(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .utf16) { return text }
        return nil
    }
}
