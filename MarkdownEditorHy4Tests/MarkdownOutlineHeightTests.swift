//
//  MarkdownOutlineHeightTests.swift
//  MarkdownEditorHy4Tests
//
//  大纲面板高度的验收测试。
//
//  要锁住的是四条规则：
//  1. 默认按「父视图高度的 70%」算上限；
//  2. 这个 70% 是**上限**不是固定高度 —— 标题少时面板贴着内容变矮；
//  3. 百分比模式下「最大高度」完全不参与计算（用户调它不该有任何变化）；
//  4. 父视图尺寸变了（转屏、拉窗口）面板跟着重算。
//
//  外加一条「启动时面板是收起的」—— 需求要的是冷启动只显示那个展开小方块。
//

import XCTest
@testable import MarkdownEditorHy4

@MainActor
final class MarkdownOutlineHeightTests: XCTestCase {

    /// 宿主窗口的默认高度。取 800 是为了让 70% 算出来是个整数（560），
    /// 断言里一眼能看出对不对
    private let defaultParentHeight: CGFloat = 800

    // MARK: - 测试数据

    /// 造 `count` 个 H1（没有子标题）：一行的 30 点，直接决定内容有多高
    private func makeItems(_ count: Int) -> [OutlineItem] {
        (1...count).map { index in
            OutlineItem(id: UUID(), level: 1, title: "第 \(index) 节", sourceOffset: index * 100)
        }
    }

