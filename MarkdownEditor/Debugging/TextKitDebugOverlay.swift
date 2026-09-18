//
//  TextKitDebugOverlay.swift
//  Debug-only TextKit line fragment / usedRect visualizer
//
//  用法：
//      #if DEBUG
//      textView.installLineFragmentDebugOverlay()
//      // 再次调用可关闭
//      textView.installLineFragmentDebugOverlay()
//      #endif
//
//  支持 TextKit 1 (NSLayoutManager) 和 TextKit 2 (NSTextLayoutManager)，
//  会自动探测 UITextView 当前使用的是哪一套。
//

import UIKit

// MARK: - 配置

struct TextKitDebugConfig {
    /// line fragment 矩形颜色（每行文本实际占用的完整行框，含行高）
    var lineFragmentColor: UIColor = UIColor.systemRed.withAlphaComponent(0.9)
    /// usedRect 矩形颜色（该行字形实际使用的区域，通常比 lineFragment 略小）
    var usedRectColor: UIColor = UIColor.systemBlue.withAlphaComponent(0.9)
    /// 段落级 NSTextAttachment（图片/代码块/表格容器等）的边界颜色
    var attachmentColor: UIColor = UIColor.systemGreen.withAlphaComponent(0.9)
    /// 容器（textContainer）整体可用区域颜色
    var containerColor: UIColor = UIColor.systemOrange.withAlphaComponent(0.6)
    var lineWidth: CGFloat = 1
    var dashPattern: [NSNumber]? = [4, 3]
    var showIndexLabels: Bool = true
    var indexLabelFont: UIFont = .monospacedSystemFont(ofSize: 9, weight: .medium)
}

// MARK: - Overlay View

/// 叠加在 UITextView 上方的透明绘制层，随 UITextView 滚动同步刷新
final class TextKitDebugOverlayView: UIView {

    weak var textView: UITextView?
    var config: TextKitDebugConfig

    init(textView: UITextView, config: TextKitDebugConfig = .init()) {
        self.textView = textView
        self.config = config
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard let textView = textView, let ctx = UIGraphicsGetCurrentContext() else { return }

        // 坐标系对齐：overlay 与 textView 同 frame，但要减去 textView 的 contentOffset
        // 以及 textContainerInset，使得绘制坐标与文本坐标一致。
        let inset = textView.textContainerInset
        let offset = textView.contentOffset

        ctx.saveGState()
        ctx.translateBy(x: inset.left - offset.x, y: inset.top - offset.y)

        if #available(iOS 16.0, *), textView.textLayoutManager != nil {
            drawUsingTextKit2(textView: textView, context: ctx)
        } else {
            drawUsingTextKit1(textView: textView, context: ctx)
        }

