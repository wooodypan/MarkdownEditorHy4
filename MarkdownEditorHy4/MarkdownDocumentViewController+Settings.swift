//
//  MarkdownDocumentViewController+Settings.swift
//  MarkdownEditorHy4
//
//  设置页和主题页的入口、「设置变了就写主题、重排」这条链，以及大纲展开时正文让位那套算术。
//
//  ⚠️ 从 `MarkdownDocumentViewController.swift` 拆出来的：代码原样搬过来，只去掉了 `private`
//  （Swift 的 private 只在本文件可见，跨文件就调不到）。
//

import UIKit

extension MarkdownDocumentViewController {

    // MARK: 设置

    /// 打开设置页。「⋯」菜单里的「设置」和 Mac 菜单栏的「设置…」(⌘,) 都走到这里。
    ///
    /// ⚠️ 这里刻意不加 `private`：Mac 菜单栏那条 ⌘, 要引用它的 selector（`AppDelegate.buildMenu`），`#selector` 够不到 `private` 的方法，编译直接报 `inaccessible due to 'private' protection level`。和 `saveDocument` 是同一个理由。
    ///
    /// 具体怎么开（Mac 独立窗口 / 其它设备模态，已经开着就不再开一个）收在 `SettingsOpener.open(from:)` 里，这里只回答「从谁身上开」。
    @objc func showSettings() {
        SettingsOpener.open(from: self)
    }

    /// 弹出主题页。
    ///
    /// 为什么单开一页而不在设置页里加一个分组：主题往后不止三套，设置页那种「一个分组 + 一个分段控件」的写法，选项一多就挤成「…」。
    /// 包一层导航栏是为了把「完成」挂在上面，和设置页一样。
    ///
    /// ### 这一页改了不用手动刷新编辑器
    /// 它写的是同一个 `settings`，改动会发出 `didChangeNotification`，本页的 `settingsDidChange` 收到后照旧调用 `applyEditorStyle()`，关掉页面时编辑区已经换成新配色了。
    @objc func showThemePicker() {
        let controller = MarkdownThemeViewController(settings: settings)
        present(UINavigationController(rootViewController: controller), animated: true)
    }

