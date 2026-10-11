//
//  RulerOverlayView.swift
//  MarkdownEditorHy4
//
//  调试用：给编辑器内部的上边和左侧铺一层半透明标尺（类似 Chrome DevTools 的那个）
//
//  ### 怎么打开
//  Debug 版本里打开文档 → 右上角「⋯」→「显示标尺」。代码里也可以直接 `textView.installRuler()`。
//
//  ### 刻度读的是什么坐标
//  读的是**文档坐标**（content 坐标系，y = 0 就是正文最顶上、跟当前滚到哪儿无关），和代码里打印的 `codeBlockFrames` / 折叠锚点那些矩形用的是同一套数 —— 想核对「灰底是不是画在 ```swift 那一行上」时，把标尺读数拿去和日志里的数字直接比就行（不用自己再加滚动偏移）。
//

import UIKit
import ObjectiveC

/// 上边量 x、左侧量 y 的半透明标尺。
///
/// ### 它为什么不会跟着内容滚走
/// 目标（`MarkdownTextView`）本身是个 UIScrollView，直接加进去的子视图会跟着内容一起滚。这里用编辑器里其它浮层（代码块背景、引用竖条）同一套办法：**把本视图的 `frame` 永远设成目标的 `bounds`**。`bounds.origin` 就是滚动偏移，所以 `frame.origin` 跟着滚动偏移走之后，本视图在屏幕上正好停在原地；再把同一个偏移喂给 `contentOffset`，画刻度时减掉它，刻度就变成「印在文档上」的了。
final class RulerOverlayView: UIView {

    // MARK: - 可调参数

