//
//  MarkdownColorEditingTests.swift
//  MarkdownEditorHy4Tests
//
//  逐色编辑（十六进制 / 取色器）和 JSON 导入导出的验收测试。
//
//  ### 这里守的是三条「错了用户一眼就能看出来」的事
//  1. 配色表里每一个色，界面上都得有一行 —— 加一个新颜色忘了补 `MarkdownPaletteColorKey`，这里立刻红；
//  2. 敲进去的十六进制要真的存下来、并落到渲染用的颜色上（不是只在格子里变了字）；
//  3. 敲错了不能把界面涂乱 —— 非法字符串一个字都不写。
//
//  ⚠️ 一律用临时目录里的假配置：**不许**碰到用户真实的那一套设置。
//

import XCTest
@testable import MarkdownEditorHy4

@MainActor
final class MarkdownColorEditingTests: XCTestCase {

    // MARK: 辅助

    /// 临时目录里的一套配置 + 存放自定义 JSON 的地方，跑完整个目录删掉
    private func makeSettings() -> (settings: MarkdownEditorSettings, store: MarkdownCustomThemeStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownColorEditingTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        return (MarkdownEditorSettings(fileURL: directory.appendingPathComponent("settings.json")),
                // 一份配色一个文件，所以给的是「装它们的那个目录」
                MarkdownCustomThemeStore(directoryURL: directory.appendingPathComponent("Themes", isDirectory: true)))
    }

    /// 把「逐色调整」那一页装载起来，返回页面和它里面的表格
    private func makeEditor(settings: MarkdownEditorSettings,
                            store: MarkdownCustomThemeStore) throws -> (controller: MarkdownColorEditorViewController, table: UITableView) {
        let controller = MarkdownColorEditorViewController(settings: settings, store: store)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 900)
        controller.view.layoutIfNeeded()

