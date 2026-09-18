//
//  VectorIcon+Outline.swift
//  MarkdownEditorHy4
//
//  大纲面板标题栏用的两个自绘图标：全部展开 / 全部折叠
//
//  ### 坐标从哪来
//  这两个图形是 Sketch（或同类工具）导出的，画布 **256×256**。
//  ⚠️ 下面的坐标是导出的原始数值，**不要手改**：要微调形状就回设计稿改，
//  然后重新导出、整段替换 —— 手改出来的数值下次重新导出就丢了。
//

import UIKit

extension VectorIcon {

    /// https://www.iconfont.cn/collections/detail?cid=3991 
    /// 「全部展开」：一个空心圆角方框，中间一个「＋」
    static let outlineExpandAll = VectorIcon(canvasSize: CGSize(width: 256, height: 256)) {
        let path = UIBezierPath()

        //// 中间的「＋」：竖臂 x 120..136、横臂 y 120..136，四端都是 8 的圆角
        path.move(to: CGPoint(x: 136, y: 120))
        path.addLine(to: CGPoint(x: 192.06, y: 120))
        path.addCurve(to: CGPoint(x: 200, y: 128), controlPoint1: CGPoint(x: 196.44, y: 120), controlPoint2: CGPoint(x: 200, y: 123.55))
        path.addCurve(to: CGPoint(x: 192.06, y: 136), controlPoint1: CGPoint(x: 200, y: 132.42), controlPoint2: CGPoint(x: 196.44, y: 136))
        path.addLine(to: CGPoint(x: 136, y: 136))
        path.addLine(to: CGPoint(x: 136, y: 192.06))
        path.addLine(to: CGPoint(x: 136, y: 192.05))
        path.addCurve(to: CGPoint(x: 128.05, y: 200), controlPoint1: CGPoint(x: 136, y: 196.44), controlPoint2: CGPoint(x: 132.44, y: 200))
        path.addCurve(to: CGPoint(x: 120, y: 192.06), controlPoint1: CGPoint(x: 123.58, y: 200), controlPoint2: CGPoint(x: 120, y: 196.44))
        path.addLine(to: CGPoint(x: 120, y: 136))
        path.addLine(to: CGPoint(x: 63.94, y: 136))
        path.addLine(to: CGPoint(x: 63.95, y: 136))
        path.addCurve(to: CGPoint(x: 56, y: 128.05), controlPoint1: CGPoint(x: 59.56, y: 136), controlPoint2: CGPoint(x: 56, y: 132.44))
        path.addCurve(to: CGPoint(x: 63.94, y: 120), controlPoint1: CGPoint(x: 56, y: 123.58), controlPoint2: CGPoint(x: 59.56, y: 120))
        path.addLine(to: CGPoint(x: 120, y: 120))
        path.addLine(to: CGPoint(x: 120, y: 63.94))
        path.addLine(to: CGPoint(x: 120, y: 63.95))
        path.addCurve(to: CGPoint(x: 127.95, y: 56), controlPoint1: CGPoint(x: 120, y: 59.56), controlPoint2: CGPoint(x: 123.56, y: 56))
        path.addCurve(to: CGPoint(x: 136, y: 63.94), controlPoint1: CGPoint(x: 132.42, y: 56), controlPoint2: CGPoint(x: 136, y: 59.56))
        path.addLine(to: CGPoint(x: 136, y: 120))
        path.close()

        appendOutlineFrame(to: path)
        return path
    }

    /// 「全部折叠」：同样的空心圆角方框，中间一条横杠
    static let outlineCollapseAll = VectorIcon(canvasSize: CGSize(width: 256, height: 256)) {
        let path = UIBezierPath()

        appendOutlineFrame(to: path)

        //// 中间那条横杠：x 56..200、y 120..136，圆角 8 的胶囊形
        path.move(to: CGPoint(x: 56, y: 128))
        path.addCurve(to: CGPoint(x: 63.94, y: 120), controlPoint1: CGPoint(x: 56, y: 123.58), controlPoint2: CGPoint(x: 59.56, y: 120))
        path.addLine(to: CGPoint(x: 192.06, y: 120))
        path.addCurve(to: CGPoint(x: 200, y: 128), controlPoint1: CGPoint(x: 196.44, y: 120), controlPoint2: CGPoint(x: 200, y: 123.55))
        path.addCurve(to: CGPoint(x: 192.06, y: 136), controlPoint1: CGPoint(x: 200, y: 132.42), controlPoint2: CGPoint(x: 196.44, y: 136))
        path.addLine(to: CGPoint(x: 63.94, y: 136))
        path.addLine(to: CGPoint(x: 63.95, y: 136))
        path.addCurve(to: CGPoint(x: 56, y: 128.05), controlPoint1: CGPoint(x: 59.56, y: 136), controlPoint2: CGPoint(x: 56, y: 132.44))
        path.addLine(to: CGPoint(x: 56, y: 128))
        path.close()
        return path
    }
}

