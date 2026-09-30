//
//  MarkdownCustomThemeStore.swift
//  MarkdownEditorHy4
//
//  用户自己指定的那份主题 JSON 放在哪儿、怎么读。
//
//  ### 为什么要把文件**拷进来**而不是记一个路径
//  用户从「文件」App 里挑的那个文件在别人的沙盒里，App 只在这次会话期间有权读它；
//  下次启动再按路径去读会被系统拒掉（除非额外存一张安全作用域的书签，那套 API 很啰嗦）。
//  挑完就把内容拷进 App 自己的目录，路径永远是自己的，读的时候不用任何授权。
//
//  ### 文件名记在别处
//  界面上要显示「你现在用的是哪份文件」，而文件名属于**用户的一项设置**，
//  所以记在 `MarkdownEditorSettings.customThemeFileName` 里，这里只管内容本身。
//

import UIKit

/// 用户指定的主题 JSON 的存放处。
///
/// 整个 App 只有一份可选的自定义配色：有就用它（叠加在内置主题之上），没有就用内置主题的色。
final class MarkdownCustomThemeStore {

    static let shared = MarkdownCustomThemeStore()

    /// 拷进来的那份 JSON 放在这儿。
    ///
    /// 用 `Application Support` 而不是 `Caches`：系统磁盘紧张时会清 Caches，
    /// 清掉之后用户会莫名其妙地「自定义主题不见了」。这一份只有几 KB，不值得冒险。
    static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("MarkdownEditorHy4", isDirectory: true)
            .appendingPathComponent("theme.json")
    }

    private let fileURL: URL

    /// 测试可以传一个临时目录里的地址进来
    init(fileURL: URL = MarkdownCustomThemeStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    /// 原因见 `MarkdownBlock` / `OutlineCoordinator` 里 `nonisolated deinit` 的长注释：
    /// app target 开了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，
    /// 「不继承 UIView 的 class」不写这一行就可能踩 Swift 6.2 运行时的野指针 free。
    /// 本类只有一个 URL 成员，声明成 nonisolated 完全安全。
    nonisolated deinit {}

    /// 把用户挑的那份 JSON 拷进来（同名覆盖，一个 App 只留一份）
    func save(data: Data) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    /// 删掉自定义的那份，之后一律用内置主题的色
    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// 读出来解析成配色表。
    ///
    /// ### 读不出来会怎样
    /// 文件不存在、不是合法 JSON、字段名不对 —— 一律返回 `nil`，调用方就当「用户没指定」，
    /// 接着用内置主题的颜色。**绝不能**因为一份坏掉的 JSON 把界面搞成一片黑或者崩溃。
    func loadPalette() -> MarkdownColorPalette? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(MarkdownColorPalette.self, from: data)
    }
}
