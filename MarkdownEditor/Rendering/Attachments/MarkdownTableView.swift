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

    /// 表格总宽度（所有列宽之和）。
    ///
    /// 注意它**不一定**等于排版时给的容器宽度：容器宽只是「最多能用多宽」，
    /// 表格自己按内容算出来是多少就是多少（见 `makeLayout` 第 2 步的说明）
    var totalWidth: CGFloat { columnWidths.reduce(0, +) }

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

/// 表格在给定宽度下的「呈现方式」：真实画多宽、屏幕上露多宽、要不要横向滚动。
///
/// ### 三种结果（判据是「列数 × 最小列宽」装不装得下）
/// 1. **内容算出来就比容器窄** → 原样画，不放大撑满（表格多宽由内容说了算）；
/// 2. **比容器宽，但每列都保持 `minColumnWidth` 还塞得下** → 整体等比压缩（老行为）；
/// 3. **连最小列宽都塞不下（列太多，比如 30 列）** → 按内容画完整宽度，屏幕上只露容器那么宽，剩下的靠横向滚动看 —— 此时 `layout.totalWidth` 比 `visibleWidth` 大，浮层会盖一个 `MarkdownTableScrollView` 上来。
///
/// 第 3 条是这次要解决的问题：压缩再狠也不能让一列窄到显示不出一个字，那就别压了，改成滚。
struct MarkdownTablePresentation {
    /// 真正拿去画的布局（滚动模式下**不压缩**，每列至少 `minColumnWidth`）
    let layout: MarkdownTableLayout
    /// 屏幕上露出来的宽度（= 文本流里那个 attachment 的宽度）
    let visibleWidth: CGFloat

    /// 要不要横向滚动：画出来的比露出来的宽，就得滚
    var isScrollable: Bool { layout.totalWidth - visibleWidth > 0.5 }
    /// 横向滚动的内容总宽（不可滚动时等于 `visibleWidth`）
    var contentWidth: CGFloat { layout.totalWidth }
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
/// 表格本身不能交互（表格要改就改它下面那几行源码）。
/// 唯一例外是**列太多装不下**：这时表格画成完整宽度，由 `MarkdownTableScrollView` 浮在文本上面做横向滚动（见 `MarkdownTablePresentation`）。
///
/// ### 画的时候只画露出来那一块
/// 宽表格可能上万点宽（30 列 × 每列最多 280pt），但 `draw(_:)` 拿到的脏矩形只有一屏，所以 `MarkdownTableLayoutBox.draw(in:dirty:)` 会把落在脏矩形外的单元格整格跳过 —— 一次只画一屏的量。
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

