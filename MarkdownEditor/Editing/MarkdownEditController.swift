//
//  MarkdownEditController.swift
//  MarkdownEditorHy4
//
//  编辑控制层：监听 UITextView 的变化，派发增量渲染任务
//

import UIKit

/// 编辑控制器：UITextView 的 delegate，负责「文本变了 → 增量重新解析渲染」。
///
/// 它本身不做解析也不做渲染，只负责在正确的时机把活派给 `MarkdownDocumentStore`。
final class MarkdownEditController: NSObject, UITextViewDelegate {
    weak var textView: MarkdownTextView?

    /// ### 为什么这里要显式写 `nonisolated deinit`（很重要，别删）
    /// 和 `MarkdownPasteboardController` 同一个坑（详细堆栈见那个文件）：
    /// 本类是编辑器的一个存储属性，编辑器释放时会销毁它；只要销毁发生在
    /// RunLoop / dispatch 回调里，隔离 deinit 就会踩 Swift 6.2 运行时的野指针 free。
    /// 本类只持有一个 `weak` 引用，不需要主线程状态，所以声明成 `nonisolated`。
    nonisolated deinit {}

    /// 文本内容变了（敲键、自动纠错、粘贴、删除…都会走到这里）
    func textViewDidChange(_ textView: UITextView) {
        self.textView?.reconcileFromTextChange()
    }

    /// 光标变了。顺便在这里补一次排版：
    /// 输入法组合期间我们是跳过的，等组合结束（markedTextRange 变成 nil）再补上。
    ///
    /// 另外把光标位置报给大纲（目录高亮跟着光标走）。上报内部做了防抖，
    /// 拖光标 / 快速打字时不会把目录刷爆。
    func textViewDidChangeSelection(_ textView: UITextView) {
        self.textView?.reconcileIfNeededAfterComposition()
        self.textView?.publishOutlineCursor()
    }

    /// 结束编辑时也补一次，防止输入法相关的改动漏掉
    func textViewDidEndEditing(_ textView: UITextView) {
        self.textView?.reconcileFromTextChange()
    }
}
