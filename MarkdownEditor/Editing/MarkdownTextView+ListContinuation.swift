//
//  MarkdownTextView+ListContinuation.swift
//  MarkdownEditorHy4
//
//  Enter 键的列表续写：列表项里按回车自动带出下一项的标记；空列表项上按回车退出列表。
//
//  ### 为什么单独一个文件
//  和 `+Formatting` / `+Search` 一个道理：主文件已经一千七百多行，这套「认列表 → 构造复合编辑 → 落光标」的逻辑自成一坨，挪出来好读也好改。
//
//  ### 为什么必须在字符插进去**之前**决定
//  「先让系统插换行、再 diff 回写补一个 `- `」看着更简单，但那是**两步编辑**：
//  撤销栈里会记成两条，用户按一次 ⌘Z 只退掉 `- `、换行还留在那儿，连按几次 ⌘Z 才会发现「撤销动的东西和刚才敲的不一样」。
//  这里一步把 `\n- ` 整体插进去，撤销就正好退回到按回车之前。
//

import UIKit

extension MarkdownTextView {

    /// 这次回车要不要由编辑器接管。
    ///
    /// 接管后返回 `true`，调用方（`MarkdownEditController`）据此让系统别再插字符。
    ///
    /// - parameter renderedLocation: 光标在**渲染文本**里的位置（`shouldChangeTextIn` 传进来的那个）
    /// - returns: `true` = 文档已经改好了；`false` = 不管，让系统正常插一个换行
    func applyListContinuationForNewline(at renderedLocation: Int) -> Bool {
        // 输入法正在组合：这次回车是「确认候选词」，不是要换行 —— 一律不接管，否则中文拼音输入会坏掉
        guard markedTextRange == nil else { return false }
        // 有选区时按回车是「把选中的替换成一个换行」，不做续写（免得插出谁也没想到的标记）
        guard selectedRange.length == 0 else { return false }

        let sourceCaret = documentStore.sourceCaret(forRenderedOffset: renderedLocation)
        // 代码块里的 `- 1` 只是代码文本，不是列表 —— 在那里回车绝不能自动加标记
        guard !isInsideCodeBlock(sourceOffset: sourceCaret) else { return false }
        guard let continuation = MarkdownListContinuation.parse(source: documentStore.sourceDocument,
                                                                caret: sourceCaret) else { return false }

        switch continuation.action {
        case .insertItem(let prefix):
            // 自己接管 = 系统不会替我们记撤销，得自己补一笔（理由见主文件 `performUndoableModelEdit` 的注释）
            performUndoableModelEdit(actionName: "列表续写") {
                applyEdit(renderedRange: NSRange(location: renderedLocation, length: 0),
                          replacementText: "\n" + prefix,
                          alreadyAppliedToTextStorage: false)
            }

        case .exitList(let markerRange):
            // 退出列表删的是源码里的一段（`- ` 那几个字符），而编辑管线只认渲染坐标，所以先换算一次
            guard let rendered = documentStore.renderedRange(forSourceRange: markerRange) else { return false }
            performUndoableModelEdit(actionName: "退出列表") {
                applyEdit(renderedRange: rendered,
                          replacementText: "",
                          alreadyAppliedToTextStorage: false)
            }
        }
        return true
    }

    /// 光标（源码偏移）是不是落在代码块里。
    ///
    /// ### 为什么要有这道闸
    /// 续写判定看的是**源码文本**（行首有没有 `- `），它分不清「列表项」和「代码里恰好写着 `- xxx`」。
    /// 在 shell / yaml 代码块里敲一行 `- 参数` 再回车，凭空多出一个 `- `，代码就废了。
    private func isInsideCodeBlock(sourceOffset: Int) -> Bool {
        for block in documentStore.blocks where !block.isHidden {
            let range = block.sourceRange
            guard sourceOffset >= range.location, sourceOffset < NSMaxRange(range) else { continue }
            return block.isCodeBlock
        }
        return false
    }
}
