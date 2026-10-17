//
//  SettingsCatalog.swift
//  MarkdownEditorHy4
//
//  设置页「有哪些分组、每组有哪些行」的唯一一份清单。
//
//  ### 为什么要单独拎成一个文件
//  设置页现在是两层结构 —— Mac 上左边一列侧边栏、右边一块面板；iPhone / iPad 上是一张列表、点进去 push 一块面板。
//  这两种界面的「目录」读的是同一份清单：加一个分组只要在这儿补一个 case，两端的列表自动多一行，不用两边各维护一份（不然迟早漏一处）。
//
//  ### 这里只描述「有什么」，不碰界面
//  每一行的量程、步进、当前取值这些也收在这儿，因为它们和「这一行」绑得死；
//  但这里一个控件都不造，真正画界面的活儿在 `SettingsPaneViewController`。
//

import UIKit

/// 设置页上的分组。侧边栏 / 列表里一行一个，点进去就是这个分组的面板。
enum SettingsSection: Int, CaseIterable {
    /// 正文字体与段落排版。放最上面：这是用户最常进来改的一组
    case typography
    /// 阅读与显示（开关类）
    case reading
    /// 大纲面板多宽 / 多高 / 背景多透
    case outlineSize
    /// 表格画出来时的列宽限制，以及表格下方那几行源码的字号 / 颜色
    case tableLayout
    /// 图片画多大
    case imageSize
    /// 粘贴 / 插入的图片存到哪儿
    case imageInsertion
    /// 粘贴剪贴板内容时的处理
    case clipboard

    /// 列表行 / 面板标题上显示的名字
    var title: String {
        switch self {
        case .typography: return "正文排版"
        case .reading: return "阅读与显示"
        case .outlineSize: return "大纲面板"
        case .tableLayout: return "表格"
        case .imageSize: return "图片尺寸"
        case .imageInsertion: return "插入图片"
        case .clipboard: return "剪贴板"
        }
    }

    /// 列表 / 侧边栏那一行左边的小图标（SF Symbol 的名字）。
    ///
    /// 挑的都是从 iOS 14 就有的符号：侧边栏那条路只有 Mac 走，但列表那条路 iPhone / iPad 也走，符号名写新了会静默画不出图（返回 nil），不如挑老的稳。
    var iconName: String {
        switch self {
        case .typography: return "textformat"
        case .reading: return "book"
        case .outlineSize: return "list.bullet.indent"
        case .tableLayout: return "tablecells"
        case .imageSize: return "photo"
        case .imageInsertion: return "folder.badge.plus"
        case .clipboard: return "doc.on.clipboard"
        }
    }

    /// 列表那一行副标题上的一句摘要。
    ///
    /// 从前所有分组摊在同一页里，一眼能看到有什么；拆成「目录 + 面板」之后，光看「大纲面板」四个字不知道里头能改什么，所以这里说一句。
    var summary: String {
        switch self {
        case .typography: return "字号、行高、段落间距、首行缩进、行宽上限、列表圆点大小"
        case .reading: return "行号、引用底色、记住上次读到哪儿"
        case .outlineSize:
            // iPhone 上「正文让位」那一行不存在，摘要里也就别提，否则点进去发现少一项
            return SettingsRow.outlineReservesSpace.isAvailableOnCurrentDevice
                ? "展开时正文是否让出右侧空间，面板的宽度、高度、背景不透明度"
                : "面板的宽度、高度、背景不透明度"
        case .tableLayout: return "列宽、下方源码的字号与文字颜色"
        case .imageSize: return "图片画多大：宽度怎么算、最大高度"
        case .imageInsertion: return "粘贴进来的图片存到哪儿、文件叫什么名字"
        case .clipboard: return "粘贴网页内容时先转成 Markdown 源码"
        }
    }