        ctx.restoreGState()
    }

    // MARK: TextKit 1 (NSLayoutManager)

    private func drawUsingTextKit1(textView: UITextView, context ctx: CGContext) {
        let layoutManager = textView.layoutManager
        let textContainer = textView.textContainer
        let glyphRange = layoutManager.glyphRange(for: textContainer)

        // 容器整体区域
        drawContainerBounds(textContainer.size, context: ctx)

        var lineIndex = 0
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { [weak self] rect, usedRect, container, glyphRange, stop in
            guard let self = self else { return }

            // line fragment：整行分配到的矩形（包含行距）
            self.strokeRect(rect, color: self.config.lineFragmentColor, context: ctx)

            // usedRect：该行字形实际占用的矩形（不含多余行距）
            self.strokeRect(usedRect, color: self.config.usedRectColor, context: ctx)

            if self.config.showIndexLabels {
                self.drawLabel("\(lineIndex)", at: CGPoint(x: rect.minX, y: rect.minY), color: self.config.lineFragmentColor)
            }
            lineIndex += 1
        }

        // NSTextAttachment（图片/代码块容器等）边界
        drawAttachments(textView: textView, layoutManager: layoutManager, textContainer: textContainer, context: ctx)
    }

    private func drawAttachments(textView: UITextView, layoutManager: NSLayoutManager, textContainer: NSTextContainer, context ctx: CGContext) {
        guard let attributedText = textView.attributedText else { return }
        let fullRange = NSRange(location: 0, length: attributedText.length)

        attributedText.enumerateAttribute(.attachment, in: fullRange, options: []) { [weak self] value, range, _ in
            guard let self = self, value is NSTextAttachment else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            self.strokeRect(rect, color: self.config.attachmentColor, context: ctx, lineWidth: self.config.lineWidth + 0.5)
        }
    }

    // MARK: TextKit 2 (NSTextLayoutManager) — iOS 16+

    @available(iOS 16.0, *)
    private func drawUsingTextKit2(textView: UITextView, context ctx: CGContext) {
        guard let textLayoutManager = textView.textLayoutManager,
              let textContentManager = textLayoutManager.textContentManager else { return }

        // 容器整体区域
        if let container = textLayoutManager.textContainer {
            drawContainerBounds(container.size, context: ctx)
        }

        var lineIndex = 0
        let documentRange = textContentManager.documentRange

        textLayoutManager.enumerateTextLayoutFragments(from: documentRange.location, options: [.ensuresLayout]) { [weak self] fragment in
            guard let self = self else { return false }

            // fragment.layoutFragmentFrame 大致对应 TextKit1 的多行 line fragment 集合（一个 fragment 可能含多个 line）
            for lineFragment in fragment.textLineFragments {
                // typographicBounds 是相对于 fragment 自身原点的，需要加上 fragment 的 frame origin
                var rect = lineFragment.typographicBounds
                rect.origin.x += fragment.layoutFragmentFrame.origin.x
                rect.origin.y += fragment.layoutFragmentFrame.origin.y

                self.strokeRect(rect, color: self.config.lineFragmentColor, context: ctx)

                if self.config.showIndexLabels {
                    self.drawLabel("\(lineIndex)", at: CGPoint(x: rect.minX, y: rect.minY), color: self.config.lineFragmentColor)
                }
                lineIndex += 1
            }

            // fragment 本身的 frame，类似 attachment/段落容器边界
            self.strokeRect(fragment.layoutFragmentFrame, color: self.config.usedRectColor, context: ctx)

            return true // 继续枚举
        }
    }

    // MARK: 绘制辅助

    private func drawContainerBounds(_ size: CGSize, context ctx: CGContext) {
        // ⚠️ 文本容器的「高度」是**无界**的（`CGFloat.greatestFiniteMagnitude`）—— 文字可以一直往下排，
        // 容器本身没有右下角。拿这个值去描边会坑死人：CoreGraphics 遇到这种坐标会把
        // **这一帧里的所有描边全部丢掉**（实测：只在它之后画一条正常的矩形，也一样看不见），
        // 表现就是「菜单打了勾、屏幕上一根线都没有」。
        // 所以宽高都按可视区域兜底 —— 橙色框只负责标出正文的可用宽度，高度延伸到看得见的地方为止。
        let width = size.width.isFinite ? min(size.width, bounds.width) : bounds.width
        let height = size.height.isFinite ? min(size.height, bounds.height) : bounds.height
        let rect = CGRect(origin: .zero, size: CGSize(width: width, height: height))
        strokeRect(rect, color: config.containerColor, context: ctx, lineWidth: config.lineWidth, dashed: false)
    }

    /// 这一笔矩形能不能拿去描边。
    ///
    /// 判得比「宽高大于 0」严：坐标必须是**有限的、而且在合理范围内**。
    /// ⚠️ 光判 `isFinite` 是不够的 —— `greatestFiniteMagnitude` 本身就是个有限值
    ///（上面那条无界高度正是这么溜进来的），所以还要卡一个上限。
    private func isDrawable(_ rect: CGRect) -> Bool {
        let limit: CGFloat = 1_000_000
        return rect.width > 0 && rect.height > 0
            && rect.minX.isFinite && rect.minY.isFinite
            && rect.width < limit && rect.height < limit
            && abs(rect.minX) < limit && abs(rect.minY) < limit
    }

    private func strokeRect(_ rect: CGRect, color: UIColor, context ctx: CGContext, lineWidth: CGFloat? = nil, dashed: Bool = true) {
        guard isDrawable(rect) else { return }
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(lineWidth ?? config.lineWidth)
        if dashed, let pattern = config.dashPattern {
            ctx.setLineDash(phase: 0, lengths: pattern.map { CGFloat(truncating: $0) })
        }
        ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
        ctx.restoreGState()
    }

    private func drawLabel(_ text: String, at point: CGPoint, color: UIColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: config.indexLabelFont,
            .foregroundColor: UIColor.white,
            .backgroundColor: color
        ]
        let str = NSAttributedString(string: " \(text) ", attributes: attrs)
        str.draw(at: CGPoint(x: point.x, y: point.y))
    }
}

// MARK: - UITextView 集成

private var overlayAssociationKey: UInt8 = 0
private var scrollObserverKey: UInt8 = 0

extension UITextView {

    private var debugOverlay: TextKitDebugOverlayView? {
        get { objc_getAssociatedObject(self, &overlayAssociationKey) as? TextKitDebugOverlayView }
        set { objc_setAssociatedObject(self, &overlayAssociationKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private var scrollObserver: NSKeyValueObservation? {
        get { objc_getAssociatedObject(self, &scrollObserverKey) as? NSKeyValueObservation }
        set { objc_setAssociatedObject(self, &scrollObserverKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// 开关 line fragment 调试叠加层。再次调用会移除。
    @discardableResult
    func installLineFragmentDebugOverlay(config: TextKitDebugConfig = .init()) -> Bool {
        if let existing = debugOverlay {
            existing.removeFromSuperview()
            debugOverlay = nil
            scrollObserver?.invalidate()
            scrollObserver = nil
            return false
        }

        let overlay = TextKitDebugOverlayView(textView: self, config: config)
        overlay.frame = bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(overlay)
        debugOverlay = overlay

        // 滚动/内容变化时刷新
        scrollObserver = observe(\.contentOffset, options: [.new]) { [weak overlay] _, _ in
            overlay?.setNeedsDisplay()
        }

        NotificationCenter.default.addObserver(
            forName: UITextView.textDidChangeNotification, object: self, queue: .main
        ) { [weak overlay] _ in
            overlay?.setNeedsDisplay()
        }

        overlay.setNeedsDisplay()
        return true
    }

    /// 手动触发一次重绘（比如外部改变了 attributedText 后）
    func refreshLineFragmentDebugOverlay() {
        debugOverlay?.setNeedsDisplay()
    }
}
