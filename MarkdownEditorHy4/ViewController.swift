//
//  ViewController.swift
//  MarkdownEditorHy4
//
//  Demo 界面：一个 markdown 编辑器 + 一排验证按钮
//

import UIKit

final class ViewController: UIViewController {

    // MARK: 子视图

    private let editor = MarkdownTextView()
    private let statusLabel = UILabel()
    private var bottomConstraint: NSLayoutConstraint?

    /// 当前打开的文件。nil 表示在看内置示例文档，这类内容不能保存回磁盘
    private var openedFileURL: URL?
    /// 上次打开/保存时的源码快照，和它比对就知道有没有改动
    private var savedSource = ""
    /// 有没有未保存的改动
    private var isDirty: Bool { editor.markdownSource != savedSource }
    /// 临时提示（比如「已保存」）显示完要恢复成常规状态栏
    private var statusResetWork: DispatchWorkItem?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        setupEditor()
        setupStatusLabel()
        setupToolbar()
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
            editor.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
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

    private func setupToolbar() {
        let items: [(String, Selector)] = [
            ("校验", #selector(verifyRoundTrip)),
            ("源码", #selector(showSource)),
            ("分块", #selector(showBlocks)),
            ("重载", #selector(reloadSample))
        ]

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 8
        view.addSubview(stack)

        for (title, selector) in items {
            var config = UIButton.Configuration.bordered()
            config.title = title
            config.cornerStyle = .capsule
            let button = UIButton(configuration: config)
            button.addTarget(self, action: selector, for: .touchUpInside)
            stack.addArrangedSubview(button)
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),
            stack.heightAnchor.constraint(equalToConstant: 36)
        ])
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
        openedFileURL = nil
        savedSource = text
        editor.imageBaseURL = FileManager.default.urls(for: .documentDirectory,
                                                       in: .userDomainMask).first
        editor.setMarkdown(text)
        refreshStatus()
        updateWindowTitle()
    }

    // MARK: 打开 / 保存外部 .md 文件

    /// 打开 Finder 传进来的文件（右键「打开方式」、双击、拖到 Dock 图标都走这里）
    private func openDocument(at url: URL) {
        do {
            let text = try loadText(from: url)
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

    /// ⌘S：写回原文件。没打开外部文件时给个提示
    @objc private func saveDocument() {
        guard let url = openedFileURL else {
            showAlert(title: "没有可保存的文件",
                      message: "现在看的是内置示例文档。在 Finder 里右键 .md 文件 →「打开方式」→ 选本 App，打开后就能用 ⌘S 存回原文件。")
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

    override var keyCommands: [UIKeyCommand]? {
        // Mac 上的 ⌘S
        [UIKeyCommand(input: "s", modifierFlags: .command, action: #selector(saveDocument))]
    }

    private func updateWindowTitle() {
        let name = openedFileURL?.lastPathComponent ?? "示例文档"
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
        let name = openedFileURL?.lastPathComponent ?? "内置示例文档"
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