        let table = try XCTUnwrap(tableView(in: controller.view), "这一页上该有一个表格")
        return (controller, table)
    }

    private func tableView(in view: UIView) -> UITableView? {
        for subview in view.subviews {
            if let table = subview as? UITableView { return table }
            if let found = tableView(in: subview) { return found }
        }
        return nil
    }

    /// 某一个色在第几区第几行（和页面里用的是同一套分区规则）
    private func indexPath(of key: MarkdownPaletteColorKey) -> IndexPath {
        let section = MarkdownPaletteColorGroup.allCases.firstIndex(of: key.group) ?? 0
        let row = MarkdownPaletteColorKey.keys(in: key.group).firstIndex(of: key) ?? 0
        return IndexPath(row: row, section: section)
    }

    /// 直接向数据源要一个 cell（原因见 `MarkdownThemePageTests` 里那条注释：`cellForRowAt` 只给屏幕上排好的那些）
    private func cell(in table: UITableView, for key: MarkdownPaletteColorKey) -> UITableViewCell? {
        table.dataSource?.tableView(table, cellForRowAt: indexPath(of: key))
    }

    /// 从 `accessoryView` 里挖出那个十六进制输入框。
    ///
    /// ⚠️ 必须从 `cell.accessoryView` 往下找，别在 cell 自己的视图树里递归 —— accessoryView 是等 `UITableView` 把 cell 装进层级时才挂上去的。
    private func hexField(in cell: UITableViewCell) -> UITextField? {
        func find(in view: UIView) -> UITextField? {
            for subview in view.subviews {
                if let field = subview as? UITextField { return field }
                if let found = find(in: subview) { return found }
            }
            return nil
        }
        return cell.accessoryView.flatMap { find(in: $0) }
    }

    // MARK: 颜色清单

    /// 配色表里有多少个色，清单里就得有多少项 —— 加一个色忘了补 case，界面上那一行就会凭空消失
    func testEveryColorInPaletteHasAKey() {
        let fieldCount = Mirror(reflecting: MarkdownColorPalette()).children.count
        XCTAssertEqual(MarkdownPaletteColorKey.allCases.count, fieldCount,
                       "配色表有 \(fieldCount) 个字段，`MarkdownPaletteColorKey` 就得有 \(fieldCount) 个 case")

        // 每个 case 还得真的指到自己的字段上：挨个写进去再挨个读出来，读出来的值必须还在原处
        var palette = MarkdownColorPalette()
        for (offset, key) in MarkdownPaletteColorKey.allCases.enumerated() {
            palette[key] = MarkdownHexColor(String(format: "#%06x", offset + 1))
        }
        for (offset, key) in MarkdownPaletteColorKey.allCases.enumerated() {
            XCTAssertEqual(palette[key]?.hex, String(format: "#%06x", offset + 1),
                           "\(key.rawValue) 这一项没指回自己的字段")
        }
    }

    /// 套进 `MarkdownTheme` 之后，清单里的每一项都要落在自己的那个字段上（`applyColorPalette` 是遍历这份清单实现的）
    func testEveryKeyReachesItsOwnThemeField() {
        var palette = MarkdownColorPalette()
        for (offset, key) in MarkdownPaletteColorKey.allCases.enumerated() {
            // 用 8 位写法带上透明度，顺便把「透明度不能丢」也钉住
            palette[key] = MarkdownHexColor(String(format: "#%06xee", offset + 1))
        }

        var theme = MarkdownTheme.default
        theme.applyColorPalette(palette)

        for (offset, key) in MarkdownPaletteColorKey.allCases.enumerated() {
            let expected = String(format: "#%06xee", offset + 1)
            let actual = MarkdownHexColor.string(from: theme[keyPath: key.themeColorPath])
            XCTAssertEqual(actual, expected, "\(key.rawValue) 没落到它自己在 `MarkdownTheme` 上的字段")
        }
    }

    // MARK: 十六进制字符串

    /// 颜色 → 字符串 → 颜色要能原样回来，透明度也不能丢（底色那几色全靠它）
    func testHexStringRoundTripsColor() throws {
        // ⚠️ `parse` 给回来的是 `UIColor`（那一层是给渲染用的），这里要的是「字符串 → 颜色 → 字符串」这一整圈
        let solid = try XCTUnwrap(MarkdownHexColor("#42b983").color)
        XCTAssertEqual(MarkdownHexColor.string(from: solid), "#42b983", "不透明的颜色写 6 位")

        let translucent = try XCTUnwrap(MarkdownHexColor("#42b983d9").color)
        XCTAssertEqual(MarkdownHexColor.string(from: translucent), "#42b983d9", "带透明度的颜色写 8 位，透明度不能丢")

        // 取色器给回来的就是这种「不透明」的颜色，写出去不该多两位
        let white = UIColor(red: 1, green: 1, blue: 1, alpha: 1)
        XCTAssertEqual(MarkdownHexColor.string(from: white), "#ffffff")
    }

    // MARK: 导出 / 导入

    /// 导出来的 JSON 读回来还得是同一张表，而且键名就是清单里那几个（别人照着改的时候要对得上）
    func testExportedJSONComesBackAsTheSamePalette() throws {
        var palette = MarkdownColorPalette()
        palette.link = "#ff0000"
        palette.inlineCodeBackground = "#00000008"

        let data = try palette.jsonData()
        // 只写改过的那两色：这是一张覆盖表，没改的色不该出现在文件里
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"link\""), "改过的 `link` 要写进文件")
        XCTAssertFalse(text.contains("\"text\""), "没改过的色不该写进文件 —— 覆盖表只记录动过的那几色")

        let decoded = try JSONDecoder().decode(MarkdownColorPalette.self, from: data)
        XCTAssertEqual(decoded, palette, "导出来再读回来必须是同一张表")
        XCTAssertEqual(decoded.definedColorCount, 2, "导出来的这张表里就两个色")
    }

    // MARK: 主题文件的读取（面板挑的 / 从 Finder 送进来的，走的是同一段）

    /// 一份正常的主题文件要能读出里面的颜色
    func testReadingAThemeFileGivesBackItsColors() throws {
        let url = try writeThemeFile(named: "someone.json", content: ##"{"link": "#ff0000"}"##)
        let palette = try MarkdownThemeFileImport.palette(from: url)
        XCTAssertEqual(palette.link?.hex, "#ff0000", "文件里写了 `link` 就该读出来")
    }

    /// 合法 JSON 但一个色都没有（比如挑到了 package.json）要当成失败 —— 不然就是「选了文件却没反应」
    func testThemeFileWithoutAnyColorIsRejected() throws {
        let url = try writeThemeFile(named: "empty.json", content: "{}")
        XCTAssertThrowsError(try MarkdownThemeFileImport.palette(from: url)) { error in
            XCTAssertTrue(error is MarkdownThemeImportError, "该给出我们自己的那种错误，界面才说得清原因")
            XCTAssertEqual(error.localizedDescription,
                           MarkdownThemeImportError.noColorFound.errorDescription)
        }
    }

    /// 根本不是 JSON 的时候也不能崩，要给一句人话
    func testBrokenThemeFileIsRejected() throws {
        let url = try writeThemeFile(named: "broken.json", content: "{ 这不是 json")
        XCTAssertThrowsError(try MarkdownThemeFileImport.palette(from: url))
    }

    // MARK: 从 Finder 送进来的文件要分对路

    /// 双击 /「打开方式」一份 .json：该被主题那边收走，**不能**当成文档在编辑器里打开
    func testJSONFromFinderGoesToThemeInsteadOfDocument() throws {
        _ = MarkdownDocumentOpener.shared.takePendingURL()
        _ = MarkdownThemeOpener.shared.takePending()
        let url = try writeThemeFile(named: "theme.json", content: ##"{"link": "#123456"}"##)

        MarkdownDocumentOpener.shared.handle(url: url)

        XCTAssertNil(MarkdownDocumentOpener.shared.takePendingURL(),
                     ".json 不是文档：不该被当成 .md 打开（不然一按 ⌘S 就把主题文件覆盖了）")
        let arrival = try XCTUnwrap(MarkdownThemeOpener.shared.takePending(), ".json 该被主题那边收走")
        XCTAssertEqual(arrival.fileName, "theme.json")
    }

    /// .md 照旧走文档那条路，不能被上面的分流抢走
    func testMarkdownFromFinderStillOpensAsDocument() throws {
        _ = MarkdownDocumentOpener.shared.takePendingURL()
        _ = MarkdownThemeOpener.shared.takePending()
        let url = try writeThemeFile(named: "note.md", content: "# 标题")

        MarkdownDocumentOpener.shared.handle(url: url)

        XCTAssertNotNil(MarkdownDocumentOpener.shared.takePendingURL(), ".md 该照旧走文档那条路")
        XCTAssertNil(MarkdownThemeOpener.shared.takePending(), ".md 不该被主题那边拦下")
    }

    /// 往临时目录里写一份文件（导入 / 分流这两条用例都要用）
    private func writeThemeFile(named name: String, content: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownColorEditingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }

    // MARK: 逐色调整那一页

    /// 清单里有几个色，页面上就得有几行
    func testEditorPageHasOneRowPerColor() throws {
        let parts = makeSettings()
        let (_, table) = try makeEditor(settings: parts.settings, store: parts.store)

        var total = 0
        for section in 0..<table.numberOfSections {
            total += table.numberOfRows(inSection: section)
        }
        XCTAssertEqual(total, MarkdownPaletteColorKey.allCases.count,
                       "清单里有几个色，页面上就该有几行")

        // 每一行显示的是「现在真正会渲染出来的色」：默认主题下也该是个能解析的字符串，不能是空的
        let cell = try XCTUnwrap(cell(in: table, for: .link), "「链接」那一行不见了")
        XCTAssertEqual(cell.accessibilityLabel, "链接")
        let field = try XCTUnwrap(hexField(in: cell), "每一行右边该有一个能敲十六进制的格子")
        XCTAssertNotNil(MarkdownHexColor.parse(field.text ?? ""),
                        "格子里该显示当前实际的颜色，而不是空的")

        // 色块 + 输入框那个整体的宽度得自己报出来：报不出来会被 UIKit 压成零宽，屏幕上等于没这一半（见 `FixedSizeAccessoryView`）
        let accessory = try XCTUnwrap(cell.accessoryView, "每一行右边该挂着「色块 + 输入框」")
        XCTAssertGreaterThan(accessory.intrinsicContentSize.width, 0,
                             "右边那半个附件被问成零宽了，会被压没 —— 得自己报尺寸")
    }

    /// 敲一个合法的十六进制进去：要存进自定义那份 JSON，并且真的落到渲染用的颜色上
    func testTypingAValidHexStoresItAndReachesTheRenderer() throws {
        let parts = makeSettings()
        let (_, table) = try makeEditor(settings: parts.settings, store: parts.store)

        let cell = try XCTUnwrap(cell(in: table, for: .link), "「链接」那一行不见了")
        let field = try XCTUnwrap(hexField(in: cell), "「链接」那一行该有个能敲十六进制的格子")
        field.text = "#ff0000"
        field.sendActions(for: .editingDidEnd)

        // 1) 存下来了
        XCTAssertEqual(parts.store.loadPalette(named: parts.settings.customThemeFileName)?.link?.hex, "#ff0000",
                       "敲进去的颜色要写进自定义那份 JSON")
        // 2) 记着「用户有自定义配色」，不然渲染时压根不会去看这份表
        XCTAssertNotNil(parts.settings.customThemeFileName, "改过色之后要记上「有自定义配色」")
        // 3) 真的落到渲染用的主题上（只改了格子里的字不算数）
        var theme = MarkdownTheme.default
        parts.settings.applyColors(to: &theme, customPalette: parts.store.loadPalette(named: parts.settings.customThemeFileName))
        XCTAssertEqual(MarkdownHexColor.string(from: theme.linkColor), "#ff0000",
                       "改完的颜色要出现在渲染用的 `MarkdownTheme` 里")
    }

    /// 敲一个不合法的十六进制：一个字都不该写进去 —— 最坏的结果不是「没生效」，而是把界面涂成一片黑
    func testTypingAnInvalidHexChangesNothing() throws {
        let parts = makeSettings()
        try parts.store.save(palette: MarkdownColorPalette(link: "#ff0000"), named: "someone.json")
        parts.settings.setCustomThemeFileName("someone.json")

        let (_, table) = try makeEditor(settings: parts.settings, store: parts.store)
        let cell = try XCTUnwrap(cell(in: table, for: .link), "「链接」那一行不见了")
        let field = try XCTUnwrap(hexField(in: cell), "「链接」那一行该有个能敲十六进制的格子")

        field.text = "不是颜色"
        field.sendActions(for: .editingDidEnd)

        XCTAssertEqual(parts.store.loadPalette(named: "someone.json")?.link?.hex, "#ff0000",
                       "敲错了不该改动已经存好的颜色")
    }
}
