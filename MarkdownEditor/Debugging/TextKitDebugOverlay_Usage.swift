//
//  使用示例
//

import UIKit

final class MarkdownDebugViewController: UIViewController {

    private let textView = UITextView()

    override func viewDidLoad() {
        super.viewDidLoad()

        textView.frame = view.bounds
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        textView.attributedText = makeSampleMarkdownAttributedString()
        view.addSubview(textView)

        #if DEBUG
        // 三指长按切换调试边框（也可以换成摇一摇手势、Debug 菜单按钮等）
        let gesture = UITapGestureRecognizer(target: self, action: #selector(toggleDebugOverlay))
        gesture.numberOfTouchesRequired = 3
        view.addGestureRecognizer(gesture)
        #endif
    }

    @objc private func toggleDebugOverlay() {
        var config = TextKitDebugConfig()
        config.showIndexLabels = true
        textView.installLineFragmentDebugOverlay(config: config)
    }

    private func makeSampleMarkdownAttributedString() -> NSAttributedString {
        // 这里替换成你自己 Markdown 解析器产出的 NSAttributedString
        let str = NSMutableAttributedString(string: "示例段落，用来验证 line fragment 与 usedRect 是否对齐。\n第二行文本。")
        str.addAttribute(.font, value: UIFont.systemFont(ofSize: 17), range: NSRange(location: 0, length: str.length))
        return str
    }
}
