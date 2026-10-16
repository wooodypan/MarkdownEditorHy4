//
//  MarkdownMoveLineTests.swift
//  MarkdownEditorHy4Tests
//
//  ⌥↑ / ⌥↓ 把光标所在的这一行整行搬家（VS Code 那一套）。
//
//  ### 守的是哪条规矩
//  动的是**源码的两行**，不是光标：交换之后光标还得待在原来那一行上、停在第几列也不变。
//  另外守一件容易写错的小事 —— 每行末尾那个换行属于「槽位」，不跟着内容一起搬，所以「文档最后一行没有换行」这种情形也得搬对（不然两行会粘成一行的样子）。
//
//  ### 后半截守的是「按键怎么接到手」
//  Mac 上 ⌥↑ / ⌥↓ 默认被系统当「跳到上/下一段」，会抢在 `UIKeyCommand` 前面把事件吃掉（真机上就是按了没反应）。
//  修法是给这两条命令开 `wantsPriorityOverSystemBehavior`，再在 `pressesBegan` 里兜一道。
//  两条路共用同一份「认键」逻辑（`MoveLineKey`），它是整数进整数出，所以这里照样测得着。
//

import XCTest
import UIKit
@testable import MarkdownEditorHy4

@MainActor
final class MarkdownMoveLineTests: XCTestCase {

    // MARK: - 小工具

    private func makeEditor(_ markdown: String) -> MarkdownTextView {
        let textView = MarkdownTextView(markdown: markdown)
        textView.frame = CGRect(x: 0, y: 0, width: 420, height: 800)
        let window = UIWindow(frame: textView.frame)
        window.addSubview(textView)
        window.makeKeyAndVisible()
        textView.layoutIfNeeded()
        textView.setNeedsLayout()
        textView.layoutIfNeeded()
        return textView
    }

    /// 把光标放到**源码**的 `offset` 上（源码坐标要翻译成渲染坐标，编辑器自己才有这套换算）
    private func placeCaret(_ textView: MarkdownTextView, atSource offset: Int) {
        let rendered = textView.documentStore.renderedCaret(forSourceOffset: offset)
        textView.selectedRange = NSRange(location: min(rendered, (textView.text as NSString).length), length: 0)
    }

    /// 光标现在停在源码的哪一个字符前
    private func sourceCaret(_ textView: MarkdownTextView) -> Int {
        textView.documentStore.sourceCaret(forRenderedOffset: textView.selectedRange.location)
    }

    // MARK: - 下移 / 上移

    /// ⌥↓：和下面那一行交换
    func testMoveDownSwapsWithNextLine() {
        let tv = makeEditor("- 1\n- 2\n- 3\n")
        placeCaret(tv, atSource: 4)          // 光标在第二行 `- 2` 的行首
        tv.moveCurrentLineDown()
        XCTAssertEqual(tv.markdownSource, "- 1\n- 3\n- 2\n", "第二行该换到第三行下面")
    }

    /// ⌥↑：和上面那一行交换
    func testMoveUpSwapsWithPreviousLine() {
        let tv = makeEditor("- 1\n- 2\n- 3\n")
        placeCaret(tv, atSource: 8)          // 光标在第三行 `- 3` 的行首
        tv.moveCurrentLineUp()
        XCTAssertEqual(tv.markdownSource, "- 1\n- 3\n- 2\n", "第三行该换到第二行上面")
    }

    /// 光标跟着这一行走：搬完之后它还该停在同一行的同一个位置（源码第 8 个字符前，也就是新的第二行行首）
    func testCaretFollowsTheMovedLine() {
        let tv = makeEditor("- 1\n- 2\n- 3\n")
        placeCaret(tv, atSource: 8)
        tv.moveCurrentLineUp()
        XCTAssertEqual(sourceCaret(tv), 4, "光标该跟着 `- 3` 走到新的第二行，而不是留在原来的行号上")
    }