    /// 这一组里从上到下有哪些行
    var rows: [SettingsRow] {
        switch self {
        case .typography:
            // 顺序就是界面上从上到下的顺序：
            // 先定字号，再定行与行、段与段、段首，最后是整行的宽度
            return [.bodyFontSize, .lineHeightMultiple, .paragraphSpacing,
                    .paragraphIndentCharacters, .bodyContentWidth, .bulletDiameter]
        case .reading:
            // 行号放最上面：它是「一眼能看出开关有没有生效」的那一项
            return [.showsLineNumbers, .remembersScrollPosition, .showsQuoteBackground]
        case .outlineSize:
            // 顺序就是界面上从上到下的顺序：先是一个开关（要不要给正文让地方），
            // 再宽度（怎么算 + 两个数值）、高度（同样三行）、最后是背景多透。
            // 两种模式的说明都要跟模式联动，所以每一组里「怎么算」放最上面
            //
            // ⚠️ iPhone 上没有「正文让位」这回事（屏幕太窄，让完只剩一条缝），
            // 所以那个开关在那边整行都不出现 —— 留一个拨了没反应的开关只会让人以为自己弄坏了
            let items: [SettingsRow] = [.outlineReservesSpace,
                                        .outlineWidthMode, .outlineWidthRatio, .outlineWidthPoints,
                                        .outlineHeightMode, .outlineHeightRatio, .outlineMaximumHeight,
                                        .outlineBackgroundOpacity]
            return items.filter(\.isAvailableOnCurrentDevice)
        case .tableLayout:
            // 顺序：先把表格这张图排好（两个列宽），再管图下面那几行源码（字号、颜色）
            return [.tableMinColumnWidth, .tableMaxColumnWidth,
                    .tableSourceFontSize, .tableSourceTextColor]
        case .imageSize:
            // 顺序就是界面上从上到下的顺序：先选「宽度怎么算」，再调两个数值，
            // 最后是「最多占多高」
            return [.imageWidthMode, .imageWidthRatio, .imageWidthPoints, .imageMaxHeight]
        case .imageInsertion:
            // 「存哪儿」在上面：它是这一组的主题。「指定路径那个文件夹」紧跟着 ——
            // 只有选中「复制到指定路径」时它才有意义，而且只有 Mac 上才有这一项
            // （理由见 `ImageInsertionMode.selectableCases`）。最后是「文件叫什么名字」，
            // 它和存哪儿互相独立（哪个目录都能配哪种名字）
            #if targetEnvironment(macCatalyst)
            return [.imageInsertionMode, .imageCustomFolderPath, .imageNameMode]
            #else
            return [.imageInsertionMode, .imageNameMode]
            #endif
        case .clipboard:
            return [.pastesHTMLAsMarkdown]
        }
    }
}

/// 设置页上的行。加新设置就先在这里加一个 case，再去 `SettingsPaneViewController` 里给它配一个控件。
enum SettingsRow: Int, CaseIterable {
    // 正文排版
    /// 正文字号（点）
    case bodyFontSize
    /// 行高倍数
    case lineHeightMultiple
    /// 段落之间的间距（点）
    case paragraphSpacing
    /// 段落首行缩进（字符数）
    case paragraphIndentCharacters
    /// 正文栏宽上限（点），拖到最右端 = 不限
    case bodyContentWidth
    /// 无序列表圆点的直径（点）
    case bulletDiameter
    // 阅读与显示
    /// 正文左边要不要显示行号
    case showsLineNumbers
    case remembersScrollPosition
    /// 引用块的内容要不要铺一层淡背景（竖条颜色的 10% 透明度）
    case showsQuoteBackground
    // 大纲面板：留白
    /// 大纲展开时，正文要不要往左让出它那块宽度
    case outlineReservesSpace
    // 大纲面板：宽度
    /// 面板宽度按什么算（百分比 / 固定点数）
    case outlineWidthMode
    /// 宽度占编辑器（窗口）宽度的比例
    case outlineWidthRatio
    /// 固定宽度（点）
    case outlineWidthPoints
    /// 高度按什么算（百分比 / 固定最大高度）
    case outlineHeightMode
    /// 高度占父视图高度的比例
    case outlineHeightRatio
    /// 固定高度上限（点）
    case outlineMaximumHeight
    /// 面板背景的不透明度（1 = 完全不透明）
    case outlineBackgroundOpacity
    /// 表格最窄的一列（点）
    case tableMinColumnWidth
    /// 表格最宽的一列（点）
    case tableMaxColumnWidth
    /// 表格下方那几行**源码**的字号（点）
    case tableSourceFontSize
    /// 表格下方那几行**源码**的文字颜色（选过才覆盖主题里的那一色）
    case tableSourceTextColor
    /// 图片最大宽度按什么算（百分比 / 固定点数）
    case imageWidthMode
    /// 图片宽度占编辑器宽度的比例
    case imageWidthRatio
    /// 图片固定宽度（点）
    case imageWidthPoints
    /// 图片最大高度（点）
    case imageMaxHeight
    /// 插入的图片存到哪个文件夹（四个选项选一个）
    case imageInsertionMode
    /// 「复制到指定路径」用的那个文件夹（只有 Mac 上有这一行）
    case imageCustomFolderPath
    /// 插入的图片文件叫什么名字（原始文件名 / 当前时间 / 内容哈希）
    case imageNameMode
    /// 粘贴网页复制来的富文本时，要不要先转成 markdown 源码
    case pastesHTMLAsMarkdown

