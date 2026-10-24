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
        guard let editor = self.textView, editor === textView else { return true }

        // 只读模式：一切字符改动都不许进（键盘输入、自动纠错、粘贴都先从这里过）。
        // 详见 `MarkdownTextView.isReadOnly` 的注释
        guard !editor.isReadOnly else { return false }

        guard text == "\n" else { return true }
        return !editor.applyListContinuationForNewline(at: range.location)
    }

    /// 文本内容变了（敲键、自动纠错、粘贴、删除…都会走到这里）
    func textViewDidChange(_ textView: UITextView) {
        self.textView?.reconcileFromTextChange()
        // 打字机模式：敲完这一下把光标拉回屏幕中间（里面自己判断开关、方向和时机）
        self.textView?.keepCaretNearScreenCenterIfNeeded()
    }

    /// 光标变了。顺便在这里补一次排版：
    /// 输入法组合期间我们是跳过的，等组合结束（markedTextRange 变成 nil）再补上。
    ///
    /// 另外把光标位置报给大纲（目录高亮跟着光标走）。上报内部做了防抖，
    /// 拖光标 / 快速打字时不会把目录刷爆。
    ///
    /// 打字机模式下还要把光标摆回屏幕中间：点另一行、按 ↑↓ 都只动光标不动文本，光靠 `textViewDidChange` 那条接不住（它只在内容真的变了时才响）。
    func textViewDidChangeSelection(_ textView: UITextView) {
        self.textView?.reconcileIfNeededAfterComposition()
        self.textView?.publishOutlineCursor()
        self.textView?.keepCaretNearScreenCenterIfNeeded()
    }

    /// 结束编辑时也补一次，防止输入法相关的改动漏掉
    func textViewDidEndEditing(_ textView: UITextView) {
        self.textView?.reconcileFromTextChange()
    }

    // MARK: 右键菜单

    /// 选中文字后的菜单里加一项「清除文本格式」。
    ///
    /// ### 为什么写在 delegate 里，而不是照方案文档写进 textView 子类
    /// 文档里那套示例把 `delegate` 设成 textView 自己；本项目的 delegate 是编辑控制器，文本变化、输入法补排、大纲上报全靠它，换掉等于把编辑管线拆了。
    /// 好在 iOS 16 起「自定义编辑菜单」本来就是 delegate 的活，放这里正合适。
    ///
    /// ### Mac 上走的是同一条路
    /// Catalyst 的右键菜单就是指针形态的编辑菜单（`UIEditMenuInteraction`），16 起同样会问这个方法；
    /// 不用再往 `buildMenu` 里插一份，否则菜单里会出现两个同名项。
    func textView(_ textView: UITextView,
                  editMenuForTextIn range: NSRange,
                  suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let editor = self.textView, editor === textView else {
            return UIMenu(children: suggestedActions)
        }
        // 没选中东西时不加；只读时一个字都不许改，也不摆这一项
        guard range.length > 0, !editor.isReadOnly else {
            return UIMenu(children: suggestedActions)
        }

        let action = UIAction(title: "清除文本格式") { [weak editor] _ in
            editor?.clearMarkdownFormatting()
        }
        // 选中的这段里没有能清的标记时置灰：菜单项一直都在（用户找得到），但不会点了没反应
        if !editor.canClearMarkdownFormatting {
            action.attributes = .disabled
        }
        return UIMenu(children: suggestedActions + [action])
    }
}