    /// 上边那条和左边那条各自的厚度（pt）
    var rulerThickness: CGFloat = 24
    /// 最小刻度线的长度
    var minorTickLength: CGFloat = 4
    /// 中等刻度线的长度（每 5 根最小刻度一根）
    var midTickLength: CGFloat = 7
    /// 大刻度线的长度（每 10 根最小刻度一根，并且标数字）
    var majorTickLength: CGFloat = 12
    /// 相邻两根最小刻度之间差多少点（10 → 每 100pt 标一个数字）
    var unit: CGFloat = 10
    /// 刻度线的线宽（pt）。
    ///
    /// ⚠️ 这一条独立于上面那条分界线是**必须的**：分界线用的是「1 个物理像素」（3x 屏上只有 0.33pt），而这个线宽会一直生效到下次设置为止 —— 不单独给刻度线设一次的话，刻度线也会被画成一根几乎看不见的头发丝。实测：1x 位图上抗锯齿之后只剩三分之一的墨，肉眼在 Retina 屏上基本看不到刻度。
    var tickLineWidth: CGFloat = 1
    /// 底色条的不透明度（太透就压不住底下的文字，刻度看不清）
    var backgroundAlpha: CGFloat = 0.5
    /// 刻度线的颜色
    var tickColor: UIColor = UIColor.white.withAlphaComponent(0.85)
    /// 数字的颜色
    var textColor: UIColor = UIColor.white.withAlphaComponent(0.95)
    /// 数字用的字体。刻意用等宽数字：滚动时数字宽度不变，读数不会左右抖
    var font: UIFont = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)

    /// 目标视图当前的滚动偏移，由外面在滚动时同步进来。
    ///
    /// 画刻度时要把它减掉：减掉之后，同一根刻度线会随着滚动往屏幕上方挪，看上去就像刻度钉在文档上，而不是浮在屏幕上。
    var contentOffset: CGPoint = .zero {
        didSet {
            // 偏移一变，所有刻度线都要换个位置画，所以整块重绘
            if contentOffset != oldValue { setNeedsDisplay() }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        // 半透明的视图不能对外声称「我是不透明的」，否则系统会按不透明的方式合成，边上会出现黑块
        isOpaque = false
        backgroundColor = .clear
        // 只负责画，不接收触摸 —— 否则它会挡住底下的光标定位、折叠三角和表格的横向滑动
        isUserInteractionEnabled = false
        // 尺寸没变、只是内容要重画时，让系统老老实实走一遍 draw(_:)，而不是拿旧位图凑合
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("RulerOverlayView 不支持从 coder 解档") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        let width = bounds.width
        let height = bounds.height
        let thickness = rulerThickness

        // 尺寸还没定下来（刚 addSubview、还没轮到布局）、或者参数被人配成了 0 时什么都不画，免得画出奇怪的东西或转死循环
        guard width > thickness, height > thickness, unit > 0 else { return }

        // 1) 两条半透明底色：上边横着一条、左边竖着一条。
        //    左上角那个小方块归「上边那条」管，所以左边这条从 y = thickness 才开始
        ctx.setFillColor(UIColor.black.withAlphaComponent(backgroundAlpha).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: thickness))
        ctx.fill(CGRect(x: 0, y: thickness, width: thickness, height: height - thickness))

        // 2) 底色条和正文之间那条分界线。用 1 个物理像素，屏幕上最细，不挡内容
        ctx.setStrokeColor(tickColor.cgColor)
        ctx.setLineWidth(1 / max(1, traitCollection.displayScale))
        ctx.move(to: CGPoint(x: 0, y: thickness))
        ctx.addLine(to: CGPoint(x: width, y: thickness))
        ctx.move(to: CGPoint(x: thickness, y: 0))
        ctx.addLine(to: CGPoint(x: thickness, y: height))
        ctx.strokePath()

        // ⚠️ 刻度线要**重新设一次线宽**：上面那条分界线的「1 个物理像素」会一直生效到下次设置为止，不重置的话刻度线会跟着变成头发丝（理由见 `tickLineWidth` 的注释）
        ctx.setLineWidth(tickLineWidth)

        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]

        // 3) 上边那条：量横向的 x
        drawHorizontalTicks(in: ctx, width: width, attributes: attributes)
        // 4) 左边那条：量纵向的 y
        drawVerticalTicks(in: ctx, height: height, attributes: attributes)
    }

    // MARK: - 两条刻度

    /// 画上边那条的横向刻度，读数是**文档坐标下的 x**。
    private func drawHorizontalTicks(in ctx: CGContext, width: CGFloat, attributes: [NSAttributedString.Key: Any]) {
        let thickness = rulerThickness

        // 只在上边这条带子里画，越界的刻度线会被这一步裁掉，不用自己判断
        ctx.saveGState()
        ctx.clip(to: CGRect(x: thickness, y: 0, width: width - thickness, height: thickness))

        // 从「屏幕左边第一根落在带子里的刻度」开始画。用 floor 是为了滚动偏移带小数时也从一个整数刻度起算
        var index = Int(floor(contentOffset.x / unit))
        while true {
            let value = CGFloat(index) * unit
            // 文档坐标 → 本视图坐标：减掉滚动偏移（理由见 `contentOffset` 的注释）
            let x = value - contentOffset.x
            if x > width { break }

            // 左上角那个方块留给竖尺，所以还没越过 thickness 的刻度直接跳过
            if x >= thickness {
                let length = tickLength(for: index)
                ctx.move(to: CGPoint(x: x, y: thickness))
                ctx.addLine(to: CGPoint(x: x, y: thickness - length))
                // 每 10 根标一次数字（也就是每 100pt 一个）
                if index % 10 == 0 {
                    ("\(Int(value))" as NSString).draw(at: CGPoint(x: x + 2, y: 1), withAttributes: attributes)
                }
            }
            index += 1
        }

        // 上面只攒了路径、没真的画，这里一次性描出来
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// 画左边那条的纵向刻度，读数是**文档坐标下的 y**。
    private func drawVerticalTicks(in ctx: CGContext, height: CGFloat, attributes: [NSAttributedString.Key: Any]) {
        let thickness = rulerThickness

        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: thickness, width: thickness, height: height - thickness))

        var index = Int(floor(contentOffset.y / unit))
        while true {
            let value = CGFloat(index) * unit
            let y = value - contentOffset.y
            if y > height { break }

            if y >= thickness {
                let length = tickLength(for: index)
                ctx.move(to: CGPoint(x: thickness, y: y))
                ctx.addLine(to: CGPoint(x: thickness - length, y: y))
                if index % 10 == 0 {
                    drawRotatedNumber("\(Int(value))", at: y, in: ctx, attributes: attributes)
                }
            }
            index += 1
        }

        ctx.strokePath()
        ctx.restoreGState()
    }

    /// 竖着写一个数字，摆在左尺上 `y` 那个刻度旁边。
    ///
    /// ### 为什么锚点要摆在 `thickness - 3` 而不是靠左边
    /// 先 `translate` 再 `rotate(π/2)`，是「文字往下排」的写法；转完之后**文字的宽度占了纵向、高度占了横向，而且是往锚点的左边长**。所以锚点的 x 必须靠近带子的右边缘，让文字正好落在这条带子里 —— 把锚点挪到左边的话，字会整块长到带子外面被裁掉（一个字都看不见）。
    private func drawRotatedNumber(_ text: String, at y: CGFloat, in ctx: CGContext, attributes: [NSAttributedString.Key: Any]) {
        ctx.saveGState()
        ctx.translateBy(x: rulerThickness - 3, y: y + 2)
        ctx.rotate(by: .pi / 2)
        (text as NSString).draw(at: .zero, withAttributes: attributes)
        ctx.restoreGState()
    }

    /// 第 `index` 根刻度线该多长：每 10 根最长、每 5 根中等、其余最短。
    private func tickLength(for index: Int) -> CGFloat {
        if index % 10 == 0 { return majorTickLength }
        if index % 5 == 0 { return midTickLength }
        return minorTickLength
    }
}

