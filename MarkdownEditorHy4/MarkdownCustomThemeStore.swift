//
//  MarkdownCustomThemeStore.swift
//  MarkdownEditorHy4
//
//  用户自己的那几份主题 JSON 放在哪儿、怎么读。
//
//  ### 为什么要把文件**拷进来**而不是记一个路径
//  用户从「文件」App 里挑的那个文件在别人的沙盒里，App 只在这次会话期间有权读它；
//  下次启动再按路径去读会被系统拒掉（除非额外存一张安全作用域的书签，那套 API 很啰嗦）。
//  挑完就把内容拷进 App 自己的目录，路径永远是自己的，读的时候不用任何授权。
//
//  ### 为什么是「一份一份」而不是「只有一份」
//  导入一份主题是**多一套配色**，不是把当前这套改掉：用户手里往往攒着好几份别人发的 JSON，来回切着看才挑得出想要的。所以每份各存一个文件、各占列表一行，导入只增不覆盖。
//  当前用哪一份属于「用户的一项设置」，记在 `MarkdownEditorSettings.customThemeFileName` 里，这里只管内容本身。
//

import UIKit

/// 用户自己那几份主题 JSON 的存放处（导入进来的、以及在本机逐色调出来的，都算）。
///
/// 一份配色一个文件，名字就是列表上显示的那一行；选中的那份由 `MarkdownEditorSettings.customThemeFileName` 记着。
final class MarkdownCustomThemeStore {

    static let shared = MarkdownCustomThemeStore()

    /// 拷进来的那几份 JSON 放在这个目录里。
    ///
    /// 用 `Application Support` 而不是 `Caches`：系统磁盘紧张时会清 Caches，清掉之后用户会莫名其妙地「主题不见了」。这几份只有几 KB，不值得冒险。
    static var defaultDirectoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("MarkdownEditorHy4", isDirectory: true)
            .appendingPathComponent("Themes", isDirectory: true)
    }

    /// 用户在本机**逐色调出来**的那份叫什么（不是从外面导入的，所以没有真的文件名）。
    ///
    /// 界面上要显示「你现在用的是哪一份」，而从取色器里改出来的那份没有来源文件，就给它这一个名字 —— 和导入进来的 `xxx.json` 显示在同一处，用户分得清。
    static let inAppEditedName = "自定义配色"

    private let directoryURL: URL

    /// 测试可以传一个临时目录进来
    init(directoryURL: URL = MarkdownCustomThemeStore.defaultDirectoryURL) {
        self.directoryURL = directoryURL
    }

    /// 原因见 `MarkdownBlock` / `OutlineCoordinator` 里 `nonisolated deinit` 的长注释：
    /// app target 开了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，「不继承 UIView 的 class」不写这一行就可能踩 Swift 6.2 运行时的野指针 free。
    /// 本类只有一个 URL 成员，声明成 nonisolated 完全安全。
    nonisolated deinit {}

    // MARK: 读写

    /// 存一份配色（**同名才覆盖**；界面那边会先用 `uniquedName(_:)` 保证名字不撞车，见 `MarkdownThemeViewController`）
    func save(palette: MarkdownColorPalette, named name: String) throws {
        try save(data: palette.jsonData(), named: name)
    }

    /// 把用户挑中的那份 JSON 拷进来
    func save(data: Data, named name: String) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try data.write(to: fileURL(for: name), options: .atomic)
    }

    /// 读一份出来解析成配色表。传 `nil`（= 用户没选）就返回 `nil`。
    ///
    /// ### 读不出来会怎样
    /// 文件不存在、不是合法 JSON、字段名不对 —— 一律返回 `nil`，调用方就当「没这套」，接着用内置主题的颜色。**绝不能**因为一份坏掉的 JSON 把界面搞成一片黑或者崩溃。
    func loadPalette(named name: String?) -> MarkdownColorPalette? {
        guard let name, !name.isEmpty else { return nil }
        guard let data = try? Data(contentsOf: fileURL(for: name)) else { return nil }
        return try? JSONDecoder().decode(MarkdownColorPalette.self, from: data)
    }

    /// 删掉一份（列表上少一行），其余不受影响
    func remove(named name: String) {
        try? FileManager.default.removeItem(at: fileURL(for: name))
    }

    // MARK: 列表

    /// 现在存着哪几份（列表的行就是这个）。排序用 `localizedStandardCompare`，中文按拼音、数字按大小，看着才顺。
    func allNames() -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: directoryURL,
                                                                     includingPropertiesForKeys: nil)) ?? []
        return contents
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// 起一个不撞车的名字：已经有一份同名的就往后加「 2」「 3」…
    ///
    /// ### 为什么不能同名直接覆盖
    /// 导入是「多一套配色」，不是「改掉这一套」。用户第二次导入同名文件（比如都叫 `theme.json`），覆盖的话他前一份就凭空没了 —— 那正是这次要修掉的「导入把现有的盖掉」。
    func uniquedName(_ name: String) -> String {
        let taken = Set(allNames())
        guard taken.contains(name) else { return name }

        var suffix = 2
        while taken.contains("\(name) \(suffix)") { suffix += 1 }
        return "\(name) \(suffix)"
    }

    // MARK: 内部

    /// 名字 → 文件。名字是给用户看的，可能有斜杠之类的字符，先换成安全字符再用
    private func fileURL(for name: String) -> URL {
        let safe = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return directoryURL.appendingPathComponent("\(safe).json")
    }
}
