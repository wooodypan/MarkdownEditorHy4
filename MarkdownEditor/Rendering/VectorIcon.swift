//
//  VectorIcon.swift
//  MarkdownEditorHy4
//
//  矢量图标工具箱：把 Sketch / PaintCode 导出的贝塞尔路径变成能直接用的图标
//
//  ### 一份绘制代码，三个出口
//  - `image(size:color:)` / `templateImage(size:)` → `UIImage`，塞进 `UIButton`、`UIImageView`
//  - `draw(in:color:)` → 画在**当前**图形上下文里，`UIView.draw(_:)` 里直接调它
//  - `VectorIconView` → 当成普通视图用（能进 `UIStackView`、跟 `tintColor` 变色）
//
//  三个出口走的是同一段绘制代码，所以「按钮上的图标」和「视图里画的图标」永远长得一样。
//
//  ### 为什么要有这个工具
//  设计稿导出的是一堆 `move(to:)` / `addCurve(...)`，坐标全按画布（比如 256×256）写死。
//  直接抄进项目有三个麻烦：换个尺寸要重新导出、颜色改不了、放进按钮还得自己包一层。
//  这里把「形状」（设计稿坐标）和「多大、什么颜色」（渲染时给）拆开 ——
//  一个图标定义一次，17 点、20 点、红色、灰色随叫随到。
//

import UIKit

/// 图标画进目标矩形的方式
enum VectorIconContentMode {
    /// 等比缩放后居中（默认）。图标**永不变形**：目标矩形比设计稿胖就左右留白
    case aspectFit
    /// 非等比拉满整个矩形。只在这张图本来就该变形时才用，图标基本用不上
    case stretch
}

/// 一个矢量图标：一段设计稿坐标下的绘制路径 + 几条绘制规则。
///
/// 定义一次，到处渲染：
/// ```swift
/// extension VectorIcon {
///     /// 五角星
///     static let star = VectorIcon(canvasSize: CGSize(width: 24, height: 24)) {
///         let path = UIBezierPath()
///         path.move(to: CGPoint(x: 12, y: 2))
///         // …照着设计稿把路径拼出来…
///         return path
///     }
/// }
///
/// // 跟着 tintColor 变色（等价于 SF Symbol 的行为）
/// button.setVectorIcon(.star, size: CGSize(width: 20, height: 20))
/// ```
///
/// ⚠️ 绘制代码里**只写设计稿坐标**。缩放和平移由本类型在渲染时统一处理，
/// 别在每个图标里自己乘系数 —— 否则以后改尺寸得挨个去翻。
struct VectorIcon {

    /// 设计稿的画布尺寸。绘制代码里的坐标就是相对它的，比如 256×256 的稿子上左上角是 (0, 0)
    let canvasSize: CGSize

    /// 图形在画布上**真正**占用的范围。
    ///
    /// 默认是整块画布。等比缩放按这个范围算，所以：几个图标摆一排如果大小看着不齐
    /// （导出稿四周留白不一样多），就把这里改成图形的实际外接矩形，它们立刻按图形本身对齐。
    let contentBounds: CGRect

    /// 填充规则，取值见 `CGPathFillRule`。
    ///
    /// **默认 `.evenOdd`**：设计稿里「空心边框」的做法通常是画一大一小两条**同方向**的闭合路径，
    /// 只有奇偶规则会把里面那条挖成透的。换成默认的 `.nonZero`，两条同向路径叠加会把
    /// 整个方块涂成实心 —— 看到一坨黑块时先回来查这里。
    let fillRule: CGPathFillRule

    /// 真正画路径的地方：**每次调用都要返回一个新的 `UIBezierPath`**。
    ///
    /// 渲染时会就地变换这个 path（`apply(_:)`），复用同一个实例会让图形越变越小。
    let makePath: () -> UIBezierPath

    /// - parameter canvasSize: 设计稿画布
    /// - parameter contentBounds: 图形在画布上占的范围，传 nil 表示「整块画布」
    /// - parameter fillRule: 填充规则，默认 `.evenOdd`（空心图形的正确选择）
    /// - parameter makePath: 拼路径的闭包，坐标写设计稿坐标
    init(canvasSize: CGSize,
         contentBounds: CGRect? = nil,
         fillRule: CGPathFillRule = .evenOdd,
         makePath: @escaping () -> UIBezierPath) {
        self.canvasSize = canvasSize
        self.contentBounds = contentBounds ?? CGRect(origin: .zero, size: canvasSize)
        self.fillRule = fillRule
        self.makePath = makePath
    }
}

// MARK: - 画

extension VectorIcon {