    /// 光标在行的中间：列号也要保住（`- 3` 里的 `3` 前面）
    func testCaretKeepsItsColumn() {
        let tv = makeEditor("- 1\n- 2\n- 3\n")
        placeCaret(tv, atSource: 10)         // `- 3` 的那个 `3` 前面
        tv.moveCurrentLineUp()
        XCTAssertEqual(tv.markdownSource, "- 1\n- 3\n- 2\n")
        XCTAssertEqual(sourceCaret(tv), 6, "还该停在 `3` 前面（换到新位置上的同一列）")
    }

    /// 已经在第一行：再按 ⌥↑ 什么都不该发生
    func testMoveUpAtFirstLineDoesNothing() {
        let tv = makeEditor("- 1\n- 2\n")
        placeCaret(tv, atSource: 0)
        tv.moveCurrentLineUp()
        XCTAssertEqual(tv.markdownSource, "- 1\n- 2\n", "第一行上面没有行可换")
    }

    /// 已经在最后一行：再按 ⌥↓ 什么都不该发生
    func testMoveDownAtLastLineDoesNothing() {
        let tv = makeEditor("- 1\n- 2\n")
        placeCaret(tv, atSource: 4)
        tv.moveCurrentLineDown()
        XCTAssertEqual(tv.markdownSource, "- 1\n- 2\n", "最后一行下面没有行可换")
    }

    /// 文件末尾没有换行这种情形也要搬对 —— 换行符属于槽位，不跟着内容走
    func testMoveUpKeepsNewlinesWhenLastLineHasNoTrailingNewline() {
        let tv = makeEditor("AAA\nBBB")
        placeCaret(tv, atSource: 4)          // 光标在第二行 BBB（这一行结尾没有换行）
        tv.moveCurrentLineUp()
        XCTAssertEqual(tv.markdownSource, "BBB\nAAA", "两行换了位置，换行还在中间，末尾也没有多出空行")
    }

    /// 下移时下一行是最后一行、没有换行：同样不许把两行粘在一起
    func testMoveDownKeepsNewlinesWhenNextLineHasNoTrailingNewline() {
        let tv = makeEditor("AAA\nBBB")
        placeCaret(tv, atSource: 0)
        tv.moveCurrentLineDown()
        XCTAssertEqual(tv.markdownSource, "BBB\nAAA", "换行留在中间，AAA 变成没有行尾换行的最后一行")
    }

    /// 搬的是源码，不是渲染出来的富文本 —— 标题这类带语法标记的行整行一起走
    func testMoveCarriesTheWholeLineIncludingItsMarker() {
        let tv = makeEditor("# 标题\n正文\n")
        placeCaret(tv, atSource: 6)          // 第二行「正文」
        tv.moveCurrentLineUp()
        XCTAssertEqual(tv.markdownSource, "正文\n# 标题\n", "标题那一行的 `#` 跟着整行走，不该留在原地")
    }

    // MARK: - 认键（两条通道共用的那份判据）

    private let altBit = MarkdownTextView.MoveLineKey.alternateBit
    private let cmdBit = MarkdownTextView.MoveLineKey.commandBit
    private let ctrlBit = MarkdownTextView.MoveLineKey.controlBit
    private let upUsage = MarkdownTextView.MoveLineKey.upArrowUsage
    private let downUsage = MarkdownTextView.MoveLineKey.downArrowUsage

    /// 认出来的方向写成 -1 / 1 好断言（省得给枚举再配一次 Equatable）
    private func delta(of key: MarkdownTextView.MoveLineKey?) -> Int? { key?.delta }

    private func match(_ keyCode: Int, _ flags: Int) -> Int? {
        delta(of: MarkdownTextView.MoveLineKey.matching(keyCode: keyCode, modifierFlags: flags))
    }

    /// ⌥↑ 认成「和上一行换」
    func testOptionUpArrowIsRecognized() {
        XCTAssertEqual(match(upUsage, altBit), -1)
    }

