//
//  ImageAttachment.swift
//  MarkdownEditorHy4
//
//  图片 attachment：在文本流里占 1 个字符位，但复制时要吐回整段 ![alt](url) 源码
//

import UIKit

/// 一个 markdown 图片。
///
/// 在文本流里它只占 **1 个字符位**（`NSAttachmentCharacter`），所以换行、缩进全部由 TextKit 自动处理；
/// 但它背后记着自己对应的整段源码（`![示例图片](sample.png)`），复制时由文档模型的映射表负责还原。
///
/// ### 为什么用 `image` 而不是 view provider（很重要）
/// 一开始这里走的是 TextKit 2 的 `viewProvider(for:…)` + 一个 `UIImageView`。
/// 实测发现：整篇替换内容之后，TextKit 2 会把 attachment 的 view 从视图树里摘掉，
/// 却**不会**为新的 attachment 重新调 `loadView()`（整个 App 生命周期里只调了一次）。
/// 表现就是「点重载后图片消失，滚动一下才回来」，而且各种强制重排的 API 都救不回来。
///
/// 改成把 `UIImage` 直接赋给 `NSTextAttachment.image`，绘制交给 TextKit 自己完成：
/// 它是跟着文本排版走的，文本怎么重排它就怎么重画，不存在「view 生命周期对不上」的问题。
final class ImageAttachment: NSTextAttachment {
    /// 对应的 markdown 源码，比如 `![示例图片](sample.png)`
    let markdownSource: String
    let imageURL: URL

    /// 加载完成后通知宿主刷新布局
    weak var host: MarkdownAttachmentHost?

    /// 预览窗标题栏上显示的名字：优先用 `![这里写的替代文字]`，没写就用文件名。
    ///
    /// 之所以要专门算一下：用户写 `![架构图](a.png)` 时，「架构图」才是他心里这张图的名字，
    /// 而文件名常常是 `pasted-3F2A….png` 这种机器起的，摆到标题栏上毫无意义。
    var previewTitle: String {
        guard let start = markdownSource.range(of: "!["),
              let end = markdownSource[start.upperBound...].range(of: "]") else {
            return imageURL.lastPathComponent
        }
        let alt = String(markdownSource[start.upperBound..<end.lowerBound])
        return alt.isEmpty ? imageURL.lastPathComponent : alt
    }

    /// 已经加载好的图片（本地图片在 init 里就有了）
    private(set) var loadedImage: UIImage?
    /// 图片确认加载不出来（网络 404、本地文件不存在或不是图片）之后置为 true。
    /// 置为 true 之后尺寸会收成小占位，见 `markAsMissing`。
    private(set) var isMissing = false

    private let maxWidth: CGFloat
    private let maxHeight: CGFloat
    /// **一行正文的高度**。加载失败的占位块以它为基准算自己应该多高。
    ///
    /// 由外面（`MarkupToAttributedRenderer`）从主题的正文字体算好传进来 ——
    /// attachment 自己不认识主题，也就不知道正文行高是多少。
    private let lineHeight: CGFloat
    /// 占位块的画笔颜色（外面传主题的弱化色，占位才不会比正文还显眼）
    private let placeholderColor: UIColor
    private var didStartLoading = false

    /// 加载中占位的宽高比（高 / 宽 = 9 / 16，也就是常见的 16:9）
    private static let loadingAspectRatio: CGFloat = 9.0 / 16.0
    /// 加载失败后那个小占位的宽高比（宽 / 高）
    private static let missingAspectRatio: CGFloat = 16.0 / 9.0
    /// 失败占位最多占「几行正文」的高度。
    ///
    /// 需求：图片加载不出来时别留一大块空白，占位高度不超过行高的 2 倍。
    private static let missingLineCount: CGFloat = 2

    /// 原因见 `MarkdownBlock` 里 `nonisolated deinit` 的注释：
    /// 隔离 deinit 一旦嵌套就会踩 Swift 6.2 运行时的野指针 free。
    nonisolated deinit {}

    init(markdownSource: String,
         imageURL: URL,
         maxWidth: CGFloat,
         maxHeight: CGFloat,
         lineHeight: CGFloat,
         placeholderColor: UIColor) {
        self.markdownSource = markdownSource
        self.imageURL = imageURL
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.lineHeight = lineHeight
        self.placeholderColor = placeholderColor
        super.init(data: nil, ofType: nil)

        if let image = ImageLoader.shared.loadSynchronously(imageURL) {
            // 本地图片同步就能拿到，直接用真实尺寸排版，不会有跳动
            loadedImage = image
            apply(image: image, notifyHost: false)
        } else if imageURL.isFileURL {
            // 本地文件在渲染这一刻就能确定读不出来（不存在 / 不是图片格式），
            // 那就别先撑一大块再缩回去，直接收成小占位
            markAsMissing(notifyHost: false)
        } else {
            // 网络图片先按 16:9 占位；加载完要么换成真实尺寸，要么换成失败小占位
            bounds = CGRect(x: 0, y: 0,
                            width: maxWidth,
                            height: min(maxHeight, maxWidth * Self.loadingAspectRatio))
        }
    }

    required init?(coder: NSCoder) {
        // 我们只在内存里构造，不从 storyboard 解档
        fatalError("ImageAttachment 不支持从 coder 解档")
    }

    // MARK: 加载

