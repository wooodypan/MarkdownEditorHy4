//
//  MarkdownDocumentViewController+FolderAccess.swift
//  MarkdownEditorHy4
//
//  文档所在文件夹没权限时：告诉用户，并带他去授权。
//

import UIKit
import UniformTypeIdentifiers

// MARK: - 提示与授权

extension MarkdownDocumentViewController {

    /// 文档在 App 沙盒外面、文件夹又没权限时，跟用户说一句。
    ///
    /// ### 为什么要主动说，而不是等图片坏了再让用户猜
    /// 图片读不到时渲染器不会报错，它会把 `![](./assets/x.png)` 原样当文字显示出来 ——
    /// 用户看到的是「图裂了」，第一反应是文件丢了或者 App 有 bug，根本想不到是权限。
    /// 粘贴图片更糟：存不进去就干脆什么都不发生，连一行字都没有。
    ///
    /// ### 一个文件夹只说一次
    /// 本页可能在多个 Tab 之间复用、切来切去都会走到这里。不拦的话每次切回来都弹一个框，用户要疯。
    func notifyIfFolderAccessMissing() {
        guard let url = openedFileURL else { return }
        // 页面还没进窗口时弹不出来（UIKit 会直接把这次 present 丢掉），等 viewDidAppear 那一次
        guard view.window != nil else { return }
        guard !DocumentFolderAccess.isAvailable(forDocumentAt: url) else { return }

        let key = url.deletingLastPathComponent().path
        guard !folderAccessNoticesShown.contains(key) else { return }
        folderAccessNoticesShown.insert(key)

        presentFolderAccessAlert(for: url)
    }

    /// 弹那个「这个文件夹读不到，要不要授权」的框。
    private func presentFolderAccessAlert(for documentURL: URL) {
        let folderName = documentURL.deletingLastPathComponent().lastPathComponent
        let missing = DocumentFolderAccess.unreadableImageCount(in: editor.markdownSource,
                                                                documentURL: documentURL)

        // 有图读不到和没图可读是两件事，分开说：用户最关心的是「我那些图是不是没了」
        var lines = ["「\(folderName)」在 App 的沙盒外面，打开这份文档时只拿到了它自己的访问权限，同一个文件夹里的图片没有。"]
        if missing > 0 {
            lines.append("现在有 \(missing) 张图片读不到，粘贴新图片也存不进去。")
        } else {
            lines.append("粘贴新图片会存不进去。")
        }
        lines.append("授权这个文件夹之后，图片就能正常显示，粘贴也能用。")

        let alert = UIAlertController(title: "图片没权限读取",
                                      message: lines.joined(separator: "\n"),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "授权文件夹", style: .default) { [weak self] _ in
            // 等这个框真的收下去再弹系统面板：在 action 回调里当场 present，UIKit 有时会说「上一个还没关完」直接拒绝，看着就是点了没反应
            DispatchQueue.main.async { self?.requestFolderAccess() }
        })
        alert.addAction(UIAlertAction(title: "以后再说", style: .cancel))
        present(alert, animated: true)
    }

    /// 让用户挑一次文档所在的文件夹，把它的通行证收下来。
    ///
    /// 为什么非得用户亲手挑：系统只给「用户自己点选过的东西」发通行证。
    /// 我们没法替用户把整个文件夹「申请」下来，只能把面板打开、默认停在那层目录上，让他点一下「打开」。
    @objc func requestFolderAccess() {
        guard let url = openedFileURL else {
            flashStatus("先打开一份文档")
            return
        }
        guard !DocumentFolderAccess.isAvailable(forDocumentAt: url) else {
            flashStatus("这个文件夹本来就能读写，不用授权")
            return
        }

        let directory = url.deletingLastPathComponent()
        folderAccessPicker = FolderAccessPicker(presenter: self, directory: directory) { [weak self] in
            guard let self else { return }
            self.folderAccessPicker = nil
            // 不看面板返回成功没成功，直接问「现在能不能读写」：用户可能挑错了目录（挑了子文件夹之类），
            // 那个目录确实拿到权限了，可这份文档的目录还是没有
            guard DocumentFolderAccess.isAvailable(forDocumentAt: self.openedFileURL) else {
                self.flashStatus("还是没权限，可能选错文件夹了，再试一次")
                return
            }
            self.reloadAfterFolderAccessGranted()
        }
        folderAccessPicker?.start()
    }

    /// 授权拿到了，整篇重渲染一遍，让图片真的去读一次。
    ///
    /// ### 为什么必须整篇重设，不能只刷图片
    /// 图片读不到时渲染器已经把那一行退化成了源码文字，那些位置根本没有图片附件。
    /// 只有重新渲染，图片才会被重新解析、重新挂上去。顺带把光标位置保住，用户正在读的地方不会被顶走。
    func reloadAfterFolderAccessGranted() {
        let caretSource = editor.documentStore.sourceCaret(forRenderedOffset: editor.selectedRange.location)
        editor.setMarkdown(editor.markdownSource)
        let caret = editor.documentStore.renderedCaret(forSourceOffset: caretSource)
        editor.selectedRange = NSRange(location: min(caret, (editor.text as NSString).length), length: 0)
        flashStatus("已授权，图片会重新加载")
    }
}

// MARK: - 选文件夹的面板

/// 让用户挑一个文件夹。
///
/// ### 为什么单独一个类，不直接让编辑页当 delegate
/// `MarkdownDocumentViewController` 早就实现了 `UIDocumentPickerDelegate`（⌘O 打开文档那条路），
/// 同一个类里再实现一遍 `documentPicker(_:didPickDocumentsAt:)` 会重复定义，编译直接过不去。
final class FolderAccessPicker: NSObject, UIDocumentPickerDelegate {

    private weak var presenter: UIViewController?
    /// 面板默认停在哪儿（文档所在的那层目录）
    private let directory: URL
    /// 用户挑完之后回调。取消也算结束，只是这时得自己再问一遍有没有权限
    private var completion: (() -> Void)?

    init(presenter: UIViewController, directory: URL, completion: @escaping () -> Void) {
        self.presenter = presenter
        self.directory = directory
        self.completion = completion
        super.init()
    }

    /// 打开面板。
    ///
    /// `asCopy: false`：要的是「访问权」，不是文件夹的副本 —— 拷一份到 App 里对「读原目录的图」毫无帮助。
    func start() {
        guard let presenter else { return finish() }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        // 直接停在文档所在的那层，用户少点几下
        picker.directoryURL = directory
        picker.delegate = self
        picker.allowsMultipleSelection = false
        presenter.present(picker, animated: true)
    }

    /// 只回调一次：面板关掉时系统可能连着来两个回调，重复回调会让编辑页重渲染两遍
    private func finish() {
        guard let completion else { return }
        self.completion = nil
        completion()
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if let picked = urls.first {
            // 先把通行证收下来，收没收到由调用方再查一次权限，不靠这个返回值下结论
            ExternalDocumentAccess.shared.takeFolderAccess(picked)
        }
        finish()
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish()
    }
}
