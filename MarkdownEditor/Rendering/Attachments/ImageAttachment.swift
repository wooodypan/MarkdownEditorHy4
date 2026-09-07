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
final class ImageAttachment: NSTextAttachment {
    /// 对应的 markdown 源码，比如 `![示例图片](sample.png)`
    let markdownSource: String
    let imageURL: URL

    /// 加载完成后通知宿主刷新布局
    weak var host: MarkdownAttachmentHost?

    /// 已经加载好的图片（本地图片在 init 里就有了）
    private(set) var loadedImage: UIImage?

    /// 正在显示这个 attachment 的 imageView，异步加载完要回填
    private weak var displayImageView: UIImageView?

    private let maxWidth: CGFloat
    private let maxHeight: CGFloat
    private var didStartLoading = false
    /// 占位用的期望宽高比（图片没加载出来时先占个位置）
    private static let placeholderAspectRatio: CGFloat = 9.0 / 16.0

    /// 原因见 `MarkdownBlock` 里 `nonisolated deinit` 的注释：
    /// 隔离 deinit 一旦嵌套就会踩 Swift 6.2 运行时的野指针 free。
    nonisolated deinit {}

    init(markdownSource: String, imageURL: URL, maxWidth: CGFloat, maxHeight: CGFloat) {
        self.markdownSource = markdownSource
        self.imageURL = imageURL
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        super.init(data: nil, ofType: nil)

        // 本地图片同步就能拿到，直接用真实尺寸排版，不会有跳动
        if let image = ImageLoader.shared.loadSynchronously(imageURL) {
            loadedImage = image
            apply(image: image, notifyHost: false)
        } else {
            // 网络图片先用 16:9 占位，加载完再改尺寸
            bounds = CGRect(x: 0, y: 0,
                            width: maxWidth,
                            height: min(maxHeight, maxWidth * Self.placeholderAspectRatio))
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
        // 只有传进来的非空时才更新，避免 view provider 用 nil 把宿主清掉
        if let host { self.host = host }
        guard !didStartLoading else { return }
        didStartLoading = true

        ImageLoader.shared.load(imageURL) { [weak self] image in
            guard let self, let image else { return }
            self.loadedImage = image
            self.displayImageView?.image = image
            self.apply(image: image, notifyHost: true)
        }
    }

    /// view provider 把真正显示的 imageView 登记进来，异步加载完成后回填图片
    func registerDisplayImageView(_ imageView: UIImageView?) {
        displayImageView = imageView
    }

    /// 按真实图片尺寸更新 bounds
    private func apply(image: UIImage, notifyHost: Bool) {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }

        // 等比缩放塞进容器，但不放大（scale 上限 1.0）
        let scale = min(maxWidth / size.width, maxHeight / size.height, 1.0)
        let newBounds = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)

        let sizeChanged = newBounds != bounds
        bounds = newBounds
        if notifyHost, sizeChanged { host?.invalidateLayout(for: self) }
    }

    // MARK: TextKit 2 的 view provider

    override func viewProvider(for parentView: UIView?,
                               location: any NSTextLocation,
                               textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        ImageAttachmentViewProvider(
            textAttachment: self,
            parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager,
            location: location
        )
    }
}

/// 图片的 view provider：真正干活的是一个 `UIImageView`。
private final class ImageAttachmentViewProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 6
        imageView.backgroundColor = .secondarySystemBackground
        self.view = imageView

        guard let attachment = textAttachment as? ImageAttachment else { return }

        // 本地图片同步就有，直接显示；网络图片等异步回调回填
        imageView.image = attachment.loadedImage
        attachment.registerDisplayImageView(imageView)
        attachment.loadIfNeeded(host: nil)
    }
}