    /// 开始加载（重复调用只会真正加载一次）。
    /// - parameter host: 加载完尺寸变了，需要通过它通知 TextKit 重新排版
    func loadIfNeeded(host: MarkdownAttachmentHost?) {
        // 只有传进来的非空时才更新，避免用 nil 把宿主清掉
        if let host { self.host = host }
        // 本地文件已经在 init 里判过一次了，失败就别再白跑一趟
        guard !didStartLoading, !isMissing else { return }
        didStartLoading = true

        ImageLoader.shared.load(imageURL) { [weak self] image in
            guard let self else { return }
            if let image {
                self.loadedImage = image
                self.apply(image: image, notifyHost: true)
            } else {
                // 网络 404 / 下载失败：把加载中的大占位收成小占位，别留一大块空白
                self.markAsMissing(notifyHost: true)
            }
        }
    }

    /// 图片确定加载不出来：把占位收小，并画一个「图没了」的标记。
    ///
    /// 之前失败时什么都不做 —— attachment 会停在加载中的 16:9 尺寸上，
    /// 而且 `image` 是 nil，屏幕上就是**一大块空白**，看不出这儿本来该有张图。
    private func markAsMissing(notifyHost: Bool) {
        guard !isMissing else { return }
        isMissing = true
        didStartLoading = true

        // 高度 = 2 行正文，但也不能超过图片自己的高度上限
        let height = min(maxHeight, lineHeight * Self.missingLineCount)
        let width = min(maxWidth, height * Self.missingAspectRatio)
        let newBounds = CGRect(x: 0, y: 0, width: width, height: height)

        let sizeChanged = newBounds != bounds
        bounds = newBounds
        image = Self.missingImage(size: newBounds.size, color: placeholderColor)
        // 尺寸变了要通知 TextKit 重排，否则行高还停在老占位上
        if notifyHost, sizeChanged { host?.invalidateLayout(for: self) }
    }

    /// 按真实图片尺寸更新 bounds，并把图片交给 TextKit 去画
    private func apply(image: UIImage, notifyHost: Bool) {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }

        // 等比缩放塞进容器，但不放大（scale 上限 1.0）
        let scale = min(maxWidth / size.width, maxHeight / size.height, 1.0)
        let newBounds = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)

        let sizeChanged = newBounds != bounds
        bounds = newBounds
        self.image = image
        if notifyHost, sizeChanged { host?.invalidateLayout(for: self) }
    }

    // MARK: 占位图

    /// 画一张「图片加载不出来」的小占位图：虚线圆角框 + 中间一个照片小图标。
    ///
    /// ### 为什么必须画点东西
    /// `NSTextAttachment.image` 为 nil 时，它只占位置、什么都不画 ——
    /// 用户看到的就是一段说不清多高的空白，不知道这儿其实有张图没加载出来。
    private static func missingImage(size: CGSize, color: UIColor) -> UIImage? {
        // 太小就没法画了（比如行高被调成 0 的极端情况），直接放弃，不至于崩
        guard size.width > 2, size.height > 2 else { return nil }

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            // 往里缩 1 点，虚线边框才不会被裁掉一半
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            let frame = UIBezierPath(roundedRect: rect,
                                     cornerRadius: min(6, size.height * 0.16))

            // 极淡的底色：告诉用户「这儿有个东西」，但不抢正文的注意力
            color.withAlphaComponent(0.10).setFill()
            frame.fill()

            // 虚线边框：实线会被误认成一张真图片，虚线才像「这里缺了东西」
            context.cgContext.saveGState()
            context.cgContext.setLineDash(phase: 0, lengths: [4, 3])
            color.withAlphaComponent(0.5).setStroke()
            frame.lineWidth = 1
            frame.stroke()
            context.cgContext.restoreGState()

            drawPhotoIcon(in: rect, color: color.withAlphaComponent(0.55))
        }
    }

    /// 在 `rect` 正中画一个「照片」小图标（方框 + 太阳 + 山），让人一眼看出这是图片位。
    private static func drawPhotoIcon(in rect: CGRect, color: UIColor) {
        // 图标只占框内 44% 宽，画太大就显得笨重
        let iconWidth = min(rect.width * 0.44, rect.height * 0.62)
        let iconHeight = iconWidth * 0.78
        let iconRect = CGRect(x: rect.midX - iconWidth / 2,
                              y: rect.midY - iconHeight / 2,
                              width: iconWidth,
                              height: iconHeight)

        // 照片的外框
        let box = UIBezierPath(roundedRect: iconRect, cornerRadius: 1.5)
        box.lineWidth = 1
        color.setStroke()
        box.stroke()

        // 右上角一个小太阳（圆点）
        let sunDiameter = iconWidth * 0.16
        color.setFill()
        UIBezierPath(ovalIn: CGRect(x: iconRect.minX + iconWidth * 0.18,
                                    y: iconRect.minY + iconHeight * 0.18,
                                    width: sunDiameter,
                                    height: sunDiameter)).fill()

        // 下面一座山：从左下爬到中间最高点，再落回右下，闭合成实心三角
        let mountain = UIBezierPath()
        mountain.move(to: CGPoint(x: iconRect.minX + iconWidth * 0.08,
                                  y: iconRect.maxY - iconHeight * 0.16))
        mountain.addLine(to: CGPoint(x: iconRect.minX + iconWidth * 0.45,
                                     y: iconRect.minY + iconHeight * 0.52))
        mountain.addLine(to: CGPoint(x: iconRect.maxX - iconWidth * 0.08,
                                     y: iconRect.maxY - iconHeight * 0.16))
        mountain.close()
        mountain.fill()
    }
}
