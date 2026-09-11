//
//  CodeBlockDecoration.swift
//  MarkdownEditorHy4
//
//  代码块的装饰层：代码正文一个圆角矩形背景（画在文字下面，首尾 ``` 围栏行不带底）
//  + 右上角复制按钮（浮在文字上面）
//

import UIKit

/// 背景层：加在 UITextView **最底层**，画在文字下面。
///
/// ### 为什么必须单独一层且 `hitTest` 返回 nil
/// 背景矩形盖住了大半个屏幕宽度，如果它能吃点击事件，用户就没法点中代码里的文字、
/// 也没法把光标放到代码块里。所以这一层「看得见、摸不着」，点击全部穿透给下面的 textView。
final class CodeBlockBackgroundLayer: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

/// 控件层：加在 UITextView **最上层**，只让复制按钮吃点击。
///
/// 和背景层同理，除了按钮之外的区域一律穿透，否则会挡住文本交互。
final class CodeBlockControlLayer: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // 只认自己内部的按钮，其余区域返回 nil（事件继续往下传给 textView）
        for subview in subviews where subview.frame.contains(point) {
            if let hit = subview.hitTest(convert(point, to: subview), with: event) { return hit }
        }
        return nil
    }
}

/// 代码块右上角的复制按钮。
///
/// 点一下把该代码块的正文放进系统剪贴板，图标临时变成对勾给个反馈。
final class CodeBlockCopyButton: UIButton {
    /// 这个按钮对应哪个代码块（点击时从这里取要复制的文本）
    var codeBlock: CodeBlockInfo?

    /// 按钮边长
    static let size: CGFloat = 26

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.size, height: Self.size))

        let configuration = UIImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        setImage(UIImage(systemName: "doc.on.doc", withConfiguration: configuration), for: .normal)
        tintColor = .secondaryLabel

        // 半透明底色：压在代码文字上也能看清按钮边界
        backgroundColor = UIColor.tertiarySystemFill
        layer.cornerRadius = 6
        clipsToBounds = true

        accessibilityLabel = "复制代码"
    }

    required init?(coder: NSCoder) {
        fatalError("CodeBlockCopyButton 不支持从 coder 解档")
    }

    /// 复制成功的视觉反馈：图标换成对勾，1 秒后换回来
    func flashCopied() {
        let configuration = UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        setImage(UIImage(systemName: "checkmark", withConfiguration: configuration), for: .normal)
        tintColor = .systemGreen

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            let configuration = UIImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            self.setImage(UIImage(systemName: "doc.on.doc", withConfiguration: configuration), for: .normal)
            self.tintColor = .secondaryLabel
        }
    }
}