    /// 这一行在**当前设备**上有没有意义（没有就整行不出现）。
    ///
    /// 现在只有一项不总是有意义：「大纲展开时正文右侧留白」—— iPhone 屏幕太窄，
    /// 让完那一块正文只剩一条缝，那边固定不让，开关也就不必显示。
    /// 判断本身收在 `MarkdownEditorSettings.supportsReservingSpaceForOutline`，
    /// 免得设置页和编辑器各判一套、哪天判岔了变成「开关在、拨了不动」。
    ///
    /// ⚠️ 只在 `#if targetEnvironment(macCatalyst)` 下才有的行（比如「指定文件夹」）
    /// 不用进这里，那几个已经在 `rows` 里按编译条件分好了
    var isAvailableOnCurrentDevice: Bool {
        switch self {
        case .outlineReservesSpace:
            return MarkdownEditorSettings.supportsReservingSpaceForOutline
        default:
            return true
        }
    }

    /// 主标题
    var title: String {
        switch self {
        case .bodyFontSize:
            return "正文字号"
        case .lineHeightMultiple:
            return "行高"
        case .paragraphSpacing:
            return "段落间距"
        case .paragraphIndentCharacters:
            return "段落首行缩进"
        case .bodyContentWidth:
            return "行宽上限"
        case .bulletDiameter:
            return "列表圆点大小"
        case .showsLineNumbers:
            return "显示行号"
        case .showsQuoteBackground:
            return "引用内容加底色"
        case .remembersScrollPosition:
            return "记住上次阅读位置"
        case .outlineReservesSpace:
            return "大纲展开时正文右侧留白"
        case .outlineWidthMode:
            return "宽度怎么算"
        case .outlineWidthRatio:
            return "宽度百分比"
        case .outlineWidthPoints:
            return "固定宽度"
        case .outlineHeightMode:
            return "高度怎么算"
        case .outlineHeightRatio:
            return "高度百分比"
        case .outlineMaximumHeight:
            return "最大高度"
        case .outlineBackgroundOpacity:
            return "背景不透明度"
        case .tableMinColumnWidth:
            return "最小列宽"
        case .tableMaxColumnWidth:
            return "最大列宽"
        case .tableSourceFontSize:
            return "源码字号"
        case .tableSourceTextColor:
            return "源码文字颜色"
        case .imageWidthMode:
            return "宽度怎么算"
        case .imageWidthRatio:
            return "宽度百分比"
        case .imageWidthPoints:
            return "固定宽度"
        case .imageMaxHeight:
            return "最大高度"
        case .imageInsertionMode:
            return "图片存放位置"
        case .imageCustomFolderPath:
            return "指定路径的文件夹"
        case .imageNameMode:
            return "图片文件名"
        case .pastesHTMLAsMarkdown:
            return "粘贴网页内容时转成 Markdown"
        }
    }

    /// 找控件用的无障碍标识（也是单测在视图树里找这一行的身份证）。
    ///
    /// ⚠️ 默认就是 `title`，但必须唯一：设置页里有重名的可见标题 —— 「宽度怎么算 / 宽度百分比 / 固定宽度」在大纲面板和图片尺寸两组里各有一套，界面上靠分组标题区分完全够用，但按标识找控件时重名就会摸到别人那一条。又因为视图树顺序和分组顺序并不一致，也不能靠「谁在前」碰运气，所以这几行另起一套名字（拆成「目录 + 面板」之后，同一个面板里其实不会再撞名了，但这套标识是单测的接口，仍然留着）
    var accessibilityLabel: String {
        switch self {
        case .outlineWidthMode: return "大纲宽度怎么算"
        case .outlineWidthRatio: return "大纲宽度百分比"
        case .outlineWidthPoints: return "大纲固定宽度"
        default: return title
        }
    }

