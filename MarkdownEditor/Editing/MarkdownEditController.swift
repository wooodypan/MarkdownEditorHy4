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

    /// 文本内容变了（敲键、自动纠错、粘贴、删除…都会走到这里）
    func textViewDidChange(_ textView: UITextView) {
        self.textView?.reconcileFromTextChange()
    }

    /// 光标变了。顺便在这里补一次排版：
    /// 输入法组合期间我们是跳过的，等组合结束（markedTextRange 变成 nil）再补上。
    func textViewDidChangeSelection(_ textView: UITextView) {
        self.textView?.reconcileIfNeededAfterComposition()
    }

    /// 结束编辑时也补一次，防止输入法相关的改动漏掉
    func textViewDidEndEditing(_ textView: UITextView) {
        self.textView?.reconcileFromTextChange()
    }
}