    /// 按「最多能用多宽」自己算布局（普通表格走这条）
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
                                      headerFont: bodyFont.adding(.traitBold),
                                      availableWidth: width)
        super.init(frame: CGRect(x: 0, y: 0,
                                 width: layout.totalWidth,
                                 height: layout.totalHeight))
        isOpaque = false
        backgroundColor = .clear
    }

    /// 按**已经量好的布局**直接画（横向滚动的画布走这条：它要的是完整宽度那一份，不能再按容器宽度压一次）
    init(data: MarkdownTableData,
         style: MarkdownTheme.TableStyle,
         bodyFont: UIFont,
         textColor: UIColor,
         layout: MarkdownTableLayout) {
        self.data = data
        self.style = style
        self.bodyFont = bodyFont
        self.headerFont = bodyFont.adding(.traitBold)
        self.textColor = textColor
        self.layout = layout
        super.init(frame: CGRect(x: 0, y: 0,
                                 width: layout.totalWidth,
                                 height: layout.totalHeight))
        isOpaque = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("MarkdownTableView 不支持从 coder 解档")
    }

    /// 把表格画到当前的图形上下文里（attachment 生成图片时走这里）
    func render() {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        drawTable(in: context, size: bounds.size, dirty: bounds)
    }

    /// ⚠️ 把 `rect` 当成「只要画这一块」往下传：宽表格可能上万点宽，整张重画一次太贵
    override func draw(_ rect: CGRect) {
        super.draw(rect)
        guard let context = UIGraphicsGetCurrentContext() else { return }
        drawTable(in: context, size: bounds.size, dirty: rect)
    }

    // MARK: 生成图片

    /// 画一张表格图片（attachment 直接拿它当 `NSTextAttachment.image`）。
    ///
    /// 图片的宽度是**表格自己的宽度**（`layout.totalWidth`），不是传进来的
    /// `availableWidth` —— 后者只是「最多能用多宽」。
    static func image(data: MarkdownTableData,
                      style: MarkdownTheme.TableStyle,
                      bodyFont: UIFont,
                      textColor: UIColor,
                      availableWidth: CGFloat) -> UIImage {
        image(data: data, style: style, bodyFont: bodyFont, textColor: textColor,
              layout: presentation(data: data, style: style, bodyFont: bodyFont,
                                   availableWidth: availableWidth).layout)
    }

    /// 按**已经量好的布局**出图（滚动模式下画布自己画，不用这张）
    static func image(data: MarkdownTableData,
                      style: MarkdownTheme.TableStyle,
                      bodyFont: UIFont,
                      textColor: UIColor,
                      layout: MarkdownTableLayout) -> UIImage {
        let headerFont = bodyFont.adding(.traitBold)
        let size = CGSize(width: layout.totalWidth, height: layout.totalHeight)
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
                       availableWidth: CGFloat) -> CGFloat {
        presentation(data: data, style: style, bodyFont: bodyFont,
                     availableWidth: availableWidth).layout.totalHeight
    }

    /// 一张**全透明**的占位图：宽表格交给浮层的滚动视图去画，文本流里只留一个位置。
    ///
    /// ### 为什么必须是透明图而不是「不设 image」
    /// `image = nil` 时 TextKit 会替我们补画一张「白纸 + 回形针」的占位图标（项目里踩过的老坑），屏幕上就多出一个莫名的小图标。给一张同尺寸的透明图，占的位置一样、一个像素都不画。
    ///
    /// ### 为什么透明而不是「画最左边那一块」
    /// 浮层滚动视图盖在同一块位置上；底下要是有图，两者只要差一两个点就会看出重影。留白就没有可比对象。
    static func transparentPlaceholder(width: CGFloat, height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        let size = CGSize(width: max(1, width), height: max(1, height))
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in }
    }

    // MARK: 呈现方式（画多宽 / 露多宽 / 要不要横滚）

    /// 决定表格在给定宽度下怎么呈现（三种结果的判据见 `MarkdownTablePresentation`）。
    ///
    /// - parameter availableWidth: 最多能用多宽（容器宽度）。不是「必须这么宽」
    static func presentation(data: MarkdownTableData,
                             style: MarkdownTheme.TableStyle,
                             bodyFont: UIFont,
                             availableWidth: CGFloat) -> MarkdownTablePresentation {
        let headerFont = bodyFont.adding(.traitBold)
        let limit = max(availableWidth, 1)
        // 1) 先按内容量一份「不压缩」的，看看它自己有多宽
        let natural = makeLayout(data: data, style: style, bodyFont: bodyFont,
                                 headerFont: headerFont, availableWidth: limit,
                                 compressesToFit: false)
        // 比容器窄：原样画（压缩这一步在没超宽时什么也不做，直接用这一份）
        guard natural.totalWidth > limit else {
            return MarkdownTablePresentation(layout: natural, visibleWidth: natural.totalWidth)
        }
        // 2) 超宽，但「每列都按最小宽度」还塞得下 → 等比压缩（几列的表格挤一挤还看得清）
        let minimumTotal = CGFloat(max(1, data.columnCount)) * style.minColumnWidth
        guard minimumTotal > limit else {
            let fitted = makeLayout(data: data, style: style, bodyFont: bodyFont,
                                    headerFont: headerFont, availableWidth: limit,
                                    compressesToFit: true)
            return MarkdownTablePresentation(layout: fitted, visibleWidth: fitted.totalWidth)
        }
        // 3) 连最小列宽都塞不下 → 横向滚动：画完整宽度，只露容器那么宽
        return MarkdownTablePresentation(layout: natural, visibleWidth: limit)
    }

    // MARK: 量尺寸

    /// 算列宽和行高。
    ///
    /// ### 列宽只缩不放（这是「列宽限制能生效」的关键）
    /// 分三步：先按内容量出每列的「理想宽度」并夹在 `[min, max]` 之间；
    /// 加起来**没超过**容器宽度就直接用（表格多宽由内容说了算）；
    /// 超过了才整体等比压缩。
    ///
    /// 之前这里写的是「不管多窄都等比撑满容器」，结果 `min/max` 白夹：
    /// 一个三列的小表格在宽屏上照样被拉到跟窗口一样宽 —— 正是用户报的那个 bug。
    /// 表格图和代码块背景不一样，它不是「铺满才好看」的装饰，撑满只会让列变得又空又散。
    ///
    /// - parameter availableWidth: 最多能用多宽（容器宽度）。不是「必须这么宽」
    /// - parameter compressesToFit: 超宽时要不要整体等比压缩。
    ///             `false` = 一压都不压，每列至少 `minColumnWidth`（横向滚动的画布要这一份）
    static func makeLayout(data: MarkdownTableData,
                           style: MarkdownTheme.TableStyle,
                           bodyFont: UIFont,
                           headerFont: UIFont,
                           availableWidth: CGFloat,
                           compressesToFit: Bool = true) -> MarkdownTableLayout {
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

        // 2) 够宽就原样用（不放大！一放大 min/max 就白夹了）；
        //    超了才整体等比压缩到容器宽度。
        //    ⚠️ 压缩只在 `compressesToFit` 为真时做：列太多时压缩会把每列压到只剩二十几点（一个字都显示不全），那种场合改成横向滚动（见 `presentation` 第 3 条），所以那一趟要的是**不压**的布局
        let limit = max(availableWidth, 1)
        let total = desired.reduce(0, +)
        var columnWidths = desired
        if compressesToFit, total > limit, total > 0 {
            let scale = limit / total
            columnWidths = desired.map { $0 * scale }

            // 3) 压完可能把某列压得比 minColumnWidth 还窄（列很多时尤其明显），
            //    给每列保底宽度；保完如果又超了，再整体缩一次（宁可挤一点也不能溢出容器）
            let floorWidth = min(style.minColumnWidth, limit / CGFloat(columnCount))
            columnWidths = columnWidths.map { max($0, floorWidth) }
            let adjusted = columnWidths.reduce(0, +)
            if adjusted > limit, adjusted > 0 {
                let fix = limit / adjusted
                columnWidths = columnWidths.map { $0 * fix }
            }
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

    private func drawTable(in context: CGContext, size: CGSize, dirty: CGRect) {
        MarkdownTableLayoutBox(layout: layout,
                               data: data,
                               style: style,
                               headerFont: headerFont,
                               bodyFont: bodyFont,
                               textColor: textColor).draw(in: size, dirty: dirty)
    }
}

/// 真正干绘制活的「画匠」。
///
/// 单独拎出来是因为 **attachment 生成图片时手上并没有一个 view**——
/// 直接在一个离屏图形上下文里画就行，没必要先造个 UIView 再截图（那样还多一层风险）。
struct MarkdownTableLayoutBox {
    let layout: MarkdownTableLayout
    let data: MarkdownTableData
    let style: MarkdownTheme.TableStyle
    let headerFont: UIFont
    let bodyFont: UIFont
    let textColor: UIColor

    /// - parameter dirty: 只要画这一块（表格坐标系里的矩形）。传 `.null` 或整张大小 = 全画。
    ///             宽表格上万点宽，`draw(_:)` 每次只给一屏，落在它外面的单元格直接跳过，一次就只画一屏的量
    func draw(in size: CGSize, dirty: CGRect = .null) {
        guard size.width > 0, size.height > 0 else { return }
        let bounds = CGRect(origin: .zero, size: size)
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let band = dirty.isNull ? bounds : dirty

        // 外框：圆角矩形，后面所有内容都裁在它里面（表头底色才不会戳出圆角）
        let frame = UIBezierPath(roundedRect: bounds, cornerRadius: style.cornerRadius)
        context.saveGState()
        frame.addClip()

        // 表头底色（只填露出来那一块：宽表格时整条填一遍要横跨上万点）
        let headerRect = CGRect(x: 0, y: 0, width: size.width, height: layout.rowHeights.first ?? 0)
        if band.intersects(headerRect) {
            style.headerBackground.setFill()
            context.fill(headerRect)
        }

        // 单元格文字
        for row in 0..<layout.rowHeights.count {
            let rowY = layout.y(ofRow: row)
            let rowHeight = layout.rowHeights[row]
            // 整行都在脏矩形外面（比如滚到上一屏去了）就整行跳过
            guard rowY + rowHeight >= band.minY, rowY <= band.maxY else { continue }
            let font = row == 0 ? headerFont : bodyFont

            for column in 0..<layout.columnWidths.count {
                let columnX = layout.x(ofColumn: column)
                let columnWidth = layout.columnWidths[column]
                guard columnX + columnWidth >= band.minX, columnX <= band.maxX else { continue }
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
                guard lineY + style.borderWidth >= band.minY, lineY <= band.maxY else { continue }
                style.borderColor.setFill()
                context.fill(CGRect(x: band.minX, y: lineY, width: band.width, height: style.borderWidth))
            }
        }

        // 列分隔线
        for column in 0..<(layout.columnWidths.count - 1) {
            let lineX = layout.x(ofColumn: column + 1) - style.borderWidth / 2
            guard lineX + style.borderWidth >= band.minX, lineX <= band.maxX else { continue }
            style.borderColor.setFill()
            context.fill(CGRect(x: lineX, y: band.minY, width: style.borderWidth, height: band.height))
        }

        context.restoreGState()

        // 外框描边（在裁剪外面画，线才不会被裁掉一半）
        style.borderColor.setStroke()
        frame.lineWidth = style.borderWidth
        frame.stroke()
    }
}
