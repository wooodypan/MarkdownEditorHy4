//
//  MarkdownTextView+LineNumbers.swift
//  MarkdownEditorHy4
//
//  正文左边的行号（默认关闭，App 层设置页里打开）
//
//  ### 为什么行号是「画」出来的，不占正文的字符位
//  这个编辑器有个铁律：**展示的一定是源码本身**（全选复制出来 === 源文件）。
//  只要往文本流里插一个字符，复制出来的文本就多一个字符，这条铁律就破了。
//  所以行号和折叠三角、引用竖条一样，走 **overlay**：把 `lineNumberGutterWidth`
//  加进 `textContainerInset.left`，正文整体右移，行号画在让出来的那条带子里。
//
//  ### 编号数的是「渲染文本里第几行」
//  渲染文本和源码不是一对一（图片、表格只占 1 个字符位却吃掉一大段源码），
//  所以行号和「源码第几行」在含图片 / 表格的地方会错开。这里按**屏幕上看到的
//  那一行的行号**来编 —— 用户拿行号是为了「找到屏幕上那一行」，不是去数源文件。
//

import UIKit

/// 行号装订线：只负责把「第几行 + 画在哪儿」画出来。
///
/// 它是一个**纯绘制**的 view：不参与排版、不吃点击、不带子 view
/// （行号是几十个短字符串，自己画比建几十个 `UILabel` 便宜得多，也不会挡住正文的点击）。
final class LineNumberGutterView: UIView {

    /// 一个要画的号码
    struct Entry {
        /// 号码文字
        let text: String
        /// 这一行在**屏幕坐标**（viewport 坐标）里的顶部
        let top: CGFloat
        /// 这一行的高度，用来把号码垂直居中
        let height: CGFloat
    }

    /// 这一屏要画哪些号码。赋值即重画
    var entries: [Entry] = [] {
        didSet { setNeedsDisplay() }
    }

    /// 号码的字体（从主题派生，比正文小 2 号的等宽数字）
    var numberFont: UIFont = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    /// 号码的颜色
    var numberColor: UIColor = .tertiaryLabel
    /// 号码**右对齐**的那条线（本 view 自己的坐标系）
    var numberRightEdge: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        // 透明背景 + 不吃点击：它只是正文旁边的一条装饰带
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("LineNumberGutterView 不支持从 coder 解档")
    }

    override func draw(_ rect: CGRect) {
        guard !entries.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: numberFont,
                                                         .foregroundColor: numberColor]
        for entry in entries {
            let size = (entry.text as NSString).size(withAttributes: attributes)
            // 右对齐到 numberRightEdge，垂直方向上落在这行文字的中间
            let origin = CGPoint(x: numberRightEdge - size.width,
                                 y: entry.top + (entry.height - size.height) / 2)
            (entry.text as NSString).draw(at: origin, withAttributes: attributes)
        }
    }
}

extension MarkdownTextView {

    /// 把行号画到左边的装订线上。
    ///
    /// 调用时机和折叠三角一致：每次 `layoutSubviews`、每次滚动（滚动只改位置，
    /// 但哪些行露出来变了，得重画）。关着的时候第一行就返回，几乎不花钱。
    ///
    /// ### 只画「已经排好版」的行（和折叠三角同一个理由）
    /// TextKit 2 是按需排版的，屏幕外 / 刚进视野的 fragment 给的坐标是**估算值**
    /// （实测差几十上百点）。拿估算值画号码必然错位，所以只认
    /// `state == .layoutAvailable` 的 fragment。
    func positionLineNumbers() {
        lineNumberGutter.frame = bounds

        guard showsLineNumbers,
              let layoutManager = textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage,
              let viewport = layoutManager.textViewportLayoutController.viewportRange,
              bounds.width > 1 else {
            lineNumberGutter.entries = []
            return
        }

        let theme = renderer.theme
        lineNumberGutter.numberFont = theme.lineNumberFont
        lineNumberGutter.numberColor = theme.lineNumberColor
        // 号码贴在正文左边缘往左一条带子的位置上（再往左让开折叠三角那条带子）。
        // 这样「行宽上限」把正文推到窗口中间时，行号跟着正文一起挪，看着才像一条装订线。
        lineNumberGutter.numberRightEdge = textContainerInset.left
            - theme.foldGutterWidth - theme.lineNumberTrailingGap

        let starts = lineStartOffsetsIfNeeded()
        let documentStart = contentStorage.documentRange.location
        // 上下各留 60 点余量：滚快一点也不会在屏幕边缘闪出「还没画出来的号码」
        let visibleBottom = bounds.height + 60

        var entries: [LineNumberGutterView.Entry] = []
        // 从视口的第一段开始往后扫：视口之外的行不用管（它们的坐标本来也是估算值）
        layoutManager.enumerateTextLayoutFragments(from: viewport.location,
                                                   options: [.ensuresLayout]) { fragment in
            // 文档坐标 → viewport 坐标（和代码块背景那套换算一致：y 要补回 inset.top）
            let top = fragment.layoutFragmentFrame.minY + textContainerInset.top - contentOffset.y
            // 已经滚过屏幕下沿，后面不用看了
            guard top <= visibleBottom else { return false }

            // 只画排好版的行；一个 fragment 是一整段（可能折成好几行），
            // 号码只给**第一行** —— 折行的续行不另编号（和 Xcode、VS Code 一致）
            guard fragment.state == .layoutAvailable,
                  let line = fragment.textLineFragments.first else { return true }

            let lineRect = line.typographicBounds
            let lineTop = top + lineRect.minY
            guard lineTop + lineRect.height >= -60, lineTop <= visibleBottom else { return true }

            let offset = contentStorage.offset(from: documentStart, to: fragment.rangeInElement.location)
            entries.append(LineNumberGutterView.Entry(text: "\(lineNumber(of: offset, lineStarts: starts))",
                                                      top: lineTop,
                                                      height: lineRect.height))
            return true
        }
        lineNumberGutter.entries = entries
    }

    /// 每一行的起始字符偏移（缓存版）。
    ///
    /// ### 为什么要缓存
    /// 问「第 n 个字符在第几行」要扫一遍全文，而滚动时**每帧**都要问好几十次。
    /// 缓存一张「行首偏移表」，之后每次查询二分查找即可。
    /// 表只在内容变了的时候重算 —— 作废的时机挂在 `lastSyncedString` 的 `didSet` 上。
    private func lineStartOffsetsIfNeeded() -> [Int] {
        if let cached = lineStartOffsets, !lineNumbersStale { return cached }

        let text = textStorage.string as NSString
        var starts: [Int] = [0]
        var index = 0
        while index < text.length {
            let line = text.lineRange(for: NSRange(location: index, length: 0))
            let next = NSMaxRange(line)
            // 防御：`lineRange` 万一停在原地，别把这里变成死循环
            guard next > index else { break }
            index = next
            if index < text.length { starts.append(index) }
        }
        lineStartOffsets = starts
        lineNumbersStale = false
        return starts
    }

    /// `offset` 这个字符在第几行（1 开始）。在「行首偏移表」里二分查找。
    private func lineNumber(of offset: Int, lineStarts: [Int]) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }
}