// MARK: - MarkdownTextView 集成

/// 关联对象的键：标尺本体
private var rulerViewKey: UInt8 = 0
/// 关联对象的键：那两条 KVO 观察（滚动 / 尺寸）
private var rulerObservationsKey: UInt8 = 0

extension MarkdownTextView {

    /// 现在是不是挂着标尺
    var isRulerVisible: Bool { rulerOverlay != nil }

    /// 挂上 / 摘掉标尺。返回**切换之后**的状态：true = 现在挂着。
    ///
    /// 用法和 `installLineFragmentDebugOverlay()` 一样，连着调两次就一来一回。
    @discardableResult
    func installRuler() -> Bool {
        // 已经挂着 → 这一趟是「摘掉」
        if let existing = rulerOverlay {
            existing.removeFromSuperview()
            rulerOverlay = nil
            // 观察者要主动作废，否则它会一直活着（并且一直把 textView 拽住不放）
            rulerObservations?.forEach { $0.invalidate() }
            rulerObservations = nil
            return false
        }

        let ruler = RulerOverlayView(frame: bounds)
        ruler.isUserInteractionEnabled = false
        // 加到最上层：它是用来「量屏幕」的，被别人盖住就没意义了
        addSubview(ruler)
        rulerOverlay = ruler
        syncRulerToViewport()

        // 滚动和尺寸变化都要跟一下。
        // `contentOffset` 那条是编辑器里其它浮层一直在用的老路子（实测可靠）；`bounds` 那条补的是「转屏 / Catalyst 拉窗口」那种情况 —— 那时候偏移没变，光靠上一条不会触发。
        rulerObservations = [
            observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                self?.syncRulerToViewport()
            },
            observe(\.bounds, options: [.new]) { [weak self] _, _ in
                self?.syncRulerToViewport()
            }
        ]
        return true
    }

    private var rulerOverlay: RulerOverlayView? {
        get { objc_getAssociatedObject(self, &rulerViewKey) as? RulerOverlayView }
        set { objc_setAssociatedObject(self, &rulerViewKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private var rulerObservations: [NSKeyValueObservation]? {
        get { objc_getAssociatedObject(self, &rulerObservationsKey) as? [NSKeyValueObservation] }
        set { objc_setAssociatedObject(self, &rulerObservationsKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// 把标尺「钉」回可视区域的左上角，并告诉它当前滚到哪儿了。
    ///
    /// ### 为什么 frame 要给 `origin: contentOffset` 而不是单纯一个 size
    /// 目标是 UIScrollView，它的 `bounds.origin` 就是滚动偏移。把 `frame.origin` 也设成滚动偏移，标尺在屏幕上就停在原地不动；至于「刻度怎么跟着内容走」，交给 `contentOffset` 在绘制时处理。
    ///
    /// ### 为什么每一步都要判等
    /// 这个方法挂在滚动回调上，滚起来每帧都会跑。不判等的话每帧都要设一次 frame（顺带把父视图标成「要重新布局」），长文档滚久了容易和布局互相追着跑。
    private func syncRulerToViewport() {
        guard let ruler = rulerOverlay else { return }

        let target = CGRect(origin: contentOffset, size: bounds.size)
        if ruler.frame != target { ruler.frame = target }
        if ruler.contentOffset != contentOffset { ruler.contentOffset = contentOffset }

        // 后加进来的浮层（比如折叠三角那一层）会压在标尺上面，所以发现自己不在最上层时补一下
        if subviews.last !== ruler { bringSubviewToFront(ruler) }
    }
}
