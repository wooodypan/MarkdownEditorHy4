//
//  MarkdownPasteboardController.swift
//  MarkdownEditorHy4
//
//  剪贴板层：拦截 copy / cut / paste
//
//  ### 核心原则
//  **渲染出来的 NSAttributedString 和「复制时应该产出的文本」是两套独立数据。**
//  永远不要指望从 attributed string 反推源码，一律查 `MarkdownDocumentStore` 的源码映射表。
//

import UIKit

/// 剪贴板控制器。
final class MarkdownPasteboardController {

    weak var textView: MarkdownTextView?

    /// ### 为什么这里要显式写 `nonisolated deinit`（很重要，别删）
    /// 原因和 `MarkdownBlock` 里那段注释完全一样：app target 开了
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，本类的隐式 deinit 也是
    /// 「actor 隔离的 deinit」，Swift 6.2 运行时释放它时会先切回 MainActor 执行器
    /// （`swift_task_deinitOnExecutorImpl`），而这个函数维护的 task-local 作用域
    /// 在某些释放时机下会 free 一个野指针 → `malloc: pointer being freed was not allocated`。
    ///
    /// ### 实测踩坑（ASan 堆栈，2026-09-13）
    /// 本类是 `MarkdownTextView` 的一个存储属性，编辑器释放时会依次销毁各 ivar。
    /// 只要这次释放发生在 RunLoop / dispatch 回调里，就会崩：
    /// ```
    /// free ← TaskLocal::StopLookupScope::~StopLookupScope
    ///      ← swift_task_deinitOnExecutorImpl
    ///      ← MarkdownPasteboardController.__deallocating_deinit
    ///      ← MarkdownTextView.__ivar_destroyer ← UITextView dealloc
    /// ```
    /// 本类只持有一个 `weak` 引用，销毁时不需要任何主线程状态，所以声明成
    /// `nonisolated` 不走执行器切换，从根上避免。
    ///
    /// ⚠️ 同类问题请一并检查 `MarkdownEditController`、`FoldAnchorInfo`
    /// —— 凡是「非 UI 的类」都应该带上这一行。
    nonisolated deinit {}

    // MARK: 复制

    /// 把选区对应的 **markdown 源码** 放进剪贴板。
    /// - returns: `true` 表示已经接管，`false` 表示没接管（交给系统默认行为）
    @discardableResult
    func handleCopy() -> Bool {
        guard let textView else { return false }

        let range = textView.selectedRange
        guard range.length > 0 else { return false }

        // 查映射表还原源码：
        // - 图片占位符 → 还原成 ![alt](url)
        // - 列表圆点   → 还原成源码里的 `- `
        // - 纯装饰字符 → 直接跳过
        let source = textView.documentStore.sourceText(forRenderedRange: range)
        guard !source.isEmpty else { return false }

        // 只放纯文本，不放富文本。
        // 这样粘到任何编辑器（VS Code、微信、备忘录…）拿到的都是 markdown 源码，
        // 不会出现「粘过去变成一张图」的情况。
        UIPasteboard.general.string = source
        return true
    }

    // MARK: 粘贴

    /// 剪贴板里是图片时，存成本地文件并插入 `![](路径)` 源码。
    /// - returns: `true` 表示已处理
    @discardableResult
    func handlePasteImage() -> Bool {
        guard let textView, let image = UIPasteboard.general.image else { return false }
        guard let directory = attachmentsDirectory() else { return false }

        let fileName = "pasted-\(UUID().uuidString).png"
        let fileURL = directory.appendingPathComponent(fileName)
        guard let data = image.pngData() else { return false }

        do {
            try data.write(to: fileURL)
        } catch {
            return false
        }

        // 图片插入同样走「可撤销」那条路：图片源码渲染出来是一个附件字符，
        // 和源码长度差得更远，交给系统记撤销会残留一串字符
        textView.insertMarkdownSourceUndoably("![粘贴的图片](attachments/\(fileName))")
        return true
    }

    /// 剪贴板里的纯文本（没有、或者只有空白时返回 nil）。
    ///
    /// ### 为什么只「取出来」，不在这里插入
    /// 插入必须走 `MarkdownTextView.insertMarkdownSourceUndoably` ——
    /// 粘贴不能交给系统自带的撤销（原因见那个方法的注释：渲染文本和源码长度不等，
    /// 系统的撤销记录会失效，撤销后残留尾巴）。而「怎么插入」是编辑器的职责，
    /// 剪贴板层只负责把内容取出来，别越界。
    func pasteboardText() -> String? {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return nil }
        return text
    }

    /// 图片存放目录：`Documents/attachments`
    private func attachmentsDirectory() -> URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = documents.appendingPathComponent("attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
