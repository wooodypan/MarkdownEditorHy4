//
//  MarkdownDocumentViewController+Format.swift
//  MarkdownEditorHy4
//
//  菜单里的「格式化文档」：整理排版 → 存一份到临时目录 → 让用户对着差异看一眼 → 确认后才覆盖原文件。
//
//  大白话：像把稿子交给编辑收拾一遍，但收拾完先给你看"改了哪些行"，你点头才真正换掉原文件。
//
//  ### 为什么非要先预览再覆盖
//  整理要动的是整篇内容，一旦写错文件名或者规则有漏，用户攒了半年的笔记就当场变成别的样子。中间隔一层「你确认了吗」，用户至少能看见绿色和红色分别是哪些行。
//
//  ### 后悔药
//  覆盖之前先往历史里存一版（显示成「格式化前备份」），撤销栈则整个清掉 —— 撤销栈里那些账是按改之前的文本记的范围，套到新文本上会错位。
//

import UIKit

extension MarkdownDocumentViewController {

    // MARK: 入口

    /// 菜单里的「格式化文档」。
    ///
    /// 整理整篇要解析两遍语法树，大文档在主线程跑会卡一下，所以丢到后台算，算完再回主线程弹预览。
    func formatDocument() {
        guard let url = openedFileURL else {
            showAlert(title: "还没有可以整理的文件",
                      message: "这一页没有对应到磁盘上的文件。整理的结果要写回原文件，先把它存成一份文件再来。")
            return
        }

        let source = editor.markdownSource
        guard !source.isEmpty else {
            flashStatus("文档还是空的，没有可以整理的内容")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome: FormatOutcome
            do {
                outcome = .success(try MarkdownDocumentFormatter.format(source))
            } catch {
                outcome = .failure(error.localizedDescription)
            }

            DispatchQueue.main.async {
                guard let self else { return }
                switch outcome {
                case .success(let formatted):
                    self.presentFormatPreview(formatted, original: source, for: url)
                case .failure(let message):
                    self.showAlert(title: "没法整理这份文档", message: message)
                }
            }
        }
    }

    /// 后台线程算完的结果。
    ///
    /// 错误直接换成一句文案带回来：`Error` 能不能跨线程传要看具体类型，换成 String 最省心。
    private enum FormatOutcome {
        case success(String)
        case failure(String)
    }

    // MARK: 预览

    /// 把整理结果摆到预览页上，让用户先看差异。
    private func presentFormatPreview(_ formatted: String, original: String, for url: URL) {
        guard formatted != original else {
            flashStatus("已经很整齐了，没有需要调整的地方")
            return
        }

        do {
            // 用户要求先落一份到沙盒的 tmp 目录：预览页只是个界面，真出问题时（比如预览期间 App 被打断）磁盘上还留着一份整理好的内容
            try writeFormatPreviewToTemporaryDirectory(formatted)
        } catch {
            showAlert(title: "整理结果存不下来",
                      message: "临时目录写不进去：\(error.localizedDescription)")
            return
        }

        let preview = DocumentVersionPreviewController(titleText: "格式化预览",
                                                       content: formatted,
                                                       currentContent: original,
                                                       contentLabel: "格式化结果",
                                                       actionName: "应用")
        preview.onConfirm = { [weak self, weak preview] in
            guard let self, let preview else { return }
            self.confirmApplyingFormat(formatted, from: preview, to: url)
        }
        // 这一页是整页弹上来的第一页，导航栏里没有系统那颗返回，得自己给一个出口。
        // 历史那条路是 push 进导航栈的，靠系统的返回就够了，所以按钮加在这儿而不是预览页自己身上
        preview.navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "关闭",
            primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            })
        present(UINavigationController(rootViewController: preview), animated: true)
    }

    /// 真正覆盖之前再问一句。
    ///
    /// 预览页上那个「应用」已经是一次确认了，这里多问一句是因为接下来的动作会整篇覆盖磁盘上的文件，而且用户很可能是在预览页滚到一半顺手点的。
    private func confirmApplyingFormat(_ formatted: String,
                                       from preview: UIViewController,
                                       to url: URL) {
        let alert = UIAlertController(
            title: "用整理后的内容覆盖？",
            message: "「\(url.lastPathComponent)」会被整篇换成整理后的内容。\n\n"
                   + "改之前的模样会先存一版历史（列表里显示成「格式化前备份」），想反悔可以去「历史版本」里找回来。",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "覆盖", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.applyFormattedText(formatted, to: url)
            // 覆盖完把预览页收掉，让用户直接看到整理之后的样子
            self.dismiss(animated: true)
        })
        preview.present(alert, animated: true)
    }

    /// 把整理结果换进编辑器，并写回原文件。
    private func applyFormattedText(_ text: String, to url: URL) {
        // 先留后悔药：这一步存的是"改之前的模样"
        snapshotHistory(reason: .beforeFormat)

        // 撤销栈里的账是按改之前那段文本记的范围，套到新文本上会错位，整个清掉
        editor.resetUndoHistory()
        editor.setMarkdown(text)
        // 整篇内容都换了：大纲里折叠过的标题、查找框里找到的位置全属于上一版
        outlineView.resetFolding()
        searchCoordinator.rerunIfNeeded()
        refreshStatus()
        updateWindowTitle()

        // 用户点的是「覆盖」，所以顺手写盘，不留下"已修改未保存"的状态
        guard writeCurrentSource(to: url) else { return }
        // 上面那句提示说的是"已保存"，这里补一句说清楚是整理过之后的版本
        flashStatus("已格式化并保存 \(url.lastPathComponent)")
    }

    /// 把整理结果写一份到沙盒的 tmp 目录。
    ///
    /// - Returns: 写好的文件地址（现在只用来确认写成功了，没别的地方读它）
    @discardableResult
    private func writeFormatPreviewToTemporaryDirectory(_ text: String) throws -> URL {
        // 固定文件名：同一个预览反复生成时直接覆盖，不在 tmp 里攒一堆同名兄弟姐妹。
        // tmp 由系统自己回收，不需要我们清
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("格式化预览.md")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
