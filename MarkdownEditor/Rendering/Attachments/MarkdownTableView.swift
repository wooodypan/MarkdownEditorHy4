//
//  MarkdownTableView.swift
//  MarkdownEditorHy4
//
//  自绘的 markdown 表格：按内容算列宽行高，画成一张图片交给 attachment
//

import UIKit

/// 表格量好尺寸之后的结果：每列多宽、每行多高、整体多高。
struct MarkdownTableLayout {
    /// 每一列的宽度（加起来等于表格总宽）
    var columnWidths: [CGFloat]
    /// 每一行的高度（第 0 项是表头）
    var rowHeights: [CGFloat]
    /// 表格总高度（所有行高之和，分隔线画在行内部，不额外占高）
    var totalHeight: CGFloat

    /// 某一行顶部的 y 坐标
    func y(ofRow row: Int) -> CGFloat {
        guard row < rowHeights.count else { return totalHeight }
        return rowHeights[0..<row].reduce(0, +)
    }

    /// 某一列左边的 x 坐标
    func x(ofColumn column: Int) -> CGFloat {
        guard column < columnWidths.count else { return 0 }
        return columnWidths[0..<column].reduce(0, +)
    }
}

/// 一个轻量自绘表格。
///
/// ### 为什么自绘而不是 `UICollectionView`
/// 表格是「固定的小规模网格」：几行几列、一次全画出、内容不滚动。
/// `UICollectionView` 的复用池、dataSource 样板代码在这里全是负担；
/// 而且列宽要**整列统一算**（每列宽度取决于该列最长的内容），
/// 本来就得自己算一遍，干脆直接画。
///
/// ### 为什么最终是一张图片（重要，别改成 view provider）
/// 项目里已经踩过坑：TextKit 2 的 `NSTextAttachmentViewProvider` 在整篇替换内容之后，
/// 会把 attachment 的 view 从视图树摘掉，却**不会**为新的 attachment 重新 `loadView()`
/// （表现是「图片消失，滚动一下才回来」）。
/// 所以这里和图片、引用块绿条一样：把表格**画成 UIImage** 交给 `NSTextAttachment.image`，
/// 绘制完全跟文本排版走，没有 view 生命周期错位的问题。
///
/// 代价是表格不能交互、不能横向滚动 —— 对「源码可编辑的 markdown 编辑器」来说，
/// 表格本来就是预览，要改就改下面的源码，这个代价可以接受。
final class MarkdownTableView: UIView {

    /// 表格内容
    let data: MarkdownTableData
    /// 绘制参数
    let style: MarkdownTheme.TableStyle
    /// 表头字体（正文加粗）
    let headerFont: UIFont
    /// 单元格字体
    let bodyFont: UIFont
    /// 文字颜色
    let textColor: UIColor
    /// 量好的尺寸
    let layout: MarkdownTableLayout

    /// 原因见 `MarkdownBlock` 里 `nonisolated deinit` 的注释
    nonisolated deinit {}