    /// ⌥↓ 认成「和下一行换」
    func testOptionDownArrowIsRecognized() {
        XCTAssertEqual(match(downUsage, altBit), 1)
    }

    /// 单按 ↑ / ↓ 不算：那是「挪一下光标」，系统在管
    func testBareArrowIsLeftAlone() {
        XCTAssertNil(match(upUsage, 0), "没按 ⌥ 就别抢")
        XCTAssertNil(match(downUsage, 0))
    }

    /// ⌘↑ / ⌃↑ 是系统自己的组合，不许被我们半路吃掉
    func testCommandOrControlArrowIsLeftAlone() {
        XCTAssertNil(match(upUsage, cmdBit))
        XCTAssertNil(match(upUsage, ctrlBit))
        XCTAssertNil(match(upUsage, altBit | cmdBit), "⌥⌘↑ 另有含义，不该被当成搬行")
    }

    /// ⌥ + 别的键（比如 ⌥B）不算
    func testOptionWithOtherKeyIsLeftAlone() {
        XCTAssertNil(match(11, altBit))
    }

    /// 认出来之后真的会去搬行（两条通道调用的也是这一个方法）
    func testPerformMoveLineMovesWhenKeyMatches() {
        let tv = makeEditor("- 1\n- 2\n- 3\n")
        placeCaret(tv, atSource: 8)
        XCTAssertTrue(tv.performMoveLineIfMatched(keyCode: upUsage, modifierFlags: altBit), "认出来并且搬成了，按键该被吞掉")
        XCTAssertEqual(tv.markdownSource, "- 1\n- 3\n- 2\n")
    }

    /// 已经在首行：认出来了但搬不动 —— 返回 false，好让按键还给系统（按下去至少还有系统那套行为）
    func testPerformMoveLineReportsFalseWhenNothingMoved() {
        let tv = makeEditor("- 1\n- 2\n")
        placeCaret(tv, atSource: 0)
        XCTAssertFalse(tv.performMoveLineIfMatched(keyCode: upUsage, modifierFlags: altBit), "搬不动就该放行")
        XCTAssertEqual(tv.markdownSource, "- 1\n- 2\n")
    }

    /// 不是这两个键：既不动源码，也返回 false
    func testPerformMoveLineIgnoresOtherKeys() {
        let tv = makeEditor("- 1\n- 2\n")
        placeCaret(tv, atSource: 0)
        XCTAssertFalse(tv.performMoveLineIfMatched(keyCode: upUsage, modifierFlags: cmdBit))
        XCTAssertFalse(tv.performMoveLineIfMatched(keyCode: 11, modifierFlags: altBit))
        XCTAssertEqual(tv.markdownSource, "- 1\n- 2\n")
    }

    /// 只读模式下 ⌥↑ 也要放行：搬不动，别把系统那套「跳到上一段」也一起吞了
    func testPerformMoveLineIsIgnoredWhenReadOnly() {
        let tv = makeEditor("- 1\n- 2\n")
        placeCaret(tv, atSource: 4)
        tv.isReadOnly = true
        XCTAssertFalse(tv.performMoveLineIfMatched(keyCode: upUsage, modifierFlags: altBit))
        XCTAssertEqual(tv.markdownSource, "- 1\n- 2\n", "只读模式下源码一个字都不该变")
    }

    /// Mac 上那两条命令必须开「优先级高于系统行为」—— 不开就会被系统的段落跳转让掉（真机上就是按了没反应）
    func testMoveLineCommandsWinOverSystemBehavior() {
        let commands = MarkdownTextView.markdownKeyCommands.filter { $0.modifierFlags == .alternate }
        XCTAssertEqual(commands.count, 2, "⌥↑ / ⌥↓ 两条命令")
        for command in commands {
            XCTAssertTrue(command.wantsPriorityOverSystemBehavior,
                          "「\(command.title)」要抢在系统文本编辑命令前面，否则 Mac 上按了没反应")
        }
    }
}
