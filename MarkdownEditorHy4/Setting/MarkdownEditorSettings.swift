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
// 「大纲留白」那一项要按设备判断生不生效（见 `MarkdownEditorSettings.supportsReservingSpaceForOutline`）
import MultiTabController

/// 大纲面板的**宽度**按什么算。
///
/// 和高度那对一样做成互斥的二选一：
/// - 「按百分比」→ 宽度 = 编辑器（父视图）宽度 × 百分比，窗口拉宽面板也跟着宽；
/// - 「固定宽度」→ 永远是那个点数，窗口怎么变都不影响（窗口太窄时会被自动收窄，不会顶爆布局）。
enum OutlineWidthMode: String, Codable, CaseIterable {
    /// 宽度最多占编辑器（父视图）宽度的百分之几
    case percentage
    /// 宽度是多少点（pt）
    case fixedPoints

    /// 设置页上显示的名字
    var displayName: String {
        switch self {
        case .percentage: return "按百分比"
        case .fixedPoints: return "固定宽度"
        }
    }
}

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

/// 图片的**最大宽度**按什么算。
///
/// 和 `OutlineHeightMode` 一样做成互斥的二选一：
/// - 「按百分比」→ 最大宽度 = 编辑器可用宽度 × 百分比，窗口拉宽图也跟着变宽；
/// - 「固定宽度」→ 永远是那个点数，窗口怎么变都不影响。
enum ImageWidthMode: String, Codable, CaseIterable {
    /// 宽度最多占编辑器宽度的百分之几
    case percentage
    /// 宽度最多是多少点（px）
    case fixedPoints

    /// 设置页上显示的名字
    var displayName: String {
        switch self {
        case .percentage: return "按百分比"
        case .fixedPoints: return "固定宽度"
        }
    }
}

/// 粘贴 / 插入图片时，图片文件存到哪儿。
///
/// 四个选项是**互斥**的，用户在设置页上单选。正文里写什么路径由这一项决定（见 `ImageAssetStore`）：
/// - 「当前文件夹」写文件名；
/// - 「assets」写 `assets/名字`；
/// - 「同名文件夹」写 `笔记名/名字`；
/// - 「指定路径」写完整路径 —— 图片在这个位置之外，相对路径没法表达。
enum ImageInsertionMode: String, Codable, CaseIterable {
    /// 和笔记摆在同一层目录（`./`）
    case currentFolder
    /// 笔记旁边的 `./assets` 子目录
    case assetsFolder
    /// 和笔记同名的目录（`游记.md` → `游记/`）
    case documentFolder
    /// 用户自己挑的一个固定目录。⚠️ 只有 Mac 上能选，见 `selectableCases`
    case customFolder

    /// 设置页菜单上显示的名字
    var displayName: String {
        switch self {
        case .currentFolder: return "复制到当前文件夹（./）"
        case .assetsFolder: return "复制到 ./assets 文件夹"
        case .documentFolder: return "复制到与笔记同名的文件夹"
        case .customFolder: return "复制到指定路径…"
        }
    }

    /// 这个平台上能选哪几项。
    ///
    /// ### 为什么 iPhone / iPad 上不放「指定路径」
    /// 选目录靠的是系统的文件夹选择框，它在 Mac 上有；iPhone / iPad 上要走「文件」App 那一套，
    /// 用户很可能挑到一个自己以后再也找不到的地方（图片存进去了、正文里是一条长路径，看着像丢了）。
    /// 与其给个容易踩坑的入口，不如这一项在手机 / 平板上干脆不出现。
    static var selectableCases: [ImageInsertionMode] {
        #if targetEnvironment(macCatalyst)
        return allCases
        #else
        return allCases.filter { $0 != .customFolder }
        #endif
    }
}

/// 粘贴 / 插入的图片，**文件叫什么名字**。
///
/// 三种规则是互斥的，用户在设置页上单选。不管选哪种，**后缀都跟着图片的真实格式走**
/// （`jpg` / `png` / `gif`…）—— 不然会出现 `x.png` 里装着 JPEG 这种自相矛盾的名字。
///
/// ### 三种规则的取舍
/// - 「原始文件名」：Finder 里复制过来的图叫什么就叫什么（`截屏2026-10-15.png`），最好认；
///   但截图、网页里的图**没有原始名字**，那些会退回哈希，同一个目录里就会混着两种风格。
/// - 「当前时间」：名字永远唯一、一眼看得出什么时候存的；代价是看名字不知道图是什么内容。
/// - 「内容哈希」：名字不重、同一张图反复粘也只会有一份；代价是完全看不出图是什么。
///
/// ### 重名了怎么办（三种规则都适用）
/// 落盘前会先看目标目录里有没有同名文件，有就改用**内容哈希**兜底（见 `MarkdownImageFileStore.store`）。
/// 所以「用原始文件名」时连着粘两次同一张图，磁盘上会是 `截屏.png` + `<哈希>.png` 两份。
enum ImageNameMode: String, Codable, CaseIterable {
    /// 用图片原来的文件名（没有原始名字时退回哈希）
    case originalName
    /// 用当前时间，`20261015_172442` 这种
    case timestamp
    /// 用图片内容算出来的 md5
    case contentHash

    /// 设置页菜单上显示的名字
    var displayName: String {
        switch self {
        case .originalName: return "使用原始文件名"
        case .timestamp: return "使用当前时间"
        case .contentHash: return "使用文件 MD5 哈希"
        }
    }
}

