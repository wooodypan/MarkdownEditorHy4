//
//  MarkdownTextView+MoveLineKey.swift
//  MarkdownEditorHy4
//
//  ⌥↑ / ⌥↓ 这两个键的**认法**。
//
//  ### 搬行的动作不在这里
//  真正交换源码两行的是 `moveCurrentLine(by:)`（在 `MarkdownTextView+Formatting.swift`）。
//  这里只回答一个问题：这次按下的键是不是「⌥↑」或「⌥↓」。
//
//  ### 为什么单独抽出来
//  同一套判别要喂两条路：`UIKeyCommand`（主）和 `pressesBegan`（兜底，见主文件的重写）。
//  抽出来之后两条路共用一份判据，不会各写各的；而且它是整数进整数出，没有真键盘也能单测。
//

import UIKit

extension MarkdownTextView {

    /// ⌥↑ / ⌥↓ 这两个按键的判别。
    enum MoveLineKey {
        case up
        case down

        /// 搬几行：`-1` = 和上一行交换，`1` = 和下一行交换（跟 `moveCurrentLine(by:)` 一个意思）
        var delta: Int {
            switch self {
            case .up: return -1
            case .down: return 1
            }
        }

        /// ↑ / ↓ 的 HID 用途码（就是 `UIKey.keyCode` 报的那个数）。
        ///
        /// 认键码而不是字符：键盘布局和输入法都改不了它（德文键盘、中文输入法下按 ↑ 报的同样是 0x52），而 `characters` 这类字符属性在不同布局下会变，甚至被输入法直接吃掉。
        static let upArrowUsage = UIKeyboardHIDUsage.keyboardUpArrow.rawValue
        static let downArrowUsage = UIKeyboardHIDUsage.keyboardDownArrow.rawValue

        /// ⌥ / ⌘ / ⌃ 在 `UIKey.modifierFlags` 里占的位（写成常量是为了让单测也能拼出同样的组合）
        static let alternateBit = UIKeyModifierFlags.alternate.rawValue
        static let commandBit = UIKeyModifierFlags.command.rawValue
        static let controlBit = UIKeyModifierFlags.control.rawValue

        /// 这次按键是不是「⌥↑」或「⌥↓」；不是就返回 nil，意思是「不关我们的事，放行」。
        ///
        /// ### 为什么连 ⌘ / ⌃ 也要排掉
        /// ⌥⌘↑、⌃⌥↑ 在系统里另有含义（跳到文档开头之类），用户按它们时并没打算搬行。
        /// 只判「⌥ 按下没有」的话，这些组合会被我们半路吃掉，系统行为平白消失。
        static func matching(keyCode: Int, modifierFlags: Int) -> MoveLineKey? {
            guard modifierFlags & alternateBit != 0,
                  modifierFlags & commandBit == 0,
                  modifierFlags & controlBit == 0 else { return nil }
            switch keyCode {
            case upArrowUsage: return .up
            case downArrowUsage: return .down
            default: return nil
            }
        }

        /// 从系统送来的那次按键里认（`pressesBegan` 那条路用这个）。
        static func matching(_ key: UIKey) -> MoveLineKey? {
            matching(keyCode: Int(key.keyCode.rawValue), modifierFlags: Int(key.modifierFlags.rawValue))
        }
    }

    /// 一次按键落到手里：是 ⌥↑ / ⌥↓ 就搬行，并回答「这次按键要不要被吃掉」。
    ///
    /// - returns: `true` = 行搬成了，事件到此为止；`false` = 不是这两个键，或者搬不动 —— 交给系统照常处理。
    ///
    /// ### 为什么「搬不动」要放行而不是照吞
    /// 光标已经在首行时按 ⌥↑，搬行是空操作。这时候把事件吞掉，用户看到的是「这个键完全没反应」；
    /// 放回去，系统那套「⌥↑ = 跳到上一段开头」还能照常干活。
    @discardableResult
    func performMoveLineIfMatched(_ key: UIKey) -> Bool {
        performMoveLineIfMatched(keyCode: Int(key.keyCode.rawValue),
                                 modifierFlags: Int(key.modifierFlags.rawValue))
    }

    /// 同一个判别的整数版：`UIKey` 造不出来（没有公开的构造器），单元测试只能从这一头喂进来。
    @discardableResult
    func performMoveLineIfMatched(keyCode: Int, modifierFlags: Int) -> Bool {
        guard let direction = MoveLineKey.matching(keyCode: keyCode, modifierFlags: modifierFlags) else { return false }
        return moveCurrentLine(by: direction.delta)
    }
}
