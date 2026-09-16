//
//  MarkdownEditorSettings.swift
//  MarkdownEditorHy4
//
//  用户配置：一个很小的键值存储，落盘到沙盒里
//
//  这一层只做「存 / 取 / 夹范围 / 发通知」，自己不碰界面。
//  这里用 `import UIKit` 而不是 `import Foundation`，是因为有几个默认值是
//  **从渲染层主题里读**的（正文字号、行高、段间距），而主题里的字体是 `UIFont`。

import UIKit

/// 大纲面板的高度按什么算。
///
/// 两种模式是**互斥**的，用户在设置页上二选一：
/// - 选了「按百分比」→ 固定的「最大高度」就不再生效；
/// - 选了「按最大高度」→ 百分比不再生效。
///
/// 做成枚举而不是「两个开关」：两个值同时生效的话，
/// 「我明明把最大高度调大了，怎么面板没变」这种问题会很难解释。
enum OutlineHeightMode: String, Codable, CaseIterable {
    /// 高度最多到「父视图高度的百分之几」
    case percentage
    /// 高度最多到「一个固定的点数」
    case maximumHeight

    /// 设置页上显示的名字
    var displayName: String {
        switch self {
        case .percentage: return "按百分比"
        case .maximumHeight: return "按最大高度"
        }
    }
}

/// 编辑器的用户配置。
///
/// ### 落盘在哪
/// 按需求放沙盒的 `Library/Caches/MarkdownEditorHy4/settings.json`。
///
/// 说明一下这个选择的代价：`Library/Caches` 里的东西系统**有权回收**（磁盘紧张时会清）。
/// 真被清了不会出别的问题 —— 读不到文件就当成「全部用默认值」，只是用户的开关会复位。
/// 换成 `UserDefaults` 或 `Library/Application Support` 会更稳，要改的话只动
/// `defaultFileURL` 这一处即可，其余代码不用碰。
///
/// ### 为什么做成一个类而不是直接散用 `UserDefaults`
/// 1. 单元测试要能把落盘位置换成一个临时目录（不然测试会读写用户真实的配置），
///    所以落盘路径必须能在初始化时注入，见 `init(fileURL:)`；
/// 2. 开关一变要通知界面上关心它的人（大纲面板、编辑器），
///    集中在这里发一条通知比每个使用方自己盯着配置方便。
final class MarkdownEditorSettings {

    /// 全局唯一实例。App 里用这个；单元测试自己 new 一个指向临时目录的
    static let shared = MarkdownEditorSettings()

    /// 配置变了就发这条通知。
    ///
    /// `object` 是发通知的那个 `MarkdownEditorSettings` 实例，
    /// 监听方可以据此忽略掉不认识的实例（测试之间互不干扰）。
    static let didChangeNotification = Notification.Name("MarkdownEditorSettingsDidChange")

    // MARK: 默认值

    private enum Default {
        /// 「记住目录大纲滚动位置」默认打开
        static let remembersScrollPosition = true
        /// 大纲高度默认按「父视图高度的 70%」算上限
        static let outlineHeightMode: OutlineHeightMode = .percentage
        static let outlineHeightRatio: Double = 0.7
        static let outlineMaximumHeight: Double = 360
        /// 表格列宽默认值，和渲染层 `TableStyle` 的默认值保持一致
        static let tableMinColumnWidth: Double = 64
        static let tableMaxColumnWidth: Double = 280

        /// 渲染层主题里的那套默认排版。
        ///
        /// 下面「正文排版」那几个默认值**都从它取**，不在这里写死第二份数字 ——
        /// 同一件事写两份，改了一边忘了另一边，用户就会遇到
        /// 「我什么都没调，外观怎么变了」。只构造一次，别在下面反复访问。
        static let theme = MarkdownTheme.default

