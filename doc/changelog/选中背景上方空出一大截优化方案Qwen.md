

``` swift
override func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        let rects = super.selectionRects(for: range)
        guard renderer.theme.lineHeightMultiple > 1, textStorage.length > 0 else { return rects }
        guard let layoutManager = textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage else { return rects }
        let documentStart = contentStorage.documentRange.location

        return rects.map { item in
            let box = item.rect
            guard !box.isNull, box.height > 0 else { return item }

            // 用矩形中心反查这里是哪个字，再拿到它所在的那一行（fragment）
            let probe = closestPosition(to: CGPoint(x: box.midX, y: box.midY)) ?? range.start
            let offset = self.offset(from: beginningOfDocument, to: probe)
            guard let location = contentStorage.location(documentStart, offsetBy: offset),
                  let fragment = layoutManager.textLayoutFragment(for: location) else { return item }
            let fragmentStart = contentStorage.offset(from: documentStart, to: fragment.rangeInElement.location)
            // 量不到字形（空行之类）就不动，避免把色块挪飞
            guard let glyphs = textGlyphVerticalBounds(of: fragment, fragmentStart: fragmentStart) else { return item }

            let glyphCenter = (glyphs.top + glyphs.bottom) / 2
            let frame = fragment.layoutFragmentFrame
            let fragmentCenter = (frame.minY + frame.maxY) / 2
            let shift = glyphCenter - fragmentCenter     // 正=文字在行盒中线下方，色块要跟着下移
            guard abs(shift) > 0.5 else { return item }   // 图片这种字形撑满行盒的不用动
            return ShiftedSelectionRect(base: item, rect: box.offsetBy(dx: 0, dy: shift))
        }
    }
/// 一个"挪过的"选区矩形：除了位置变了，其它属性都照抄原来那个。
    ///
    /// 大白话：UIKit 要的是"矩形对象"，不能直接给个坐标，所以只能这样包一层。
    private final class ShiftedSelectionRect: UITextSelectionRect {
        private let base: UITextSelectionRect
        private let shifted: CGRect
        init(base: UITextSelectionRect, rect: CGRect) { self.base = base; self.shifted = rect }
        override var rect: CGRect { shifted }
        override var writingDirection: NSWritingDirection { base.writingDirection }
        override var containsStart: Bool { base.containsStart }
        override var containsEnd: Bool { base.containsEnd }
        override var isVertical: Bool { base.isVertical }
    }
```