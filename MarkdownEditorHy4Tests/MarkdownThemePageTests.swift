//
//  MarkdownThemePageTests.swift
//  MarkdownEditorHy4Tests
//
//  主题页（`MarkdownThemeViewController`）的验收测试。
//
//  ### 这里守的是「用户看得见」的三件事
//  1. 内置主题有几套，列表里就该有几行 —— 以后加主题只是往枚举里加一个 case，
//     界面不许漏、也不许另写一份清单；
//  2. 点了哪一行就用哪一套，右边那个对勾跟着挪过去；
//  3. 预览只能看不能改 —— 它是给用户比对颜色的一小块，能编辑就成了第二篇文章。
//
//  ⚠️ 一律用临时目录里的假配置：**不许**碰到用户真实的那一套设置。
//

import XCTest
@testable import MarkdownEditorHy4

@MainActor
final class MarkdownThemePageTests: XCTestCase {

    // MARK: 辅助

    /// 临时目录里的一套配置 + 存放自定义 JSON 的地方，跑完整个目录删掉
    private func makeSettings() -> (settings: MarkdownEditorSettings, store: MarkdownCustomThemeStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownThemePageTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        return (MarkdownEditorSettings(fileURL: directory.appendingPathComponent("settings.json")),
                MarkdownCustomThemeStore(fileURL: directory.appendingPathComponent("theme.json")))
    }

    /// 把主题页装载起来，返回页面和它里面的表格
    private func makePage() throws -> (controller: MarkdownThemeViewController, table: UITableView) {
        let parts = makeSettings()
        let controller = MarkdownThemeViewController(settings: parts.settings, store: parts.store)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 900)
        controller.view.layoutIfNeeded()

        let table = try XCTUnwrap(tableView(in: controller.view), "页面上该有一个表格")
        return (controller, table)
    }

    /// 直接向数据源要一个 cell。
    ///
    /// ### 为什么不用 `cellForRow(at:)`
    /// 那个方法只返回**屏幕上已经排出**的 cell，行多的时候拿不到下面的，而且它的返回值取决于帧够不够高 —— 测试不是为了让页面铺得下，找数据源问最直接。
    private func cell(in table: UITableView, section: Int, row: Int) -> UITableViewCell? {
        table.dataSource?.tableView(table, cellForRowAt: IndexPath(row: row, section: section))
    }

    /// 点一行：走 `delegate` 那条路，和用户手指戳上去是同一条代码路径
    private func tapRow(_ row: Int, in table: UITableView) {
        let path = IndexPath(row: row, section: 0)
        table.delegate?.tableView?(table, didSelectRowAt: path)
    }

    private func tableView(in view: UIView) -> UITableView? {
        for subview in view.subviews {
            if let table = subview as? UITableView { return table }
            if let found = tableView(in: subview) { return found }
        }
        return nil
    }

    /// 递归找一个按钮出来（挂在 cell 的 accessoryView 上，只能从视图树里挖）
    private func button(in view: UIView, labeled label: String) -> UIButton? {
        for subview in view.subviews {
            if let button = subview as? UIButton, button.accessibilityLabel == label { return button }
            if let found = button(in: subview, labeled: label) { return found }
        }
        return nil
    }

    private func textViews(in view: UIView) -> [UITextView] {
        var result: [UITextView] = []
        for subview in view.subviews {
            if let textView = subview as? UITextView { result.append(textView) }
            result.append(contentsOf: textViews(in: subview))
        }
        return result
    }

    // MARK: 列表

    /// 内置主题有几套就该有几行，每行还得带上自己的名字
    func testThemePageListsEveryBuiltInTheme() throws {
        let (_, table) = try makePage()

        XCTAssertEqual(table.numberOfRows(inSection: 0), MarkdownColorTheme.allCases.count,
                       "内置主题有几套就该有几行 —— 加一个 case 这里必须自动跟上")
        XCTAssertEqual(table.numberOfRows(inSection: 1), 1, "「自定义配色」那一区只有一行")

        for (row, item) in MarkdownColorTheme.allCases.enumerated() {
            let cell = try XCTUnwrap(cell(in: table, section: 0, row: row), "第 \(row) 行不见了")
            XCTAssertEqual(cell.accessibilityLabel, item.displayName,
                           "第 \(row) 行该是 \(item.displayName)")
        }
    }

    // MARK: 选中

    /// 点哪一行就用哪一套，右边的对勾跟着挪过去
    func testTappingRowAppliesThemeAndMovesCheckmark() throws {
        let parts = makeSettings()
        let controller = MarkdownThemeViewController(settings: parts.settings, store: parts.store)
        controller.loadViewIfNeeded()
        let table = try XCTUnwrap(tableView(in: controller.view))

        let target = try XCTUnwrap(MarkdownColorTheme.allCases.first(where: { $0 != .default }),
                                   "得有一套非默认的主题，这条用例才有意义")
        let row = try XCTUnwrap(MarkdownColorTheme.allCases.firstIndex(of: target))

        tapRow(row, in: table)
        XCTAssertEqual(parts.settings.colorTheme, target, "点了哪一行就该用哪一套")

        // 对勾只能有一个：这一行勾上，其余都不是
        for (row, item) in MarkdownColorTheme.allCases.enumerated() {
            let cell = try XCTUnwrap(cell(in: table, section: 0, row: row))
            XCTAssertEqual(cell.accessibilityValue, item == target ? "已选中" : "未选中",
                           "\(item.displayName) 这一行的选中状态不对")
        }
    }

    // MARK: 自定义 JSON 那一行

    /// 没指定过时「清除」该是灰的 —— 点了也白点，不如干脆不让点
    func testClearButtonIsDisabledWhenNoCustomFile() throws {
        let (_, table) = try makePage()

        let cell = try XCTUnwrap(cell(in: table, section: 1, row: 0), "「自定义配色」那一区该有一行")
        XCTAssertEqual(cell.accessibilityLabel, "主题 JSON 文件")

        // ⚠️ 必须从 `accessoryView` 往下找，别在 cell 的视图树里翻：accessoryView 是等 `UITableView` 把 cell 装进自己的层级时才挂上去的，而这里直接向数据源要的 cell 没走那一步 —— 在 cell 里递归会得到「按钮不见了」这种假失败
        let accessory = try XCTUnwrap(cell.accessoryView, "这一行右边该挂着「选择 / 清除」两个按钮")
        let clear = try XCTUnwrap(button(in: accessory, labeled: "清除主题 JSON 文件"), "找不到「清除」按钮")
        XCTAssertFalse(clear.isEnabled, "本来就没指定文件，「清除」该是灰的")
    }

    // MARK: 预览

    /// 预览只许看不许动：那是给用户比对颜色的一小块，能编辑就成了第二篇文章
    func testPreviewIsReadOnly() throws {
        let (controller, _) = try makePage()

        let preview = try XCTUnwrap(textViews(in: controller.view).first, "页面上该有一块预览")
        XCTAssertFalse(preview.isEditable, "预览不许能输入")
        XCTAssertFalse(preview.isSelectable, "预览不许能被选中 —— 选中会触发那套光标逻辑，纯属添乱")
        XCTAssertFalse(preview.text?.isEmpty ?? true, "预览得真的渲染出内容，否则看不出配色")
    }
}
