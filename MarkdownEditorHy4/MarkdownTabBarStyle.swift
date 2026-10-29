//
//  MarkdownTabBarStyle.swift
//  MarkdownEditorHy4
//
//  右侧那条多 Tab 条的颜色：让它跟正文那套配色连成一片，而不是跟系统色各穿一件。
//
//  ### 为什么要自己算颜色
//  库给的三档默认色都是系统语义色（选中浅灰、未选中透明、灰点中灰），落在纯白或纯黑的容器底上。
//  本项目的正文用的是 markdown 主题底色（可能是米白、暗灰、用户自己导入的配色），
//  Tab 条却还是系统白 / 系统黑 —— 上下两块颜色对不上，中间还横着一条分隔线，看着像两个 App 拼起来的。
//
//  ### 算出来的三种颜色怎么分工
//  - 整条 Tab 条：比正文底色深一档（深色主题下则浅一档），做成一条「独立的带子」；
//  - 选中的 Tab：正文底色本身，于是它跟下面的正文无缝连成一片，像从正文里长出来的标签页；
//  - 未选中的 Tab：透明，直接露出上面那条带子。
//  这是浏览器 / Xcode 那类标签页的通行做法：选中的那个「亮起来」，跟内容区同色。
//

import UIKit
import MultiTabController

/// 一条 Tab 条要用到的三种颜色。
struct MarkdownTabBarColors: Equatable {

    /// 整条 Tab 条的底色（含 Tab 右侧那片空白）
    let barBackground: UIColor

    /// 选中 Tab 的底色
    let selectedBackground: UIColor

    /// 有未保存修改时，替代关闭按钮 x 的那个小圆点的颜色
    let editIndicator: UIColor
}

enum MarkdownTabBarStyle {

    // MARK: 算颜色

    /// 按正文底色算出一整套 Tab 条颜色。
    ///
    /// - Parameter editorBackground: 当前主题的正文底色（`MarkdownTheme.editorBackground`）。
    ///   传进来的颜色带透明度也不怕，会先按白底摊成实色再算 —— 半透明色叠在未知底色上算出来的深浅是不可靠的。
    static func colors(editorBackground: UIColor) -> MarkdownTabBarColors {
        let base = flattened(editorBackground)
        // 浅色底就往黑里混、深色底就往白里混：两边都往「离底色更远」的方向走一小步，
        // 出来的效果统一是「看得出来是两层，但不刺眼」。
        // ⚠️ 这里要取反：`isLight` 说的是「底色浅不浅」，底色浅才该往黑走
        let towardWhite = !isLight(base)
        // 深色底要多走一步：人眼在暗部对亮度差不敏感，同样 6% 铺在黑底上几乎看不出来
        let barStep: CGFloat = towardWhite ? 0.10 : 0.06

        return MarkdownTabBarColors(
            barBackground: blend(base, towardWhite: towardWhite, amount: barStep),
            // 选中项就是正文本身，一点不掺 —— 它要和下面的内容区无缝衔接
            selectedBackground: base,
            // 灰点要能一眼看见，又不能比正文还醒目，所以往反差方向走将近一半
            editIndicator: blend(base, towardWhite: towardWhite, amount: 0.45)
        )
    }

    /// 把这套颜色装到宿主上。赋值即生效，宿主只重刷已有单元格，不会重建整条 Tab 条。
    ///
    /// ### 为什么每个颜色都要先比一遍
    /// 宿主那三个属性都是「一赋值就重刷所有 Tab 单元格」。设置页里拖一下滑块会连着发几十次通知，
    /// 颜色其实一点没变，不判一下就白刷几十遍。`UIColor.isEqual` 比的是颜色分量，不是对象身份，
    /// 每次现算出来的新对象也能正确判等。
    static func apply(_ colors: MarkdownTabBarColors, to host: DetailHostViewController) {
        if !host.tabBarBackgroundColor.isEqual(colors.barBackground) {
            host.tabBarBackgroundColor = colors.barBackground
        }
        if !host.tabSelectedBackgroundColor.isEqual(colors.selectedBackground) {
            host.tabSelectedBackgroundColor = colors.selectedBackground
        }
        // 未选中的 Tab 本来就该露出条底色，显式写一遍而不靠默认值：
        // 默认值哪天变了，这里不会跟着变成「每格都涂一块」
        if !host.tabUnselectedBackgroundColor.isEqual(UIColor.clear) {
            host.tabUnselectedBackgroundColor = .clear
        }
        if !host.tabEditingIndicatorColor.isEqual(colors.editIndicator) {
            host.tabEditingIndicatorColor = colors.editIndicator
        }
    }

    // MARK: 颜色运算

    /// 这个颜色算浅色吗。
    ///
    /// 用 ITU-R BT.601 那套亮度权重（人眼对绿最敏感、对蓝最不敏感），不是简单取 RGB 平均值 ——
    /// 平均法会把纯蓝（0, 0, 255）判成中间色，实际上它看着很暗。
    static func isLight(_ color: UIColor) -> Bool {
        let rgb = components(of: color)
        let luminance = 0.299 * rgb.red + 0.587 * rgb.green + 0.114 * rgb.blue
        return luminance > 0.5
    }

    /// 把颜色朝白（`towardWhite = true`）或朝黑混一点，`amount` 是混入的比例（0 = 原色，1 = 纯白 / 纯黑）。
    static func blend(_ color: UIColor, towardWhite: Bool, amount: CGFloat) -> UIColor {
        let rgb = components(of: color)
        let ratio = min(max(amount, 0), 1)
        let target: CGFloat = towardWhite ? 1 : 0
        return UIColor(red: rgb.red + (target - rgb.red) * ratio,
                       green: rgb.green + (target - rgb.green) * ratio,
                       blue: rgb.blue + (target - rgb.blue) * ratio,
                       alpha: 1)
    }

    /// 取 RGBA 分量。`getRed` 拿不到（比如颜色空间不是 RGB）时就当白底黑字处理，返回纯白。
    ///
    /// 为什么退回白色而不是黑色：默认主题的正文底色就是浅色系，退回白色最多是「Tab 条和正文看不出来是一体」，
    /// 退回黑色则会变成「浅色界面里突兀地插一条黑带子」。
    private static func components(of color: UIColor) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        var red: CGFloat = 1
        var green: CGFloat = 1
        var blue: CGFloat = 1
        var alpha: CGFloat = 1
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return (1, 1, 1, 1)
        }
        return (red, green, blue, alpha)
    }

    /// 把带透明度的颜色摊到白底上，变回不透明色。
    ///
    /// 公式就是最普通的那一个：`结果 = 底色 + (前景 - 底色) × alpha`，底色取白。
    private static func flattened(_ color: UIColor) -> UIColor {
        let rgba = components(of: color)
        guard rgba.alpha < 1 else { return color }
        return UIColor(red: 1 + (rgba.red - 1) * rgba.alpha,
                       green: 1 + (rgba.green - 1) * rgba.alpha,
                       blue: 1 + (rgba.blue - 1) * rgba.alpha,
                       alpha: 1)
    }
}
