# 标尺

如何给某个 UIView 上边和左边加一个半透明的标尺，类似 Chrome Dev Tool 的标尺，加到内部。

> ⚠️ **本文档已按实际落地的代码（`MarkdownEditor/Debugging/RulerOverlayView.swift`）修正过（2026-10-11）。**
> 最初的参考实现有**两处会导致「画了等于没画」的坑**（刻度线看不见、竖排数字被裁掉），
> 详见下面「[落地时踩到的两个坑](#落地时踩到的两个坑)」。下面代码块里已按修正后的版本写。

## 思路

做一个 `RulerOverlayView`，它只负责画标尺（用 `draw(_:)`），然后作为子视图加到目标 view 内部，铺满、`isUserInteractionEnabled = false`，这样不会挡住内部内容的点击。

## 实现

```swift
import UIKit

final class RulerOverlayView: UIView {

    // MARK: - 可配置项
    var rulerThickness: CGFloat = 24          // 标尺宽/高
    var minorTickLength: CGFloat = 4
    var midTickLength: CGFloat = 7
    var majorTickLength: CGFloat = 12
    var unit: CGFloat = 10                    // 每个小刻度间距（pt）
    /// 刻度线的线宽（pt）。
    /// ⚠️ 这一条**必须独立于**分界线（见「坑 2」）：不单独设一次的话，刻度线会继承分界线的「1 物理像素」线宽，变成一根看不见的头发丝
    var tickLineWidth: CGFloat = 1
    var backgroundAlpha: CGFloat = 0.5
    var tickColor: UIColor = UIColor.white.withAlphaComponent(0.85)
    var textColor: UIColor = UIColor.white.withAlphaComponent(0.95)
    var font: UIFont = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)  // 等宽数字，滚动时读数不抖

    /// 内容偏移（目标是 UIScrollView 时，用来让标尺跟随滚动）
    var contentOffset: CGPoint = .zero {
        didSet { if contentOffset != oldValue { setNeedsDisplay() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false                      // 半透明视图不能对外声称「不透明」，否则边上出黑块
        backgroundColor = .clear
        isUserInteractionEnabled = false      // 不拦截触摸
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("RulerOverlayView 不支持从 coder 解档") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let w = bounds.width, h = bounds.height
        let t = rulerThickness

        // 尺寸还没定下来（刚 addSubview 还没布局）、或参数被配成 0 时什么都不画，免得画出怪东西或转死循环
        guard w > t, h > t, unit > 0 else { return }

        // 1. 半透明背景条（顶部 + 左侧）。左上角那个小方块归「上边那条」管，所以左边这条从 y = t 才开始
        ctx.setFillColor(UIColor.black.withAlphaComponent(backgroundAlpha).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: t))        // 上
        ctx.fill(CGRect(x: 0, y: t, width: t, height: h - t))    // 左

        // 2. 边界线：用「1 个物理像素」，屏幕上最细，不挡内容
        ctx.setStrokeColor(tickColor.cgColor)
        ctx.setLineWidth(1 / max(1, traitCollection.displayScale))   // 用 traitCollection.displayScale，别用已废弃的 UIScreen.main.scale
        ctx.move(to: CGPoint(x: 0, y: t)); ctx.addLine(to: CGPoint(x: w, y: t))
        ctx.move(to: CGPoint(x: t, y: 0)); ctx.addLine(to: CGPoint(x: t, y: h))
        ctx.strokePath()

        // ⚠️ 坑 2：刻度线要重新设一次线宽，否则会沿用上面那句「1 个物理像素」
        ctx.setLineWidth(tickLineWidth)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: textColor
        ]

        // 3. 顶部刻度（横向 x）
        ctx.saveGState()
        ctx.clip(to: CGRect(x: t, y: 0, width: w - t, height: t))
        var i = Int(floor(contentOffset.x / unit))      // floor：滚动偏移带小数时也从一个整数刻度起算
        while true {
            let value = CGFloat(i) * unit
            let x = value - contentOffset.x             // 文档坐标 → 视图坐标：减掉滚动偏移
            if x > w { break }
            if x >= t {                                 // 左上角那格留给竖尺
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
                    // 文字旋转 90°，竖着写。⚠️ 锚点位置见「坑 1」
                    ctx.saveGState()
                    ctx.translateBy(x: t - 3, y: y + 2)
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

这里的 `unit = 10`，所以每 10pt 一个小刻度，每 50pt 一个中刻度，每 100pt 一个大刻度并标数字。

## 落地时踩到的两个坑

### 坑 1：左侧竖排数字的旋转锚点放错了 → 一个字都看不见

**原始写法**（会坏）：

```swift
ctx.translateBy(x: 1, y: y + 2)
ctx.rotate(by: .pi / 2)
("\(Int(value))" as NSString).draw(at: .zero, withAttributes: attrs)
```

先 `translate` 再 `rotate(π/2)`，是「文字往下排」的写法。转完之后**文字的宽度占了纵向、高度占了横向，而且是往锚点的左边长**（也就是 x 的负方向）。锚点放在 `x = 1` 时，整块文字长到带子外面（负 x）被 `clip` 裁掉，一个字都看不到。

**正确写法**：锚点的 x 必须靠近带子的**右边缘**，让文字正好落在这条带子里：

```swift
ctx.translateBy(x: rulerThickness - 3, y: y + 2)
```

实测（`thickness = 24`，即 `x = 21`）：数字落在 `x ≈ 12~18`，稳稳在带子内。

### 坑 2：刻度线继承了分界线的「1 物理像素」线宽 → 只剩头发丝

`ctx.setLineWidth(...)` 是**有状态的**，会一直生效到下次设置为止。分界线那句 `setLineWidth(1 / displayScale)` 之后如果不重置，两条尺的刻度线全部沿用这个线宽 —— 3x 屏上只有 0.33pt，抗锯齿之后一根线只剩三分之一的墨，肉眼在 Retina 屏上**基本看不到刻度**（只有数字和底色条还在，很容易误判成「刻度没画出来」）。

**正确写法**：在画刻度之前重新设一次：

```swift
ctx.setLineWidth(1 / max(1, traitCollection.displayScale))   // 分界线
...strokePath()
ctx.setLineWidth(tickLineWidth)                              // ← 刻度线重置回 1pt
```

> 复盘：这个坑是靠「把标尺画成位图、逐像素读 + 打 ASCII 图」才定位出来的 —— 肉眼看屏幕只会觉得「刻度没出来」，看不出是线宽问题。

## 使用

### 普通 UIView（非滚动）

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

let ruler = someView.addRuler()
```

### 目标是 UIScrollView（本项目的用法）

⚠️ **参考实现里那段 `scrollViewDidScroll(_:)` 的写法不适用**：它假设标尺挂在**滚动视图的父视图**上、另有一个 delegate 帮你收回调。而本项目的目标（`MarkdownTextView`）**自己就是那个滚动视图**，没有独立的 delegate 可以挂，所以改成两条 KVO 直接观察自己。

关键点：**把标尺的 `frame` 永远设成目标的 `bounds`**。`UIScrollView.bounds.origin` 就等于滚动偏移，所以 `frame.origin` 跟着偏移走之后，标尺在屏幕上就停在原地不滚；至于刻度怎么随内容走，交给 `contentOffset` 在绘制时减掉。

```swift
// 挂上（连着调两次就是摘掉）
@discardableResult
func installRuler() -> Bool {
    if let existing = rulerOverlay {          // 已经挂着 → 这一趟是摘掉
        existing.removeFromSuperview()
        rulerOverlay = nil
        rulerObservations?.forEach { $0.invalidate() }   // ⚠️ 观察者要主动作废，否则会一直拽住 textView
        rulerObservations = nil
        return false
    }

    let ruler = RulerOverlayView(frame: bounds)
    ruler.isUserInteractionEnabled = false
    addSubview(ruler)
    syncRulerToViewport()

    // contentOffset 那条负责滚动；bounds 那条补「转屏 / Catalyst 拉窗口」（那时候偏移没变，光靠上一条不触发）
    rulerObservations = [
        observe(\.contentOffset, options: [.new]) { [weak self] _, _ in self?.syncRulerToViewport() },
        observe(\.bounds,         options: [.new]) { [weak self] _, _ in self?.syncRulerToViewport() }
    ]
    return true
}

private func syncRulerToViewport() {
    guard let ruler = rulerOverlay else { return }
    let target = CGRect(origin: contentOffset, size: bounds.size)
    if ruler.frame != target { ruler.frame = target }          // 判等：滚动每帧都跑，别每帧把父视图标脏
    if ruler.contentOffset != contentOffset { ruler.contentOffset = contentOffset }
    if subviews.last !== ruler { bringSubviewToFront(ruler) }  // 后加进来的浮层会压住标尺，发现不在最上层就补一下
}
```

## 注意事项

1. **滚动视图里的标尺**：见上面「目标是 UIScrollView」。核心是「`frame` 钉在 `bounds` 上 + 偏移在绘制时减掉」，不要用 `autoresizingMask`（那只会让标尺跟着内容滚走）。
2. **始终置顶**：后续若又往目标 view 里加了子视图（例如折叠三角、表格横滚层），在同步回调里补一次 `bringSubviewToFront(ruler)`。
3. **性能**：`draw(_:)` 只绘制可见范围内的刻度，普通场景没问题。同步回调里对 `frame` / `contentOffset` 都做了判等，不会每帧把父视图标脏。需要更激进的话可以把刻度改成 `CAShapeLayer` 或用 `CATiledLayer`；标尺这种规模用 Core Graphics 足够。
4. **`displayScale` 从哪来**：用视图自己的 `traitCollection.displayScale`，别用 `UIScreen.main.scale`（后者已废弃，且在多窗口 / Catalyst 下拿到的可能不是当前窗口的屏幕）。
5. **鼠标跟踪线（像 Chrome 那样的游标线）**：如果还想做拖动时显示当前坐标的指示线，可以在目标 view 上加一个 `UIPanGestureRecognizer`，把手指位置传给标尺，在 `draw` 里额外画一条红色细线和坐标数值。
6. **SwiftUI 项目**：用 `UIViewRepresentable` 包一层，或者直接用 `Canvas` 重写同样的绘制逻辑。
7. **Objective-C**：逻辑完全一致，把 `draw(_:)` 里的 CGContext 调用直接翻译即可。

## 调试这套标尺时用过的一次性探针

本沙箱截不了屏，所以验的时候是**把标尺画成位图 → 逐像素读 → 打 ASCII 图**：

```swift
let format = UIGraphicsImageRendererFormat.default()
format.scale = 1
format.opaque = false
let image = UIGraphicsImageRenderer(bounds: ruler.bounds, format: format).image { _ in
    ruler.draw(ruler.bounds)     // ⚠️ 直接调 draw(_:)，别用 drawHierarchy / layer.render —— 无头环境里那两条路常出全白
}
```

⚠️ 读 `CGContext(data:...)` 的位图内存时，「第 0 行是上还是下」**要自己探一下**（画一笔在角落里看它落在数组哪一头），别猜 —— 这次就因为多翻了一次，导致带子全读成透明。
