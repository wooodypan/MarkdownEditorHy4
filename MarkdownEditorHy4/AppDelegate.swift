//
//  AppDelegate.swift
//  MarkdownEditorHy4
//
//  Created by pan on 2026/8/31.
//

import UIKit

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
            // 保险起见：先摘掉占用了 ⌘N / ⌘S 的旧项。
            // UIKit 对重复快捷键是零容忍的 —— 撞上就抛
            // NSInvalidArgumentException: Replacement elements contain duplicates 直接崩，
            // 所以宁可先让路，再把我们这组放到菜单最前面
            let takenInputs: Set<String> = ["n", "s"]
            let keptItems = existingFileMenu.children.filter { element in
                guard let command = element as? UIKeyCommand,
                      let input = command.input,
                      command.modifierFlags == .command else { return true }
                return !takenInputs.contains(input)
            }
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

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
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
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        // Called when the user discards a scene session.
        // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
        // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
    }


}