    /// 副标题：把「这一项是干嘛的、什么时候不起作用」说清楚，
    /// 免得用户点完/拖完不知道发生了什么。
    /// 两句高度相关的说明要跟着模式变 —— 不生效的那一项得明说
    func detail(in settings: MarkdownEditorSettings) -> String {
        let usesRatio = settings.outlineHeightMode == .percentage
        let usesWidthRatio = settings.outlineWidthMode == .percentage
        let imageUsesRatio = settings.imageWidthMode == .percentage
        switch self {
        case .bodyFontSize:
            return "正文的字号。标题、行内代码、代码块都是从这个数推出来的"
                + "（标题更大、代码略小），会跟着一起变。"
        case .lineHeightMultiple:
            return "行与行之间的距离。「1.00 倍」就是字体自带的松紧度，"
                + "中文正文调到 1.40～1.60 读起来最省力。"
                + "只影响文字，图片、表格、分隔线不跟着变松。"
        case .paragraphSpacing:
            return "上下两段之间空多少。正文、标题、列表项用的是同一个值，"
                + "调大一点段落之间就分得清楚。"
        case .paragraphIndentCharacters:
            return "每个自然段**第一行**往右缩进几个字（后面的行不缩），"
                + "中文排版习惯是缩 2 个字。标题、列表项、引用块、代码块都不缩。"
        case .bodyContentWidth:
            return "一行最多排多宽。窗口比它宽时正文居中、两边留白"
                + "（一行拉太长，读到行尾容易串行）；拖到最右边显示「不限」，"
                + "正文就铺满整个窗口。"
        case .bulletDiameter:
            return "无序列表每一行前面那个圆点画多大（点的直径）。"
                + "调小是清秀的一点，调大更接近正文一个字的大小；有序列表的序号是文字，"
                + "跟着字号走，不受这一项影响。"
        case .showsLineNumbers:
            return "打开：正文左边多出一条装订线，按**屏幕上看到的行**编号。"
                + "写长文、对着文档讨论「第几行」时有用；关掉则一点地方都不占。"
                + "行号数的是屏幕上那一行 —— 图片、表格在源码里占好几行、"
                + "在屏幕上只占一个字符位，所以行号和「源文件第几行」会错开。"
        case .remembersScrollPosition:
            return "打开：关闭文件时记住读到哪儿，下次打开同一个文件回到原处。"
                + "关闭：每次打开都从文档开头看起。目录大纲永远跟着光标走，不受这一项影响。"
        case .showsQuoteBackground:
            return "打开：引用块除了左边那条竖条，右边那一整片再铺一层极淡的底色（竖条颜色的 10%），"
                + "从竖条一直铺到行尾，引用看着像一整块色条；关闭：只有一条竖条，和正文一样干净。"
                + "ⓘ 底色和竖条同色，跟着主题里的「引用竖条」颜色走；"
                + "它铺在文字下面，框选引用文字时系统的蓝色高亮照样盖得住。"
        case .outlineReservesSpace:
            return "打开：大纲展开时，正文右边让出和面板一样宽的一块，字不会被面板卡片压住 ——"
                + "代价是每行能排的字变少。"
                + "关闭：正文始终铺满整个窗口，大纲摊开时会盖住右边那部分字。"
                + "大纲收起成右上角那个小方块时不受影响，正文照旧用满宽度。"
        case .outlineWidthMode:
            return "「按百分比」：宽度跟着窗口走，窗口拉宽面板也变宽；"
                + "「固定宽度」：永远是你指定的点数，跟窗口无关。"
        case .outlineWidthRatio:
            return usesWidthRatio
                ? "面板最多占编辑器宽度的百分之几。窗口太窄时还会被自动收窄，不会把编辑区盖住。"
                : "当前用的是「固定宽度」，这一项暂不生效。"
        case .outlineWidthPoints:
            return usesWidthRatio
                ? "当前用的是「按百分比」，这一项暂不生效。"
                : "面板有多宽（点）。窗口窄到放不下时会被自动收窄，左边始终给正文留得下位置。"
        case .outlineHeightMode:
            return "「按百分比」按窗口高度算上限（下面的「最大高度」不生效）；"
                + "「按最大高度」改用固定值。两种都只是上限：标题少的时候，"
                + "面板会贴着内容变矮，不会空一大片。"
        case .outlineHeightRatio:
            return usesRatio
                ? "面板高度最多占窗口高度的百分之几。"
                : "当前用的是「按最大高度」，这一项暂不生效。"
        case .outlineMaximumHeight:
            return usesRatio
                ? "当前用的是「按百分比」，这一项暂不生效。"
                : "面板高度最多是多少点。窗口太小的话还会被压一道，不会盖满整屏。"
        case .outlineBackgroundOpacity:
            return "面板卡片有多不透。100% 是**完全不透明**，背后的正文一点都看不到（卡片带毛玻璃，看着厚实）；"
                + "只要往下拖就变成一层半透明的底色，背后正文**清清楚楚**透出来 —— "
                + "这时候毛玻璃会关掉，不然透出来的只是一团糊影。最低 20%。"
                + "这一项只管背景，标题文字本身不会跟着变淡。"
        case .tableMinColumnWidth:
            return "表格里再短的列也不窄于这个值，「姓名」这类两字列才不会挤成一团。"
                + "如果调得比「最大列宽」还大，会按最大列宽算。"
        case .tableMaxColumnWidth:
            return "某一列内容特别长（比如贴了长链接）时，列宽到这里就封顶，"
                + "多出来的文字自动换行，不把别的列挤没。"
        case .tableSourceFontSize:
            return "表格画成一张图之后，下面仍然留着那几行 | 姓名 | 年龄 | 源码，光标能停进去改内容 ——"
                + "这一项调的就是那几行字的大小。"
                + "默认跟着正文字号走（比正文小 1 点），调正文时它一起变；在这里拖一下，就固定成你选的值。"
        case .tableSourceTextColor:
            return "上面那几行源码的颜色。默认跟着主题里的「表格源码文字」，换主题时它跟着换；"
                + "在这里选一个颜色就固定用它，不再受换主题影响。"
                + "想交还给主题，点按钮选「跟随主题」。"
        case .imageWidthMode:
            return "「按百分比」：图片最多占编辑器宽度的百分之几，窗口拉宽图也跟着变宽；"
                + "「固定宽度」：永远是你指定的点数，跟窗口无关。"
        case .imageWidthRatio:
            return imageUsesRatio
                ? "图片最多占编辑器宽度的百分之几。图片按原始比例缩放，"
                    + "比这个宽度小的小图**不会被放大**（不会为了填满而变糊）。"
                : "当前用的是「固定宽度」，这一项暂不生效。"
        case .imageWidthPoints:
            return imageUsesRatio
                ? "当前用的是「按百分比」，这一项暂不生效。"
                : "图片最多画多少点宽。比它小的图按原尺寸显示，不会被拉大。"
        case .imageMaxHeight:
            return "图片最高能画多少点，防止一张长图撑爆屏幕。"
                + "这是个固定值，跟窗口多高没关系；比它矮的图按原尺寸显示，不会被拉高。"
        case .imageInsertionMode:
            return "粘贴进来的图片会先存成一份文件，正文里写的是这个文件的路径。"
                + "四个选项的区别只有「文件放哪儿」：和笔记放一起（./）、放进笔记旁边的 assets 文件夹、"
                + "放进和笔记同名的文件夹（笔记叫「游记.md」就是「游记/」）、"
                + "或者放进你指定的一个固定文件夹（只有 Mac 上能选）。"
                + "文件叫什么名字由下面那一项决定。"
        case .imageCustomFolderPath:
            return "点一下选一个文件夹，「复制到指定路径」就是往这儿存。"
                + "正文里记的是完整路径（图片在笔记目录之外，相对路径表达不了），"
                + "所以这个文件夹以后最好别删、也别挪窝 ——"
                + "真挪走了，插入图片时会自动改存到 ./assets，并在状态栏告诉你一声。"
        case .imageNameMode:
            return "图片文件叫什么名字。后缀（.jpg / .png）永远按图片的真实格式来，这一项只管前面那截。"
                + "「原始文件名」：Finder 里复制过来的图，原来叫什么就叫什么；"
                    + "截图、网页里的图本来就没有文件名，这些会退回用哈希。"
                + "「当前时间」：存成 20261015_172442 这种（年月日_时分秒），一眼看得出是什么时候粘的。"
                + "「文件 MD5 哈希」：按图片内容算名字，同一张图反复粘贴只会留下一个文件。"
                + "三者都会先把名字里的空格之类换掉（换成 -）——"
                + "markdown 的图片地址里带空格会解析不出来。"
                + "另外，目标目录里已经有同名文件时会自动改用哈希，不会把原来那张盖掉。"
        case .pastesHTMLAsMarkdown:
            return "打开：从网页、Word、备忘录复制内容再粘贴，粘进来的是 markdown 源码 ——"
                + "标题、列表、表格、链接、图片都转成对应的 markdown 写法，而不是一堆标签。"
                + "关掉：剪贴板里有什么就原样插什么。"
                + "复制的是纯文本时这一项没有区别，只有带格式的富文本才看得出开关。"
        }
    }

