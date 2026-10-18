//
//  MarkdownDocumentViewController+DocumentActions.swift
//  MarkdownEditorHy4
//
//  菜单背后那些动作：新建和打开、校验、源码、分块、重载、导出、键盘避让，还有文件选择器的回调。
//
//  ⚠️ 从 `MarkdownDocumentViewController.swift` 拆出来的：代码原样搬过来，只去掉了 `private`
//  （Swift 的 private 只在本文件可见，跨文件就调不到）。
//

import UIKit
import UniformTypeIdentifiers
import MultiTabController

extension MarkdownDocumentViewController {

    // MARK: 新建 / 打开（Mac 菜单入口）

    /// ⌘N：新建一份空白文档。
    ///
    /// 这个动作不在这一页里完成，它只是把「想新建」报出去，由左侧栏（它管着文档目录和路由）去磁盘上建文件，并在右侧开一个新 Tab。
    ///
    /// ### 为什么绕这一圈
    /// 现在每一份文档都是目录里的一个真文件。如果在这里就地清空当前 Tab，用户正在看的那份文件会从界面上被顶掉，而新文档又没落盘，左侧栏和右侧就对不上了。
    @objc func newDocument() {
        NotificationCenter.default.post(name: DocumentsWorkspace.newDocumentRequestedNotification,
                                        object: nil)
    }
    /// ⌘O：弹系统文件选择器，挑一个 .md / .txt 打开，在新 Tab 里开，不会把当前这一页顶掉。
    ///
    /// 这里不像以前那样先问「当前这份改了还没存要不要放弃」：打开新 Tab 根本不碰当前这一份，没什么可放弃的。
    @objc func openDocumentFromPanel() {
        // UTType 里没有预置的 markdown 常量，只能按扩展名推一个；
        // 推不出来就退回纯文本：md 本来就是纯文本，还能正常选到
        let markdownType = UTType(filenameExtension: "md") ?? .plainText
        // asCopy: false = 原地打开、不复制副本，这样 ⌘S 才能写回原文件
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [markdownType, .plainText],
                                                    asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    /// 接管系统菜单自带的「文件 > 打开…」(⌘O)。
    ///
    /// Catalyst 的「文件」菜单里本来就有一条 Open…，它的 action 是 `open:`。
    /// 不新增一条同快捷键的菜单项（UIKit 遇到重复快捷键会抛异常崩溃），而是实现这个方法，系统那条菜单项会顺着响应链找到这里。
    /// 方法名必须叫 `open`（selector 就是 `open:`），所以加了反引号
    @objc func `open`(_ sender: Any?) {
        openDocumentFromPanel()
    }

    /// 有未保存改动时先问一句。回调传 true 表示可以继续，false 表示用户选了取消
    func confirmDiscardIfNeeded(_ completion: @escaping (Bool) -> Void) {
        guard isDirty else {
            completion(true)
            return
        }
        let name = openedFileURL?.lastPathComponent ?? "未命名文档"
        let alert = UIAlertController(title: "还有改动没保存",
                                      message: "「\(name)」改了还没存，继续的话这部分改动就丢了。",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completion(false) })
        alert.addAction(UIAlertAction(title: "放弃改动", style: .destructive) { _ in completion(true) })
        present(alert, animated: true)
    }
}

extension MarkdownDocumentViewController {

    // MARK: 按钮动作