    /// 造一个挂到真实窗口上的目录面板（和 App 里一样只给它定位、不给尺寸）
    private func makeOutlineView(parentHeight: CGFloat? = nil) -> (view: MarkdownOutlineView, host: UIWindow) {
        let height = parentHeight ?? defaultParentHeight
        let host = UIWindow(frame: CGRect(x: 0, y: 0, width: 700, height: height))
        let view = MarkdownOutlineView()
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor)
        ])
        host.makeKeyAndVisible()
        host.layoutIfNeeded()
        return (view, host)
    }

    // MARK: - 默认规则

    /// 需求：默认按父视图高度的 70% 当上限。
    /// 40 个标题的内容高度是 40*30+8 = 1208，远超上限，所以面板停在 560 上
    func testDefaultHeightCapIsSeventyPercentOfParent() throws {
        let (view, host) = makeOutlineView()
        let ratio = try XCTUnwrap(view.appearance.heightRatio, "默认该按百分比算")
        XCTAssertEqual(ratio, 0.7, accuracy: 0.0001, "默认该是父视图高度的 70%")

        view.updateOutlineItems(makeItems(40))
        host.layoutIfNeeded()

        XCTAssertEqual(view.panelHeight, 560, accuracy: 0.5,
                       "父视图 800 高的 70% = 560，面板高度该停在这儿")
    }

    /// 70% 是**上限**：标题少的时候面板贴着内容，不该硬撑到 560 那么高
    func testShortOutlineStaysShorterThanCap() {
        let (view, host) = makeOutlineView()
        view.updateOutlineItems(makeItems(3))
        host.layoutIfNeeded()

        // 3 行 = 3*30 + 上下留白 8 = 98，再加标题栏 36
        XCTAssertEqual(view.panelHeight, 134, accuracy: 0.5,
                       "只有 3 个标题时面板该贴着内容（标题栏 36 + 内容 98），而不是撑满上限")
    }

    // MARK: - 两种模式互斥

    /// 需求：用了百分比，`maximumHeight` 就失效。
    ///
    /// 这里故意把 `maximumHeight` 设成一个很小的值（100）：只要它还参与计算，
    /// 面板高度就会变成 136（标题栏 36 + 100），一眼能看出有没有失效
    func testMaximumHeightIsIgnoredInPercentageMode() {
        let (view, host) = makeOutlineView()
        view.appearance.maximumHeight = 100
        view.appearance.heightRatio = 0.7

        view.updateOutlineItems(makeItems(40))
        host.layoutIfNeeded()

        XCTAssertEqual(view.panelHeight, 560, accuracy: 0.5,
                       "选了百分比之后 maximumHeight 该完全不参与，面板不该被压到 136")
    }

    /// 反过来：`heightRatio` 是 nil 时改由 `maximumHeight` 说了算
    func testMaximumHeightModeUsesFixedValue() {
        let (view, host) = makeOutlineView()
        view.appearance.heightRatio = nil
        view.appearance.maximumHeight = 300

        view.updateOutlineItems(makeItems(40))
        host.layoutIfNeeded()

        XCTAssertEqual(view.panelHeight, 300, accuracy: 0.5,
                       "heightRatio 为 nil 时该按 maximumHeight 封顶")
    }

    /// 「按最大高度」模式下，固定值仍然压不过父视图那道保护
    /// （不然小屏手机上目录会一路顶到底，甚至伸出屏幕）
    func testMaximumHeightModeStillCappedByParent() {
        let (view, host) = makeOutlineView(parentHeight: 500)
        view.appearance.heightRatio = nil
        view.appearance.maximumHeight = 900    // 故意超过父视图

        view.updateOutlineItems(makeItems(40))
        host.layoutIfNeeded()

        XCTAssertLessThanOrEqual(view.panelHeight, 500,
                                 "固定值再大也不能让面板高过父视图")
        XCTAssertEqual(view.panelHeight, 310, accuracy: 0.5, "500 的 62% = 310")
    }

    // MARK: - 改设置 / 改窗口要立刻生效

    /// 把比例调小，面板当场变矮（设置页拖滑块就是这个路径）
    func testChangingRatioResizesPanelImmediately() {
        let (view, host) = makeOutlineView()
        view.updateOutlineItems(makeItems(40))
        host.layoutIfNeeded()
        XCTAssertEqual(view.panelHeight, 560, accuracy: 0.5, "测试前提：先是 70%")

        view.appearance.heightRatio = 0.5
        view.refreshAppearance()
        host.layoutIfNeeded()

        XCTAssertEqual(view.panelHeight, 400, accuracy: 0.5,
                       "改成 50% 之后该是 800*0.5 = 400")
    }

    /// 窗口变矮（转屏 / 拉窗口）→ 面板跟着重算
    func testPanelFollowsParentResize() {
        let (view, host) = makeOutlineView()
        view.updateOutlineItems(makeItems(40))
        host.layoutIfNeeded()
        XCTAssertEqual(view.panelHeight, 560, accuracy: 0.5, "测试前提：先是 560")

        host.frame = CGRect(x: 0, y: 0, width: 700, height: 400)
        // 尺寸变了要显式让它排一次版，模拟真实的一次布局
        view.setNeedsLayout()
        host.layoutIfNeeded()

        XCTAssertEqual(view.panelHeight, 280, accuracy: 0.5,
                       "父视图矮了一半，面板该跟着矮到 400*0.7 = 280")
    }

    // MARK: - 收起态

    /// 收起态只有标题栏那么高（那个小方块），跟内容多少无关
    func testCollapsedPanelIsHeaderHeightOnly() {
        let (view, host) = makeOutlineView()
        view.updateOutlineItems(makeItems(40))
        host.layoutIfNeeded()

        view.setCollapsed(true, animated: false)
        host.layoutIfNeeded()

        XCTAssertTrue(view.isCollapsed)
        XCTAssertEqual(view.panelHeight, view.appearance.headerHeight, accuracy: 0.5,
                       "收起后只剩标题栏那么高")
    }

    // MARK: - 启动时的默认状态

    /// 需求：默认不展开，只显示那个展开小方块。
    ///
    /// 这条断言的是**主控制器装配后的真实状态** —— 面板自己没法知道「启动时该不该
    /// 展开」，那是 `ViewController.setupOutline` 里定的
    func testEditorScreenStartsWithCollapsedOutline() throws {
        let controller = ViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 700, height: 900)
        controller.view.layoutIfNeeded()

        let outline = try XCTUnwrap(firstOutlineView(in: controller.view),
                                    "主界面上该有一个大纲面板")
        XCTAssertTrue(outline.isCollapsed, "冷启动时大纲该是收起的")

        let expand = try XCTUnwrap(visibleExpandButton(in: outline),
                                   "收起态必须看得见展开按钮，否则没有入口把大纲打开")
        XCTAssertFalse(expand.isHidden)
    }

    /// 面板拿到的初始高度配置，要和当前设置一致
    /// （不能出现「设置里选了按最大高度，启动后却按百分比算」这种脱节）
    func testOutlineAppearanceMatchesCurrentSettings() throws {
        let controller = ViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 700, height: 900)
        controller.view.layoutIfNeeded()

        let outline = try XCTUnwrap(firstOutlineView(in: controller.view))
        switch MarkdownEditorSettings.shared.outlineHeightMode {
        case .percentage:
            XCTAssertNotNil(outline.appearance.heightRatio, "百分比模式下该有比例")
        case .maximumHeight:
            XCTAssertNil(outline.appearance.heightRatio, "按最大高度模式下比例该是 nil")
        }
    }

    // MARK: - 小工具

    private func firstOutlineView(in view: UIView) -> MarkdownOutlineView? {
        for subview in view.subviews {
            if let outline = subview as? MarkdownOutlineView { return outline }
            if let found = firstOutlineView(in: subview) { return found }
        }
        return nil
    }

    /// 收起态那个展开按钮。它没有对外属性，靠无障碍标签认出来
    private func visibleExpandButton(in view: UIView) -> UIButton? {
        for subview in view.subviews {
            if let button = subview as? UIButton, button.accessibilityLabel == "展开大纲" {
                return button
            }
            if let found = visibleExpandButton(in: subview) { return found }
        }
        return nil
    }
}