    /// 这一项的滑块值范围
    var sliderRange: ClosedRange<Double> {
        switch self {
        case .bodyFontSize: return MarkdownEditorSettings.Limits.bodyFontSize
        case .lineHeightMultiple: return MarkdownEditorSettings.Limits.lineHeightMultiple
        case .paragraphSpacing: return MarkdownEditorSettings.Limits.paragraphSpacing
        case .paragraphIndentCharacters:
            return MarkdownEditorSettings.Limits.paragraphIndentCharacters
        case .bodyContentWidth: return MarkdownEditorSettings.Limits.bodyContentWidth
        case .bulletDiameter: return MarkdownEditorSettings.Limits.bulletDiameter
        case .outlineWidthRatio: return MarkdownEditorSettings.Limits.outlineWidthRatio
        case .outlineWidthPoints: return MarkdownEditorSettings.Limits.outlineWidthPoints
        case .outlineHeightRatio: return MarkdownEditorSettings.Limits.outlineHeightRatio
        case .outlineMaximumHeight: return MarkdownEditorSettings.Limits.outlineMaximumHeight
        case .outlineBackgroundOpacity:
            return MarkdownEditorSettings.Limits.outlineBackgroundOpacity
        case .tableMinColumnWidth: return MarkdownEditorSettings.Limits.tableMinColumnWidth
        case .tableMaxColumnWidth: return MarkdownEditorSettings.Limits.tableMaxColumnWidth
        case .tableSourceFontSize: return MarkdownEditorSettings.Limits.tableSourceFontSize
        case .imageWidthRatio: return MarkdownEditorSettings.Limits.imageWidthRatio
        case .imageWidthPoints: return MarkdownEditorSettings.Limits.imageWidthPoints
        case .imageMaxHeight: return MarkdownEditorSettings.Limits.imageMaxHeight
        default: return 0...1
        }
    }

