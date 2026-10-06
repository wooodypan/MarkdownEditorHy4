//
//  MarkdownTextView+Table.swift
//  MarkdownEditorHy4
//
//  宽表格的横向滚动：找出「装不下」的表格，在它上面浮一层可横滑的滚动视图
//

import UIKit

/// 宽表格滚动容器所在的控件层：加在最上层，只让滚动视图自己吃点击。
///
/// 和 `CheckboxLayer`、`FoldControlLayer` 是同一套机制 —— 除了滚动视图之外的区域
/// 一律穿透，否则会挡住正文的点击和光标定位。
final class MarkdownTableScrollLayer: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        for subview in subviews where subview.frame.contains(point) {
            if let hit = subview.hitTest(convert(point, to: subview), with: event) { return hit }
        }
        return nil
    }
}

extension MarkdownTextView {

    // MARK: - 宽表格横向滚动

    /// 重扫一遍「哪些表格要横滚」以及它们各占哪几个字符位。
    ///
    /// ### 为什么单独一个方法、而且只在内容变了才调
    /// 这一步要 `enumerateAttribute` 扫**全篇**富文本，是这趟里唯一 O(n) 的活。
    /// 滚动时每 40pt 就要重算一次装饰矩形（`refreshDecorationsNearViewport`），那时候内容并没变、结果也不会变，再扫一遍纯属浪费 —— 所以扫描结果缓存进 `tableScrollMarks`，滚动那趟只重算**坐标**（见 `computeTableScrollFrames`）。
    func refreshTableScrollMarks() {
        let full = NSRange(location: 0, length: textStorage.length)
        var marks: [(range: NSRange, attachment: MarkdownTableAttachment)] = []
        textStorage.enumerateAttribute(.attachment, in: full, options: []) { value, range, _ in
            guard let attachment = value as? MarkdownTableAttachment,
                  attachment.needsHorizontalScroll else { return }
            marks.append((range, attachment))
        }
        tableScrollMarks = marks
    }

    /// 算出每个「可横滚表格」在**文档坐标系**下占的矩形。
    ///
    /// 坐标系和 `computeCheckboxFrames` 同一套：TextKit 给的矩形不含 `textContainerInset`，画到 textView 里要补回来。
    ///
    /// 不开 `private` 是为了让单元测试能直接调它。
    ///
    /// - parameter reusingOutside: 传视野附近的文档坐标矩形时，落在它外面的表格沿用上一轮结果
    ///             （屏幕外的 fragment 坐标是估算值，见 `refreshDecorationsNearViewport` 的注释）
    func computeTableScrollFrames(reusingOutside band: CGRect? = nil)
        -> [(attachment: MarkdownTableAttachment, frame: CGRect)] {
        guard let layoutManager = textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage,
              bounds.width > 1 else { return [] }

        let documentStart = contentStorage.documentRange.location
        var frames: [(attachment: MarkdownTableAttachment, frame: CGRect)] = []
        frames.reserveCapacity(tableScrollMarks.count)

        for mark in tableScrollMarks {
            // 视野外的沿用上一轮结果（理由见方法注释里的 reusingOutside）
            if let band,
               let cached = tableScrollFrames.first(where: { $0.attachment === mark.attachment })?.frame,
               !cached.intersects(band) {
                frames.append((mark.attachment, cached))
                continue
            }

            guard NSMaxRange(mark.range) <= textStorage.length,
                  let startLocation = contentStorage.location(documentStart, offsetBy: mark.range.location),
                  let endLocation = contentStorage.location(documentStart, offsetBy: NSMaxRange(mark.range)),
                  let textRange = NSTextRange(location: startLocation, end: endLocation) else { continue }

            // 表格在文本流里占 1 个字符位，取它覆盖到的所有 segment 求并集就是它的矩形
            var rect: CGRect?
            layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, segment, _, _ in
                guard !segment.isNull else { return true }
                rect = rect.map { $0.union(segment) } ?? segment
                return true
            }
            guard let rect else { continue }

            frames.append((mark.attachment,
                           CGRect(x: rect.minX + textContainerInset.left,
                                  y: rect.minY + textContainerInset.top,
                                  width: rect.width,
                                  height: rect.height)))
        }
        return frames
    }

    /// 把滚动容器摆到屏幕上（和 `positionCheckboxes` 同一套平移逻辑）。
    ///
    /// ### ⚠️ 复用池为什么按 attachment 的身份存
    /// 每次滚动都要重摆一次；要是每次都新建一个 `MarkdownTableScrollView`，用户横滑到表格中间再竖着滚一点，回来就**跳回最左边**了 —— 等于根本没法看。
    /// 所以同一份表格（同一个 attachment 对象）一直用同一个滚动视图，位置自己记着。
    func positionTableScrollViews() {
        tableScrollLayer.frame = bounds
        // 可见范围，上下各留 200pt 余量，滚快一点也不会闪出空白
        let visible = CGRect(x: 0, y: -200, width: bounds.width, height: bounds.height + 400)

        var used: Set<ObjectIdentifier> = []
        used.reserveCapacity(tableScrollFrames.count)

        for entry in tableScrollFrames {
            // 文档坐标 → 本层坐标：减掉滚动偏移
            var frame = entry.frame
            frame.origin.x -= contentOffset.x
            frame.origin.y -= contentOffset.y
            guard frame.intersects(visible) else { continue }

            let key = ObjectIdentifier(entry.attachment)
            let scroller: MarkdownTableScrollView
            if let reused = tableScrollPool[key] {
                scroller = reused
            } else {
                scroller = MarkdownTableScrollView(attachment: entry.attachment)
                tableScrollPool[key] = scroller
            }
            scroller.frame = frame
            if scroller.superview !== tableScrollLayer { tableScrollLayer.addSubview(scroller) }
            used.insert(key)
        }

        // 回收：表格滚出视野、或者内容已经换成新的 attachment（编辑过表格）的，都拆下来
        for (key, view) in tableScrollPool where !used.contains(key) {
            view.removeFromSuperview()
            tableScrollPool[key] = nil
        }
    }
}
