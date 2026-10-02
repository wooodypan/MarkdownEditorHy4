//
//  MarkdownThemeFileImport.swift
//  MarkdownEditorHy4
//
//  主题 JSON 文件的「读进来」+「从 Finder 送进来」这两件事。
//
//  ### 为什么要单独收一层
//  主题文件现在有三条来的路：主题页里点「导入」挑一份、在 Finder 里双击 /「打开方式」/ 拖到 Dock 图标、以及（iPad / Mac）直接拖到主题页上。
//  三条路要做的检查一模一样：**读得到 → 是合法 JSON → 里面至少有一个色**，差别只在「文件从哪来」。
//  写成三份的话，迟早有一条忘了「一个色都没有要拒绝」那一关，用户就会遇到「导入了却没反应」。
//
//  ### 为什么「一个色都没有」要当失败
//  配色表是一张覆盖表（`MarkdownColorPalette`），字段全是可选的：随便拿一份别的 JSON（package.json 之类）
//  都能「解码成功」，只是解码出来一张空表。空表等于什么都没指定 —— 不挡住它就是「选了文件却没反应」。
//

import UIKit

/// 主题文件用不了时的几种原因。
///
/// ### 为什么要分这么细
/// 「导入失败」只有一个说法的话，用户没法自己排除：是文件被删了、是这文件压根不是主题、还是它只是恰好没有我们认得的字段？三种情况各说一句话，用户当场就知道下一步该怎么办。
enum MarkdownThemeImportError: LocalizedError {

    /// 文件读不出来（被删了、或者沙盒没给权限）
    case unreadable
    /// 读出来了，但不是一份能解的 JSON（或者结构完全对不上）
    case notValidJSON
    /// 是合法 JSON，但一个颜色字段都没匹配上
    case noColorFound

    /// 界面上那一句话
    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "这份文件读不出来（可能已经被删掉，或者没有访问它的权限）。"
        case .notValidJSON:
            return "这份文件不是一份能解析的 JSON。主题文件应该长这样：{\"link\": \"#ff0000\"}。"
        case .noColorFound:
            return "这份 JSON 里一个颜色字段都没匹配上。键名要写成配色表里的那些（比如 link、editorBackground），写完可以先用「导出」存一份对照明细。"
        }
    }
}

/// 主题文件的读取与识别
enum MarkdownThemeFileImport {

    /// 认哪些扩展名（Finder 送进来的文件先过这一关：`scene(openURLContexts:)` 什么文件都会送到）
    static let acceptedExtensions: Set<String> = ["json"]

    /// 这一份是不是主题文件
    static func isThemeFile(_ url: URL) -> Bool {
        acceptedExtensions.contains(url.pathExtension.lowercased())
    }

    /// 读出一份主题文件里的配色表。
    ///
    /// ### 为什么要自己申请「安全作用域」
    /// Finder 送进来的文件在 App 沙盒之外，不显式申请访问就读不到（沙盒没开时这个调用返回 false，直接读也没问题）。
    /// 申请了就得还，所以走 `defer` —— 借了不还系统会一直替这个文件开着口子。
    static func palette(from url: URL) throws -> MarkdownColorPalette {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw MarkdownThemeImportError.unreadable
        }

        let palette: MarkdownColorPalette
        do {
            palette = try JSONDecoder().decode(MarkdownColorPalette.self, from: data)
        } catch {
            throw MarkdownThemeImportError.notValidJSON
        }

        // 解码成功 ≠ 有内容：空表等于「一个色都没指定」，记成成功的话界面上就是「选了文件却没反应」
        guard !palette.isEmpty else { throw MarkdownThemeImportError.noColorFound }
        return palette
    }
}

// MARK: - 从 Finder 送进来的主题文件

extension Notification.Name {
    /// Finder 送进来一份主题 JSON（object 是那个文件的 URL）
    static let markdownThemeFileReceived = Notification.Name("MarkdownThemeFileReceived")
}

/// 一份「等着被主题页取走」的主题文件。
///
/// ### 为什么连结果一起存下来，而不是只存 URL
/// 冷启动时系统把文件送进来，那一刻我们**当场就读**了；等主题页被弹出来、再来读这个 URL，安全作用域可能已经过期（读出来就是 `unreadable`，而文件明明就在那儿）。
/// 所以进门就读、把结果（和文件名）一起攒着，主题页取的时候只管往界面上摆。
struct MarkdownThemeFileArrival {
    /// 文件名（界面上要显示「导入的是哪一份」）
    var fileName: String
    /// 读的结果：成功是那张配色表，失败是 `MarkdownThemeImportError`
    var result: Result<MarkdownColorPalette, Error>
}

/// Finder「打开方式」/ 双击 / 拖到 Dock 图标 进来的 .json，先落到这儿，再由主题页取走。
///
/// 套路和 `MarkdownDocumentOpener` 一模一样：冷启动时界面还没起来，先攒着；
/// 热启动直接发通知，主题页（如果开着）当场就导入。
final class MarkdownThemeOpener {

    static let shared = MarkdownThemeOpener()

    /// 攒着的那一份，被取走后清空
    private(set) var pending: MarkdownThemeFileArrival?

    private init() {}

    /// 原因见 `MarkdownBlock` / `OutlineCoordinator` 里 `nonisolated deinit` 的长注释：
    /// app target 开了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，不继承 UIView 的 class 不写这一行就可能踩 Swift 6.2 运行时的野指针 free。
    nonisolated deinit {}

    /// 收到一个文件 URL。`.json` 才收，别的（.md、.txt 之类）一律不拦 —— 它们是文档，走 `MarkdownDocumentOpener`
    func handle(url: URL) {
        guard url.isFileURL, MarkdownThemeFileImport.isThemeFile(url) else { return }

        pending = MarkdownThemeFileArrival(
            fileName: url.lastPathComponent,
            result: Result { try MarkdownThemeFileImport.palette(from: url) }
        )
        NotificationCenter.default.post(name: .markdownThemeFileReceived, object: url)
    }

    /// 主题页就绪后调用：取走攒下的那一份（取走就清空，避免下次又被导入一遍）
    func takePending() -> MarkdownThemeFileArrival? {
        defer { pending = nil }
        return pending
    }
}