    /// 拖动时的步进：一档一档地吸，免得停在 63.7% 这种数上
    var sliderStep: Double {
        switch self {
        case .bodyFontSize: return 1
        case .lineHeightMultiple: return 0.05
        case .paragraphSpacing: return 2
        case .paragraphIndentCharacters: return 0.5
        case .bodyContentWidth: return 20
        // 圆点直径一档 1 点：量程只有 4~16，一档 2 点就只剩 6 个位置可选
        case .bulletDiameter: return 1
        // 一档 1%：宽度的量程只有 15%~50%，跟 5% 一档比，1% 一档才够用
        case .outlineWidthRatio: return 0.01
        case .outlineWidthPoints: return 10
        case .outlineHeightRatio: return 0.05
        case .outlineMaximumHeight: return 20
        // 一档 5%：这一项量程是 20%~100%，5% 一档拖起来手感和别的比例项一致
        case .outlineBackgroundOpacity: return 0.05
        case .tableMinColumnWidth, .tableMaxColumnWidth: return 8
        // 字号一档 1 点：量程 9~28，一档 2 点就只能挑十个大小了
        case .tableSourceFontSize: return 1
        case .imageWidthRatio: return 0.05
        case .imageWidthPoints, .imageMaxHeight: return 20
        default: return 1
        }
    }