        /// 正文字号默认 = 主题里那个正文大小（系统 body，通常是 17）
        static let bodyFontSize = Double(theme.bodyFont.pointSize)
        /// 行高默认 1 倍：就是字体自带的自然行高，等于没有这一项
        static let lineHeightMultiple = Double(theme.lineHeightMultiple)
        /// 段落间距默认 = 主题里的值（列表项段落也读同一个数）
        static let paragraphSpacing = Double(theme.paragraphSpacing)
        /// 段落首行缩进默认 **0**：不缩进。中文排版习惯是缩 2 个字，但那是偏好，不该替用户决定
        static let paragraphIndentCharacters: Double = 0
        /// 行宽默认「不限」—— 就是量程上限那个值，正文照旧铺满窗口宽度
        static let bodyContentWidth = Limits.bodyContentWidth.upperBound
    }

    /// 各项数值的合法范围。
    ///
    /// ### 为什么要在这里夹一道，而不是只靠设置页的滑块
    /// 配置是**落盘**的，能被手改、能被更早的版本写坏、也许多年以后换了套界面。
    /// 只在界面上限制范围的话，一个 `ratio: 999` 进来就会把面板高度算成天文数字。
    /// 夹在「配置的入口」这一层，别的使用方就永远能相信拿到的值是可用的。
    enum Limits {
        static let outlineHeightRatio: ClosedRange<Double> = 0.3...1.0
        static let outlineMaximumHeight: ClosedRange<Double> = 120...900
        /// 表格「最小列宽」的合法范围
        static let tableMinColumnWidth: ClosedRange<Double> = 32...200
        /// 表格「最大列宽」的合法范围
        static let tableMaxColumnWidth: ClosedRange<Double> = 80...600

        /// 正文字号的合法范围（点）。下限 12 再小就难认，上限 28 再大一行放不下几个字
        static let bodyFontSize: ClosedRange<Double> = 12...28
        /// 行高倍数的合法范围。下限 1 表示「不松」，上限 2 倍已经相当松了
        static let lineHeightMultiple: ClosedRange<Double> = 1.0...2.0
        /// 段落间距的合法范围（点）。0 = 段与段贴在一起
        static let paragraphSpacing: ClosedRange<Double> = 0...40
        /// 段落首行缩进的合法范围（**字符数**，不是点）。
        /// 中文排版的习惯值是 2，所以上限给到 4 足够
        static let paragraphIndentCharacters: ClosedRange<Double> = 0...4
        /// 正文栏宽上限的合法范围（点）。
        /// ⚠️ 拖到**上限值**表示「不限」—— 见 `MarkdownEditorSettings.bodyContentWidthLimit`
        static let bodyContentWidth: ClosedRange<Double> = 320...1200
    }

    // MARK: 落盘

    /// 配置文件地址。测试会传一个临时目录进来
    private let fileURL: URL

