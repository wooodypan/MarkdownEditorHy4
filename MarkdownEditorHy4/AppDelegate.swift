//
//  AppDelegate.swift
//  MarkdownEditorHy4
//
//  Created by pan on 2026/8/31.
//

import UIKit
// 只在 Debug 构建里引入：Release 用不到这套调试面板，别让它的代码进正式包。
#if DEBUG
//import DebugSwift
#endif

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    // MARK: Mac 菜单栏

    #if targetEnvironment(macCatalyst)
    /// Mac 专属：往菜单栏加「文件」菜单 —— 新建 ⌘N / 打开… ⌘O / 存储 ⌘S。
    ///
    /// 整段用 `#if targetEnvironment(macCatalyst)` 包住 —— iOS 上这段代码
    /// 不参与编译，所以 iOS 构建完全不受影响。
    ///
    /// 关于 target：这里不指定任何对象，等于让系统沿响应链（responder chain）
    /// 去找「谁实现了这些方法」，当前窗口里的 ViewController 会接住。
    /// 链上没人实现时菜单项自动变灰，不会崩。
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        // 只管主菜单栏，系统菜单之类的一律不动
        guard builder.system == .main else { return }

        let newDoc = UIKeyCommand(title: "新建",
                                  action: #selector(MarkdownDocumentViewController.newDocument),
                                  input: "n",
                                  modifierFlags: .command)
        // ⚠️ 这里**故意不放**「打开…」。
        // Catalyst 会为所有 App 自动提供一个「文件 > 打开…」(⌘O)，藏在系统菜单的子分组里：
        // 再自己加一条同快捷键的项，UIKit 会直接抛
        // NSInvalidArgumentException: Replacement elements contain duplicates 崩溃。
        // 所以改成「接管」系统那一条 —— MarkdownDocumentViewController 实现 open(_:) 后，
        // 系统菜单的「打开…」就会调到我们的实现，菜单位置和快捷键都是原生的。
        let save = UIKeyCommand(title: "存储",
                                action: #selector(MarkdownDocumentViewController.saveDocument),
                                input: "s",
                                modifierFlags: .command)

        // 「存储」单独分一组（displayInline），菜单里和「新建」之间会显示一条分隔线
        let fileItems: [UIMenuElement] = [
            newDoc,
            UIMenu(options: .displayInline, children: [save])
        ]

        if let existingFileMenu = builder.menu(for: .file) {
            // ### 保险起见：先让路
            // UIKit 对重复快捷键是零容忍的 —— 撞上就抛 `NSInvalidArgumentException: Replacement elements contain duplicates` 直接崩，而且是**崩在启动那一刻**（菜单是启动时构建的），查起来毫无头绪。所以宁可先让路，再把我们这组放到菜单最前面。
            //
            // ⚠️ 2026-10-14 实测（这条踩过一次）：**必须递归往下找**。系统那几组 ——「新建窗口」「打开…」「关闭」… —— 都不是直接挂在「文件」菜单下的，而是套在子菜单分组里（`com.apple.menu.new-item` / `com.apple.menu.open` 这种）。只看第一层的话，下面这段过滤等于没写。
            // 具体踩到的：为了「设置」独立窗口把 `UIApplicationSupportsMultipleScenes` 打开之后，系统往「文件」菜单里多塞了一条 **New Window (⌘N)**，正好和我们的「新建」撞车 → 启动即崩。
            let takenInputs: Set<String> = ["n", "s"]

            /// 这一项（或者它下面任意一层）有没有占用我们要用的快捷键。
            /// `UICommand`（Move / Rename… 那种系统项）读不到快捷键，一律当没占用。
            func takesOurShortcut(_ element: UIMenuElement) -> Bool {
                if let command = element as? UIKeyCommand {
                    guard let input = command.input, command.modifierFlags == .command else { return false }
                    return takenInputs.contains(input)
                }
                if let menu = element as? UIMenu {
                    return menu.children.contains(where: takesOurShortcut)
                }
                return false
            }

            // 分组里只要有一项撞上就**整组摘掉**（不去动组内其他项）：现实里这样的分组都只装着自己一项 —— 上面那条 New Window 就是独占 `com.apple.menu.new-item` 一组的。
            // 代价是少了一条「新建窗口」：本工程是多 Tab 编辑器，⌘N 留给「新建文档」更合适，也不需要开第二个工作区窗口。
            let keptItems = existingFileMenu.children.filter { !takesOurShortcut($0) }
            builder.replaceChildren(ofMenu: .file) { _ in
                fileItems + keptItems
            }
        } else {
            // Catalyst 默认没有「文件」菜单，就自己建一个。
            // 插在 App 菜单（.application）后面 —— 这正是 macOS 上「文件」该在的位置
            let fileMenu = UIMenu(title: "文件",
                                  image: nil,
                                  identifier: UIMenu.Identifier("com.pan.MarkdownEditorHy4.file"),
                                  options: [],
                                  children: fileItems)
            builder.insertSibling(fileMenu, afterMenu: .application)
        }

        // ### 「设置…」(⌘,)
        // 这是 macOS 的固定约定：菜单项放在 App 菜单里「关于」的**正下方**，快捷键就是 ⌘+逗号。
        // 系统只在 App 自带 `Settings.bundle` 时才会自动提供这一项（本工程没有），所以得自己加 —— 也正因为没有，撞不上系统那条，不用担心快捷键重复。
        // 点它的效果：有 Tab 时是 `MarkdownDocumentViewController.showSettings`、没 Tab 时是本类下面那个兜底，两条都汇到 `SettingsOpener.open()` —— Mac 上开**独立窗口**，其它设备模态弹出。
        let preferences = UIKeyCommand(title: "设置…",
                                       action: #selector(MarkdownDocumentViewController.showSettings),
                                       input: ",",
                                       modifierFlags: .command)
        // 标题留空 + `.displayInline`：不生成二级菜单，这一行直接平铺在 App 菜单里（和上面「存储」那个分组的写法一样）。
        let preferencesMenu = UIMenu(title: "", options: .displayInline, children: [preferences])
        builder.insertSibling(preferencesMenu, afterMenu: .about)
    }
    #endif

    // MARK: ⌘N 的兜底落点

    /// 「新建文档」的**兜底实现**，只为让菜单项在没有 Tab 的时候也亮着。
    ///
    /// ### 为什么要放在这儿
    /// 菜单里的「新建」是靠响应链找实现的：右侧有 Tab 时由那个 Tab 的
    /// `MarkdownDocumentViewController` 接住；但**一个 Tab 都没有**（刚启动、右栏空空）
    /// 时，响应链上没人实现它，菜单项就会变灰 —— ⌘N 也就按不动了。
    /// App 委托是响应链的最后一站（窗口 → 场景 → 应用 → 委托），放在这里必然找得到。
    ///
    /// 具体干活的不在这儿：它只把「想新建」这件事报出去，由左侧栏去磁盘上建文件、
    /// 再在右侧开个新 Tab（消息名跟 `MarkdownDocumentViewController.newDocument` 用的是同一个）。
    @objc func newDocument() {
        NotificationCenter.default.post(name: DocumentsWorkspace.newDocumentRequestedNotification,
                                        object: nil)
    }

    // MARK: ⌘, 的兜底落点

    /// 「打开设置」的**兜底实现**，理由和上面的 `newDocument()` 一模一样：**一个 Tab 都没开**（右侧空空）时，响应链上没人接 ⌘,，菜单里那一项就会变灰、按不动，而 App 委托是响应链的最后一站（窗口 → 场景 → 应用 → 委托），放在这儿必然找得到。
    ///
    /// 有 Tab 的时候轮不到这里 —— 排在前面的 `MarkdownDocumentViewController.showSettings` 会先接住；两条路走的是同一个入口（`SettingsOpener.open`），Mac 开独立窗口、其它设备模态弹出。
    @objc func showSettings() {
        // 不传 host：模态那条路会让 `SettingsOpener` 自己去当前活动窗口的根控制器弹（Mac 上根本用不到这个参数）
        SettingsOpener.open()
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // ### 先把上次选的外观读回来
        // 要在建窗口之前：`SceneDelegate` 搭好窗口后会按这里记下的模式套一次。
        // 放最前面还有个好处 —— 冷启动时界面一露脸就是用户选的那种明暗，不会先闪一下白再变黑
        MarkdownAppearance.install()

        // ### 启动先把「文档目录」准备好
        // 第一次装完 App、Documents 里一份文档都没有时，把 App 包里的 sample.md
        // 复制进去 —— 否则左侧栏是空的，新用户打开只看到一片白，不知道该干什么。
        //
        // 放在这里（而不是某个页面里）是因为它属于「启动时的数据准备」：
        // 左栏那份列表一起来就要读到内容，不能等到它出现才发现目录是空的。
        DocumentsWorkspace.installSampleIfNeeded()

        // ### 启动再查一遍「最近打开」里那些文件还在不在
        // 用户在 Finder /「文件」App 里把某份 .md 删了，App 是收不到通知的 ——
        // 不查的话，「最近」那一页就会一直躺着一条点开就报错的记录。
        // 这里把「文件已经不在了」的记录剔掉（只清记录，一份文件都不会动）。
        RecentDocumentsStore.shared.pruneMissingFiles()

        // 兜底：个别系统版本冷启动时只把文件 URL 放在 launchOptions 里，不派发给 scene
        if let url = launchOptions?[.url] as? URL {
            MarkdownDocumentOpener.shared.handle(url: url)
        }
        #if DEBUG
        // DebugSwift 调试窗口：`setup()` 注册各个调试面板，`show()` 把屏幕上那个可拖动的入口显示出来。想关掉某个开销大的面板就写成 `DebugSwift().setup(disable: [.leaksDetector]).show()`。
        // 把包依赖规则从「按版本号 Up to Next Major」改成「固定到某个提交」，钉在 rc-1.20.7 对应的那个 commit（bccfb16ff6c116b15cde8e2918a1ed1f126c9e53）。这样 Catalyst 就能编过了
//        DebugSwift().setup().show()
        #endif
        return true
    }

    // MARK: 从 Finder 打开 .md 文件

    /// 兜底路径：SceneDelegate 没实现 openURLContexts 时，系统会走这里。
    /// 两条路不会同时被调用（UIKit 优先派发给 scene），所以不会重复打开。
    func application(_ app: UIApplication,
                     open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        MarkdownDocumentOpener.shared.handle(url: url)
        return true
    }

    // MARK: UISceneSession Lifecycle

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Called when a new scene session is being created.
        // Use this method to select a configuration to create the new scene with.
        let config = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        // ⚠️ 这一行不能省。Info.plist 里那份配置是按**名字**找的，靠名字匹配有点绕；这里直接点名 SceneDelegate，保证**设置窗口那个新场景**（Mac 上点 ⌘, 时由 `requestSceneSessionActivation` 创建）也归 SceneDelegate 管 —— 它得先认出「这是设置窗口」，才不会搭出一整个工作区来。
        config.delegateClass = SceneDelegate.self
        return config
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        // Called when the user discards a scene session.
        // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
        // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // 容器外文件的安全作用域是成对申请 / 释放的，退出时统一还回去。
        // 书签已经落盘，下次启动还能解析出来，不影响「最近」。
        MarkdownDocumentOpener.shared.stopAccessing()
    }

}