    /// 设置一变就生效，不用重启
    func observeSettingsChanges() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(settingsDidChange),
                                               name: MarkdownEditorSettings.didChangeNotification,
                                               object: settings)
    }

    @objc func settingsDidChange() {
        applyOutlineAppearance()
        applyEditorStyle()
    }

    /// 把配色、正文排版、表格（列宽和源码样式）、图片尺寸这几组配置写进编辑器主题，再套上主题外壳（编辑区字号、链接样式、底色）。**不重排。**
    ///
    /// 🚨 单拆出来是为了「打开文档」那条路：那边必须在 `setMarkdown` **之前**调它，让文档那一次渲染就用上最终主题。
    /// 顺序反过来（先 `setMarkdown` 再 `refreshTheme()`）会先用默认主题整篇渲一遍，紧接着再用真主题整篇重渲一遍，同一份内容渲染两次，实测各约 155 ms（2026-10-11 的 Time Profiler）。
    ///
    /// 为什么这几组必须一起写，见下面 `applyEditorStyle` 的注释。
    func applyStyleToTheme() {
        // 配色放最前面：它只改颜色，后面那几组（字号、表格列宽、图片尺寸）
        // 会再按用户拖过的滑块覆盖自己那几个值，两者不冲突
        settings.applyColors(to: &editor.renderer.theme,
                             customPalette: MarkdownCustomThemeStore.shared
            .loadPalette(named: settings.customThemeFileName))
        // 编辑区外面这一圈（宿主留白、大纲底下的底板）也要跟着底色走：
        // 深色主题下编辑区黑了、边框还是白的，看着像没换干净。
        // ⚠️ 大纲面板不动：它用的是系统色，自己跟着系统的浅色 / 深色外观走
        view.backgroundColor = editor.renderer.theme.editorBackground
        settings.applyTypography(to: &editor.renderer.theme)
        settings.applyTableColumnWidths(to: &editor.renderer.theme)
        // 表格源码的字号 / 颜色：必须排在 `applyColors` 之后，
        // 用户单独指定的那一色才不会被配色表盖掉（理由见 `applyTableSourceStyle`）
        settings.applyTableSourceStyle(to: &editor.renderer.theme)
        settings.applyImageSize(to: &editor.renderer.theme)
        // 行宽是编辑器自己的布局参数，不走主题：主题管文字长什么样，行宽取决于窗口有多宽
        editor.maxContentWidth = settings.bodyContentWidthLimit.map { CGFloat($0) }
        // 行号是编辑器自己的显示开关：改它会让左边的装订线占掉或让出一条带子，正文宽度跟着变
        editor.showsLineNumbers = settings.showsLineNumbers
        // 只读模式是编辑器的行为开关（能不能改），和长什么样无关，单独赋值一次
        editor.isReadOnly = settings.isReadOnly
        // 「引用内容加底色」是渲染期读的开关，改完要整篇重渲染才见效。
        // 从设置页过来那条路会走到 `applyEditorStyle()`（里面有刷新），不用在这儿再排一遍
        editor.renderer.theme.showsQuoteBackground = settings.showsQuoteBackground
        // 「行内代码反引号加底色」同理：底色是渲染时挂到字符上的，改完必须重渲染
        editor.renderer.theme.inlineCodeBacktickHasBackground =
            settings.showsInlineCodeBacktickBackground
        // 字号 / 链接色 / 底色存在 view 自己身上，不跟着富文本走，得手动搬一次
        editor.applyThemeChrome()
    }

    /// 设置变了（设置页改了排版、主题页换了配色）：写主题，再整篇重排一遍。
    ///
    /// ### 为什么这几组合成一个方法
    /// 它们走的是同一条路：改主题里的数值，必须重渲染才生效。字号、行高、段间距、首行缩进是渲染时写进段落样式的，表格是渲染时画成图的，图片尺寸是渲染时写进 attachment 的 `bounds` 的，事后改主题也改不动已经排好的图。
    /// 各写一个方法、各排一遍的话，用户在设置页拖一下滑块会多排一次。
    ///
    /// ### 为什么必须重排
    /// 只改主题里的数值、不重新渲染，屏幕上的文字不会变。
    /// 好在这套渲染是幂等的：同一份源码加同一套主题，结果永远一样，所以拖滑块时每动一下就重排也扛得住。
    /// 它还保着光标位置（见 `MarkdownTextView.refreshTheme`），不会拖两下就跳回文首。
    func applyEditorStyle() {
        applyStyleToTheme()
        editor.refreshTheme()
    }

    /// 把大纲面板这一组的配置（宽高和背景不透明度）同步给面板本体。
    ///
    /// 配置到面板参数的换算放在配置那边（`MarkdownEditorSettings.applyOutlineWidth` / `applyOutlineHeight` / `applyOutlineBackground`），这样能各自单独测；
    /// 这里只负责把结果送过去，再让面板重算一次宽高。
    func applyOutlineAppearance() {
        settings.applyOutlineWidth(to: &outlineView.appearance)
        settings.applyOutlineHeight(to: &outlineView.appearance)
        settings.applyOutlineBackground(to: &outlineView.appearance)
        // 宽高是算出来的，不用动画：拖滑块时不该一直有动画
        outlineView.refreshAppearance()
        // 宽度变了，正文要让出去的那块也得跟着变。
        // 这一句同时是设置页里那个留白开关的落点：`settingsDidChange` 会走到这里
        updateEditorTrailingInset()
    }

    /// 正文右边距：离父视图右边多少点。常态是 `editorHorizontalInset`，大纲展开时再加上面板那块。
    ///
    /// 展开时让出「面板宽度 + 它离屏幕右边的留白（`edgeMargin`）+ 一点空隙」，正文右边界正好落在卡片左边缘左边，字不会被卡片压住。
    /// 收起态是右上角那个 46×36 的小方块，只压一个角，不为它挤窄整列正文。
    ///
    /// 面板宽度可以调到占屏幕 80%（「按百分比」模式），照这个数让，窄屏上正文只剩一条缝，所以封顶：正文最多让出一半。
    /// iPhone 竖屏才三百来点宽，封顶一半也救不回来（让完每行只剩两三个字），所以这一项在 iPhone 上固定不生效，设置里也不显示那个开关，判断同在 `MarkdownEditorSettings.supportsReservingSpaceForOutline`。
    var outlineTrailingInset: CGFloat {
        // 常态：和左边距对称，也是 20 点
        let base = Self.editorHorizontalInset
        guard settings.reservesSpaceForOutline,
              MarkdownEditorSettings.supportsReservingSpaceForOutline else { return base }
        // 收起时 occupiedWidth 就是 0，下面那道判断会直接返回
        let occupied = outlineView.occupiedWidth
        guard occupied > 0, view.bounds.width > 0 else { return base }
        let wanted = occupied + outlineView.appearance.edgeMargin + Self.outlineEditorGap
        // 封顶用正文满宽来算（扣掉左右各 20 点），否则留的那一半里还含着一截边距
        let fullWidth = view.bounds.width - base * 2
        return min(max(base, wanted), base + fullWidth * Self.maximumOutlineShare)
    }

    /// 正文左右两边的边距（点）。两边对称，贴着窗口边排字显得很挤
    static let editorHorizontalInset: CGFloat = 20
    /// 正文和面板之间再空出多少（点）。纯视觉，贴着卡片边缘排字显得很挤
    static let outlineEditorGap: CGFloat = 8
    /// 正文最多让出多少比例（0.5 = 让人一半、自己留一半）
    static let maximumOutlineShare: CGFloat = 0.5

    /// 把正文右边距改成该给大纲让出多少。
    ///
    /// ⚠️ 值没变就直接返回：这个方法在每次布局里都会被调（`viewDidLayoutSubviews`），
    /// 不判一下的话等于每次布局都改一次约束，Auto Layout 会被拖着多跑一轮。
    ///
    /// ### 为什么不做动画（大纲卡片自己是动画收放的）
    /// 编辑器一改宽度就整篇重排（见 `MarkdownTextView.layoutSubviews` 里按 `renderedWidth` 重渲那一段）。
    /// 塞进 `UIView.animate` 的话，Auto Layout 会在 0.22 秒里逐帧改宽度，等于每帧整篇重渲一遍，长文档会明显卡顿。
    /// 所以正文直接换到新宽度，只有大纲卡片自己滑过去。两条动画不同步，换来的是不掉帧。
    func updateEditorTrailingInset() {
        guard let editorTrailingConstraint else { return }
        let inset = outlineTrailingInset
        // 约束上的值是负的（往左收），所以比较时取反
        guard abs(-editorTrailingConstraint.constant - inset) > 0.5 else { return }
        // 不在这儿催布局：这个方法多数时候是在布局过程中被调的（`viewDidLayoutSubviews`），
        // 当场 `layoutIfNeeded()` 等于就地再跑一轮。设完 constant，系统下一拍自然会重排
        editorTrailingConstraint.constant = -inset
    }
}