    /// 默认位置：`Library/Caches/MarkdownEditorHy4/settings.json`
    static var defaultFileURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches
            .appendingPathComponent("MarkdownEditorHy4", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    /// 落盘用的结构。
    ///
    /// ⚠️ 字段都写成可选的：以后往设置页加新行（新增字段）时，
    /// 老的配置文件里没有那个键，可选字段会解成 nil 然后退化成默认值，
    /// 不会因为「缺字段」整份解析失败、把所有设置一起丢回默认。
    private struct Payload: Codable {
        var remembersScrollPosition: Bool?
        /// ⚠️ 这里存**字符串**而不是枚举本身：将来枚举改了名、或者文件被手改成一个
        /// 现在的版本不认识的值时，用枚举解码会让**整份** Payload 解不出来、
        /// 所有设置一起复位。存字符串的话只有这一项退回默认，别的照旧
        var outlineHeightMode: String?
        var outlineHeightRatio: Double?
        var outlineMaximumHeight: Double?
        var tableMinColumnWidth: Double?
        var tableMaxColumnWidth: Double?
        /// 正文排版那一组。同样都写成可选的，老配置文件里没有就各自退默认
        var bodyFontSize: Double?
        var lineHeightMultiple: Double?
        var paragraphSpacing: Double?
        var paragraphIndentCharacters: Double?
        var bodyContentWidth: Double?
    }

    // MARK: 配置项

    /// 是否记住目录大纲（也就是文档）的滚动位置。默认 `true`。
    ///
    /// 打开时：
    /// 1. 大纲面板会**跟着光标所在的标题自动滚动**，把当前章节滚进可视区；
    /// 2. 大纲列表因为编辑被重建之后，保持原来滚到哪儿；
    /// 3. 关闭 / 离开文件时记下文档滚到哪儿，下次打开同一个文件回到原处。
    ///
    /// 关掉时以上三件事都不做 —— 大纲面板只在你手动滚它的时候才动，列表刷新后回到顶部。
    private(set) var remembersScrollPosition: Bool

    /// 大纲面板的高度按什么算，默认「按百分比」。
    /// 两种模式的详细解释见 `OutlineHeightMode`
    private(set) var outlineHeightMode: OutlineHeightMode

    /// 「按百分比」模式下，面板高度最多占父视图高度的百分之几。默认 `0.7`（70%）。
    ///
    /// 这是个**上限**不是固定高度：标题少的时候面板照样只占那么矮一点，
    /// 到「父视图高度 × 这个比例」就封顶，再多就在面板内部滚动。
    ///
    /// 这个模式下 `outlineMaximumHeight` 不参与计算
    private(set) var outlineHeightRatio: Double

    /// 「按最大高度」模式下，面板高度的上限（点）。默认 `360`。
    ///
    /// 同样是上限不是固定高度。另外为了小屏上不把整屏盖住，
    /// 实际用时还会被父视图高度压一道（见 `MarkdownOutlineView.effectiveMaximumHeight`）
    private(set) var outlineMaximumHeight: Double

    /// 表格**最窄**的一列有多宽（点）。默认 `64`。
    ///
    /// 列内容再短，列宽也不小于这个值 —— 不然「姓名」这种两字列会挤成一团。
    private(set) var tableMinColumnWidth: Double

    /// 表格**最宽**的一列有多宽（点）。默认 `280`。
    ///
    /// 某一列内容特别长（贴了个长链接）时，列宽到这个值就封顶，
    /// 多出来的文字换行，别把别的列挤没了。
    private(set) var tableMaxColumnWidth: Double

    // MARK: 正文排版

    /// 正文字号（点）。默认取系统 body 的大小（通常 17）。
    ///
    /// 注意它改的不只是正文：等宽字体（行内代码、代码块）和各级标题都是
    /// 「从这个数推出来的」，一起跟着变。换算见 `MarkdownTheme.applyBodyFontSize`。
    private(set) var bodyFontSize: Double

    /// 行高倍数。默认 `1`（= 用字体自带的自然行高）。
    ///
    /// `1.5` 表示行与行之间比自然值多出 50%。只作用于**文字**段落，
    /// 图片、表格、分隔线那些整块内容不跟着变松。
    private(set) var lineHeightMultiple: Double

    /// 段落之间的间距（点）。默认取主题里的值。
    ///
    /// 正文段落、标题、列表项都读这一个数 —— 它是全局的段间距。
    private(set) var paragraphSpacing: Double

    /// 正文段落**首行**缩进几个**字符**。默认 `0`（不缩进）。
    ///
    /// ### 为什么单位是「字符」而不是「点」
    /// 用户想的是「缩进两格」，而不是「缩进 34 点」。存字符数、用时再乘正文字号，
    /// 这样把字号从 17 调到 24，缩进会自己跟着变宽，「两个汉字」始终是两个字宽。
    private(set) var paragraphIndentCharacters: Double

    /// 正文**栏宽上限**（点）。默认取量程上限，也就是「不限」。
    ///
    /// ⚠️ 这个值和 `bodyContentWidthLimit` 不是一回事：这里存的是滑块上的数，
    /// 拖到最右端（量程上限）表示「不限宽」，真正的上限要看
    /// `bodyContentWidthLimit`（它会返回 `nil`）。
    private(set) var bodyContentWidth: Double

    /// 正文栏宽上限（点）。**`nil` = 不限**，正文铺满整个编辑器宽度。
    ///
    /// ### 为什么用「量程上限」表示「不限」
    /// 滑块只有一根，得让「不限」也有个位置。放在最右端的好处是：
    /// 默认值就是「跟随窗口」，谁都不会因为多了这一项而发现自己排版变了；
    /// 想收窄就往左拖，拖到底看到「不限」两个字也一眼明白是什么意思。
    var bodyContentWidthLimit: Double? {
        bodyContentWidth >= Limits.bodyContentWidth.upperBound ? nil : bodyContentWidth
    }

    /// 改「是否记住滚动位置」。值没变就什么都不做（不发通知、不写盘）
    func setRemembersScrollPosition(_ value: Bool) {
        guard value != remembersScrollPosition else { return }
        remembersScrollPosition = value
        save()
        postChange()
    }

    /// 改「高度按什么算」
    func setOutlineHeightMode(_ value: OutlineHeightMode) {
        guard value != outlineHeightMode else { return }
        outlineHeightMode = value
        save()
        postChange()
    }

    /// 改「高度百分比」。超出 `Limits.outlineHeightRatio` 的值会被夹到边界上
    func setOutlineHeightRatio(_ value: Double) {
        let clamped = clamp(value, to: Limits.outlineHeightRatio)
        guard clamped != outlineHeightRatio else { return }
        outlineHeightRatio = clamped
        save()
        postChange()
    }

    /// 改「最大高度」。超出 `Limits.outlineMaximumHeight` 的值会被夹到边界上
    func setOutlineMaximumHeight(_ value: Double) {
        let clamped = clamp(value, to: Limits.outlineMaximumHeight)
        guard clamped != outlineMaximumHeight else { return }
        outlineMaximumHeight = clamped
        save()
        postChange()
    }

    /// 改「表格最小列宽」。超出 `Limits.tableMinColumnWidth` 的值会被夹到边界上
    func setTableMinColumnWidth(_ value: Double) {
        let clamped = clamp(value, to: Limits.tableMinColumnWidth)
        guard clamped != tableMinColumnWidth else { return }
        tableMinColumnWidth = clamped
        save()
        postChange()
    }

    /// 改「表格最大列宽」。超出 `Limits.tableMaxColumnWidth` 的值会被夹到边界上
    func setTableMaxColumnWidth(_ value: Double) {
        let clamped = clamp(value, to: Limits.tableMaxColumnWidth)
        guard clamped != tableMaxColumnWidth else { return }
        tableMaxColumnWidth = clamped
        save()
        postChange()
    }

    // MARK: 改正文排版

    /// 改「正文字号」
    func setBodyFontSize(_ value: Double) {
        let clamped = clamp(value, to: Limits.bodyFontSize)
        guard clamped != bodyFontSize else { return }
        bodyFontSize = clamped
        save()
        postChange()
    }

    /// 改「行高倍数」
    func setLineHeightMultiple(_ value: Double) {
        let clamped = clamp(value, to: Limits.lineHeightMultiple)
        guard clamped != lineHeightMultiple else { return }
        lineHeightMultiple = clamped
        save()
        postChange()
    }

    /// 改「段落间距」
    func setParagraphSpacing(_ value: Double) {
        let clamped = clamp(value, to: Limits.paragraphSpacing)
        guard clamped != paragraphSpacing else { return }
        paragraphSpacing = clamped
        save()
        postChange()
    }

    /// 改「段落首行缩进」（单位是字符数，不是点）
    func setParagraphIndentCharacters(_ value: Double) {
        let clamped = clamp(value, to: Limits.paragraphIndentCharacters)
        guard clamped != paragraphIndentCharacters else { return }
        paragraphIndentCharacters = clamped
        save()
        postChange()
    }

    /// 改「正文栏宽上限」。拖到量程上限就是「不限」
    func setBodyContentWidth(_ value: Double) {
        let clamped = clamp(value, to: Limits.bodyContentWidth)
        guard clamped != bodyContentWidth else { return }
        bodyContentWidth = clamped
        save()
        postChange()
    }

    // MARK: 初始化

    init(fileURL: URL = MarkdownEditorSettings.defaultFileURL) {
        self.fileURL = fileURL
        // 先给一套默认值，再用盘上的内容覆盖 —— 这样「读文件失败」也能得到一份可用的配置
        self.remembersScrollPosition = Default.remembersScrollPosition
        self.outlineHeightMode = Default.outlineHeightMode
        self.outlineHeightRatio = Default.outlineHeightRatio
        self.outlineMaximumHeight = Default.outlineMaximumHeight
        self.tableMinColumnWidth = Default.tableMinColumnWidth
        self.tableMaxColumnWidth = Default.tableMaxColumnWidth
        self.bodyFontSize = Default.bodyFontSize
        self.lineHeightMultiple = Default.lineHeightMultiple
        self.paragraphSpacing = Default.paragraphSpacing
        self.paragraphIndentCharacters = Default.paragraphIndentCharacters
        self.bodyContentWidth = Default.bodyContentWidth
        load()
    }

    /// 原因见 `MarkdownBlock` / `OutlineCoordinator` 里 `nonisolated deinit` 的长注释：
    /// app target 开了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，
    /// 「不继承 UIView 的 class」不写这一行就可能踩 Swift 6.2 运行时的野指针 free。
    /// 本类只有值类型成员，声明成 nonisolated 完全安全。
    nonisolated deinit {}

    // MARK: 读 / 写

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        if let value = payload.remembersScrollPosition { remembersScrollPosition = value }
        // 认不出来的模式名就保持默认，不能让它把别的设置一起带走
        if let raw = payload.outlineHeightMode, let value = OutlineHeightMode(rawValue: raw) {
            outlineHeightMode = value
        }
        // 盘上的数值也要夹一道：文件可能被手改过，或者是很早以前的版本写的
        if let value = payload.outlineHeightRatio {
            outlineHeightRatio = clamp(value, to: Limits.outlineHeightRatio)
        }
        if let value = payload.outlineMaximumHeight {
            outlineMaximumHeight = clamp(value, to: Limits.outlineMaximumHeight)
        }
        if let value = payload.tableMinColumnWidth {
            tableMinColumnWidth = clamp(value, to: Limits.tableMinColumnWidth)
        }
        if let value = payload.tableMaxColumnWidth {
            tableMaxColumnWidth = clamp(value, to: Limits.tableMaxColumnWidth)
        }
        if let value = payload.bodyFontSize {
            bodyFontSize = clamp(value, to: Limits.bodyFontSize)
        }
        if let value = payload.lineHeightMultiple {
            lineHeightMultiple = clamp(value, to: Limits.lineHeightMultiple)
        }
        if let value = payload.paragraphSpacing {
            paragraphSpacing = clamp(value, to: Limits.paragraphSpacing)
        }
        if let value = payload.paragraphIndentCharacters {
            paragraphIndentCharacters = clamp(value, to: Limits.paragraphIndentCharacters)
        }
        if let value = payload.bodyContentWidth {
            bodyContentWidth = clamp(value, to: Limits.bodyContentWidth)
        }
    }

