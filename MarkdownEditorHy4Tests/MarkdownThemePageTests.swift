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
                // 一份配色一个文件，所以给的是「装它们的那个目录」
                MarkdownCustomThemeStore(directoryURL: directory.appendingPathComponent("Themes", isDirectory: true)))
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

    /// 用**指定**的那套配置把主题页装载起来（`makePage()` 用的是临时目录里那份空配置）
    private func makePage(settings: MarkdownEditorSettings,
                          store: MarkdownCustomThemeStore) throws -> UITableView {
        let controller = MarkdownThemeViewController(settings: settings, store: store)
        controller.loadViewIfNeeded()
        // ⚠️ 必须给个 frame 并让它排一遍：只 `loadViewIfNeeded` 的话表格还没问过数据源，这时候 `numberOfRows(inSection:)` 会抛「section (1) is out of bounds」
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 900)
        controller.view.layoutIfNeeded()
        return try XCTUnwrap(tableView(in: controller.view))
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

    /// 递归找一个按钮出来（挂在 cell 的 accessoryView 上，只能从视图树里挖）。
    ///
    /// ⚠️ 先看看 `view` 自己是不是那个按钮：「导出」那一行右边挂的就是一个裸按钮，它自己就是 accessoryView。
    private func button(in view: UIView, labeled label: String) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityLabel == label { return button }
        for subview in view.subviews {
            if let button = subview as? UIButton, button.accessibilityLabel == label { return button }
            if let found = button(in: subview, labeled: label) { return found }
        }
        return nil
    }

    /// 从行右边那枚色卡里挖出第一个方块的颜色（= 编辑区底色）
    private func swatchBackground(in cell: UITableViewCell) -> UIColor? {
        guard let accessory = cell.accessoryView else { return nil }
        return stackView(in: accessory)?.arrangedSubviews.first?.backgroundColor
    }

    private func stackView(in view: UIView) -> UIStackView? {
        if let stack = view as? UIStackView { return stack }
        for subview in view.subviews {
            if let found = stackView(in: subview) { return found }
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
        XCTAssertEqual(table.numberOfRows(inSection: 1), 0, "一份都没导入过时「我的主题」那一区是空的")
        XCTAssertEqual(table.numberOfRows(inSection: 2), 1, "「自己调色」那一区只有「逐色调整」一行")
        XCTAssertEqual(table.numberOfRows(inSection: 3), 2, "「主题 JSON 文件」那一区是「导入」+「导出」两行")

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
        let table = try makePage(settings: parts.settings, store: parts.store)

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

    /// 内置主题和「我的主题」**互斥**：点内置主题要同时停用自定义配色，对勾只能落在一个地方
    ///
    /// ### 守的是哪个坑
    /// 以前点内置主题只改 `colorTheme`，`customThemeFileName` 还挂着 → 自定义配色盖在上面，内置主题换了个底色也看不出来，「我的主题」里那份还一直勾着。
    /// 用户看到的就是「三个内置主题全都点不动」。
    func testBuiltInAndCustomThemesAreMutuallyExclusive() throws {
        let parts = makeSettings()
        try parts.store.save(palette: MarkdownColorPalette(link: "#ff0000"), named: "someone.json")
        parts.settings.setCustomThemeFileName("someone.json")

        let table = try makePage(settings: parts.settings, store: parts.store)

        // 用着自定义配色时，内置主题一行都不该勾
        XCTAssertEqual(try XCTUnwrap(cell(in: table, section: 1, row: 0)).accessibilityValue, "已选中",
                       "「我的主题」里那份该是勾上的")
        for row in MarkdownColorTheme.allCases.indices {
            XCTAssertEqual(try XCTUnwrap(cell(in: table, section: 0, row: row)).accessibilityValue, "未选中",
                           "在用自定义配色时，内置主题不该带对勾 —— 两套只能选一个")
        }

        let target = try XCTUnwrap(MarkdownColorTheme.allCases.first(where: { $0 != parts.settings.colorTheme }),
                                   "得有一套跟当前不一样的，这条用例才有意义")
        let row = try XCTUnwrap(MarkdownColorTheme.allCases.firstIndex(of: target))
        table.delegate?.tableView?(table, didSelectRowAt: IndexPath(row: row, section: 0))

        XCTAssertEqual(parts.settings.colorTheme, target, "点了哪套内置主题就用哪套")
        XCTAssertNil(parts.settings.customThemeFileName, "点内置主题要同时停用自定义配色")
        XCTAssertEqual(try XCTUnwrap(cell(in: table, section: 0, row: row)).accessibilityValue, "已选中",
                       "对勾要挪到刚点的那套上")
        XCTAssertEqual(try XCTUnwrap(cell(in: table, section: 1, row: 0)).accessibilityValue, "未选中",
                       "「我的主题」里那份要把对勾摘掉")
        XCTAssertNotNil(parts.store.loadPalette(named: "someone.json"),
                        "停用只是不用它了，那份得留着 —— 要删是左滑那一行的事")
    }

    /// 内置主题那几行要画出**各自**的颜色，不许被当前那份自定义配色盖成一样
    ///
    /// ### 守的是哪个坑
    /// 以前那几行的色卡是「内置主题 + 当前自定义配色」叠出来的：一份把底色、正文、链接都写满的 JSON 会把几行盖成一模一样，用户点哪套看到的都不变 —— 表现出来还是「三个内置主题全都点不动」。
    func testBuiltInRowsShowTheirOwnColorsEvenWhenACustomThemeIsInUse() throws {
        let parts = makeSettings()
        try parts.store.save(palette: MarkdownColorPalette(editorBackground: "#123456",
                                                           text: "#654321",
                                                           link: "#ff0000"),
                             named: "someone.json")
        parts.settings.setCustomThemeFileName("someone.json")

        let table = try makePage(settings: parts.settings, store: parts.store)

        var backgrounds: [UIColor] = []
        for row in MarkdownColorTheme.allCases.indices {
            let cell = try XCTUnwrap(cell(in: table, section: 0, row: row))
            backgrounds.append(try XCTUnwrap(swatchBackground(in: cell), "第 \(row) 行右边该有一枚色卡"))
        }
        // 三套主题的底色各不相同 —— 长得一样就说明又被自定义配色盖住了
        XCTAssertEqual(Set(backgrounds).count, backgrounds.count,
                       "内置主题那几行的色卡得是各自的颜色，不许被当前那份自定义配色盖成一样")
    }

    // MARK: 自定义 JSON 那一行

    /// 没选任何一份时「取消使用」该是灰的 —— 点了也白点，不如干脆不让点
    func testClearButtonIsDisabledWhenNoCustomFile() throws {
        let (_, table) = try makePage()

        let cell = try XCTUnwrap(cell(in: table, section: 3, row: 0), "「主题 JSON 文件」那一区该有「导入」那一行")
        XCTAssertEqual(cell.accessibilityLabel, "导入主题 JSON 文件")

        // ⚠️ 必须从 `accessoryView` 往下找，别在 cell 的视图树里翻：accessoryView 是等 `UITableView` 把 cell 装进自己的层级时才挂上去的，而这里直接向数据源要的 cell 没走那一步 —— 在 cell 里递归会得到「按钮不见了」这种假失败
        let accessory = try XCTUnwrap(cell.accessoryView, "这一行右边该挂着「导入 / 取消使用」两个按钮")
        let clear = try XCTUnwrap(button(in: accessory, labeled: "取消使用自定义主题"), "找不到「取消使用」按钮")
        XCTAssertFalse(clear.isEnabled, "还没选任何一份，「取消使用」该是灰的（它只取消选用，不删文件）")
    }

    // MARK: 我的主题：一份一行

    /// 攒了几份就有几行，切过去用也不动其它那份的内容 —— 导入是「多一份」，不是「把现有的改掉」
    func testEachCustomThemeGetsItsOwnRowAndSwitchingKeepsBoth() throws {
        let parts = makeSettings()
        try parts.store.save(palette: MarkdownColorPalette(link: "#ff0000"), named: "a.json")
        try parts.store.save(palette: MarkdownColorPalette(link: "#00ff00"), named: "b.json")
        parts.settings.setCustomThemeFileName("a.json")

        let table = try makePage(settings: parts.settings, store: parts.store)

        XCTAssertEqual(table.numberOfRows(inSection: 1), 2, "存了几份，「我的主题」里就该有几行")

        // 切到第二份：第一份的内容一个字都不许动
        table.delegate?.tableView?(table, didSelectRowAt: IndexPath(row: 1, section: 1))
        XCTAssertEqual(parts.settings.customThemeFileName, "b.json", "点了哪一行就用哪一份")
        XCTAssertEqual(parts.store.loadPalette(named: "a.json")?.link?.hex, "#ff0000",
                       "换一份用，不该动到另一份的内容")

        // 对勾只能有一个
        for (row, name) in parts.store.allNames().enumerated() {
            let cell = try XCTUnwrap(cell(in: table, section: 1, row: row))
            XCTAssertEqual(cell.accessibilityValue, name == "b.json" ? "已选中" : "未选中",
                           "\(name) 这一行的选中状态不对")
        }
    }

    /// 同名再导一次要**另起一行**，绝不能把上一份盖掉 —— 盖掉就是「导入把现有的颜色冲掉了」
    func testImportingTheSameFileNameTwiceAddsAnotherRowInsteadOfOverwriting() throws {
        let parts = makeSettings()
        try parts.store.save(palette: MarkdownColorPalette(link: "#ff0000"), named: "theme.json")

        let second = parts.store.uniquedName("theme.json")
        XCTAssertEqual(second, "theme.json 2", "已经有同名的一份时，新那份要另起一个名字")
        try parts.store.save(palette: MarkdownColorPalette(link: "#00ff00"), named: second)

        XCTAssertEqual(parts.store.allNames().count, 2, "两份都在，谁也没被谁盖掉")
        XCTAssertEqual(parts.store.loadPalette(named: "theme.json")?.link?.hex, "#ff0000",
                       "先导入那份得原封不动")
    }

    /// 左滑删一份：只删那一份；删掉的正好是在用的那份时，退回「只用内置主题」
    func testDeletingOneCustomThemeKeepsTheOthers() throws {
        let parts = makeSettings()
        try parts.store.save(palette: MarkdownColorPalette(link: "#ff0000"), named: "a.json")
        try parts.store.save(palette: MarkdownColorPalette(link: "#00ff00"), named: "b.json")
        parts.settings.setCustomThemeFileName("a.json")

        let table = try makePage(settings: parts.settings, store: parts.store)

        // ⚠️ 走 `as?` 而不是 `table.delegate?.tableView?`：协议上那个同名方法有好几个重载，从 existential 上调编译器挑不出来（报 no exact matches）
        let page = try XCTUnwrap(table.delegate as? MarkdownThemeViewController, "表格的 delegate 该是主题页自己")
        page.tableView(table,
                       commit: UITableViewCell.EditingStyle.delete,
                       forRowAt: IndexPath(row: 0, section: 1))

        XCTAssertNil(parts.store.loadPalette(named: "a.json"), "删掉的那份读不到了")
        XCTAssertEqual(parts.store.loadPalette(named: "b.json")?.link?.hex, "#00ff00", "另一份不受影响")
        XCTAssertNil(parts.settings.customThemeFileName, "删掉的正好是在用的那份 → 退回只用内置主题")
    }

    // MARK: 导入 / 导出

    /// 行右边挂的东西**必须自己报尺寸**。
    ///
    /// ### 守的是哪个坑
    /// `accessoryView` 的宽度是 UIKit 按 `intrinsicContentSize` 问出来的，`UIStackView` 和普通 `UIView`
    /// 在这个位置一律答「不知道」（`(-1, -1)`）→ 被压成零宽 → 屏幕上什么都看不见，可代码里按钮明明挂着、target 也接了 —— 查起来只会越查越糊涂。所以一律走 `FixedSizeAccessoryView`。
    func testEveryAccessoryReportsItsOwnSize() throws {
        let (_, table) = try makePage()

        let paths = [IndexPath(row: 0, section: 0),   // 内置主题：色卡
                     IndexPath(row: 0, section: 3),   // 导入：两个按钮
                     IndexPath(row: 1, section: 3)]   // 导出：一个按钮
        for path in paths {
            let cell = try XCTUnwrap(cell(in: table, section: path.section, row: path.row))
            let accessory = try XCTUnwrap(cell.accessoryView, "\(path) 右边没挂东西")
            XCTAssertGreaterThan(accessory.intrinsicContentSize.width, 0,
                                 "\(path) 右边那个被问成零宽了，UIKit 会把它压没 —— 得自己报尺寸")
        }
    }

    /// 「导入」这一行**整行**都能点，不只是右边那个小按钮。
    ///
    /// ### 为什么不直接看弹没弹出面板
    /// 弹文件面板要真的挂在窗口上，单测里 `present` 会被系统静默丢掉（视图不在窗口层级里），断言 `presentedViewController` 永远是 nil —— 那是一条**永远绿**的假测试。
    /// 所以这里守两件查得到的：整行可选（点了会高亮）+ 按钮确实接了线。
    func testImportRowIsTappableAndButtonIsWired() throws {
        let (controller, table) = try makePage()

        let cell = try XCTUnwrap(cell(in: table, section: 3, row: 0), "「导入」那一行不见了")
        XCTAssertNotEqual(cell.selectionStyle, .none,
                          "「导入」这一行得能点 —— 设了 .none 点上去不高亮，用户会以为没反应")

        let accessory = try XCTUnwrap(cell.accessoryView, "这一行右边该挂着「导入 / 取消使用」两个按钮")
        let choose = try XCTUnwrap(button(in: accessory, labeled: "选择主题 JSON 文件"), "找不到「导入」按钮")
        let actions = choose.actions(forTarget: controller, forControlEvent: .touchUpInside) ?? []
        XCTAssertFalse(actions.isEmpty, "「导入」按钮得接在本页上，不然点它就是个死按钮")
    }

    /// 一个色都没改过时「导出」是灰的：导出来是一份空 JSON，等于白忙一场
    func testExportButtonIsDisabledWhenNoColorIsCustomized() throws {
        let (_, table) = try makePage()

        let cell = try XCTUnwrap(cell(in: table, section: 3, row: 1), "「主题 JSON 文件」那一区该有「导出」那一行")
        XCTAssertEqual(cell.accessibilityLabel, "导出主题 JSON 文件")

        let accessory = try XCTUnwrap(cell.accessoryView, "「导出」那一行右边该挂着一个按钮")
        let export = try XCTUnwrap(button(in: accessory, labeled: "导出主题 JSON 文件"), "找不到「导出」按钮")
        XCTAssertFalse(export.isEnabled, "什么都还没改，「导出」该是灰的")
    }

    /// 改过色（或者导入过一份）之后「导出」就该能点了
    func testExportButtonIsEnabledOnceAColorIsCustomized() throws {
        let parts = makeSettings()
        try parts.store.save(palette: MarkdownColorPalette(link: "#ff0000"), named: "someone.json")
        parts.settings.setCustomThemeFileName("someone.json")

        let table = try makePage(settings: parts.settings, store: parts.store)

        let cell = try XCTUnwrap(cell(in: table, section: 3, row: 1), "「导出」那一行不见了")
        let accessory = try XCTUnwrap(cell.accessoryView, "「导出」那一行右边该挂着一个按钮")
        let export = try XCTUnwrap(button(in: accessory, labeled: "导出主题 JSON 文件"), "找不到「导出」按钮")
        XCTAssertTrue(export.isEnabled, "已经有自定义颜色了，「导出」该能点")
    }

    /// 点「逐色调整」要能推进那一页 —— 用户改色的入口就在这一行
    func testTappingColorEditorRowPushesEditor() throws {
        let parts = makeSettings()
        let controller = MarkdownThemeViewController(settings: parts.settings, store: parts.store)
        // 主题页是被 `UINavigationController` 包着弹出来的（见 `showThemePicker`），没有它 push 不出去
        let navigation = UINavigationController(rootViewController: controller)
        navigation.loadViewIfNeeded()
        controller.loadViewIfNeeded()
        let table = try XCTUnwrap(tableView(in: controller.view))

        table.delegate?.tableView?(table, didSelectRowAt: IndexPath(row: 0, section: 2))
        // push 是走 runloop 的，等一拍再看栈顶
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(navigation.topViewController is MarkdownColorEditorViewController,
                      "点了「逐色调整」就该推进逐色调整那一页")
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