    /// 开关类这一项现在是开还是关（滑块那几行走不到这里，`makeToggleCell` 才会用它）。
    ///
    /// ### 为什么不写成「按 tag 判断」
    /// 每个开关行各自从配置里读自己那一项，加新开关就不用回来改一处集中判断 ——
    /// 漏改的表现是「拨了开关没反应」，很难查
    func isOn(in settings: MarkdownEditorSettings) -> Bool {
        switch self {
        case .showsLineNumbers: return settings.showsLineNumbers
        case .remembersScrollPosition: return settings.remembersScrollPosition
        case .pastesHTMLAsMarkdown: return settings.pastesHTMLAsMarkdown
        case .showsQuoteBackground: return settings.showsQuoteBackground
        case .outlineReservesSpace: return settings.reservesSpaceForOutline
        default: return false
        }
    }

    /// 配置里这一项现在的值
    func currentValue(in settings: MarkdownEditorSettings) -> Double {
        switch self {
        case .bodyFontSize: return settings.bodyFontSize
        case .lineHeightMultiple: return settings.lineHeightMultiple
        case .paragraphSpacing: return settings.paragraphSpacing
        case .paragraphIndentCharacters: return settings.paragraphIndentCharacters
        case .bodyContentWidth: return settings.bodyContentWidth
        case .bulletDiameter: return settings.bulletDiameter
        case .outlineWidthRatio: return settings.outlineWidthRatio
        case .outlineWidthPoints: return settings.outlineWidthPoints
        case .outlineHeightRatio: return settings.outlineHeightRatio
        case .outlineMaximumHeight: return settings.outlineMaximumHeight
        case .outlineBackgroundOpacity: return settings.outlineBackgroundOpacity
        case .tableMinColumnWidth: return settings.tableMinColumnWidth
        case .tableMaxColumnWidth: return settings.tableMaxColumnWidth
        // 从配置读「实际用的字号」：没单独设过时它是「正文 - 1」，滑块的起点才是对的位置
        case .tableSourceFontSize: return settings.tableSourceFontSize
        case .imageWidthRatio: return settings.imageWidthRatio
        case .imageWidthPoints: return settings.imageWidthPoints
        case .imageMaxHeight: return settings.imageMaxHeight
        default: return 0
        }
    }

    /// 把滑块的连续值吸到步进上（不然会停在 63.700003 这种数上）
    func steppedValue(_ raw: Double) -> Double {
        (raw / sliderStep).rounded() * sliderStep
    }

    /// 数值怎么显示给用户看
    func formatted(_ value: Double) -> String {
        switch self {
        case .bodyFontSize:
            return "\(Int(value.rounded())) pt"
        case .lineHeightMultiple:
            // 1 倍就是「什么都没加」，写个数字反而不如直接说清楚
            return value <= 1.001 ? "默认" : String(format: "%.2f 倍", value)
        case .paragraphSpacing:
            return "\(Int(value.rounded())) pt"
        case .paragraphIndentCharacters:
            return Self.formatCharacters(value)
        case .bodyContentWidth:
            // 量程最右端是「不限」—— 和 `MarkdownEditorSettings.bodyContentWidthLimit` 保持一致
            return value >= sliderRange.upperBound
                ? "不限"
                : "\(Int(value.rounded())) pt"
        case .outlineWidthRatio, .outlineHeightRatio, .outlineBackgroundOpacity:
            return "\(Int((value * 100).rounded()))%"
        case .outlineWidthPoints, .outlineMaximumHeight, .tableMinColumnWidth, .tableMaxColumnWidth,
             .tableSourceFontSize:
            return "\(Int(value.rounded())) pt"
        case .bulletDiameter:
            return "\(Int(value.rounded())) pt"
        case .imageWidthRatio:
            return "\(Int((value * 100).rounded()))%"
        case .imageWidthPoints, .imageMaxHeight:
            return "\(Int(value.rounded())) px"
        default:
            return "\(value)"
        }
    }

    /// 「缩进几个字」的显示：0 说「不缩进」，半个字也照实写出来
    private static func formatCharacters(_ value: Double) -> String {
        if value < 0.01 { return "不缩进" }
        let rounded = (value * 2).rounded() / 2
        let number = rounded == rounded.rounded()
            ? "\(Int(rounded))"
            : String(format: "%.1f", rounded)
        return "\(number) 字符"
    }
}