/// 两个图标共用的那个「空心方框」：外轮廓 16→240，内轮廓 32→224。
///
/// ### 为什么里外要各画一条
/// 这是个**空心的粗边框**：外轮廓和内轮廓两条同方向的闭合路径叠在一起，
/// 靠 `VectorIcon` 默认的 `fillRule: .evenOdd` 把中间那块挖成透的。
/// 要是哪次不小心改成了 `.nonZero`，两条同向路径会把整个方块涂实 ——
/// 屏幕上变成一坨黑方块时，先回来查这个规则。
///
/// ⚠️ 坐标同样是 Sketch 导出的（画布 256×256），别手改。
private func appendOutlineFrame(to path: UIBezierPath) {
    //// 外轮廓：16 → 240，圆角 16
    path.move(to: CGPoint(x: 16, y: 31.93))
    path.addCurve(to: CGPoint(x: 31.93, y: 16), controlPoint1: CGPoint(x: 16, y: 23.13), controlPoint2: CGPoint(x: 23.2, y: 16))
    path.addLine(to: CGPoint(x: 224.08, y: 16))
    path.addCurve(to: CGPoint(x: 240, y: 31.93), controlPoint1: CGPoint(x: 232.87, y: 16), controlPoint2: CGPoint(x: 240, y: 23.2))
    path.addLine(to: CGPoint(x: 240, y: 224.08))
    path.addCurve(to: CGPoint(x: 224.07, y: 240.01), controlPoint1: CGPoint(x: 240, y: 232.88), controlPoint2: CGPoint(x: 232.8, y: 240.01))
    path.addLine(to: CGPoint(x: 31.92, y: 240.01))
    path.addCurve(to: CGPoint(x: 16, y: 224.07), controlPoint1: CGPoint(x: 23.13, y: 240), controlPoint2: CGPoint(x: 16, y: 232.8))
    path.addLine(to: CGPoint(x: 16, y: 31.92))
    path.addLine(to: CGPoint(x: 16, y: 31.93))
    path.close()

    //// 内轮廓：32 → 224，圆角 8
    path.move(to: CGPoint(x: 32, y: 40.01))
    path.addLine(to: CGPoint(x: 32, y: 215.99))
    path.addLine(to: CGPoint(x: 32, y: 216))
    path.addCurve(to: CGPoint(x: 40, y: 224), controlPoint1: CGPoint(x: 32, y: 220.42), controlPoint2: CGPoint(x: 35.58, y: 224))
    path.addLine(to: CGPoint(x: 216, y: 224))
    path.addLine(to: CGPoint(x: 216, y: 224))
    path.addCurve(to: CGPoint(x: 224, y: 216), controlPoint1: CGPoint(x: 220.42, y: 224), controlPoint2: CGPoint(x: 224, y: 220.42))
    path.addLine(to: CGPoint(x: 224, y: 40))
    path.addLine(to: CGPoint(x: 224, y: 40))
    path.addCurve(to: CGPoint(x: 216, y: 32), controlPoint1: CGPoint(x: 224, y: 35.58), controlPoint2: CGPoint(x: 220.42, y: 32))
    path.addLine(to: CGPoint(x: 40, y: 32))
    path.addLine(to: CGPoint(x: 40, y: 32))
    path.addCurve(to: CGPoint(x: 32, y: 40), controlPoint1: CGPoint(x: 35.58, y: 32), controlPoint2: CGPoint(x: 32, y: 35.58))
    path.addLine(to: CGPoint(x: 32, y: 40.01))
    path.close()
}