    private func save() {
        let payload = Payload(remembersScrollPosition: remembersScrollPosition,
                              outlineHeightMode: outlineHeightMode.rawValue,
                              outlineHeightRatio: outlineHeightRatio,
                              outlineMaximumHeight: outlineMaximumHeight,
                              tableMinColumnWidth: tableMinColumnWidth,
                              tableMaxColumnWidth: tableMaxColumnWidth,
                              bodyFontSize: bodyFontSize,
                              lineHeightMultiple: lineHeightMultiple,
                              paragraphSpacing: paragraphSpacing,
                              paragraphIndentCharacters: paragraphIndentCharacters,
                              bodyContentWidth: bodyContentWidth)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        do {
            // 目录可能还不存在（第一次跑），先建出来
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                   withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // 配置写不进去不值得打扰用户，也不要断言崩掉 —— 内存里的值已经生效了，
            // 只是这次会话结束后会丢掉，下次启动退回默认
        }
    }

    /// 把值夹进范围
    private func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// 告诉外面「配置变了」。设置页拨一下，大纲面板要当场跟着变，不用重启
    private func postChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}

// MARK: - 套到大纲面板的外观参数上

extension MarkdownEditorSettings {

    /// 把当前的高度配置写进大纲面板的外观参数。
    ///
    /// ### 为什么这个换算放在这里，而不是写在大纲面板里
    /// 面板那个文件刻意保持「不认识 App 层的任何东西」—— 它只认
    /// `MarkdownOutlineAppearance` 里的字段。反过来由配置侧知道「模式的枚举怎么翻译成
    /// 面板能懂的参数」，依赖方向就一直是「App 层 → 组件」，组件可以单独拿走复用。
    ///
    /// ### 两个值的写法
    /// `maximumHeight` 每次都照配置写，不管当前模式用不用它 —— 这样切回
    /// 「按最大高度」时它还是用户上次调好的值。真正决定用哪个的是 `heightRatio`：
    /// 百分比模式给它比例，「按最大高度」模式给它 `nil`（`nil` = 这一项不参与）
    func applyOutlineHeight(to appearance: inout MarkdownOutlineAppearance) {
        appearance.maximumHeight = CGFloat(outlineMaximumHeight)
        switch outlineHeightMode {
        case .percentage:
            appearance.heightRatio = CGFloat(outlineHeightRatio)
        case .maximumHeight:
            appearance.heightRatio = nil
        }
    }

