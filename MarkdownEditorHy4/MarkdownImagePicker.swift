//
//  MarkdownImagePicker.swift
//  MarkdownEditorHy4
//
//  插入图片时用的选择器：从照片图库 / 「文件」里挑一张图，读出原始字节交给调用方。
//
//  ### 为什么选择器在 App 层，而不是编辑器组件里
//  `MarkdownEditor/` 将来要单独开源，它只提供 `insertImageMarkdown(path:alt:)`：
//  「路径给我，我插进正文」。图从相册来、从「文件」来、还是应用自己拍照，
//  界面和权限都归使用它的 App，组件里一行 `PHPicker` 都不该有。
//
//  ### 这里只做「挑」，不做「存」也不做「插」
//  挑出来的字节原样交回去；存到哪个目录（当前笔记旁边 / assets / 指定文件夹）
//  由 `ImageAssetStore` 按设置决定，写进正文则由文档页调编辑器完成。
//

import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// 挑一张图片：先让用户选来源，再弹对应的系统面板。
final class MarkdownImagePicker: NSObject {

    /// 挑中的一张图。
    struct Selection {
        /// 图片的原始字节（不重新编码，动图 / HEIC 都能原样保留）
        let data: Data
        /// 原来叫什么名字（照片图库不一定有；「文件」里挑的有）。落盘起名时用得上
        let originalFileName: String?
    }

    /// 从谁身上弹面板（weak：展示期间由 UIKit 持有，别绕成循环引用）
    private weak var presenter: UIViewController?

    /// 挑完 / 取消后回调。只回调一次；`nil` 表示用户取消（或者没读出数据）
    private var completion: ((Selection?) -> Void)?

    init(presenter: UIViewController, completion: @escaping (Selection?) -> Void) {
        self.presenter = presenter
        self.completion = completion
        super.init()
    }

    // MARK: 入口

    /// 开始挑图：先弹一个来源菜单（照片图库 / 文件）。
    ///
    /// ### 为什么要有「文件」这一项
    /// Mac 上用户的图片大多躺在 Finder 里，照片图库不一定同步过；
    /// iPhone 上「文件」也是从 iCloud 云盘拿图的正经入口。两边都给，谁都用得上。
    func start() {
        guard let presenter else {
            finish(nil)
            return
        }

        let sheet = UIAlertController(title: "插入图片", message: nil, preferredStyle: .actionSheet)
        // 等菜单真正收下去再弹下一个面板：在 action 回调里当场 present 的话，
        // 有时会撞上「上一个面板还没 dismiss 完」，系统直接拒绝这次展示（看着就是点了没反应）
        sheet.addAction(UIAlertAction(title: "从照片图库选择", style: .default) { [weak self] _ in
            DispatchQueue.main.async { self?.presentPhotoPicker() }
        })
        sheet.addAction(UIAlertAction(title: "从文件选择", style: .default) { [weak self] _ in
            DispatchQueue.main.async { self?.presentDocumentPicker() }
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
            self?.finish(nil)
        })

        // iPad / Mac 上 action sheet 必须以 popover 形式出现，得给个锚点。
        // 摆在屏幕中央、不留箭头 —— 这是「没有具体按钮可指」时的通行做法
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX,
                                        y: presenter.view.bounds.midY,
                                        width: 1,
                                        height: 1)
            popover.permittedArrowDirections = []
        }
        presenter.present(sheet, animated: true)
    }

    // MARK: 照片图库

    private func presentPhotoPicker() {
        guard let presenter else { return finish(nil) }

        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 1
        // 要「现在这份」而不是系统转好的解码图：HEIC / PNG / GIF 都原样拿出来
        configuration.preferredAssetRepresentationMode = .current

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        presenter.present(picker, animated: true)
    }

    /// 从 `NSItemProvider` 里按「第一个真正的图片类型」读原始字节。
    ///
    /// 直接问 `UTType.image`（抽象类型）有时拿不到：provider 只登记了
    /// `public.heic` / `public.jpeg` 这些具体类型。先挑一个符合 `public.image` 的具体类型再问，
    /// 才能拿到用户相册里那张图本来的格式。
    private func loadImageData(from provider: NSItemProvider, completion: @escaping (Data?) -> Void) {
        let typeIdentifier = provider.registeredTypeIdentifiers.first {
            UTType($0)?.conforms(to: .image) == true
        } ?? UTType.image.identifier

        provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
            completion(data)
        }
    }

    // MARK: 文件

    private func presentDocumentPicker() {
        guard let presenter else { return finish(nil) }

        // `asCopy: true`：要的是拷进来的一份副本。这样读完就能用，不用在整个生命周期里
        // 攥着一枚安全作用域书签；用户那份原图也不会被我们误改
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        presenter.present(picker, animated: true)
    }

    // MARK: 收尾

    /// 结束这次挑选。`nil` = 取消 / 没拿到数据。
    ///
    /// 只回调一次：面板关闭的回调可能和取消路径前后脚都来，
    /// 不去重的话文档页会把一次挑选处理两遍
    private func finish(_ selection: Selection?) {
        guard let completion else { return }
        self.completion = nil
        completion(selection)
    }
}

// MARK: - 照片图库回调

extension MarkdownImagePicker: PHPickerViewControllerDelegate {

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)

        guard let provider = results.first?.itemProvider else {
            // 用户没选就关了面板：不算错误，什么都不做
            finish(nil)
            return
        }

        loadImageData(from: provider) { [weak self] data in
            // `loadDataRepresentation` 的回调不保证在主线程；文档页那边要碰编辑器，切回主线程再交
            DispatchQueue.main.async {
                guard let self else { return }
                guard let data, !data.isEmpty else {
                    self.finish(nil)
                    return
                }
                self.finish(Selection(data: data, originalFileName: provider.suggestedName))
            }
        }
    }
}

// MARK: - 文件选择回调

extension MarkdownImagePicker: UIDocumentPickerDelegate {

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first,
              let data = try? Data(contentsOf: url),
              !data.isEmpty else {
            finish(nil)
            return
        }
        finish(Selection(data: data, originalFileName: url.lastPathComponent))
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish(nil)
    }
}