/// 编辑器的用户配置。
///
/// ### 颜色主题存在这里的是什么
/// 只存「选了哪一套内置主题」（`MarkdownColorTheme`）和「有没有指定一份 JSON 文件」。
/// 颜色值本身一个都不在这儿 —— 它们全在渲染层，将来渲染层单独开源，这一层不用改。
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

    /// 「大纲展开时正文右侧留白」在**当前设备**上生不生效。
    /// 设置页也拿它决定要不要显示那个开关（见 `SettingsSection.rows`）。
    ///
    /// ### 为什么 iPhone 上直接不给
    /// iPhone 竖屏的可用宽度就三百来点，大纲卡片本身要占掉三成到一半；
    /// 正文再让出这么一块，每行就剩两三个字 —— 与其给一个「拨了也读不舒服」的开关，
    /// 不如固定不让，设置里也不显示（免得拨完发现没反应）。
    ///
    /// ### 怎么判断设备
    /// 用库里的 `DeviceHelper.currentLayout`，**别自己写** `userInterfaceIdiom == .phone` ——
    /// Mac Catalyst 的 idiom 也是 `.phone`，自己判会把 Mac 一起判成 iPhone。
    static var supportsReservingSpaceForOutline: Bool {
        DeviceHelper.currentLayout != .iPhone
    }

    // MARK: 默认值

    private enum Default {
        /// 「记住目录大纲滚动位置」默认打开
        static let remembersScrollPosition = true

        /// 「粘贴网页内容时转成 Markdown」默认打开：
        /// 复制网页的人本来就是冲着「把内容搬进来」来的，默认转出来的才是他想要的；
        /// 想要原样 HTML 的人可以来关掉
        static let pastesHTMLAsMarkdown = true

        /// 「网页图片存到本地」默认打开。
        /// 网页里复制来的图片原本只是一串网络地址，原网页改了、删了或者断网，笔记里的图就全没了。
        /// 存一份到本地，笔记才算独立。
        static let savesWebImagesLocally = true

        /// 「显示行号」默认**关闭**：对读代码 / 校对长文的人来说它有用，
        /// 但默认打开会白占正文左边一条带子 —— 纯读文档的人不需要它
        static let showsLineNumbers = false

        /// 「引用内容铺淡背景」默认**关闭**：默认是只有左边一条竖条的干净样子，
        /// 铺底色会让页面多出一大块浅色，不是所有人都喜欢
        static let showsQuoteBackground = false

        /// 「行内代码的反引号也铺底色」默认**关闭**：
        /// 默认灰块只包住代码正文，反引号留在外面，一眼能分出「哪是语法、哪是内容」
        static let showsInlineCodeBacktickBackground = false

        /// 「只读模式」默认**关闭**：默认是能正常编辑的。
        /// 打开之后能选能复制、也能移动光标，但改不动一个字（理由见 `MarkdownTextView.isReadOnly`）
        static let isReadOnly = false

        /// 「大纲展开时正文右侧留白」默认**打开**：
        /// 展开的大纲是一张浮在正文上面的卡片，正文让出它那块宽度，字才不会被卡片压住。
        /// ⚠️ 收起成小方块时不让（理由见 `MarkdownDocumentViewController.outlineTrailingInset`）
        /// ⚠️ iPhone 上这个默认值等于没写：那边固定不让（见 `supportsReservingSpaceForOutline`）
        static let reservesSpaceForOutline = true

        /// 大纲面板的默认外观 —— 「宽度默认多少点」这一项**从它读**，免得同一个数字在配置层和组件层各写一份（改了一边忘了另一边）。
        /// 只构造一次，别在下面反复访问
        static let outlineAppearance = MarkdownOutlineAppearance()
        /// 宽度默认「固定宽度」= 300 点（就是 `MarkdownOutlineAppearance.width` 那个数）
        static let outlineWidthMode: OutlineWidthMode = .fixedPoints
        /// 切到「按百分比」时默认占编辑器宽度的 30%
        static let outlineWidthRatio: Double = 0.3
        static let outlineWidthPoints = Double(outlineAppearance.width)
        /// 面板背景默认**完全不透明**（就是 `MarkdownOutlineAppearance.backgroundOpacity` 那个数）
        static let outlineBackgroundOpacity = Double(outlineAppearance.backgroundOpacity)

        /// 大纲高度默认按「父视图高度的 70%」算上限
        static let outlineHeightMode: OutlineHeightMode = .percentage
        static let outlineHeightRatio: Double = 0.7
        static let outlineMaximumHeight: Double = 360
        /// 表格列宽默认值，和渲染层 `TableStyle` 的默认值保持一致
        static let tableMinColumnWidth: Double = 64
        static let tableMaxColumnWidth: Double = 280

        /// 表格源码字号**默认不单独指定**（`nil`）：跟着正文字号走（正文 - 1）。
        ///
        /// 为什么不直接给个固定 16：以前源码字号就是从正文推出来的。
        /// 要是这里一上来就写死 16，用户把正文调到 24 之后，源码会突然比正文小一大截 ——
        /// 没人动过这一项，外观却变了。留一个「没设过」的状态，默认表现才和以前一致。
        static let tableSourceFontSizeOverride: Double? = nil
        /// 表格源码文字颜色默认**不覆盖**（`nil`）：跟着主题 / 配色里那一色走，换主题时它跟着换
        static let tableSourceTextColorHex: String? = nil

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
        /// 无序列表圆点的直径默认 = 主题里那个值（改主题就跟着变，不在这里写第二份数字）
        static let bulletDiameter = Double(theme.bulletDiameter)

        /// 颜色主题默认「默认」：一套都不覆盖，全部用 `MarkdownTheme` 自带的颜色
        static let colorTheme = MarkdownColorTheme.default
        /// 自定义主题 JSON 默认「没有」—— 用户没指定过就不加载任何文件
        static let customThemeFileName: String? = nil

        /// 图片尺寸默认值同样**从主题读**，不在这里写第二份数字（理由同上）
        static let imageWidthMode: ImageWidthMode = .percentage
        static let imageWidthRatio = Double(theme.image.maxWidthRatio ?? 0.5)
        static let imageWidthPoints = Double(theme.image.maxWidthPoints)
        /// 图片最大高度默认 **420 点**（从主题读，不在这里写第二份数字）
        static let imageMaxHeight = Double(theme.image.maxHeight)

        /// 图片存到哪儿，默认「笔记旁边的 ./assets」。
        ///
        /// 挑这一项当默认的理由：图片和正文分开摆，笔记目录一眼看过去还是清清爽爽的一排 `.md`；
        /// 而「当前文件夹」会把目录塞满图片，「指定路径」又要用户先做一次选择、没选之前存不了
        static let imageInsertionMode: ImageInsertionMode = .assetsFolder
        /// 「指定路径」那个文件夹默认**没有** —— 用户没选过就是 nil
        static let imageCustomFolderPath: String? = nil
        /// 图片文件名默认「用原始文件名」：Finder 里拖过来的图叫什么就叫什么，最好认；
        /// 拿不到原始名字的那些（截图、网页图）会自己退回哈希，不会存不下
        static let imageNameMode: ImageNameMode = .originalName
    }

    /// 各项数值的合法范围。
    ///
    /// ### 为什么要在这里夹一道，而不是只靠设置页的滑块
    /// 配置是**落盘**的，能被手改、能被更早的版本写坏、也许多年以后换了套界面。
    /// 只在界面上限制范围的话，一个 `ratio: 999` 进来就会把面板高度算成天文数字。
    /// 夹在「配置的入口」这一层，别的使用方就永远能相信拿到的值是可用的。
    enum Limits {
        /// 大纲宽度百分比的合法范围。15% 再窄标题就整段被截，50% 已经是「编辑区让出一半」
        static let outlineWidthRatio: ClosedRange<Double> = 0.15...0.8
        /// 大纲固定宽度的合法范围（点）。
        ///
        /// ⚠️ 量程的**上下界一起**不能和别人撞车（表格最大列宽 600、图片最大高度 1600 都已占用）—— 设置页的测试是按「量程」在视图树里找滑块的，两行的上下界都一样就分不出谁是谁。
        ///
        /// 下限 160 比 `MarkdownOutlineAppearance.minimumWidth`（148）留了一点余量，免得用户在设置页上挑了个比「自动保底」还小的值、看到数字对不上
        static let outlineWidthPoints: ClosedRange<Double> = 160...520
        static let outlineHeightRatio: ClosedRange<Double> = 0.3...1.0
        static let outlineMaximumHeight: ClosedRange<Double> = 120...900
        /// 大纲面板背景不透明度的合法范围。`1` = 完全不透明。
        ///
        /// 下限 **0.2** 是需求指定的：再往下拖，卡片就快看不见了，标题会和背后透出来的正文叠在一起、认不清。
        ///
        /// ⚠️ `1` 同时还是「卡片戴不戴毛玻璃」的分界线：只有 100% 这一档是厚实的实心卡片，往下拖会关掉毛玻璃、让背后正文清清楚楚透出来（见 `MarkdownOutlineView.applyBackgroundOpacity`）。
        ///
        /// ⚠️ 上限 `1.0` 和 `outlineHeightRatio` 撞了（都是 1）—— 这正是「量程必须连下限一起看」的原因：两行的下限 0.2 / 0.3 不一样，还能分得开
        static let outlineBackgroundOpacity: ClosedRange<Double> = 0.2...1.0
        /// 表格「最小列宽」的合法范围
        static let tableMinColumnWidth: ClosedRange<Double> = 32...200
        /// 表格「最大列宽」的合法范围
        static let tableMaxColumnWidth: ClosedRange<Double> = 80...600
        /// 表格源码字号的合法范围（点）。
        ///
        /// 下限 9 是「再小就认不出字」的边界，上限 28 和正文字号的上限齐平。
        /// ⚠️ 量程的**上下界一起**不能和别的行撞车（正文字号 12...28、圆点 4...16 都已占用）——
        /// 设置页的测试是按「量程」在视图树里找滑块的，两行完全一样就分不出谁是谁。
        static let tableSourceFontSize: ClosedRange<Double> = 9...28

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
        /// 无序列表圆点直径的合法范围（点）。
        ///
        /// 4 以下在高分屏上就是一个模糊的小点，16 已经和正文一个字差不多大、压过文字本身了。
        /// ⚠️ 量程的**上下界一起**不能和别的行撞车（表格最小列宽 32...200、段落首行缩进 0...4 都已占用）—— 设置页的测试是按「量程」在视图树里找滑块的，两行的上下界都一样就分不出谁是谁。
        static let bulletDiameter: ClosedRange<Double> = 4...16

        /// 图片宽度百分比的合法范围。20% 再小就看不清了，90% 基本就是满栏
        static let imageWidthRatio: ClosedRange<Double> = 0.2...0.9
        /// 图片固定宽度的合法范围（点）
        static let imageWidthPoints: ClosedRange<Double> = 80...800
        /// 图片最大高度的合法范围（点）。
        ///
        /// ⚠️ 量程的**上下界一起**不能和 `bodyContentWidth` 的 320...1200 撞车 —— 设置页的测试是按「量程」在视图树里找滑块的，两行完全一样就分不出谁是谁。
        static let imageMaxHeight: ClosedRange<Double> = 120...1600
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
        /// 粘贴网页复制来的富文本时，要不要先转成 markdown 源码
        var pastesHTMLAsMarkdown: Bool?
        /// 网页内容里的图片要不要下载下来存到本地
        var savesWebImagesLocally: Bool?
        /// 正文左边要不要显示行号
        var showsLineNumbers: Bool?
        /// 引用块的内容（竖条右边那一整片）要不要铺一层淡背景
        var showsQuoteBackground: Bool?
        /// 行内代码两侧的反引号要不要跟着代码正文一起铺底色
        var showsInlineCodeBacktickBackground: Bool?
        /// 只读模式：能选能复制但不能改
        var isReadOnly: Bool?
        /// 大纲展开时，正文要不要往左让出它那块宽度
        var reservesSpaceForOutline: Bool?
        /// 大纲宽度那一组。模式同样存字符串，理由见下面 `outlineHeightMode` 的注释
        var outlineWidthMode: String?
        var outlineWidthRatio: Double?
        var outlineWidthPoints: Double?
        /// ⚠️ 这里存**字符串**而不是枚举本身：将来枚举改了名、或者文件被手改成一个
        /// 现在的版本不认识的值时，用枚举解码会让**整份** Payload 解不出来、
        /// 所有设置一起复位。存字符串的话只有这一项退回默认，别的照旧
        var outlineHeightMode: String?
        var outlineHeightRatio: Double?
        var outlineMaximumHeight: Double?
        /// 大纲面板背景的不透明度
        var outlineBackgroundOpacity: Double?
        var tableMinColumnWidth: Double?
        var tableMaxColumnWidth: Double?
        /// 表格源码样式。字号没设过就是「跟随正文」，所以是可选
        var tableSourceFontSize: Double?
        /// 表格源码文字颜色的覆盖值（`#rrggbb` / `#rrggbbaa`）。没设过就是「跟随主题」
        var tableSourceTextColorHex: String?
        /// 正文排版那一组。同样都写成可选的，老配置文件里没有就各自退默认
        var bodyFontSize: Double?
        var lineHeightMultiple: Double?
        var paragraphSpacing: Double?
        var paragraphIndentCharacters: Double?
        var bodyContentWidth: Double?
        var bulletDiameter: Double?
        /// 图片尺寸那一组
        var imageWidthMode: String?
        var imageWidthRatio: Double?
        var imageWidthPoints: Double?
        var imageMaxHeight: Double?
        /// 颜色主题那一组（都写成可选 + 字符串，理由同前）
        var colorTheme: String?
        var customThemeFileName: String?
        /// 插入图片那一组。模式存字符串的理由和上面几个模式一样
        var imageInsertionMode: String?
        /// 「指定路径」那个文件夹的完整路径
        var imageCustomFolderPath: String?
        /// 图片文件名按什么起（原始名 / 时间 / 哈希）
        var imageNameMode: String?
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

    /// 粘贴网页里复制来的富文本时，先把它转成 **markdown 源码** 再插进来。默认 `true`（开）。
    ///
    /// 打开时：从浏览器、Word、备忘录复制内容再粘贴，粘进来的是 `# 标题` / `- 列表` / `[链接](地址)` 这样的源码，而不是一堆 `<div>`。
    ///
    /// 关掉时：剪贴板里有什么就原样插什么。复制的是纯文本时这一项没有区别；
    /// 只有剪贴板里带 HTML（从网页、Word 那边复制的）才看得出开关的效果。
    ///
    /// ### 为什么做成开关
    /// 转换是「尽力而为」的 —— 结果不保证和原页面一模一样。
    /// 想保留原始 HTML（比如要粘一段现成的网页代码）的人得有办法关掉它。
    private(set) var pastesHTMLAsMarkdown: Bool

    /// 粘贴网页内容时，把正文里指向网络的图片下载下来存到本地。默认 `true`（开）。
    ///
    /// 打开时：网页里的图会先下载一份，按「插入图片」那一组的选择存进对应目录，正文里的地址换成本地路径。
    /// 这样断网、或者原网页把图删了，笔记里的图照样打得开。
    ///
    /// 关掉时：正文里保留原来的网络地址，图能不能显示全看那张网还在不在。
    ///
    /// ### 什么时候才轮得到这一项
    /// 它挂在「粘贴网页内容时转成 Markdown」后面：那个开关关着时，粘进来的是纯文本，正文里根本没有图片地址，这一项也就无从下手。
    private(set) var savesWebImagesLocally: Bool

    /// 正文左边要不要显示行号。默认 `false`（关）。
    ///
    /// 打开时编辑器左边多出一条装订线，按**屏幕上看到的那一行的序号**编号
    /// （渲染文本和源码不是一对一 —— 图片、表格只占一个字符位却吃掉一大段源码 ——
    /// 所以行号数的是「屏幕上第几行」，不是「源文件第几行」）。
    private(set) var showsLineNumbers: Bool

    /// 引用块的内容要不要铺一层淡背景。默认 `false`（关）。
    ///
    /// 打开之后，引用块除了左边那条竖条之外，右边那一整片会铺上一层极淡的底色
    /// （颜色 = 竖条颜色透明度压到 10%，见 `MarkdownTheme.quoteBackground`）。
    ///
    /// ⚠️ 它是**渲染时**烙进富文本的，改完得把整篇重新渲染一遍才生效。
    private(set) var showsQuoteBackground: Bool

    /// 行内代码两侧的反引号要不要跟着代码正文一起铺底色。默认 `false`（关）。
    ///
    /// 关着的时候灰块只包住代码正文，反引号留在灰块外边（它们本来就是语法标记）；
    /// 打开之后整段是一块完整的灰底，和 2026-10-17 之前的样子一样。
    ///
    /// ⚠️ 它和颜色 / 字号一样是**渲染时**烙进富文本的，改完得整篇重新渲染才生效。
    private(set) var showsInlineCodeBacktickBackground: Bool

    /// 只读模式。默认 `false`（关），也就是正常编辑。
    ///
    /// 打开后：光标能移动、文字能选中也能复制，但**输入、粘贴、格式化、点复选框**这些会改源码的入口全部失灵
    /// （拦在哪几道见 `MarkdownTextView.isReadOnly` 的注释）。
    ///
    /// ### 开关在哪儿
    /// 入口在文档页右上角「⋯」菜单里那一条带勾的「只读模式」（`MarkdownDocumentViewController.readOnlyAction`），
    /// 这里是它**存盘**的地方 —— 关掉 App 再回来还是上次的形态。
    private(set) var isReadOnly: Bool

    /// 大纲面板**展开**时，正文要不要往左让出它那一块宽度。默认 `true`（开）。
    ///
    /// ### 为什么要有这一项
    /// 大纲是一张浮在正文上面的卡片（`MarkdownOutlineView`），展开后能盖住右边三成甚至一半的字。
    /// 打开这一项，正文的右边距就跟着面板宽度走 —— 字不再被卡片压住，代价是每行能排的字变少。
    /// 觉得「宁可让卡片盖着也要满宽读」的人可以关掉。
    ///
    /// ### 收起时不让
    /// 收起态只是右上角一个小方块（46×36），只压住一个角，为它把整列正文挤窄不值当。
    ///
    /// ### iPhone 上不生效
    /// 屏幕太窄，让完只剩一条缝。那边这个开关连设置页都不显示
    /// （判断收在 `supportsReservingSpaceForOutline`，别在各处各写一遍）
    ///
    /// ### 只改布局，不改文字
    /// 它动的是编辑器右边那条约束的 constant（见 `MarkdownDocumentViewController.updateEditorTrailingInset`），
    /// 不碰任何字体 / 段落样式，所以不会重排富文本 —— 但宽度一变正文照样要重新折行，步骤在编辑器内部。
    private(set) var reservesSpaceForOutline: Bool

    /// 大纲面板的宽度按什么算，默认「固定宽度」。
    /// 两种模式的详细解释见 `OutlineWidthMode`
    private(set) var outlineWidthMode: OutlineWidthMode

    /// 「按百分比」模式下，面板宽度占编辑器（父视图）宽度的百分之几。默认 `0.3`（30%）。
    ///
    /// 这个模式下 `outlineWidthPoints` 完全不参与计算。
    /// 实际宽度还会被父视图宽度压一道（不能盖住整个编辑区），见 `MarkdownOutlineView.effectiveWidth`
    private(set) var outlineWidthRatio: Double

    /// 「固定宽度」模式下，面板的宽度（点）。默认 `300`。
    ///
    /// ⚠️ 它是**理想宽度**不是死值：窗口窄到放不下时会按比例收窄，免得一个大数字把左边的编辑区全盖住
    private(set) var outlineWidthPoints: Double

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

    /// 大纲面板**背景**的不透明度。默认 `1`（完全不透明）。
    ///
    /// 面板是一张浮在正文上面的卡片：`1` 表示背后的正文被完全盖住，越小透出来越多（透出来的是糊过的正文，不是清清楚楚的字 —— 卡片本身有毛玻璃）。
    ///
    /// 这一项只管**背景**，标题文字本身永远是实色，不会跟着变淡
    private(set) var outlineBackgroundOpacity: Double

    /// 表格**最窄**的一列有多宽（点）。默认 `64`。
    ///
    /// 列内容再短，列宽也不小于这个值 —— 不然「姓名」这种两字列会挤成一团。
    private(set) var tableMinColumnWidth: Double

    /// 表格**最宽**的一列有多宽（点）。默认 `280`。
    ///
    /// 某一列内容特别长（贴了个长链接）时，列宽到这个值就封顶，
    /// 多出来的文字换行，别把别的列挤没了。
    private(set) var tableMaxColumnWidth: Double

    /// 用户**单独指定**的表格源码字号（点）。`nil` = 没设过，跟着正文字号走。
    ///
    /// 为什么要分「没设过」和「设成某个值」：默认值是从正文字号推出来的（正文 - 1），
    /// 这样用户调正文时源码会跟着变，看起来才是一套；只有他真去拖了设置页那一根滑块，
    /// 才固化成他挑的数（之后不再跟着正文跑）。
    private(set) var tableSourceFontSizeOverride: Double?

    /// 表格源码**实际**用的字号（点）：没单独设过就跟正文（正文 - 1，至少 9）。
    var tableSourceFontSize: Double {
        tableSourceFontSizeOverride
            ?? max(Limits.tableSourceFontSize.lowerBound, bodyFontSize - 1)
    }

    /// 表格源码文字颜色的覆盖值（十六进制）。`nil` = 跟随主题 / 配色。
    ///
    /// ### 为什么要一个独立的覆盖位
    /// 主题里本来就有这一色（配色表的「表格源码文字」，主题页也能逐色调）。
    /// 但用户常常只是想「这篇源码太淡了，调深一点」，不值得为此换一套主题 ——
    /// 所以设置页也给一个入口，选完就固定用它，换主题也不影响。
    ///
    /// ⚠️ 它的优先级**高于配色表**（套完配色之后才写进主题），否则换个主题就被盖掉了。
    private(set) var tableSourceTextColorHex: String?

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

    /// 无序列表左侧那个圆点画多大（点）。默认取主题里的值。
    ///
    /// 圆点是渲染时按这个直径画出来的图片附件，只改配置不动画面 —— 改完要整篇重渲染（和字号那一组一样）。
    private(set) var bulletDiameter: Double

    /// 正文栏宽上限（点）。**`nil` = 不限**，正文铺满整个编辑器宽度。
    ///
    /// ### 为什么用「量程上限」表示「不限」
    /// 滑块只有一根，得让「不限」也有个位置。放在最右端的好处是：
    /// 默认值就是「跟随窗口」，谁都不会因为多了这一项而发现自己排版变了；
    /// 想收窄就往左拖，拖到底看到「不限」两个字也一眼明白是什么意思。
    var bodyContentWidthLimit: Double? {
        bodyContentWidth >= Limits.bodyContentWidth.upperBound ? nil : bodyContentWidth
    }

    // MARK: 图片尺寸

    /// 图片的**最大宽度**按什么算，默认「按百分比」。两种模式的解释见 `ImageWidthMode`
    private(set) var imageWidthMode: ImageWidthMode

    /// 「按百分比」模式下，图片最多占编辑器宽度的百分之几。默认 `0.5`（一半）。
    ///
    /// 和正文的「行宽上限」是两回事：那个管文字排多宽，这个管图片画多大。
    private(set) var imageWidthRatio: Double

    /// 「固定宽度」模式下图片的最大宽度（点）。默认 `200`。
    private(set) var imageWidthPoints: Double

    // MARK: 颜色主题

    /// 用哪一套内置配色，默认「默认」（= 不覆盖，全用 `MarkdownTheme` 自带的颜色）。
    ///
    /// 三套可选：`default` / `vue` / `vueDark`，名字和颜色都由渲染层提供，这里只记选择。
    private(set) var colorTheme: MarkdownColorTheme

    /// 用户自己指定的那份主题 JSON 的**文件名**（只在设置页上显示用）。
    ///
    /// `nil` = 用户没指定过，一律用内置主题的颜色。
    ///
    /// ### 为什么这里只记名字
    /// 内容本身由 `MarkdownCustomThemeStore` 保管（挑完就拷进 App 自己的目录），
    /// 这层只留一个「显示给用户看」的名字 —— 存路径没用，下次启动那份路径已经读不了了。
    private(set) var customThemeFileName: String?

    /// 图片的最大高度（点）。默认 `420`。
    ///
    /// 只防「一张长图撑爆屏幕」，正常大小的图根本碰不到这个上限。
    /// 跟窗口高度无关：用户几乎不会去动这个值，不值得为它每次拉窗口都重排整篇文档。
    private(set) var imageMaxHeight: Double

    // MARK: 插入图片

    /// 粘贴 / 插入的图片存到哪儿。默认「笔记旁边的 ./assets」。四种选择的区别见 `ImageInsertionMode`
    private(set) var imageInsertionMode: ImageInsertionMode

    /// 「复制到指定路径」那一项用的文件夹的**完整路径**。`nil` = 用户还没选过。
    ///
    /// ### 为什么这里只有路径
    /// App 在 Mac Catalyst 上开了沙盒（见 `MarkdownEditorHy4.entitlements`），
    /// 用户挑的文件夹在容器外时，这里只记下了路径，没有保存 security-scoped bookmark。
    /// 结果就是往这个目录写图片会失败，`ImageAssetStore` 会退回 `./assets` 并提示用户。
    /// 要让它跨启动可用，得在这个回调里补一次授权，再把书签存下来（参考 `ExternalDocumentAccess`）。
    private(set) var imageCustomFolderPath: String?

    /// 粘贴 / 插入的图片**文件叫什么名字**。默认「用原始文件名」。三种规则的取舍见 `ImageNameMode`
    private(set) var imageNameMode: ImageNameMode

    /// 「指定路径」那个文件夹，转成 `URL` 给落盘用。没选过、或者存的是空串时返回 `nil`
    var imageCustomFolderURL: URL? {
        guard let imageCustomFolderPath, !imageCustomFolderPath.isEmpty else { return nil }
        return URL(fileURLWithPath: imageCustomFolderPath, isDirectory: true)
    }

    /// 改「插入的图片存到哪儿」。
    ///
    /// ### 这里为什么不发「配置变了」广播
    /// 别的几组设置都发，是因为它们会改变**屏幕上已经有的内容**（字号、配色、图片尺寸…），
    /// 发的目的是让打开着的文档重排一遍。这一项只管**下一次**插入的图存哪儿，
    /// 屏幕上那篇一个字都不用动 —— 广播出去只会白重排一次整篇文档（大文档上肉眼可见地卡一下）。
    func setImageInsertionMode(_ value: ImageInsertionMode) {
        guard value != imageInsertionMode else { return }
        imageInsertionMode = value
        save()
    }

    /// 改「指定路径」那个文件夹（传 `nil` = 清掉）
    ///
    /// 不发广播的理由同上一条：它只影响下一次插入。
    func setImageCustomFolderPath(_ value: String?) {
        // 空串当成「没选」处理，免得界面上显示一个空的按钮、又判断不出到底选没选
        let normalized = (value?.isEmpty ?? true) ? nil : value
        guard normalized != imageCustomFolderPath else { return }
        imageCustomFolderPath = normalized
        save()
    }

    /// 改「插入图片的文件名怎么起」。
    ///
    /// 不发广播的理由同上：它只影响**下一次**插入的图叫什么，屏幕上那篇一个字都不用动。
    func setImageNameMode(_ value: ImageNameMode) {
        guard value != imageNameMode else { return }
        imageNameMode = value
        save()
    }

    /// 改「是否记住滚动位置」。值没变就什么都不做（不发通知、不写盘）
    func setRemembersScrollPosition(_ value: Bool) {
        guard value != remembersScrollPosition else { return }
        remembersScrollPosition = value
        save()
        postChange()
    }

    /// 改「粘贴网页内容时转成 Markdown」。
    ///
    /// 不用重新渲染：这一项只影响**下一次粘贴**走哪条路，已经粘进来的内容不受影响
    func setPastesHTMLAsMarkdown(_ value: Bool) {
        guard value != pastesHTMLAsMarkdown else { return }
        pastesHTMLAsMarkdown = value
        save()
        postChange()
    }

    /// 改「网页图片存到本地」。
    ///
    /// 和上面那一项一样，只影响下一次粘贴，已经粘进来的内容不动，所以不用重新渲染。
    func setSavesWebImagesLocally(_ value: Bool) {
        guard value != savesWebImagesLocally else { return }
        savesWebImagesLocally = value
        save()
        postChange()
    }

    /// 改「显示行号」。开关一拨，编辑器左边那条装订线当场出现 / 消失
    func setShowsLineNumbers(_ value: Bool) {
        guard value != showsLineNumbers else { return }
        showsLineNumbers = value
        save()
        postChange()
    }

    /// 改「引用内容铺淡背景」。
    ///
    /// 底色是 UI 层按矩形铺的（见 `MarkdownTheme.showsQuoteBackground`），通知发出去之后由内容页整篇重排一遍。
    /// 严格说只要重摆一次装饰就够，但这里走的是和别的开关同一条刷新路径 —— 多渲一遍也看不出来
    func setShowsQuoteBackground(_ value: Bool) {
        guard value != showsQuoteBackground else { return }
        showsQuoteBackground = value
        save()
        postChange()
    }

    /// 改「行内代码反引号加底色」。
    ///
    /// 底色是烙进富文本的 `.backgroundColor`（见 `MarkdownTheme.inlineCodeBacktickAttributes`），
    /// 所以这里只能走「通知 → 内容页整篇重渲染」这条路，不能只改主题不动画面。
    func setShowsInlineCodeBacktickBackground(_ value: Bool) {
        guard value != showsInlineCodeBacktickBackground else { return }
        showsInlineCodeBacktickBackground = value
        save()
        postChange()
    }

    /// 改「只读模式」。拨了之后输入框还看得见光标、也还能选中复制，就是改不动内容
    func setIsReadOnly(_ value: Bool) {
        guard value != isReadOnly else { return }
        isReadOnly = value
        save()
        postChange()
    }

    /// 改「大纲展开时正文右侧留白」。
    ///
    /// 拨完当场生效：内容页收到通知后重算一次编辑器右边距（见 `applyOutlineAppearance`），
    /// 正文立刻让开 / 贴回右边。走的是和别的开关同一条刷新路径 —— 顺带重排一遍文字，
    /// 但宽度变了本来就得重新折行，这一次不算白花。
    func setReservesSpaceForOutline(_ value: Bool) {
        guard value != reservesSpaceForOutline else { return }
        reservesSpaceForOutline = value
        save()
        postChange()
    }

    /// 改「宽度按什么算」
    func setOutlineWidthMode(_ value: OutlineWidthMode) {
        guard value != outlineWidthMode else { return }
        outlineWidthMode = value
        save()
        postChange()
    }

    /// 改「宽度百分比」。超出 `Limits.outlineWidthRatio` 的值会被夹到边界上
    func setOutlineWidthRatio(_ value: Double) {
        let clamped = clamp(value, to: Limits.outlineWidthRatio)
        guard clamped != outlineWidthRatio else { return }
        outlineWidthRatio = clamped
        save()
        postChange()
    }

    /// 改「固定宽度」。超出 `Limits.outlineWidthPoints` 的值会被夹到边界上
    func setOutlineWidthPoints(_ value: Double) {
        let clamped = clamp(value, to: Limits.outlineWidthPoints)
        guard clamped != outlineWidthPoints else { return }
        outlineWidthPoints = clamped
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

    /// 改「背景不透明度」。超出 `Limits.outlineBackgroundOpacity`（0.2 ~ 1）的值会被夹到边界上
    func setOutlineBackgroundOpacity(_ value: Double) {
        let clamped = clamp(value, to: Limits.outlineBackgroundOpacity)
        guard clamped != outlineBackgroundOpacity else { return }
        outlineBackgroundOpacity = clamped
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

    /// 改「表格源码字号」。超出 `Limits.tableSourceFontSize` 的值会被夹到边界上。
    ///
    /// ⚠️ 调过之后这一项就**不再跟着正文字号走**了（用户既然单独拖了，就该听他的）。
    func setTableSourceFontSize(_ value: Double) {
        let clamped = clamp(value, to: Limits.tableSourceFontSize)
        guard clamped != tableSourceFontSizeOverride else { return }
        tableSourceFontSizeOverride = clamped
        save()
        postChange()
    }

    /// 改「表格源码文字颜色」。传 `nil` = 恢复成跟随主题。
    ///
    /// 颜色统一以十六进制字符串落盘（`MarkdownHexColor` 那套），读回来再转成 `UIColor` ——
    /// `UIColor` 自己不能被 JSON 编解码，项目里所有颜色都是这么存的。
    func setTableSourceTextColor(_ color: UIColor?) {
        let hex = color.map { MarkdownHexColor.string(from: $0) }
        guard hex != tableSourceTextColorHex else { return }
        tableSourceTextColorHex = hex
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

    /// 改「无序列表圆点的直径」（点）
    func setBulletDiameter(_ value: Double) {
        let clamped = clamp(value, to: Limits.bulletDiameter)
        guard clamped != bulletDiameter else { return }
        bulletDiameter = clamped
        save()
        postChange()
    }

    // MARK: 改图片尺寸

    /// 改「图片最大宽度按什么算」
    func setImageWidthMode(_ value: ImageWidthMode) {
        guard value != imageWidthMode else { return }
        imageWidthMode = value
        save()
        postChange()
    }

    /// 改「图片宽度百分比」
    func setImageWidthRatio(_ value: Double) {
        let clamped = clamp(value, to: Limits.imageWidthRatio)
        guard clamped != imageWidthRatio else { return }
        imageWidthRatio = clamped
        save()
        postChange()
    }

    /// 改「图片固定宽度」（点）
    func setImageWidthPoints(_ value: Double) {
        let clamped = clamp(value, to: Limits.imageWidthPoints)
        guard clamped != imageWidthPoints else { return }
        imageWidthPoints = clamped
        save()
        postChange()
    }

    /// 改「图片最大高度」（点）
    func setImageMaxHeight(_ value: Double) {
        let clamped = clamp(value, to: Limits.imageMaxHeight)
        guard clamped != imageMaxHeight else { return }
        imageMaxHeight = clamped
        save()
        postChange()
    }

    // MARK: 改颜色主题

    /// 换一套内置配色
    func setColorTheme(_ value: MarkdownColorTheme) {
        guard value != colorTheme else { return }
        colorTheme = value
        save()
        postChange()
    }

    /// 选一套内置主题，**同时**停用「我的主题」里那份自定义配色 —— 两者互斥，同一时刻只能选一个。
    ///
    /// ### 为什么要单独合成一个方法
    /// 界面上连着调 `setColorTheme` + `setCustomThemeFileName(nil)` 的话会发两次「配置变了」通知，打开的文档就要整篇重渲染两遍（大文档上肉眼可见地卡一下）。这里一次写盘、一次广播。
    ///
    /// ### 为什么「换内置」要顺手清掉自定义配色
    /// 不清的话，用户点「Vue」看到的还是旧样子 —— 自定义配色盖在上面，内置主题换了个底色也看不出来，表现出来就是「三个内置主题全都点不动」。
    func selectBuiltInTheme(_ value: MarkdownColorTheme) {
        // 已经是这套、又没在用自定义配色 → 什么都没变，别惊动界面
        guard value != colorTheme || customThemeFileName != nil else { return }
        colorTheme = value
        customThemeFileName = nil
        save()
        postChange()
    }

    /// 记住「用户指定了哪份 JSON」（传 `nil` = 清除，回到只用内置主题的状态）
    func setCustomThemeFileName(_ value: String?) {
        guard value != customThemeFileName else { return }
        customThemeFileName = value
        save()
        postChange()
    }

    /// 自定义配色的**内容**变了，但文件名没变（比如只是把链接从绿改成红）—— 这种情况上面那个 setter 会直接 return，得手动广播一次。
    ///
    /// 不发的话打开的文档不知道要重渲染，用户改完颜色回到正文会看到「没生效」。
    func noteCustomPaletteChanged() {
        postChange()
    }

    // MARK: 初始化

    init(fileURL: URL = MarkdownEditorSettings.defaultFileURL) {
        self.fileURL = fileURL
        // 先给一套默认值，再用盘上的内容覆盖 —— 这样「读文件失败」也能得到一份可用的配置
        self.remembersScrollPosition = Default.remembersScrollPosition
        self.pastesHTMLAsMarkdown = Default.pastesHTMLAsMarkdown
        self.savesWebImagesLocally = Default.savesWebImagesLocally
        self.showsLineNumbers = Default.showsLineNumbers
        self.showsQuoteBackground = Default.showsQuoteBackground
        self.showsInlineCodeBacktickBackground = Default.showsInlineCodeBacktickBackground
        self.isReadOnly = Default.isReadOnly
        self.reservesSpaceForOutline = Default.reservesSpaceForOutline
        self.outlineWidthMode = Default.outlineWidthMode
        self.outlineWidthRatio = Default.outlineWidthRatio
        self.outlineWidthPoints = Default.outlineWidthPoints
        self.outlineHeightMode = Default.outlineHeightMode
        self.outlineHeightRatio = Default.outlineHeightRatio
        self.outlineMaximumHeight = Default.outlineMaximumHeight
        self.outlineBackgroundOpacity = Default.outlineBackgroundOpacity
        self.tableMinColumnWidth = Default.tableMinColumnWidth
        self.tableMaxColumnWidth = Default.tableMaxColumnWidth
        self.tableSourceFontSizeOverride = Default.tableSourceFontSizeOverride
        self.tableSourceTextColorHex = Default.tableSourceTextColorHex
        self.bodyFontSize = Default.bodyFontSize
        self.lineHeightMultiple = Default.lineHeightMultiple
        self.paragraphSpacing = Default.paragraphSpacing
        self.paragraphIndentCharacters = Default.paragraphIndentCharacters
        self.bodyContentWidth = Default.bodyContentWidth
        self.bulletDiameter = Default.bulletDiameter
        self.imageWidthMode = Default.imageWidthMode
        self.imageWidthRatio = Default.imageWidthRatio
        self.imageWidthPoints = Default.imageWidthPoints
        self.imageMaxHeight = Default.imageMaxHeight
        self.imageInsertionMode = Default.imageInsertionMode
        self.imageCustomFolderPath = Default.imageCustomFolderPath
        self.imageNameMode = Default.imageNameMode
        self.colorTheme = Default.colorTheme
        self.customThemeFileName = Default.customThemeFileName
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
        if let value = payload.pastesHTMLAsMarkdown { pastesHTMLAsMarkdown = value }
        if let value = payload.savesWebImagesLocally { savesWebImagesLocally = value }
        if let value = payload.showsLineNumbers { showsLineNumbers = value }
        if let value = payload.showsQuoteBackground { showsQuoteBackground = value }
        if let value = payload.showsInlineCodeBacktickBackground {
            showsInlineCodeBacktickBackground = value
        }
        if let value = payload.isReadOnly { isReadOnly = value }
        if let value = payload.reservesSpaceForOutline { reservesSpaceForOutline = value }
        // 宽度那一组：模式和高度一样存字符串，认不出来就只让这一项退回默认
        if let raw = payload.outlineWidthMode, let value = OutlineWidthMode(rawValue: raw) {
            outlineWidthMode = value
        }
        if let value = payload.outlineWidthRatio {
            outlineWidthRatio = clamp(value, to: Limits.outlineWidthRatio)
        }
        if let value = payload.outlineWidthPoints {
            outlineWidthPoints = clamp(value, to: Limits.outlineWidthPoints)
        }
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
        if let value = payload.outlineBackgroundOpacity {
            outlineBackgroundOpacity = clamp(value, to: Limits.outlineBackgroundOpacity)
        }
        if let value = payload.tableMinColumnWidth {
            tableMinColumnWidth = clamp(value, to: Limits.tableMinColumnWidth)
        }
        if let value = payload.tableMaxColumnWidth {
            tableMaxColumnWidth = clamp(value, to: Limits.tableMaxColumnWidth)
        }
        // 源码字号：盘上有值才算「用户单独设过」，没有就继续跟着正文字号走
        if let value = payload.tableSourceFontSize {
            tableSourceFontSizeOverride = clamp(value, to: Limits.tableSourceFontSize)
        }
        // 颜色覆盖：只认能解析出来的十六进制，写坏了（或者手改错）就当没设过、继续跟主题
        if let value = payload.tableSourceTextColorHex, MarkdownHexColor.parse(value) != nil {
            tableSourceTextColorHex = value
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
        if let value = payload.bulletDiameter {
            bulletDiameter = clamp(value, to: Limits.bulletDiameter)
        }
        // 和上面那个模式一样存字符串：认不出来就只让这一项退回默认
        if let raw = payload.imageWidthMode, let value = ImageWidthMode(rawValue: raw) {
            imageWidthMode = value
        }
        if let value = payload.imageWidthRatio {
            imageWidthRatio = clamp(value, to: Limits.imageWidthRatio)
        }
        if let value = payload.imageWidthPoints {
            imageWidthPoints = clamp(value, to: Limits.imageWidthPoints)
        }
        if let value = payload.imageMaxHeight {
            imageMaxHeight = clamp(value, to: Limits.imageMaxHeight)
        }
        // 和别的模式一样：认不出来的名字只让这一项退回默认，不连累别的设置
        if let raw = payload.imageInsertionMode, let value = ImageInsertionMode(rawValue: raw) {
            imageInsertionMode = value
        }
        // 路径不需要夹范围；空串当成「没选过」
        if let value = payload.imageCustomFolderPath, !value.isEmpty {
            imageCustomFolderPath = value
        }
        // 文件名规则：同样存字符串，认不出来的名字只让这一项退回默认
        if let raw = payload.imageNameMode, let value = ImageNameMode(rawValue: raw) {
            imageNameMode = value
        }
        // 认不出来的主题名（老版本存的、或者手改坏了）只让这一项退回默认
        if let raw = payload.colorTheme, let value = MarkdownColorTheme(rawValue: raw) {
            colorTheme = value
        }
        // 文件名是「显示用」的，不需要夹范围；空串当成「没指定」
        if let value = payload.customThemeFileName, !value.isEmpty {
            customThemeFileName = value
        }
    }

    private func save() {
        let payload = Payload(remembersScrollPosition: remembersScrollPosition,
                              pastesHTMLAsMarkdown: pastesHTMLAsMarkdown,
                              savesWebImagesLocally: savesWebImagesLocally,
                              showsLineNumbers: showsLineNumbers,
                              showsQuoteBackground: showsQuoteBackground,
                              showsInlineCodeBacktickBackground: showsInlineCodeBacktickBackground,
                              isReadOnly: isReadOnly,
                              reservesSpaceForOutline: reservesSpaceForOutline,
                              outlineWidthMode: outlineWidthMode.rawValue,
                              outlineWidthRatio: outlineWidthRatio,
                              outlineWidthPoints: outlineWidthPoints,
                              outlineHeightMode: outlineHeightMode.rawValue,
                              outlineHeightRatio: outlineHeightRatio,
                              outlineMaximumHeight: outlineMaximumHeight,
                              outlineBackgroundOpacity: outlineBackgroundOpacity,
                              tableMinColumnWidth: tableMinColumnWidth,
                              tableMaxColumnWidth: tableMaxColumnWidth,
                              tableSourceFontSize: tableSourceFontSizeOverride,
                              tableSourceTextColorHex: tableSourceTextColorHex,
                              bodyFontSize: bodyFontSize,
                              lineHeightMultiple: lineHeightMultiple,
                              paragraphSpacing: paragraphSpacing,
                              paragraphIndentCharacters: paragraphIndentCharacters,
                              bodyContentWidth: bodyContentWidth,
                              bulletDiameter: bulletDiameter,
                              imageWidthMode: imageWidthMode.rawValue,
                              imageWidthRatio: imageWidthRatio,
                              imageWidthPoints: imageWidthPoints,
                              imageMaxHeight: imageMaxHeight,
                              colorTheme: colorTheme.rawValue,
                              customThemeFileName: customThemeFileName,
                              imageInsertionMode: imageInsertionMode.rawValue,
                              imageCustomFolderPath: imageCustomFolderPath,
                              imageNameMode: imageNameMode.rawValue)
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

    /// 把当前的宽度配置写进大纲面板的外观参数。
    ///
    /// ### 两个值的写法（和下面高度那对一模一样）
    /// `width` 每次都照配置写，不管当前模式用不用它 —— 这样切回「固定宽度」时它还是用户上次调好的值。真正决定用哪个的是 `widthRatio`：百分比模式给它比例，「固定宽度」模式给它 `nil`（`nil` = 这一项不参与计算）。
    ///
    /// 换算放在配置侧而不是面板里，理由见下面 `applyOutlineHeight` 的注释
    func applyOutlineWidth(to appearance: inout MarkdownOutlineAppearance) {
        appearance.width = CGFloat(outlineWidthPoints)
        switch outlineWidthMode {
        case .percentage:
            appearance.widthRatio = CGFloat(outlineWidthRatio)
        case .fixedPoints:
            appearance.widthRatio = nil
        }
    }

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

    /// 把「背景不透明度」写进大纲面板的外观参数。
    ///
    /// 这一项没有模式之分，一个数直接搬过去；换算照样放在配置侧（理由同上一条）。
    /// ⚠️ 搬过去之后要调一次 `MarkdownOutlineView.refreshAppearance()`，否则屏幕上的卡片纹丝不动
    func applyOutlineBackground(to appearance: inout MarkdownOutlineAppearance) {
        appearance.backgroundOpacity = CGFloat(outlineBackgroundOpacity)
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

    /// 把「表格源码」这一组（字号 + 文字颜色）写进编辑器主题。
    ///
    /// ### 为什么单独一个方法，不并进 `applyTableColumnWidths`
    /// 列宽是「表格这张图怎么排」，字号 / 颜色是「下面那几行源码长什么样」，
    /// 是两件事，分开之后各自能被单独测、也能单独调整顺序。
    ///
    /// ### ⚠️ 必须在 `applyColors` 之后调
    /// 配色表是「覆盖表」：它会重写 `theme.table.sourceTextColor`。
    /// 这里写的是用户在设置页**专门指定**的颜色，必须最后落笔 ——
    /// 顺序反了就会被配色表重新盖掉，表现是「在设置里选了色，没反应」。
    ///
    /// ### 改完必须整篇重渲染
    /// 字号和颜色都是渲染那一刻烙进 `NSAttributedString` 的，只改主题不动画面。
    func applyTableSourceStyle(to theme: inout MarkdownTheme) {
        theme.table.sourceFontSize = CGFloat(tableSourceFontSize)
        // 没指定过（或者字符串坏了）就什么都不做：主题里已经是配色表给的那一色
        if let hex = tableSourceTextColorHex, let color = MarkdownHexColor.parse(hex) {
            theme.table.sourceTextColor = color
        }
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
        theme.bulletDiameter = CGFloat(bulletDiameter)
    }

    /// 把「图片尺寸」这一组的配置写进编辑器主题。
    ///
    /// ### 换算照样放在配置这一侧
    /// 主题里存的是「渲染层直接能用的三个数」：宽度比例（或 nil）+ 宽度点数 + 高度点数。
    /// `MarkdownEditor/` 那一层不认识 `ImageWidthMode`，也就不认识设置单例 ——
    /// 依赖方向保持「App 层 → 组件」，和上面几个 `apply...` 是同一个理由。
    ///
    /// ### 改完必须整篇重渲染
    /// 图片尺寸是**渲染那一刻**写进 attachment 的 `bounds` 的，只改主题不动画面。
    func applyImageSize(to theme: inout MarkdownTheme) {
        switch imageWidthMode {
        case .percentage:
            theme.image.maxWidthRatio = CGFloat(imageWidthRatio)
        case .fixedPoints:
            // nil = 「不按比例算，用固定点数」，主题里两个字段的互斥就是这个 nil
            theme.image.maxWidthRatio = nil
            theme.image.maxWidthPoints = CGFloat(imageWidthPoints)
        }
        theme.image.maxHeight = max(60, CGFloat(imageMaxHeight))
    }
}

// MARK: - 套到编辑器的配色上

extension MarkdownEditorSettings {

    /// 当前该用的一套颜色：内置主题 +（可选的）用户 JSON 覆盖。
    ///
    /// ### 优先级（后者盖前者）
    /// `MarkdownTheme` 自带默认色 → 内置主题（vue / vue-dark）→ 用户指定的 JSON 文件。
    ///
    /// JSON 只在「用户确实指定过」时才参与：没指定、文件读不出来、内容不合法，
    /// 都退化成「只用内置主题」—— 一份坏掉的 JSON 不该让界面变成一片黑。
    ///
    /// - parameter customPalette: 从 `MarkdownCustomThemeStore` 读出来的那套；用户没指定过就传 `nil`
    func resolvedColorPalette(customPalette: MarkdownColorPalette?) -> MarkdownColorPalette {
        resolvedColorPalette(theme: colorTheme, customPalette: customPalette)
    }

    /// 某一套内置主题（**不是**当前选中的那套）+ 可选的 JSON 之后，实际会用到的配色。
    ///
    /// 主题页要给列表里每一套都画预览，`resolvedColorPalette(customPalette:)` 只能算「当前选中的」，所以真正的叠加规则写在这里，那边再包一层。
    func resolvedColorPalette(theme: MarkdownColorTheme,
                              customPalette: MarkdownColorPalette?) -> MarkdownColorPalette {
        // 「用户指定过」这一道闸只在这儿看：叠加规则本身在下面那个方法里，只此一份
        guard customThemeFileName != nil else { return theme.palette }
        return palette(base: theme, merging: customPalette)
    }

    /// 给列表里的某一行画预览用：指定的内置主题 + 指定的那份自定义配色，跟「当前选了谁」无关。
    ///
    /// ⚠️ 不能用 `resolvedColorPalette(customPalette:)`：那一个内部要先判「用户有没有指定过自定义配色」，没指定就直接把传进来的那份扔了 —— 给「我的主题」里那几行画预览时，配色是外面传进来的（可能正是没在用的那份），不该受当前选中影响。
    func palette(base: MarkdownColorTheme, merging custom: MarkdownColorPalette?) -> MarkdownColorPalette {
        guard let custom else { return base.palette }
        return base.palette.merging(custom)
    }

    /// 把当前配色写进编辑器主题。
    ///
    /// ### 换算照样放在配置这一侧（和上面几个 `apply...` 同一个理由）
    /// 渲染层只认 `MarkdownColorPalette`，不认识「用户选了哪套、有没有指定文件」——
    /// 这些是 App 层的事，依赖方向始终是「App 层 → 组件」。
    ///
    /// ### 改完必须整篇重渲染
    /// 颜色是渲染那一刻烙进 `NSAttributedString` 的，只改主题不动画面。
    /// 底色（`editorBackground`）倒是 view 自己的属性，由 `refreshTheme()` 一起搬过去。
    func applyColors(to theme: inout MarkdownTheme, customPalette: MarkdownColorPalette?) {
        theme.applyColorPalette(resolvedColorPalette(customPalette: customPalette))
    }

    /// 按当前设置**现拼**一套主题出来。
    ///
    /// ### 什么时候用得上
    /// 编辑页是**就地**把这四组配置写进编辑器主题的（见 `MarkdownDocumentViewController.applyStyleToTheme`）——那边有编辑器可以改。但「左栏右键导出某份文件」时编辑器根本不存在（那份文档没打开），所以这里现拼一套，用的是同一份换算，导出的配色 / 字号才和编辑页一致。
    var currentTheme: MarkdownTheme {
        // 从默认主题起步：那上面已经带着渲染层默认的颜色和排版
        var theme = MarkdownTheme.default
        // 顺序和编辑页那几行一致 —— 配色只改颜色，后面三组再按用户拖过的滑块覆盖自己那几个值，两者不冲突
        applyColors(to: &theme,
                    customPalette: MarkdownCustomThemeStore.shared.loadPalette(named: customThemeFileName))
        applyTypography(to: &theme)
        applyTableColumnWidths(to: &theme)
        // 表格源码的样式放配色之后：它可能覆盖掉配色表里的那一色（理由见那个方法）
        applyTableSourceStyle(to: &theme)
        applyImageSize(to: &theme)
        // 「行内代码反引号加底色」是个开关，不是颜色 / 尺寸，但同样得带上 ——
        // 左栏「导出图片」是拿这套主题临时渲染一遍的，漏了它导出图里的反引号会和编辑页长得不一样
        theme.inlineCodeBacktickHasBackground = showsInlineCodeBacktickBackground
        return theme
    }

    /// 表格源码**现在真正会显示**的颜色（用户指定过就用那个，否则按当前主题 / 配色算出来）。
    ///
    /// 设置页画「源码文字颜色」那一行的小色块要用它 ——
    /// 只画用户设的那个 hex 的话，「跟随主题」状态下色块就不知道该画什么了。
    ///
    /// ⚠️ 它内部会现拼一套主题（含读一次自定义配色文件），别在高频路径上调。
    var effectiveTableSourceTextColor: UIColor {
        if let hex = tableSourceTextColorHex, let color = MarkdownHexColor.parse(hex) {
            return color
        }
        return currentTheme.table.sourceTextColor
    }
}