    init(data: MarkdownTableData,
         style: MarkdownTheme.TableStyle,
         bodyFont: UIFont,
         textColor: UIColor,
         width: CGFloat) {
        self.data = data
        self.style = style
        self.bodyFont = bodyFont
        self.headerFont = bodyFont.adding(.traitBold)
        self.textColor = textColor
        self.layout = Self.makeLayout(data: data, style: style, bodyFont: bodyFont,
                                      headerFont: bodyFont.adding(.traitBold), width: width)
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: layout.totalHeight))
        isOpaque = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("MarkdownTableView 不支持从 coder 解档")
    }

    /// 把表格画到当前的图形上下文里（attachment 生成图片、view 自绘都走这里）
    func render() {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        drawTable(in: context, size: bounds.size)
    }

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        render()
    }

    // MARK: 生成图片

    /// 画一张表格图片（attachment 直接拿它当 `NSTextAttachment.image`）
    static func image(data: MarkdownTableData,
                      style: MarkdownTheme.TableStyle,
                      bodyFont: UIFont,
                      textColor: UIColor,
                      width: CGFloat) -> UIImage {
        let headerFont = bodyFont.adding(.traitBold)
        let layout = makeLayout(data: data, style: style, bodyFont: bodyFont,
                                headerFont: headerFont, width: width)
        let size = CGSize(width: width, height: layout.totalHeight)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        let table = MarkdownTableLayoutBox(layout: layout,
                                           data: data,
                                           style: style,
                                           headerFont: headerFont,
                                           bodyFont: bodyFont,
                                           textColor: textColor)
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            table.draw(in: size)
        }
    }

    /// 表格在给定宽度下需要多高（attachment 用它定 bounds）
    static func height(data: MarkdownTableData,
                       style: MarkdownTheme.TableStyle,
                       bodyFont: UIFont,
                       width: CGFloat) -> CGFloat {
        makeLayout(data: data, style: style, bodyFont: bodyFont,
                   headerFont: bodyFont.adding(.traitBold), width: width).totalHeight
    }

    // MARK: 量尺寸

    /// 算列宽和行高。
    ///
    /// 列宽分两步：先按内容量出每列的「理想宽度」，再整体缩放到容器宽度
    /// （不够宽就按比例放大撑满，太宽就按比例压缩 —— 和代码块背景「撑满容器」的思路一致）。
    static func makeLayout(data: MarkdownTableData,
                           style: MarkdownTheme.TableStyle,
                           bodyFont: UIFont,
                           headerFont: UIFont,
                           width: CGFloat) -> MarkdownTableLayout {
        let columnCount = max(1, data.columnCount)
        let rowCount = max(1, data.rowCount)
        let paddingH = style.cellPaddingHorizontal * 2
        let paddingV = style.cellPaddingVertical * 2

        // 1) 每列的理想宽度 = 该列最长的内容 + 左右内边距，夹在 [min, max] 之间
        var desired: [CGFloat] = []
        desired.reserveCapacity(columnCount)
        for column in 0..<columnCount {
            var widest: CGFloat = 0
            for row in 0..<rowCount {
                let font = row == 0 ? headerFont : bodyFont
                let text = data.text(row: row, column: column)
                let size = (text as NSString).size(withAttributes: [.font: font])
                widest = max(widest, size.width)
            }
            let ideal = ceil(widest) + paddingH
            desired.append(min(max(ideal, style.minColumnWidth), style.maxColumnWidth))
        }

        // 2) 整体缩放到容器宽度
        let total = desired.reduce(0, +)
        let scale = total > 0 ? max(width, 1) / total : 1
        var columnWidths = desired.map { $0 * scale }

        // 3) 列特别多时给每列保底宽度，再超了就整体再缩一次（宁可挤一点也不能溢出容器）
        let floorWidth = min(style.minColumnWidth, max(width, 1) / CGFloat(columnCount))
        columnWidths = columnWidths.map { max($0, floorWidth) }
        let adjusted = columnWidths.reduce(0, +)
        if adjusted > width, adjusted > 0 {
            let fix = width / adjusted
            columnWidths = columnWidths.map { $0 * fix }
        }

        // 4) 行高 = 该行最高的那个单元格（文字要按列宽换行） + 上下内边距
        var rowHeights: [CGFloat] = []
        rowHeights.reserveCapacity(rowCount)
        for row in 0..<rowCount {
            let font = row == 0 ? headerFont : bodyFont
            var tallest: CGFloat = 0
            for column in 0..<columnCount {
                let text = data.text(row: row, column: column)
                let textWidth = max(1, columnWidths[column] - paddingH)
                let rect = (text as NSString).boundingRect(
                    with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: font],
                    context: nil
                )
                tallest = max(tallest, ceil(rect.height))
            }
            rowHeights.append(tallest + paddingV)
        }

        return MarkdownTableLayout(columnWidths: columnWidths,
                                   rowHeights: rowHeights,
                                   totalHeight: rowHeights.reduce(0, +))
    }

    // MARK: 绘制

    private func drawTable(in context: CGContext, size: CGSize) {
        MarkdownTableLayoutBox(layout: layout,
                               data: data,
                               style: style,
                               headerFont: headerFont,
                               bodyFont: bodyFont,
                               textColor: textColor).draw(in: size)
    }
}

/// 真正干绘制活的「画匠」。
///
/// 单独拎出来是因为 **attachment 生成图片时手上并没有一个 view**——
/// 直接在一个离屏图形上下文里画就行，没必要先造个 UIView 再截图（那样还多一层风险）。
private struct MarkdownTableLayoutBox {
    let layout: MarkdownTableLayout
    let data: MarkdownTableData
    let style: MarkdownTheme.TableStyle
    let headerFont: UIFont
    let bodyFont: UIFont
    let textColor: UIColor

    func draw(in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let bounds = CGRect(origin: .zero, size: size)
        guard let context = UIGraphicsGetCurrentContext() else { return }

        // 外框：圆角矩形，后面所有内容都裁在它里面（表头底色才不会戳出圆角）
        let frame = UIBezierPath(roundedRect: bounds, cornerRadius: style.cornerRadius)
        context.saveGState()
        frame.addClip()

        // 表头底色
        style.headerBackground.setFill()
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: layout.rowHeights.first ?? 0))

        // 单元格文字
        for row in 0..<layout.rowHeights.count {
            let rowY = layout.y(ofRow: row)
            let rowHeight = layout.rowHeights[row]
            let font = row == 0 ? headerFont : bodyFont

            for column in 0..<layout.columnWidths.count {
                let columnX = layout.x(ofColumn: column)
                let columnWidth = layout.columnWidths[column]
                let textRect = CGRect(x: columnX + style.cellPaddingHorizontal,
                                      y: rowY + style.cellPaddingVertical,
                                      width: columnWidth - style.cellPaddingHorizontal * 2,
                                      height: rowHeight - style.cellPaddingVertical * 2)

                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = data.alignment(column: column)
                paragraph.lineBreakMode = .byWordWrapping

                (data.text(row: row, column: column) as NSString).draw(
                    with: textRect,
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: font,
                                 .foregroundColor: textColor,
                                 .paragraphStyle: paragraph],
                    context: nil
                )
            }

            // 行分隔线（最后一行下面不画，那个位置是外框）
            if row < layout.rowHeights.count - 1 {
                let lineY = rowY + rowHeight - style.borderWidth / 2
                style.borderColor.setFill()
                context.fill(CGRect(x: 0, y: lineY, width: size.width, height: style.borderWidth))
            }
        }

        // 列分隔线
        for column in 0..<(layout.columnWidths.count - 1) {
            let lineX = layout.x(ofColumn: column + 1) - style.borderWidth / 2
            style.borderColor.setFill()
            context.fill(CGRect(x: lineX, y: 0, width: style.borderWidth, height: size.height))
        }

        context.restoreGState()

        // 外框描边（在裁剪外面画，线才不会被裁掉一半）
        style.borderColor.setStroke()
        frame.lineWidth = style.borderWidth
        frame.stroke()
    }
}
