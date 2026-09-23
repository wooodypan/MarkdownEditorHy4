//
//  MarkdownEditorSettingsTests.swift
//  MarkdownEditorHy4Tests
//
//  设置项的验收测试：默认值、落盘、读坏了的兜底，以及「记住读到哪儿」的记录规则
//
//  所有用例都用**临时目录**里的假文件，绝不碰用户真实的 Caches 目录 ——
//  测试跑完不能把你的设置给改了。
//

import XCTest
@testable import MarkdownEditorHy4

@MainActor
final class MarkdownEditorSettingsTests: XCTestCase {

    /// 造一个临时文件地址，并登记「跑完删掉整个临时目录」
    private func makeTempFileURL(_ name: String = "settings.json") -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownEditorSettingsTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent(name)
    }

    // MARK: - 开关本身

    /// 需求明确要求这个开关默认是打开的
    func testDefaultsToRememberingScrollPosition() {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        XCTAssertTrue(settings.remembersScrollPosition, "「记住目录大纲滚动位置」默认该是开的")
    }

    /// 关掉之后要真的写进盘里，下次启动还是关着的
    func testSettingIsPersistedAndReloaded() {
        let url = makeTempFileURL()
        MarkdownEditorSettings(fileURL: url).setRemembersScrollPosition(false)

        let reloaded = MarkdownEditorSettings(fileURL: url)
        XCTAssertFalse(reloaded.remembersScrollPosition, "开关没落盘，下次启动就复位了")
    }

    /// 改值要发通知 —— 设置页拨一下，外面的大纲面板得当场跟着变，不用重启
    func testChangingSettingPostsNotification() {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        let expectation = expectation(forNotification: MarkdownEditorSettings.didChangeNotification,
                                      object: settings)

        settings.setRemembersScrollPosition(false)

        wait(for: [expectation], timeout: 1)
    }

    /// 值没变就不该重复发通知（免得无意义地刷一遍界面）
    func testSettingSameValueDoesNotPostNotification() {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        settings.setRemembersScrollPosition(false)

        let expectation = expectation(forNotification: MarkdownEditorSettings.didChangeNotification,
                                      object: settings)
        expectation.isInverted = true

        settings.setRemembersScrollPosition(false)

        wait(for: [expectation], timeout: 0.2)
    }

    // MARK: - 读不到 / 读坏了都得能用

    /// 第一次跑，配置文件还不存在
    func testMissingFileFallsBackToDefaults() {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        XCTAssertTrue(settings.remembersScrollPosition)
    }

    /// 文件被写坏了
    func testCorruptedFileFallsBackToDefaults() throws {
        let url = makeTempFileURL()
        try Data("这不是 JSON".utf8).write(to: url)

        let settings = MarkdownEditorSettings(fileURL: url)
        XCTAssertTrue(settings.remembersScrollPosition, "配置读坏了不该崩，退回默认值就行")
    }

    /// 老配置文件里没有新加的字段 → 那一项退回默认，但不能把整份配置一起作废。
    /// （这条是给以后「设置页继续加行」兜底的）
    func testFileMissingFieldFallsBackToDefault() throws {
        let url = makeTempFileURL()
        try Data("{}".utf8).write(to: url)

        XCTAssertTrue(MarkdownEditorSettings(fileURL: url).remembersScrollPosition)
    }

    /// 按需求，配置放在沙盒的 `Library/Caches` 下
    func testDefaultLocationIsInsideCaches() {
        let path = MarkdownEditorSettings.defaultFileURL.path
        XCTAssertTrue(path.contains("/Library/Caches/"), "实际落盘路径：\(path)")
        XCTAssertTrue(path.hasSuffix("settings.json"), "实际落盘路径：\(path)")
    }

    // MARK: - 「记住读到哪儿」

    /// 一份文档一个记录，互相不串
    func testScrollMemoryRemembersPerDocument() {
        let memory = DocumentScrollMemory(fileURL: makeTempFileURL("scroll.json"))
        memory.remember(sourceOffset: 1234, for: "note.md")

        XCTAssertEqual(memory.sourceOffset(for: "note.md"), 1234)
        XCTAssertNil(memory.sourceOffset(for: "other.md"), "别的文档不该读到这份记录")
    }

    /// 记录要落盘，不然下次打开回到不了原处
    func testScrollMemoryIsPersisted() {
        let url = makeTempFileURL("scroll.json")
        DocumentScrollMemory(fileURL: url).remember(sourceOffset: 4321, for: "note.md")

        XCTAssertEqual(DocumentScrollMemory(fileURL: url).sourceOffset(for: "note.md"), 4321,
                       "阅读位置没落盘，下次打开就回不到原处了")
    }

    /// 用户又滚回文档最上面 → 记录该删掉，而不是留一个「0」
    func testZeroOffsetIsTreatedAsNoMemory() {
        let memory = DocumentScrollMemory(fileURL: makeTempFileURL("scroll.json"))
        memory.remember(sourceOffset: 800, for: "note.md")
        memory.remember(sourceOffset: 0, for: "note.md")

        XCTAssertNil(memory.sourceOffset(for: "note.md"), "回到开头等于没有要恢复的位置")
    }

    /// 删一份文档的记录，不能把别人的一起删了
    func testForgetRemovesOnlyOneDocument() {
        let memory = DocumentScrollMemory(fileURL: makeTempFileURL("scroll.json"))
        memory.remember(sourceOffset: 100, for: "a.md")
        memory.remember(sourceOffset: 200, for: "b.md")

        memory.forget(key: "a.md")

        XCTAssertNil(memory.sourceOffset(for: "a.md"))
        XCTAssertEqual(memory.sourceOffset(for: "b.md"), 200)
    }

    /// 记录文件坏了 → 当作没有记录（下次打开就是文档开头），不能崩
    func testBrokenScrollMemoryFileFallsBackToEmpty() throws {
        let url = makeTempFileURL("scroll.json")
        try Data("坏掉的".utf8).write(to: url)

        XCTAssertNil(DocumentScrollMemory(fileURL: url).sourceOffset(for: "a.md"))
    }

    // MARK: - 设置页

    /// ⚠️ 下面每处都把页面铺成 420 × 2600，是**故意的**，别改小。
    /// `UITableView` 只创建**可见范围内**的 cell：帧太矮时靠下的行根本不存在，
    /// 递归找控件的辅助函数就会返回 nil，`XCTUnwrap` 报「找不到控件」——
    /// 那是测试自己没把页面铺开，不是功能坏了。设置页现在有四个分组十来行，
    /// 帧高得盖过整个内容高度，行才会全部建出来。

    /// 设置页要能建起来，开关显示的必须是配置里的真实值，拨一下要能写回去
    func testSettingsPageShowsCurrentValueAndWritesBack() throws {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        settings.setRemembersScrollPosition(false)

        let controller = SettingsViewController(settings: settings)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 2600)
        controller.view.layoutIfNeeded()

        let toggle = try XCTUnwrap(firstSwitch(in: controller.view), "设置页里应该有一个开关")
        XCTAssertFalse(toggle.isOn, "配置里是关的，开关就该显示成关的")

        // 拨一下开关：走的是 cell 上挂的 target/action，和用户手点效果一样
        toggle.isOn = true
        toggle.sendActions(for: .valueChanged)

        XCTAssertTrue(settings.remembersScrollPosition, "拨了开关却没写回配置")
    }

    /// 拨完再从盘上读一遍，确认这一下是真的落盘了（不是只改了内存）
    func testSettingsPageChangeIsPersisted() throws {
        let url = makeTempFileURL()
        let controller = SettingsViewController(settings: MarkdownEditorSettings(fileURL: url))
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 2600)
        controller.view.layoutIfNeeded()

        let toggle = try XCTUnwrap(firstSwitch(in: controller.view))
        toggle.isOn = false
        toggle.sendActions(for: .valueChanged)

        XCTAssertFalse(MarkdownEditorSettings(fileURL: url).remembersScrollPosition,
                       "设置页上拨的开关没落盘")
    }

    // MARK: - 大纲面板高度：配置本身

    /// 需求：默认按父视图高度的 70% 算上限
    func testOutlineHeightDefaults() {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        XCTAssertEqual(settings.outlineHeightMode, .percentage, "默认按百分比算")
        XCTAssertEqual(settings.outlineHeightRatio, 0.7, accuracy: 0.0001, "默认 70%")
        XCTAssertEqual(settings.outlineMaximumHeight, 360, accuracy: 0.0001)
    }

    /// 三项都要落盘，下次启动还是用户调过的那套
    func testOutlineHeightSettingsArePersisted() {
        let url = makeTempFileURL()
        let settings = MarkdownEditorSettings(fileURL: url)
        settings.setOutlineHeightMode(.maximumHeight)
        settings.setOutlineHeightRatio(0.85)
        settings.setOutlineMaximumHeight(500)

        let reloaded = MarkdownEditorSettings(fileURL: url)
        XCTAssertEqual(reloaded.outlineHeightMode, .maximumHeight)
        XCTAssertEqual(reloaded.outlineHeightRatio, 0.85, accuracy: 0.0001)
        XCTAssertEqual(reloaded.outlineMaximumHeight, 500, accuracy: 0.0001)
    }

    /// 配置文件被手改过、塞进来一个离谱的值 → 读的时候就得夹回合法范围
    func testOutlineHeightValuesAreClampedWhenLoading() throws {
        let url = makeTempFileURL()
        let json = #"{"outlineHeightRatio": 9.9, "outlineMaximumHeight": 5}"#
        try Data(json.utf8).write(to: url)

        let settings = MarkdownEditorSettings(fileURL: url)
        XCTAssertEqual(settings.outlineHeightRatio, 1.0, accuracy: 0.0001, "超过 100% 要夹回来")
        XCTAssertEqual(settings.outlineMaximumHeight, 120, accuracy: 0.0001, "低于下限要夹回来")
    }

    /// 界面之外直接调 setter 传越界值，同样要夹住
    func testOutlineHeightValuesAreClampedWhenSetting() {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        settings.setOutlineHeightRatio(0.01)
        settings.setOutlineMaximumHeight(9999)

        XCTAssertEqual(settings.outlineHeightRatio, 0.3, accuracy: 0.0001)
        XCTAssertEqual(settings.outlineMaximumHeight, 900, accuracy: 0.0001)
    }

    /// 老配置文件里没有这几个新字段 → 各自退回默认，而不是整份配置作废
    func testOutlineHeightMissingFieldsFallBackToDefaults() throws {
        let url = makeTempFileURL()
        try Data("{}".utf8).write(to: url)

        let settings = MarkdownEditorSettings(fileURL: url)
        XCTAssertEqual(settings.outlineHeightMode, .percentage)
        XCTAssertEqual(settings.outlineHeightRatio, 0.7, accuracy: 0.0001)
        XCTAssertEqual(settings.outlineMaximumHeight, 360, accuracy: 0.0001)
    }

    /// 盘上是一个「现在的版本不认识的模式名」→ 只有这一项退回默认，
    /// 别的设置照旧生效（不能因为一个字段认不出来就把整份配置丢掉）
    func testUnknownHeightModeFallsBackWithoutLosingOtherSettings() throws {
        let url = makeTempFileURL()
        let json = #"{"outlineHeightMode": "someFutureMode", "outlineHeightRatio": 0.55, "remembersScrollPosition": false}"#
        try Data(json.utf8).write(to: url)

        let settings = MarkdownEditorSettings(fileURL: url)
        XCTAssertEqual(settings.outlineHeightMode, .percentage, "认不出来的模式该退回默认")
        XCTAssertEqual(settings.outlineHeightRatio, 0.55, accuracy: 0.0001, "别的设置不该被带走")
        XCTAssertFalse(settings.remembersScrollPosition, "别的设置不该被带走")
    }

    // MARK: - 大纲面板高度：配置怎么变成面板参数

    /// 百分比模式：面板拿到「比例」；`maximumHeight` 照样写进去（切模式时还要用），
    /// 只是当前不参与计算
    func testApplyHeightInPercentageMode() {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        settings.setOutlineHeightMode(.percentage)
        settings.setOutlineHeightRatio(0.6)
        settings.setOutlineMaximumHeight(480)

        var appearance = MarkdownOutlineAppearance()
        settings.applyOutlineHeight(to: &appearance)

        XCTAssertEqual(appearance.heightRatio ?? -1, 0.6, accuracy: 0.0001)
        XCTAssertEqual(appearance.maximumHeight, 480, accuracy: 0.0001)
    }

    /// 「按最大高度」模式：比例必须是 nil —— 面板就是靠它判断「这一项不参与」
    func testApplyHeightInMaximumHeightMode() {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        settings.setOutlineHeightMode(.maximumHeight)
        settings.setOutlineMaximumHeight(420)

        var appearance = MarkdownOutlineAppearance()
        settings.applyOutlineHeight(to: &appearance)

        XCTAssertNil(appearance.heightRatio, "不是百分比模式时，比例该是 nil")
        XCTAssertEqual(appearance.maximumHeight, 420, accuracy: 0.0001)
    }

    // MARK: - 大纲面板背景：配置本身

    /// 需求：默认 `1`，也就是**完全不透明**（卡片把背后的正文完全盖住）
    func testOutlineBackgroundOpacityDefaults() {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        XCTAssertEqual(settings.outlineBackgroundOpacity, 1, accuracy: 0.0001, "默认该是完全不透明")
        XCTAssertEqual(MarkdownOutlineAppearance().backgroundOpacity, 1, accuracy: 0.0001,
                       "组件层那个默认值也该是 1 —— 配置层的默认值是从它读的")
    }

    /// 落盘：重启之后还是用户调过的那一档
    func testOutlineBackgroundOpacityIsPersisted() {
        let url = makeTempFileURL()
        MarkdownEditorSettings(fileURL: url).setOutlineBackgroundOpacity(0.4)

        let reloaded = MarkdownEditorSettings(fileURL: url)
        XCTAssertEqual(reloaded.outlineBackgroundOpacity, 0.4, accuracy: 0.0001)
    }

    /// 界面之外直接调 setter 传越界值 → 夹回 0.2 ~ 1
    func testOutlineBackgroundOpacityIsClampedWhenSetting() {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        settings.setOutlineBackgroundOpacity(0.05)
        XCTAssertEqual(settings.outlineBackgroundOpacity, 0.2, accuracy: 0.0001,
                       "比下限还小的值该夹到 0.2（再透就快看不见卡片了）")

        settings.setOutlineBackgroundOpacity(3)
        XCTAssertEqual(settings.outlineBackgroundOpacity, 1, accuracy: 0.0001, "超过 1 该夹到 1")
    }

    /// 配置文件被手改过 → 读的时候也得夹一道
    func testOutlineBackgroundOpacityIsClampedWhenLoading() throws {
        let url = makeTempFileURL()
        try Data(#"{"outlineBackgroundOpacity": 0.01}"#.utf8).write(to: url)
        XCTAssertEqual(MarkdownEditorSettings(fileURL: url).outlineBackgroundOpacity, 0.2,
                       accuracy: 0.0001)
    }

    /// 配置 → 面板参数：一个数直接搬过去（这一项没有模式之分）
    func testApplyOutlineBackgroundWritesOpacity() {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        settings.setOutlineBackgroundOpacity(0.25)

        var appearance = MarkdownOutlineAppearance()
        settings.applyOutlineBackground(to: &appearance)

        XCTAssertEqual(appearance.backgroundOpacity, 0.25, accuracy: 0.0001)
    }

    // MARK: - 设置页上的大纲控件

    /// 设置页里该有「高度怎么算」的分段控件和两个滑块；
    /// 当前模式下不生效的那一项要灰掉（光靠文字说明不够直观）
    func testSettingsPageHasHeightControlsAndDisablesInactiveOne() throws {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        settings.setOutlineHeightMode(.percentage)

        let controller = SettingsViewController(settings: settings)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 2600)
        controller.view.layoutIfNeeded()

        let control = try XCTUnwrap(segmentedControl(in: controller.view, labeled: "高度怎么算"),
                                    "设置页该有「高度怎么算」的分段控件")
        XCTAssertEqual(control.numberOfSegments, 2, "两个选项：按百分比 / 按最大高度")

        let ratioSlider = try XCTUnwrap(slider(in: controller.view, range: 0.3...1.0),
                                        "找不到「高度百分比」的滑块")
        let heightSlider = try XCTUnwrap(slider(in: controller.view, range: 120...900),
                                         "找不到「最大高度」的滑块")

        XCTAssertTrue(ratioSlider.isEnabled, "当前用百分比，它该是可调的")
        XCTAssertFalse(heightSlider.isEnabled, "当前用百分比，最大高度那一项该灰掉")
    }

    /// 切成「按最大高度」→ 写回配置，两个滑块的可用状态对调
    func testSwitchingHeightModeWritesBackAndFlipsAvailability() throws {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        settings.setOutlineHeightMode(.percentage)

        let controller = SettingsViewController(settings: settings)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 2600)
        controller.view.layoutIfNeeded()

        let control = try XCTUnwrap(segmentedControl(in: controller.view, labeled: "高度怎么算"))
        control.selectedSegmentIndex = 1
        control.sendActions(for: .valueChanged)

        XCTAssertEqual(settings.outlineHeightMode, .maximumHeight, "切了模式要写回配置")

        // 界面刷新过了，重新取一遍滑块
        controller.view.layoutIfNeeded()
        let ratioSlider = try XCTUnwrap(slider(in: controller.view, range: 0.3...1.0))
        let heightSlider = try XCTUnwrap(slider(in: controller.view, range: 120...900))
        XCTAssertFalse(ratioSlider.isEnabled, "改用最大高度后，百分比那一项该灰掉")
        XCTAssertTrue(heightSlider.isEnabled)
    }

    /// 拖滑块 → 写回配置，并且吸到步进上（免得停在 0.63 这种数上）
    func testDraggingRatioSliderWritesBackSteppedValue() throws {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        let controller = SettingsViewController(settings: settings)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 2600)
        controller.view.layoutIfNeeded()

        let ratioSlider = try XCTUnwrap(slider(in: controller.view, range: 0.3...1.0))
        ratioSlider.value = 0.63          // 故意给一个不在步进上的值
        ratioSlider.sendActions(for: .valueChanged)

        XCTAssertEqual(settings.outlineHeightRatio, 0.65, accuracy: 0.0001,
                       "0.63 该被吸到 0.65（步进 0.05）")
        XCTAssertEqual(ratioSlider.value, 0.65, accuracy: 0.0001, "滑块本身也该被拉正")
    }

    /// 「背景不透明度」这一行：有个滑块、默认停在不透明那一端、拖动写回配置并按步进吸附
    func testSettingsPageHasBackgroundOpacitySliderAndWritesBack() throws {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        let controller = SettingsViewController(settings: settings)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 2600)
        controller.view.layoutIfNeeded()

        // ⚠️ 这一行的量程（0.2~1）**上界和「高度百分比」撞了**，所以必须连下限一起当身份证（只看上界会摸到别人那一条，表现出来是「滑块拖了、配置却没变」）—— 见 `slider(in:range:)`
        let opacitySlider = try XCTUnwrap(slider(in: controller.view, range: 0.2...1.0),
                                          "设置页该有「背景不透明度」的滑块")
        XCTAssertEqual(opacitySlider.accessibilityLabel, "背景不透明度", "这一行的标识该是它自己的标题")
        XCTAssertEqual(opacitySlider.value, 1, accuracy: 0.0001, "默认该停在最右端（完全不透明）")
        XCTAssertTrue(opacitySlider.isEnabled, "这一项永远生效，不该被灰掉")

        // 拖到一个不在步进上的值，该被吸到 0.05 的倍数上
        opacitySlider.value = 0.33
        opacitySlider.sendActions(for: .valueChanged)
        XCTAssertEqual(settings.outlineBackgroundOpacity, 0.35, accuracy: 0.0001,
                       "0.33 该被吸到 0.35（步进 0.05）")
    }

    // MARK: - 表格列宽：配置本身

    /// 默认值要和渲染层 `TableStyle` 的默认值一致（64 / 280），改了一边忘了另一边就会「没动设置也变了样」
    func testTableColumnWidthDefaults() {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        XCTAssertEqual(settings.tableMinColumnWidth, 64, accuracy: 0.0001)
        XCTAssertEqual(settings.tableMaxColumnWidth, 280, accuracy: 0.0001)
    }

    /// 两个值都要落盘，下次启动还是用户调过的那套
    func testTableColumnWidthsArePersisted() {
        let url = makeTempFileURL()
        let settings = MarkdownEditorSettings(fileURL: url)
        settings.setTableMinColumnWidth(96)
        settings.setTableMaxColumnWidth(400)

        let reloaded = MarkdownEditorSettings(fileURL: url)
        XCTAssertEqual(reloaded.tableMinColumnWidth, 96, accuracy: 0.0001)
        XCTAssertEqual(reloaded.tableMaxColumnWidth, 400, accuracy: 0.0001)
    }

    /// 越界的值要被夹住（手改配置文件 / 传参越界两条路都得防）
    func testTableColumnWidthsAreClamped() throws {
        // 路径一：直接调 setter
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        settings.setTableMinColumnWidth(9999)
        settings.setTableMaxColumnWidth(1)
        XCTAssertEqual(settings.tableMinColumnWidth, 200, accuracy: 0.0001, "超出上限要夹回来")
        XCTAssertEqual(settings.tableMaxColumnWidth, 80, accuracy: 0.0001, "低于下限要夹回来")

        // 路径二：配置文件被手改
        let url = makeTempFileURL()
        try Data(#"{"tableMinColumnWidth": 5, "tableMaxColumnWidth": 9999}"#.utf8).write(to: url)
        let reloaded = MarkdownEditorSettings(fileURL: url)
        XCTAssertEqual(reloaded.tableMinColumnWidth, 32, accuracy: 0.0001)
        XCTAssertEqual(reloaded.tableMaxColumnWidth, 600, accuracy: 0.0001)
    }

    /// 「配置 → 主题」换算：正常情况直接透传；最小 > 最大时以最大值为准把最小压回去，
    /// 不然渲染层里「最小列宽」会悄悄失效
    func testApplyTableColumnWidthsGuardsMinAboveMax() {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())

        // 正常：透传
        settings.setTableMinColumnWidth(96)
        settings.setTableMaxColumnWidth(400)
        var theme = MarkdownTheme.default
        settings.applyTableColumnWidths(to: &theme)
        XCTAssertEqual(theme.table.minColumnWidth, 96, accuracy: 0.0001)
        XCTAssertEqual(theme.table.maxColumnWidth, 400, accuracy: 0.0001)

        // 交叉：最小拖得比最大还大 → 以最大为准
        settings.setTableMinColumnWidth(200)
        settings.setTableMaxColumnWidth(120)
        settings.applyTableColumnWidths(to: &theme)
        XCTAssertEqual(theme.table.minColumnWidth, 120, accuracy: 0.0001, "最小值不该大过最大值")
        XCTAssertEqual(theme.table.maxColumnWidth, 120, accuracy: 0.0001)
    }

    // MARK: - 表格列宽：设置页控件

    /// 设置页里该有「最小 / 最大列宽」两个滑块，拖动要写回配置并吸到步进上
    func testSettingsPageHasTableColumnSlidersAndWritesBack() throws {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        let controller = SettingsViewController(settings: settings)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 2600)
        controller.view.layoutIfNeeded()

        // 两个滑块用量程当身份证找（32~200 / 80~600，和别的分组都不冲突）
        let minSlider = try XCTUnwrap(slider(in: controller.view, range: 32...200),
                                      "找不到「最小列宽」的滑块")
        let maxSlider = try XCTUnwrap(slider(in: controller.view, range: 80...600),
                                      "找不到「最大列宽」的滑块")
        XCTAssertTrue(minSlider.isEnabled)
        XCTAssertTrue(maxSlider.isEnabled, "表格列宽两项永远生效，不该被灰掉")

        // 拖一下最小列宽：故意给一个不在步进上的值，该被吸到 8 的倍数上
        minSlider.value = 70
        minSlider.sendActions(for: .valueChanged)
        XCTAssertEqual(settings.tableMinColumnWidth, 72, accuracy: 0.0001, "70 应该被吸到 72（步进 8）")

        maxSlider.value = 333
        maxSlider.sendActions(for: .valueChanged)
        XCTAssertEqual(settings.tableMaxColumnWidth, 336, accuracy: 0.0001, "333 应该被吸到 336（步进 8）")
    }

    // MARK: - 图片尺寸：配置本身

    /// 需求给的默认：按百分比、50%、固定宽度 200px、最大高度 420pt
    func testImageSizeDefaults() {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        XCTAssertEqual(settings.imageWidthMode, .percentage, "默认按百分比算宽度")
        XCTAssertEqual(settings.imageWidthRatio, 0.5, accuracy: 0.0001, "默认占编辑器宽度的一半")
        XCTAssertEqual(settings.imageWidthPoints, 200, accuracy: 0.0001)
        XCTAssertEqual(settings.imageMaxHeight, 420, accuracy: 0.0001, "默认最高 420 点")
    }

    /// 四项都要落盘 —— 换台机器 / 重启之后还是用户调过的那套
    func testImageSizeSettingsArePersisted() {
        let url = makeTempFileURL()
        let settings = MarkdownEditorSettings(fileURL: url)
        settings.setImageWidthMode(.fixedPoints)
        settings.setImageWidthRatio(0.35)
        settings.setImageWidthPoints(320)
        settings.setImageMaxHeight(600)

        let reloaded = MarkdownEditorSettings(fileURL: url)
        XCTAssertEqual(reloaded.imageWidthMode, .fixedPoints)
        XCTAssertEqual(reloaded.imageWidthRatio, 0.35, accuracy: 0.0001)
        XCTAssertEqual(reloaded.imageWidthPoints, 320, accuracy: 0.0001)
        XCTAssertEqual(reloaded.imageMaxHeight, 600, accuracy: 0.0001)
    }

    /// 越界的值要被夹住（手改配置文件、传参越界两条路都防）
    func testImageSizeValuesAreClamped() throws {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        settings.setImageWidthRatio(9)
        settings.setImageWidthPoints(5)
        settings.setImageMaxHeight(10)
        XCTAssertEqual(settings.imageWidthRatio, 0.9, accuracy: 0.0001)
        XCTAssertEqual(settings.imageWidthPoints, 80, accuracy: 0.0001)
        XCTAssertEqual(settings.imageMaxHeight, 120, accuracy: 0.0001)

        let url = makeTempFileURL()
        try Data(#"{"imageWidthRatio": 0.01, "imageWidthPoints": 9999, "imageMaxHeight": 99999}"#.utf8)
            .write(to: url)
        let reloaded = MarkdownEditorSettings(fileURL: url)
        XCTAssertEqual(reloaded.imageWidthRatio, 0.2, accuracy: 0.0001)
        XCTAssertEqual(reloaded.imageWidthPoints, 800, accuracy: 0.0001)
        XCTAssertEqual(reloaded.imageMaxHeight, 1600, accuracy: 0.0001)
    }

    /// 老配置文件里没有这几个字段 → 各自退回默认，而不是整份配置作废
    func testImageSizeMissingFieldsFallBackToDefaults() throws {
        let url = makeTempFileURL()
        try Data("{}".utf8).write(to: url)

        let settings = MarkdownEditorSettings(fileURL: url)
        XCTAssertEqual(settings.imageWidthMode, .percentage)
        XCTAssertEqual(settings.imageWidthRatio, 0.5, accuracy: 0.0001)
        XCTAssertEqual(settings.imageWidthPoints, 200, accuracy: 0.0001)
        XCTAssertEqual(settings.imageMaxHeight, 420, accuracy: 0.0001)
    }

    /// 盘上是一个不认识的模式名 → 只有这一项退回默认，别的照旧
    func testUnknownImageWidthModeFallsBackWithoutLosingOtherSettings() throws {
        let url = makeTempFileURL()
        let json = #"{"imageWidthMode": "someFutureMode", "imageWidthRatio": 0.4, "remembersScrollPosition": false}"#
        try Data(json.utf8).write(to: url)

        let settings = MarkdownEditorSettings(fileURL: url)
        XCTAssertEqual(settings.imageWidthMode, .percentage)
        XCTAssertEqual(settings.imageWidthRatio, 0.4, accuracy: 0.0001, "别的设置不该被带走")
        XCTAssertFalse(settings.remembersScrollPosition)
    }

    // MARK: - 图片尺寸：配置怎么变成主题里的值

    /// 百分比模式：主题拿到比例
    func testApplyImageSizeInPercentageMode() {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        settings.setImageWidthMode(.percentage)
        settings.setImageWidthRatio(0.35)

        var theme = MarkdownTheme.default
        settings.applyImageSize(to: &theme)

        XCTAssertEqual(theme.image.maxWidthRatio ?? -1, 0.35, accuracy: 0.0001)
    }

    /// 最大高度：设置里改了多少点，主题里就是多少点
    ///
    /// 这条链路是这次还原的重点 —— 用户要在设置页能直接调这个数，
    /// 光有配置项、主题拿不到的话界面上就是「拖了没反应」。
    func testApplyImageSizeWritesMaxHeight() {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        settings.setImageMaxHeight(520)

        var theme = MarkdownTheme.default
        settings.applyImageSize(to: &theme)

        XCTAssertEqual(theme.image.maxHeight, 520, accuracy: 0.0001)
    }

    /// 固定宽度模式：比例必须是 nil —— 渲染层就是靠这个 nil 判断「改用固定点数」
    func testApplyImageSizeInFixedPointsMode() {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        settings.setImageWidthMode(.fixedPoints)
        settings.setImageWidthPoints(320)

        var theme = MarkdownTheme.default
        settings.applyImageSize(to: &theme)

        XCTAssertNil(theme.image.maxWidthRatio, "固定宽度模式下，比例该是 nil")
        XCTAssertEqual(theme.image.maxWidthPoints, 320, accuracy: 0.0001)
    }

    // MARK: - 图片尺寸：设置页控件

    /// 设置页该有「宽度怎么算」的两个选项和三根滑块；
    /// 当前模式用不上的那一根要灰掉
    ///
    /// ⚠️ 帧高给到 3600：图片尺寸是新加的分组，排在表格最下面，
    /// 帧不够高时它的 cell 根本不会被建出来，递归找控件就会返回 nil
    /// （那是测试没把页面铺开，不是功能坏了）。
    func testSettingsPageHasImageSizeControls() throws {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        settings.setImageWidthMode(.percentage)

        let controller = SettingsViewController(settings: settings)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 3600)
        controller.view.layoutIfNeeded()

        // 页面上有三个分段控件：大纲「宽度怎么算」「高度怎么算」，加上图片「宽度怎么算」。⚠️ 要拿具体哪一个必须按 `accessibilityLabel` 找 —— 视图树顺序和分组顺序**不一致**，用 `last` / `first` 是在碰运气。大纲那两个的标识特意加了「大纲」前缀，就是为了和图片这一条重名的可见标题区分开
        let controls = allSegmentedControls(in: controller.view)
        XCTAssertEqual(controls.count, 3, "该有三个分段控件，实际 \(controls.count) 个")

        let control = try XCTUnwrap(segmentedControl(in: controller.view, labeled: "宽度怎么算"),
                                    "图片这一组的「宽度怎么算」该存在")
        XCTAssertEqual(control.numberOfSegments, 2, "两个选项：按百分比 / 固定宽度")

        let ratioSlider = try XCTUnwrap(slider(in: controller.view, range: 0.2...0.9),
                                        "找不到「宽度百分比」的滑块")
        let pointsSlider = try XCTUnwrap(slider(in: controller.view, range: 80...800),
                                         "找不到「固定宽度」的滑块")
        let heightSlider = try XCTUnwrap(slider(in: controller.view, range: 120...1600),
                                         "找不到「图片最大高度」的滑块")

        XCTAssertTrue(ratioSlider.isEnabled, "当前用百分比，它该是可调的")
        XCTAssertFalse(pointsSlider.isEnabled, "当前用百分比，固定宽度那一项该灰掉")
        XCTAssertTrue(heightSlider.isEnabled, "最大高度永远生效")
    }

    /// 切成「固定宽度」→ 写回配置，两根滑块的可用状态对调，拖动也写回配置
    func testSwitchingImageWidthModeWritesBackAndFlipsAvailability() throws {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        settings.setImageWidthMode(.percentage)

        let controller = SettingsViewController(settings: settings)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 3600)
        controller.view.layoutIfNeeded()

        let control = try XCTUnwrap(segmentedControl(in: controller.view, labeled: "宽度怎么算"))
        control.selectedSegmentIndex = 1
        control.sendActions(for: .valueChanged)

        XCTAssertEqual(settings.imageWidthMode, .fixedPoints, "切了模式要写回配置")

        controller.view.layoutIfNeeded()
        let ratioSlider = try XCTUnwrap(slider(in: controller.view, range: 0.2...0.9))
        let pointsSlider = try XCTUnwrap(slider(in: controller.view, range: 80...800))
        XCTAssertFalse(ratioSlider.isEnabled, "改用固定宽度后，百分比那一项该灰掉")
        XCTAssertTrue(pointsSlider.isEnabled)

        // 拖一下固定宽度：故意给一个不在步进上的值，该被吸到 20 的倍数上
        pointsSlider.value = 333
        pointsSlider.sendActions(for: .valueChanged)
        XCTAssertEqual(settings.imageWidthPoints, 340, accuracy: 0.0001, "333 该被吸到 340（步进 20）")
    }

    /// 拖「宽度百分比」和「最大高度」→ 写回配置并按步进吸附
    func testDraggingImageSizeSlidersWritesBack() throws {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        let controller = SettingsViewController(settings: settings)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 3600)
        controller.view.layoutIfNeeded()

        let ratioSlider = try XCTUnwrap(slider(in: controller.view, range: 0.2...0.9))
        ratioSlider.value = 0.63
        ratioSlider.sendActions(for: .valueChanged)
        XCTAssertEqual(settings.imageWidthRatio, 0.65, accuracy: 0.0001, "0.63 该被吸到 0.65（步进 0.05）")

        let heightSlider = try XCTUnwrap(slider(in: controller.view, range: 120...1600))
        heightSlider.value = 513
        heightSlider.sendActions(for: .valueChanged)
        XCTAssertEqual(settings.imageMaxHeight, 520, accuracy: 0.0001, "513 该被吸到 520（步进 20）")
    }

    /// 递归找所有的分段控件（页面上有两个：大纲高度在前、图片宽度在后）
    private func allSegmentedControls(in view: UIView) -> [UISegmentedControl] {
        var result: [UISegmentedControl] = []
        for subview in view.subviews {
            if let control = subview as? UISegmentedControl { result.append(control) }
            result.append(contentsOf: allSegmentedControls(in: subview))
        }
        return result
    }

    /// 递归找一个开关出来（设置页把开关挂在 cell 上，只能从视图树里挖）
    private func firstSwitch(in view: UIView) -> UISwitch? {
        for subview in view.subviews {
            if let toggle = subview as? UISwitch { return toggle }
            if let found = firstSwitch(in: subview) { return found }
        }
        return nil
    }

    /// 按**无障碍标签**找分段控件（页面上有两个：「高度怎么算」「宽度怎么算」）。
    ///
    /// ⚠️ 不能用「第几个」来定位：`UITableView` 的 subviews 顺序不保证等于分组顺序，
    /// 实测两个分段控件在视图树里的先后是反的 —— 用 `first` / `last` 会张冠李戴，
    /// 表现出来就是「切了模式却没写回配置」这种看不懂的失败。
    /// 单元格给控件挂的 `accessibilityLabel` 是稳定标识，用它最稳。
    private func segmentedControl(in view: UIView, labeled title: String) -> UISegmentedControl? {
        allSegmentedControls(in: view).first { $0.accessibilityLabel == title }
    }

    /// 按「滑块的量程」找一个滑块出来。
    ///
    /// ### 为什么不用顺序或者 tag
    /// 顺序取决于视图树怎么排，挪一行就挂；tag 是行枚举的 rawValue，往枚举里插一个 case 就全错位。
    /// 两行的量程是定死的，拿它当身份证最稳。
    ///
    /// ### ⚠️ 上下界要**一起**看，只看上界已经不够了
    /// 「高度百分比」（0.3~1.0）和「背景不透明度」（0.2~1.0）的上界都是 1：只按上界找会摸到别人那一条，表现出来是「滑块明明拖了、配置却没变」这种看不懂的失败；所以两行的下限也必须唯一。
    private func slider(in view: UIView, range: ClosedRange<Double>) -> UISlider? {
        let lower = Float(range.lowerBound)
        let upper = Float(range.upperBound)
        for subview in view.subviews {
            if let slider = subview as? UISlider,
               slider.minimumValue == lower, slider.maximumValue == upper {
                return slider
            }
            if let found = slider(in: subview, range: range) { return found }
        }
        return nil
    }
}
