//
//  FixedSizeAccessoryView.swift
//  MarkdownEditorHy4
//
//  给 `cell.accessoryView` 兜底用的「自报尺寸」容器。
//
//  ### 为什么 `accessoryView` 不能随便塞一个 view
//  UIKit 是按 `intrinsicContentSize` 问出 `accessoryView` 该占多宽的。而下面这两种最常见的写法都答「不知道」：
//
//  - `UIStackView` —— 实测 `intrinsicContentSize` 是 `(-1, -1)`（也就是 `UIView.noIntrinsicMetric`）；
//  - 普通 `UIView` —— 默认同样是 `(-1, -1)`，光在 init 里给一个 `frame` 不一定保得住。
//
//  结果都是**被压成零宽**：屏幕上看不见那颗按钮 / 那个输入框，可代码里它明明挂着。
//  用户点上去一点反应都没有，还得以为是按钮没接线 —— 这类 bug 最难查，因为「该写的都写了」。
//  所以凡是当 `accessoryView` 的自定义 view，都从这里继承、把尺寸明确报出来。
//

import UIKit

/// 一个「就这么大」的容器：外面怎么问都是这个尺寸
class FixedSizeAccessoryView: UIView {

    private let fixedSize: CGSize

    init(size: CGSize) {
        self.fixedSize = size
        // frame 也一起给上：有的地方（比如直接向数据源要 cell）不走 Auto Layout，只看 frame
        super.init(frame: CGRect(origin: .zero, size: size))
    }

    @available(*, unavailable, message: "这个 view 只从代码里建")
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 没实现")
    }

    override var intrinsicContentSize: CGSize {
        fixedSize
    }
}
