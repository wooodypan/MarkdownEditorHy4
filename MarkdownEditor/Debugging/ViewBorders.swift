//
//  ViewBorders.swift
//  MarkdownEditorHy4
//
//  调试用：给视图层级描一圈细边 —— 网页里那句 `*{outline:1px dashed red}` 书签的等价物
//
//  ### 为什么需要它
//  查「这个控件到底占多大、有没有伸出父视图、谁盖住了谁」的时候，光看代码和截图全靠猜。
//  网页里点一下书签，所有元素的边就都显出来了；iOS 这边没有这种**外挂式**的工具 ——
//  能改的只有自己进程里的 layer，所以这个文件就是那条书签的替身：
//  递归走一遍视图树给每个 layer 描边，再走一遍把原样还回去。
//
//  ### 三种用法（从省事到顺手）
//  1. **一行代码都不用改**：Xcode 里 ⌘< 打开 Scheme → Run → Arguments → Environment Variables，
//     加一条 `VIEW_BORDERS` = `1`，启动时自己就描上（见 `installIfRequested(in:)`）；
//  2. 代码里临时调：`ViewBorders.toggle(in: window)`；
//  3. 想要「按一下就切换」的体验：把一个菜单项 / 按钮 / 摇一摇手势接到 `toggle(in:)` 上
//     （⚠️ Mac Catalyst 上没有摇一摇，走菜单最方便）。
//
//  ### 实现上刻意选的两点
//  - **不加子视图**：加一层用来描边的子视图会改 `subviews`，进而影响布局和 `hitTest`
//    （可能把点击吃掉）。这里改的是 `layer.borderWidth` / `borderColor` —— layer 的边框
//    只影响绘制，不参与布局计算。
//  - **先存档再改**：改任何一个 layer 之前，先把它原来那套边框（宽度 + 颜色）用关联对象挂在
//    视图上，`hide()` 时逐个还回去。所以对「本来就有边框」的视图（比如面板那张卡片）也没有副作用。
//

import UIKit
import ObjectiveC

/// 描边颜色按层级轮换，一眼能看出「谁套在谁里面」。
///
/// 颜色少而分明是有意的：一屏上去几十个框，颜色太多反而看不出层次。
private let viewBorderPalette: [UIColor] = [
    .systemRed, .systemBlue, .systemGreen, .systemOrange, .systemPurple
]

/// 关联对象的键：存「视图原来那套边框」
private var viewBorderOriginalKey: UInt8 = 0

/// 视图原来那套边框的存档
private final class ViewBorderOriginal: NSObject {
    let width: CGFloat
    let color: CGColor?

    init(width: CGFloat, color: CGColor?) {
        self.width = width
        self.color = color
    }

    /// ⚠️ 这个 target 默认所有类型都是 `@MainActor`，但**隔离的 `deinit` 释放时会 free 到错误的地址**
    /// （崩在 `pointer being freed was not allocated`）。凡是不继承 `UIView` / `UIControl` /
    /// `UIViewController` 的新类，都得显式写这一句 —— 详见 skill `ios-xctest-crash-diagnosis`
    nonisolated deinit {}
}

/// 给视图层级描边 / 撤销描边
enum ViewBorders {

    /// 现在是不是描着边
    private(set) static var isVisible = false

    /// 被我们改过边框的视图
    ///
    /// 用**弱引用**表，两个作用：
    /// 1. 视图被销毁时它自己会从表里消失，`hide()` 不用去碰已经释放的对象；
    /// 2. 它是「怎么一次把改动全撤回来」的账本 —— 光靠再遍历一遍视图树是找不到那些
    ///    已经被人从树上摘下来的视图的（那种视图改了也看不见，但值得还回去）。
    private static let paintedViews = NSHashTable<UIView>.weakObjects()

    // MARK: - 描上 / 撤掉

    /// 给 `root` 和它下面所有视图描边。
    ///
    /// - parameter root: 从哪个视图开始。传 nil 表示「所有活跃窗口一起描」（多窗口、挂着弹窗时省事）
    /// - parameter lineWidth: 线宽（点）。传 0（默认）表示**1 个物理像素** —— 屏幕上最细、不挡内容
    static func show(in root: UIView? = nil, lineWidth: CGFloat = 0) {
        guard let root else {
            // 没指定就从所有窗口开始，省得调用方自己去翻 windowScene
            for window in activeWindows() {
                show(in: window, lineWidth: lineWidth)
            }
            return
        }

        // 按屏幕倍率折算：1 个物理像素 → 2x 屏上 0.5 点、3x 屏上 0.33 点。
        // 用 root 自己的 displayScale 而不是 UIScreen.main（后者在 iOS 16 之后已经废弃）
        let width = lineWidth > 0 ? lineWidth : 1 / max(1, root.traitCollection.displayScale)
        paint(root, depth: 0, lineWidth: width)
        isVisible = true
    }

    /// 把边框还回去。
    ///
    /// 还原的是**每个视图自己原来那套值**，不是统一清零 —— 面板卡片、按钮这些本来就有边框的
    /// 视图，撤销之后还是原样。
    static func hide() {
        for view in paintedViews.allObjects {
            guard let original = objc_getAssociatedObject(view, &viewBorderOriginalKey) as? ViewBorderOriginal else { continue }
            view.layer.borderWidth = original.width
            view.layer.borderColor = original.color
            objc_setAssociatedObject(view, &viewBorderOriginalKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        paintedViews.removeAllObjects()
        isVisible = false
    }

    /// 描上 / 撤掉，一键来回切。返回切换之后的状态（描着边就是 true）
    @discardableResult
    static func toggle(in root: UIView? = nil, lineWidth: CGFloat = 0) -> Bool {
        if isVisible {
            hide()
        } else {
            show(in: root, lineWidth: lineWidth)
        }
        return isVisible
    }

    // MARK: - 启动开关

    /// 启动时看一眼环境变量 `VIEW_BORDERS`，等于 `1` 就自动描上。
    ///
    /// 这是「一行代码都不用改」的那条路：开关完全落在 Xcode 的 Scheme 里。
    /// ⚠️ 环境变量是**启动时**读的，改了得重跑 App 才生效（不像网页书签那样点一下就切）。
    /// 想要即时切换，就接一个菜单项 / 按钮到 `toggle(in:)`。
    ///
    /// - parameter view: 从哪儿开始描。App 启动时传主窗口即可；不传就是所有窗口
    static func installIfRequested(in view: UIView? = nil) {
        guard ProcessInfo.processInfo.environment["VIEW_BORDERS"] == "1" else { return }
        show(in: view)
    }

    // MARK: - 内部

    /// 递归描边：一层一层往下走，每深一层换一个颜色
    private static func paint(_ view: UIView, depth: Int, lineWidth: CGFloat) {
        let layer = view.layer

        // 只在**第一次**碰到这个视图时存档。
        // 少了这个判断，第二次 show 会把「我们已经改过的值」当成原值存进去 → 永远还不回去了
        if !paintedViews.contains(view) {
            paintedViews.add(view)
            let original = ViewBorderOriginal(width: layer.borderWidth, color: layer.borderColor)
            objc_setAssociatedObject(view, &viewBorderOriginalKey, original, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }

        layer.borderWidth = lineWidth
        layer.borderColor = viewBorderPalette[depth % viewBorderPalette.count].cgColor

        for subview in view.subviews {
            paint(subview, depth: depth + 1, lineWidth: lineWidth)
        }
    }

    /// 当前所有活跃窗口（多窗口、或者有弹窗浮在外面时不止一个）
    private static func activeWindows() -> [UIWindow] {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
    }
}