    /// 把图标画进**当前**图形上下文 —— `UIView.draw(_:)` 里直接调它。
    ///
    /// - parameter rect: 目标矩形（视图坐标系，通常就是 `bounds`）
    /// - parameter color: 填充色。一般传 `tintColor`，这样它能跟着控件一起变色
    /// - parameter contentMode: 怎么塞进 rect，默认等比居中
    ///
    /// 没有图形上下文时什么都不做，只留一条断言 —— 免得在视图外面调用时静默画出一片空白、
    /// 找半天找不到原因。
    func draw(in rect: CGRect, color: UIColor, contentMode: VectorIconContentMode = .aspectFit) {
        guard rect.width > 0, rect.height > 0 else { return }
        guard UIGraphicsGetCurrentContext() != nil else {
            assertionFailure("VectorIcon.draw 要在有图形上下文的地方调用（UIView.draw(_:) 或 UIGraphicsImageRenderer 的回调里）")
            return
        }

        let path = makePath()

        // 缩放系数按 contentBounds 算（不是画布）：
        // 这样「图形在稿子上留了多少白」不影响它最终显示多大
        let source = contentBounds
        let scaleX: CGFloat
        let scaleY: CGFloat
        switch contentMode {
        case .aspectFit:
            // 取小的那个方向，保证塞得进去又不变形
            let uniform = min(rect.width / source.width, rect.height / source.height)
            scaleX = uniform
            scaleY = uniform
        case .stretch:
            scaleX = rect.width / source.width
            scaleY = rect.height / source.height
        }

        // 等比模式下 rect 里会剩下一点富余，让图形落在正中间
        let drawnSize = CGSize(width: source.width * scaleX, height: source.height * scaleY)
        let origin = CGPoint(x: rect.minX + (rect.width - drawnSize.width) / 2,
                             y: rect.minY + (rect.height - drawnSize.height) / 2)

        // 想要的先后顺序是：把图形边界挪到原点 → 缩放 → 挪到目标位置。
        //
        // ⚠️ CG 的链式调用是「**后写的那一步先作用**」，所以下面三行看起来是倒着写的 ——
        // 别顺手「整理」成正序，那会把图形挪到屏幕外面去。
        var transform = CGAffineTransform(translationX: origin.x, y: origin.y)
        transform = transform.scaledBy(x: scaleX, y: scaleY)
        transform = transform.translatedBy(x: -source.minX, y: -source.minY)
        path.apply(transform)

        path.usesEvenOddFillRule = (fillRule == .evenOdd)
        color.setFill()
        path.fill()
    }
}

// MARK: - 变成 UIImage

extension VectorIcon {

    /// 生成一张固定颜色的位图。
    ///
    /// - parameter size: 图片尺寸（点）
    /// - parameter color: 填充色
    /// - parameter scale: 像素倍率。传 0（默认）表示跟着屏幕走（2x / 3x 屏自动适配，
    ///   不会糊）。要精确到像素做测试时再显式传 1 / 2 / 3
    ///
    /// 图形是矢量画的，同一张图纸给多大都清晰，不会因为尺寸变大而糊边。
    func image(size: CGSize,
               color: UIColor,
               contentMode: VectorIconContentMode = .aspectFit,
               scale: CGFloat = 0) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale > 0 ? scale : UIScreen.main.scale
        // ⚠️ 必须透明底：图标四周要是被画成白色，贴到按钮上就是一块白补丁
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size), color: color, contentMode: contentMode)
        }
    }

    /// 生成「模板图」：图上只留透明度，实际颜色交给用它的控件（跟着 `tintColor` 走）。
    ///
    /// 和 `UIImage(systemName:)` 的行为一模一样 —— 把按钮设成 `.system` 类型、或者改
    /// 图片视图的 `tintColor`，图标就跟着变色，不需要每个颜色各生成一张图。
    func templateImage(size: CGSize, contentMode: VectorIconContentMode = .aspectFit) -> UIImage {
        image(size: size, color: .black, contentMode: contentMode)
            .withRenderingMode(.alwaysTemplate)
    }
}

extension UIButton {

    /// 一步到位地把图标设成按钮的图（模板图，跟着按钮的 `tintColor` 变色）。
    ///
    /// 之所以封这一层：生成出来的图每次都要带 `.alwaysTemplate`，漏一次按钮上的图标
    /// 就会变成「黑不溜秋、点不亮」的样子，还不容易一眼看出问题出在哪。
    func setVectorIcon(_ icon: VectorIcon, size: CGSize, for state: UIControl.State = .normal) {
        setImage(icon.templateImage(size: size), for: state)
    }
}

// MARK: - 当成普通视图用

/// 把图标当成一个普通 `UIView`：能进 `UIStackView`、能用约束定位置、跟着 `tintColor` 变色。
///
/// 和 `image(size:color:)` 走的是同一段绘制代码，区别只是「谁开的画布」：
/// 这里是系统给视图开的上下文，那边是我们自己开的图片上下文。
///
/// ### 什么时候用它，而不是 `UIImageView`
/// 需要图形的**线条粗细随尺寸连续变化**时（比如动画里从 12 点长到 40 点）：
/// 位图放大会糊，这个不会 —— 每次重绘都按当前尺寸重新栅格化。
final class VectorIconView: UIView {

    /// 画哪个图标。设成 nil 就是一个透明视图
    var icon: VectorIcon? {
        didSet {
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
        }
    }

    /// 怎么塞进自己的 `bounds`，默认等比居中
    ///
    /// ⚠️ 名字带 `icon` 前缀是必须的：`UIView` 自己就有一个 `contentMode` 属性，
    /// 重名会直接编译不过。
    var iconContentMode: VectorIconContentMode = .aspectFit {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        // 图标是纯装饰，不该吃掉点击（需要点击就在外面套一个按钮）
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("VectorIconView 不支持从 coder 解档")
    }

    /// 颜色跟着 `tintColor` 走 —— 和模板图的行为一致，父视图改了 tintColor 会自动重画
    override func tintColorDidChange() {
        super.tintColorDidChange()
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let icon else { return }
        // ⚠️ 传的是 `bounds` 不是 `rect`：等比居中要相对**整个视图**算。
        // 局部重绘时 rect 只是被刷新的一小块，拿它算图形会跳位置
        icon.draw(in: bounds, color: tintColor, contentMode: iconContentMode)
    }

    /// 没人为它定尺寸时就退回设计稿尺寸，不至于缩成零
    override var intrinsicContentSize: CGSize {
        icon?.canvasSize ?? .zero
    }
}