    /// 把表格列宽的配置写进编辑器主题的表格样式里。
    ///
    /// ### 「最小 > 最大」怎么办
    /// 两个滑块各自独立，用户完全可能把最小值拖到比最大值还大
    /// （最小值量程上限 200、最大值量程下限 80，中间是重叠的）。
    /// 不拦着的话渲染层 `min(max(理想宽, min), max)` 会拿 max 当最终结果，
    /// 「最小列宽」悄悄失效。这里以最大值为准，把最小值压回去。
    func applyTableColumnWidths(to theme: inout MarkdownTheme) {
        var minValue = tableMinColumnWidth
        let maxValue = tableMaxColumnWidth
        if minValue > maxValue { minValue = maxValue }
        theme.table.minColumnWidth = CGFloat(minValue)
        theme.table.maxColumnWidth = CGFloat(maxValue)
    }
}

// MARK: - 套到编辑器的正文字体 / 段落样式上

extension MarkdownEditorSettings {

    /// 把「正文排版」这一组的配置写进编辑器主题。
    ///
    /// ### 为什么这几个值不直接写进 `MarkdownTheme.default`
    /// 主题是**渲染层**的样式表，它只该描述「长什么样」，不该认识「用户存了什么」。
    /// 依赖方向保持「App 层 → 组件」，组件才能被单独拿走复用 ——
    /// 和上面那两个 `apply...` 是同一个理由。
    ///
    /// ### 调用之后必须重新渲染
    /// 字号、行高、段间距、首行缩进全都是**渲染时**烙进字体和 `NSParagraphStyle` 里的，
    /// 只改主题里的数值，屏幕上那篇文字纹丝不动。改完要调
    /// `MarkdownTextView.refreshTheme()` 整篇重排一遍。
    func applyTypography(to theme: inout MarkdownTheme) {
        // 字号放最前面：下面的首行缩进要按**新字号**换算
        theme.applyBodyFontSize(CGFloat(bodyFontSize))
        theme.lineHeightMultiple = CGFloat(lineHeightMultiple)
        theme.paragraphSpacing = CGFloat(paragraphSpacing)
        // 用户选的是「缩几个字」，这里乘上字号换成点 ——
        // 字号调大以后「缩进两格」还是两格，不会变成一格半
        theme.paragraphIndent = CGFloat(paragraphIndentCharacters) * theme.bodyFont.pointSize
    }
}
