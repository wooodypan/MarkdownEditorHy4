# 标尺

如何给某个UIView上边和左边加一个半透明的标尺，类似Chrome Dev Tool的标尺，加到内部

思路：做一个 `RulerOverlayView`，它只负责画标尺（用 `draw(_:)` 或 `CAShapeLayer`/`CATextLayer`），然后作为子视图加到目标 view 内部，铺满、`isUserInteractionEnabled = false`，这样不会挡住内部内容的点击。

## 实现

```swift
import UIKit

final class RulerOverlayView: UIView {

    // MARK: - 可配置项
    var rulerThickness: CGFloat = 20          // 标尺宽/高
    var minorTickLength: CGFloat = 4
    var midTickLength: CGFloat = 7
    var majorTickLength: CGFloat = 12
    var unit: CGFloat = 10                    // 每个小刻度间距（pt）
    var backgroundAlpha: CGFloat = 0.5
    var tickColor: UIColor = UIColor.white.withAlphaComponent(0.8)
    var textColor: UIColor = UIColor.white.withAlphaComponent(0.9)
    var font: UIFont = .monospacedDigitSystemFont(ofSize: 8, weight: .regular)

    /// 内容偏移（如果目标是 UIScrollView，用来让标尺跟随滚动）
    var contentOffset: CGPoint = .zero {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false      // 不拦截触摸
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let w = bounds.width, h = bounds.height
        let t = rulerThickness

        // 1. 半透明背景条（顶部 + 左侧）
        ctx.setFillColor(UIColor.black.withAlphaComponent(backgroundAlpha).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: t))        // 上
        ctx.fill(CGRect(x: 0, y: t, width: t, height: h - t))    // 左

        // 2. 边界线
        ctx.setStrokeColor(tickColor.cgColor)
        ctx.setLineWidth(1 / UIScreen.main.scale)
        ctx.move(to: CGPoint(x: 0, y: t)); ctx.addLine(to: CGPoint(x: w, y: t))
        ctx.move(to: CGPoint(x: t, y: 0)); ctx.addLine(to: CGPoint(x: t, y: h))
        ctx.strokePath()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: textColor
        ]

        // 3. 顶部刻度（横向 x）
        ctx.saveGState()
        ctx.clip(to: CGRect(x: t, y: 0, width: w - t, height: t))
        var i = Int(floor(contentOffset.x / unit))
        while true {
            let value = CGFloat(i) * unit
            let x = value - contentOffset.x
            if x > w { break }
            if x >= t {
                let len = tickLength(for: i)
                ctx.move(to: CGPoint(x: x, y: t))
                ctx.addLine(to: CGPoint(x: x, y: t - len))
                if i % 10 == 0 {
                    ("\(Int(value))" as NSString).draw(at: CGPoint(x: x + 2, y: 1), withAttributes: attrs)
                }
            }
            i += 1
        }
        ctx.strokePath()
        ctx.restoreGState()

        // 4. 左侧刻度（纵向 y）
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: t, width: t, height: h - t))
        i = Int(floor(contentOffset.y / unit))
        while true {
            let value = CGFloat(i) * unit
            let y = value - contentOffset.y
            if y > h { break }
            if y >= t {
                let len = tickLength(for: i)
                ctx.move(to: CGPoint(x: t, y: y))
                ctx.addLine(to: CGPoint(x: t - len, y: y))
                if i % 10 == 0 {
                    // 文字旋转 90°，竖着写
                    ctx.saveGState()
                    ctx.translateBy(x: 1, y: y + 2)
                    ctx.rotate(by: .pi / 2)
                    ("\(Int(value))" as NSString).draw(at: .zero, withAttributes: attrs)
                    ctx.restoreGState()
                }
            }
            i += 1
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func tickLength(for index: Int) -> CGFloat {
        if index % 10 == 0 { return majorTickLength }
        if index % 5 == 0 { return midTickLength }
        return minorTickLength
    }
}
```

## 使用

```swift
extension UIView {
    @discardableResult
    func addRuler() -> RulerOverlayView {
        let ruler = RulerOverlayView(frame: bounds)
        ruler.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(ruler)
        return ruler
    }
}

// 普通 UIView
let ruler = someView.addRuler()
```

这里的 `unit = 10`，所以每 10pt 一个小刻度，每 50pt 一个中刻度，每 100pt 一个大刻度并标数字。

## 注意事项

1. **目标是 UIScrollView 时**：子视图会跟着内容滚走。解决办法有两种：
   - 把标尺加到 scrollView 的父视图上，frame 与 scrollView 相同；
   - 或者仍加在 scrollView 内，但在 `scrollViewDidScroll` 里同步 frame 并传入偏移：
   ```swift
   func scrollViewDidScroll(_ sv: UIScrollView) {
       ruler.frame = CGRect(origin: sv.contentOffset, size: sv.bounds.size)
       ruler.contentOffset = sv.contentOffset
   }
   ```
   这种方式要保证标尺始终在最上层（`bringSubviewToFront`）。

2. **始终置顶**：如果后续又往目标 view 里添加了子视图，可以调用 `bringSubviewToFront(ruler)`。

3. **性能**：`draw(_:)` 只绘制可见范围内的刻度，普通场景没问题。如果需要频繁滚动，可以把刻度改成 `CAShapeLayer` 或用 `CATiledLayer`；一般标尺这种规模用 Core Graphics 足够。

4. **鼠标跟踪线（像 Chrome 那样的游标线）**：如果还想做拖动时显示当前坐标的指示线，可以在目标 view 上加一个 `UIPanGestureRecognizer`，把手指位置传给标尺，在 `draw` 里额外画一条红色细线和坐标数值。需要的话我可以补上这部分。

5. **SwiftUI 项目**：用 `UIViewRepresentable` 包一层，或者直接用 `Canvas` 重写同样的绘制逻辑。

6. **Objective-C**：逻辑完全一致，把 `draw(_:)` 里的 CGContext 调用直接翻译即可。