    /// 核心验收：全选复制出来的文本，必须和源码逐字符一致
    @objc func verifyRoundTrip() {
        editor.becomeFirstResponder()
        editor.selectAll(nil)
        editor.copy(nil)               // 走我们接管的 copy → 查映射表还原源码
        editor.selectedRange = NSRange(location: editor.selectedRange.location, length: 0)

        let copied = UIPasteboard.general.string ?? ""
        let source = editor.markdownSource
        let passed = copied == source

        let alert = UIAlertController(
            title: passed ? "✅ 复制结果和源码完全一致" : "❌ 复制结果和源码不一致",
            message: passed
                ? "共 \(source.utf16.count) 个字符，逐字符比对通过。\n粘到任何编辑器里都是 markdown 源码。"
                : DocumentTextDiff.firstDifferenceDescription(source, copied),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
        refreshStatus()
    }

    /// 显示当前源码
    @objc func showSource() {
        let textViewController = UIViewController()
        let textView = UITextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.text = editor.markdownSource
        textView.isEditable = false
        textViewController.view.addSubview(textView)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: textViewController.view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: textViewController.view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: textViewController.view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: textViewController.view.bottomAnchor)
        ])

        textViewController.title = "源码"
        textViewController.navigationItem.rightBarButtonItem =
            UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(dismissPresented))
        let navigation = UINavigationController(rootViewController: textViewController)
        present(navigation, animated: true)
    }

    /// 显示当前分块情况（调试增量解析用）
    @objc func showBlocks() {
        let lines = editor.documentStore.blocks.enumerated().map { index, block in
            "[\(index)] \(block.kindDescription.padding(toLength: 22, withPad: " ", startingAt: 0)) src=\(block.sourceRange.location)+\(block.sourceRange.length) render=\(block.renderedRange.location)+\(block.renderedRange.length)"
        }
        let alert = UIAlertController(title: "共 \(editor.documentStore.blocks.count) 个块",
                                      message: lines.joined(separator: "\n"),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }

    /// 「重载」：丢掉未保存的改动，从磁盘把这份文件重新读一遍。
    ///
    /// ### 为什么要有这个动作
    /// 这份文件可能被别的程序改过（用户用别的编辑器存过、iCloud 同步下来新版本），而编辑器手里还是打开那一刻的内容。重载就是以磁盘上的为准，重新读一遍。
    ///
    /// ### 为什么要先确认
    /// 它会盖掉当前未保存的改动。这不是刷新，是丢弃并重读，所以必须先问一句。
    @objc func reloadFromDisk() {
        guard let url = openedFileURL else {
            showAlert(title: "没有可重载的文件", message: "这一页没有对应到磁盘上的文件。")
            return
        }
        confirmDiscardIfNeeded { [weak self] canContinue in
            guard let self, canContinue else { return }
            guard let text = DocumentsWorkspace.read(url) else {
                self.showAlert(title: "重载失败",
                               message: "「\(url.lastPathComponent)」读不出来，可能被移走或者没有访问权限。")
                return
            }
            // 走和「换文档」同一条路：图片基准目录、大纲重置、滚动位置都一并处理
            self.apply(PPContentItem(id: url.path,
                                     title: DocumentsWorkspace.displayName(for: url),
                                     body: text,
                                     category: "Documents"))
            self.flashStatus("已重载 \(url.lastPathComponent)")
        }
    }

    @objc func dismissPresented() {
        dismiss(animated: true)
    }

    // MARK: 导出

    /// 点「导出」时交给 `DocumentExporter` 的那份内容。
    ///
    /// ### 为什么点的时候现取，而不是建菜单时取
    /// 菜单是装配时建好的一个实例，一直用着它。内容若在建菜单那一刻就定下来，用户改了半天的稿再点导出，导出的还是打开菜单之前那一版。
    ///
    /// 空文档在这里就拦下（`DocumentExporter` 那边还会再兜一次底）：空白文档导出来没有意义。
    func exportSource() -> DocumentExportSource? {
        let source = editor.markdownSource
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showAlert(title: "导出失败", message: "当前文档是空的，没有可导出的内容。")
            return nil
        }
        return DocumentExportSource(
            markdown: source,
            displayName: documentDisplayName,
            fileURL: openedFileURL,
            // 正开着这份文档，图片就让编辑器自己画，画出来就是屏幕上看到的样子
            imageRenderer: { [weak self] in self?.editor.renderFullContentImage() }
        )
    }

    // MARK: 键盘避让

    func observeKeyboard() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardFrameChanged(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
    }

    @objc func keyboardFrameChanged(_ notification: Notification) {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        // 键盘收起时 frame.origin.y 会等于屏幕高度，此时不需要避让
        let overlap = max(0, view.bounds.height - frame.origin.y)
        bottomConstraint?.constant = -overlap
        view.layoutIfNeeded()
        // 键盘一动，上面那条工具条马上要出现或消失，顺手把撤销 / 重做的亮灭跟当前撤销栈对齐
        refreshKeyboardBarButtons()
    }
}

// MARK: 文件选择器回调
//
// 这个代理现在只剩「打开」（⌘O）这一条路：挑一份文件，交给左侧栏在新 Tab 里打开。
// 导出那半边（挑个位置存文件）已经搬进 `DocumentExporter`，它自己当面板的代理，这里不用再靠一个「这次是打开还是导出」的标记去猜（原来的 `isExportingFile` 就是干这个的）。

extension MarkdownDocumentViewController: UIDocumentPickerDelegate {

    /// 用户挑完了要打开哪份文件
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }

        // 走 MarkdownDocumentOpener 而不是自己去读，是为了顺带申请一次安全作用域（文件在工作目录之外时，不申请就写不回去）。它会把通知发出去，由左侧栏在新 Tab 里打开这份文件，当前这一页不动
        MarkdownDocumentOpener.shared.handle(url: url)
    }
}

