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

    /// 用户敲了回车，列表续写要接管时返回 `false`（系统就不再插字符了）。
    ///
    /// ### 为什么这里破例拦截 —— 主文件顶部明明写着「不在 `shouldChangeTextIn` 里拦截」
    /// 那条规矩针对的是**普通字符输入**：在那里自己接管会绕过输入法的 marked text 机制，中文拼音输入会直接坏掉。
    /// 回车是唯一的例外，而且例外得很安全：
    /// - 输入法组合期间明确不接管（`applyListContinuationForNewline` 里第一道闸就是 `markedTextRange == nil`），
    ///   组合中的回车是「确认候选词」，交给系统照旧处理；
    /// - 列表续写必须**在字符插进去之前**定下来 —— 等系统插完再 diff 回写就变成两步编辑，
    ///   撤销栈记成两条，按一次 ⌘Z 只退掉标记、换行还留着（详见 `MarkdownTextView+ListContinuation.swift` 的顶部注释）。
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard text == "\n", let editor = self.textView, editor === textView else { return true }
        return !editor.applyListContinuationForNewline(at: range.location)
    }

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
