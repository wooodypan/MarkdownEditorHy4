//
//  ViewController.swift
//  MarkdownEditorHy4
//
//  Demo 界面：一个 markdown 编辑器 + 右上角「⋯」弹出菜单（重载 / 分块 / 源码 / 校验）
//  Mac 上另有菜单栏：文件 > 新建 / 打开 / 存储
//

import UIKit
// 菜单里的「打开」要判断哪些文件可选，用到 UTType.markdown
import UniformTypeIdentifiers

final class ViewController: UIViewController {

    // MARK: 子视图

    private let editor = MarkdownTextView()
    private let statusLabel = UILabel()
    /// 右上角的「⋯」按钮。点一下弹出菜单，里面装着重载 / 分块 / 源码 / 校验
    private let menuButton = UIButton(type: .system)
    private var bottomConstraint: NSLayoutConstraint?

    /// 当前打开的文件。nil 表示在看内置示例文档，这类内容不能保存回磁盘
    private var openedFileURL: URL?
    /// 上次打开/保存时的源码快照，和它比对就知道有没有改动
    private var savedSource = ""
    /// 有没有未保存的改动
    private var isDirty: Bool { editor.markdownSource != savedSource }
    /// 临时提示（比如「已保存」）显示完要恢复成常规状态栏
    private var statusResetWork: DispatchWorkItem?
    /// 是不是「新建」出来的空白草稿。用来区分它和内置示例文档 —— 两者都没有关联文件，
    /// 但标题该显示「未命名」还是「示例文档」不一样
    private var isNewDraft = false
    /// 当前弹出的文件选择器是不是「另存为」（导出）用途，回调里要靠它区分两种面板
    private var isExportingDocument = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // 顺序有讲究：菜单按钮要先建好，编辑器的顶部约束要挂在它下面
        setupMenuButton()
        setupEditor()
        setupStatusLabel()
        // 冷启动时文件 URL 已经在 MarkdownDocumentOpener 里等着了，先取出来用；
        // 没有外部文件才退回到内置示例文档
        if let url = MarkdownDocumentOpener.shared.takePendingURL() {
            openDocument(at: url)
        } else {
            loadSampleDocument()
        }
        observeKeyboard()
        observeDocumentOpenRequests()
        observeEditorChanges()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 窗口（windowScene）要等 view 挂上去才有，标题在这里补一次
        updateWindowTitle()
    }

    // MARK: 界面搭建

    private func setupEditor() {
        editor.translatesAutoresizingMaskIntoConstraints = false
        // 粘贴的图片存到 Documents，bundle 里的 sample.png 走兜底逻辑也能找到
        editor.imageBaseURL = FileManager.default.urls(for: .documentDirectory,
                                                       in: .userDomainMask).first
        view.addSubview(editor)

        bottomConstraint = editor.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        NSLayoutConstraint.activate([
            // 顶部对齐菜单按钮的下边，这样按钮不会盖住正文第一行
            editor.topAnchor.constraint(equalTo: menuButton.bottomAnchor, constant: 2),
            editor.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomConstraint!
        ])
    }

    private func setupStatusLabel() {
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 1
        statusLabel.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.9)
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            statusLabel.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    /// 页面右上角的「⋯」按钮。
    /// 原来这里是贴着状态栏的一排四个按钮（校验 / 源码 / 分块 / 重载），
    /// 现在全部收进弹出菜单，只留一个按钮，编辑区域更清爽
    private func setupMenuButton() {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "ellipsis.circle")
        config.preferredSymbolConfigurationForImage =
            UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        // 图标本身不大，靠内边距把可点区域撑到 40x40，手指和鼠标都好点
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)

        menuButton.configuration = config
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        // 关键的一行：设为 true 后，单击就弹菜单，不需要长按等右键那一套
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.menu = makeActionMenu()
        menuButton.accessibilityLabel = "更多操作"
        view.addSubview(menuButton)

        NSLayoutConstraint.activate([
            menuButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 2),
            menuButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            menuButton.widthAnchor.constraint(equalToConstant: 40),
            menuButton.heightAnchor.constraint(equalToConstant: 40)
        ])
    }

    /// 组装弹出菜单里的条目。
    /// 每个 UIAction 就是一行：标题 + 图标 + 点击后要执行的代码
    private func makeActionMenu() -> UIMenu {
        let actions: [UIAction] = [
            UIAction(title: "重载", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                // 回到内置示例文档，重新渲染一遍
                self?.reloadSample()
            },
            UIAction(title: "分块", image: UIImage(systemName: "square.grid.2x2")) { [weak self] _ in
                // 弹窗列出当前所有块的源码 / 渲染区间
                self?.showBlocks()
            },
            UIAction(title: "源码", image: UIImage(systemName: "doc.plaintext")) { [weak self] _ in
                // 新开一页展示当前 markdown 源码
                self?.showSource()
            },
            UIAction(title: "校验", image: UIImage(systemName: "checkmark.seal")) { [weak self] _ in
                // 全选复制，比对复制出来的文本和源码是否逐字符一致
                self?.verifyRoundTrip()
            }
        ]
        return UIMenu(children: actions)
    }

    // MARK: 载入示例文档

    private func loadSampleDocument() {
        let text = loadSampleMarkdown() ?? """
        # 找不到示例文档

        `Resources/sample.md` 没被打包进 App，先看这段兜底内容。

        - 列表项一
        - 列表项二

        ![示例图片](sample.png)
        """
        isNewDraft = false
        openedFileURL = nil
        savedSource = text
        editor.imageBaseURL = FileManager.default.urls(for: .documentDirectory,
                                                       in: .userDomainMask).first
        editor.setMarkdown(text)
        refreshStatus()
        updateWindowTitle()
    }

    // MARK: 新建 / 打开（Mac 菜单入口）

    /// ⌘N：新建一份空白文档。
    /// 这时还没有对应的磁盘文件，第一次按 ⌘S 会弹「另存为」让你挑保存位置
    @objc func newDocument() {
        confirmDiscardIfNeeded { [weak self] canContinue in
            guard let self, canContinue else { return }
            self.isNewDraft = true
            self.openedFileURL = nil
            self.savedSource = ""
            // 新文档还没存到磁盘，粘贴的图片先放 Documents，等另存为之后不影响
            self.editor.imageBaseURL = FileManager.default.urls(for: .documentDirectory,
                                                               in: .userDomainMask).first
            self.editor.setMarkdown("")
            self.refreshStatus()
            self.updateWindowTitle()
            self.flashStatus("已新建空白文档")
        }
    }

    /// ⌘O：弹系统文件选择器，挑一个 .md / .txt 打开
    @objc func openDocumentFromPanel() {
        confirmDiscardIfNeeded { [weak self] canContinue in
            guard let self, canContinue else { return }
            self.isExportingDocument = false
            // UTType 里没有预置的 markdown 常量，只能按扩展名推一个；
            // 推不出来就退回纯文本 —— md 本来就是纯文本，还能正常选到
            let markdownType = UTType(filenameExtension: "md") ?? .plainText
            // asCopy: false = 原地打开、不复制副本，这样 ⌘S 才能写回原文件
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [markdownType, .plainText],
                                                        asCopy: false)
            picker.delegate = self
            picker.allowsMultipleSelection = false
            self.present(picker, animated: true)
        }
    }

    /// 接管系统菜单自带的「文件 > 打开…」(⌘O)。
    ///
    /// Catalyst 的「文件」菜单里本来就有一条 Open…，它的 action 是 `open:`。
    /// 我们不去新增一条同快捷键的菜单项（UIKit 遇到重复快捷键会抛异常崩溃），
    /// 而是实现这个方法 —— 系统那条菜单项会顺着响应链找到这里。
    /// 方法名必须叫 `open`（selector 就是 `open:`），所以加了反引号
    @objc func `open`(_ sender: Any?) {
        openDocumentFromPanel()
    }

    /// 新建 / 打开都会顶掉当前内容，有未保存改动就先问一句。
    /// 回调传 true 表示可以继续，false 表示用户选了取消
    private func confirmDiscardIfNeeded(_ completion: @escaping (Bool) -> Void) {
        guard isDirty else {
            completion(true)
            return
        }
        let name = openedFileURL?.lastPathComponent ?? (isNewDraft ? "未命名文档" : "示例文档")
        let alert = UIAlertController(title: "还有改动没保存",
                                      message: "「\(name)」改了还没存，继续的话这部分改动就丢了。",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completion(false) })
        alert.addAction(UIAlertAction(title: "放弃改动", style: .destructive) { _ in completion(true) })
        present(alert, animated: true)
    }

    /// 没有关联文件时（刚「新建」的草稿）走「另存为」：把内容导出到用户挑的位置。
    /// 导出面板必须给一个真实文件，所以先把内容写到临时目录再交给系统复制过去
    private func presentSaveAsPanel() {
        let name = openedFileURL?.lastPathComponent ?? "未命名.md"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try editor.markdownSource.write(to: tempURL, atomically: true, encoding: .utf8)
        } catch {
            showAlert(title: "保存失败", message: error.localizedDescription)
            return
        }
        isExportingDocument = true
        // asCopy: true = 复制过去，临时文件留着也无所谓
        let picker = UIDocumentPickerViewController(forExporting: [tempURL], asCopy: true)
        picker.delegate = self
        present(picker, animated: true)
    }

    // MARK: 打开 / 保存外部 .md 文件

    /// 打开 Finder 传进来的文件（右键「打开方式」、双击、拖到 Dock 图标都走这里）
    private func openDocument(at url: URL) {
        do {
            let text = try loadText(from: url)
            isNewDraft = false
            openedFileURL = url
            savedSource = text
            // 关键：md 里的图片多是相对路径，基准目录要指向文件所在目录，否则图片全裂
            editor.imageBaseURL = url.deletingLastPathComponent()
            editor.setMarkdown(text)
            refreshStatus()
            updateWindowTitle()
        } catch {
            showAlert(title: "打不开文件",
                      message: "\(url.lastPathComponent)\n\n\(error.localizedDescription)")
        }
    }

    private func loadText(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        // 按 UTF-8 解码。遇到不合法的字节会换成替换字符，总比整篇打不开强
        return String(decoding: data, as: UTF8.self)
    }

    /// ⌘S：写回原文件。
    /// 没有关联文件时（内置示例文档 / 刚「新建」的草稿）分两条路走：
    ///   - Mac：弹「另存为」面板，让新建的草稿能落地成文件
    ///   - iOS：弹个提示，说明得先从外部打开一个文件
    /// 这里刻意不加 private —— 菜单栏的「存储」项要引用它的 selector，
    /// 修饰符是 private 的话，AppDelegate 里 `#selector(...)` 取不到
    @objc func saveDocument() {
        guard let url = openedFileURL else {
            #if targetEnvironment(macCatalyst)
            presentSaveAsPanel()
            #else
            showAlert(title: "没有可保存的文件",
                      message: "现在看的是内置示例文档。在 Finder 里右键 .md 文件 →「打开方式」→ 选本 App，打开后就能用 ⌘S 存回原文件。")
            #endif
            return
        }

        let source = editor.markdownSource
        do {
            try source.write(to: url, atomically: true, encoding: .utf8)
            savedSource = source
            refreshStatus()
            updateWindowTitle()
            flashStatus("已保存 \(url.lastPathComponent)")
        } catch {
            showAlert(title: "保存失败", message: "\(url.lastPathComponent)\n\n\(error.localizedDescription)")
        }
    }

    #if targetEnvironment(macCatalyst)
    /// Mac 专属：把 ⌘N / ⌘O / ⌘S 注册成键盘快捷键。
    ///
    /// 整段用 `#if targetEnvironment(macCatalyst)` 包住，iOS 上这段代码
    /// 根本不参与编译，所以 iOS 构建完全不受影响。
    ///
    /// 说明：AppDelegate 里往菜单栏加了同样三个条目。
    /// 两者不会打架 —— macOS 先走菜单的快捷键匹配，菜单命中后就不再往下传，
    /// 这里只是菜单那条路走不通时的兜底。
    override var keyCommands: [UIKeyCommand]? {
        let new = UIKeyCommand(title: "新建",
                               action: #selector(newDocument),
                               input: "n",
                               modifierFlags: .command)
        let open = UIKeyCommand(title: "打开",
                                action: #selector(openDocumentFromPanel),
                                input: "o",
                                modifierFlags: .command)
        let save = UIKeyCommand(title: "存储",
                                action: #selector(saveDocument),
                                input: "s",
                                modifierFlags: .command)
        return [new, open, save]
    }
    #endif

    /// 界面上要显示的名字：有文件就用文件名；没有文件则区分「新建的草稿」和「内置示例」
    private var documentDisplayName: String {
        if let url = openedFileURL { return url.lastPathComponent }
        return isNewDraft ? "未命名" : "示例文档"
    }

    private func updateWindowTitle() {
        let name = documentDisplayName
        let suffix = isDirty ? " — 已修改" : ""
        title = name
        // Mac Catalyst：windowScene.title 就是窗口标题栏上显示的文字
        view.window?.windowScene?.title = name + suffix
    }

    private func observeDocumentOpenRequests() {
        // 热启动：App 已经在跑，用户又双击了一个 md 文件
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(documentOpenRequested(_:)),
            name: .markdownDocumentOpenRequested,
            object: nil
        )
    }

    @objc private func documentOpenRequested(_ notification: Notification) {
        guard let url = notification.object as? URL else { return }
        openDocument(at: url)
    }

    private func observeEditorChanges() {
        // 内容一变就刷新窗口标题上的「已修改」标记
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(editorContentChanged),
            name: UITextView.textDidChangeNotification,
            object: editor
        )
    }

    @objc private func editorContentChanged() {
        updateWindowTitle()
    }

    private func loadSampleMarkdown() -> String? {
        guard let url = Bundle.main.url(forResource: "sample", withExtension: "md") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func refreshStatus() {
        let name = documentDisplayName
        let dirty = isDirty ? " · 已修改（⌘S 保存）" : ""
        statusLabel.text = "\(name)\(dirty) · 块数 \(editor.documentStore.blocks.count) · 源码 \(editor.markdownSource.utf16.count) 字符 · 渲染 \(editor.documentStore.renderedLength) 字符"
    }

    /// 状态栏上闪一句提示，1.5 秒后自动恢复成常规信息
    private func flashStatus(_ message: String) {
        statusResetWork?.cancel()
        statusLabel.text = message
        let work = DispatchWorkItem { [weak self] in self?.refreshStatus() }
        statusResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    // MARK: 按钮动作

    /// 核心验收：全选复制出来的文本，必须和源码逐字符一致
    @objc private func verifyRoundTrip() {
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
                : firstDifferenceDescription(source, copied),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
        refreshStatus()
    }

    /// 显示当前源码
    @objc private func showSource() {
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
    @objc private func showBlocks() {
        let lines = editor.documentStore.blocks.enumerated().map { index, block in
            "[\(index)] \(block.kindDescription.padding(toLength: 22, withPad: " ", startingAt: 0)) src=\(block.sourceRange.location)+\(block.sourceRange.length) render=\(block.renderedRange.location)+\(block.renderedRange.length)"
        }
        let alert = UIAlertController(title: "共 \(editor.documentStore.blocks.count) 个块",
                                      message: lines.joined(separator: "\n"),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }

    @objc private func reloadSample() {
        loadSampleDocument()
    }

    @objc private func dismissPresented() {
        dismiss(animated: true)
    }

    // MARK: 键盘避让

    private func observeKeyboard() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardFrameChanged(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
    }

    @objc private func keyboardFrameChanged(_ notification: Notification) {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        // 键盘收起时 frame.origin.y 会等于屏幕高度，此时不需要避让
        let overlap = max(0, view.bounds.height - frame.origin.y)
        bottomConstraint?.constant = -overlap
        view.layoutIfNeeded()
    }

    // MARK: 小工具

    /// 弹提示。冷启动时 view 还没挂到窗口上，present 会无效，所以延后一帧再弹
    private func showAlert(title: String, message: String) {
        let presentBlock = { [weak self] in
            guard let self else { return }
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default))
            self.present(alert, animated: true)
        }
        if view.window == nil {
            DispatchQueue.main.async(execute: presentBlock)
        } else {
            presentBlock()
        }
    }

    /// 找出两段文本第一处不同的位置，方便定位问题
    private func firstDifferenceDescription(_ source: String, _ copied: String) -> String {
        let sourceChars = Array(source)
        let copiedChars = Array(copied)
        for index in 0..<min(sourceChars.count, copiedChars.count) where sourceChars[index] != copiedChars[index] {
            let start = max(0, index - 15)
            let sourceSnippet = String(sourceChars[start..<min(sourceChars.count, index + 15)])
            let copiedSnippet = String(copiedChars[start..<min(copiedChars.count, index + 15)])
            return "第 \(index) 个字符不同\n\n源码: …\(sourceSnippet)…\n复制: …\(copiedSnippet)…"
        }
        return "长度不同：源码 \(sourceChars.count) 字符，复制出来 \(copiedChars.count) 字符"
    }
}

// MARK: 文件选择器回调
//
// 「打开」和「另存为」用的是同一个 UIDocumentPickerViewController，
// 靠 isExportingDocument 区分这次弹的是哪一种，回调里分开处理。

extension ViewController: UIDocumentPickerDelegate {

    /// 用户挑完了（打开：挑中的文件；另存为：挑中的保存位置）
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }

        if isExportingDocument {
            // 「另存为」：系统已经把临时文件复制到这个位置了，把它记成当前文件
            isExportingDocument = false
            isNewDraft = false
            openedFileURL = url
            savedSource = editor.markdownSource
            refreshStatus()
            updateWindowTitle()
            flashStatus("已保存 \(url.lastPathComponent)")
        } else {
            // 「打开」：走正常的读文件流程（换基准目录、重建分块那些都在里面）
            openDocument(at: url)
        }
    }

    /// 用户点了取消：什么都不改，保持原样，顺手把导出标记清掉
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        isExportingDocument = false
    }
}
