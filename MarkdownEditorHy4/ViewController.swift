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

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        setupEditor()
        setupStatusLabel()
        setupToolbar()
        loadSampleDocument()
        observeKeyboard()
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
        editor.setMarkdown(text)
        refreshStatus()
    }

    private func loadSampleMarkdown() -> String? {
        guard let url = Bundle.main.url(forResource: "sample", withExtension: "md") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func refreshStatus() {
        statusLabel.text = "块数 \(editor.documentStore.blocks.count) · 源码 \(editor.markdownSource.utf16.count) 字符 · 渲染 \(editor.documentStore.renderedLength) 字符"
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
