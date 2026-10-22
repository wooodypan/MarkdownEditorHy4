//
//  MarkdownTabRestoration.swift
//  MarkdownEditorHy4
//
//  冷启动恢复上次打开的 Tab：把存档里的文件路径还原成能显示的内容项。
//

import Foundation
import MultiTabController

/// 「冷启动恢复上次打开的 Tab」的接入点。
///
/// ### 库已经做完了大半，这里只补最后一段
/// 存快照、重建 Tab 条、恢复预览标记、定位选中项，`MultiTabController` 的 `PPTabRestoration` 和 `DetailHostViewController` 都已经做好了。
/// 库唯一不认识的是「本 App 的文档长什么样」—— 它只存了一个内容 id，所以这里只需要回答一个问题：给一个 id，把那份内容还原出来。
///
/// ### id 为什么是文件路径
/// 本 App 右侧每个 Tab 编辑的就是磁盘上的一份真文件，路径天然是它的身份证（见 `DocumentOpening.open`，那边也用路径当 id）。
/// 换成 UUID 之类的临时标识，重启之后就再也对不上磁盘上的文件了。
///
/// ### 只对 iPad / Mac 生效
/// 「多 Tab」本身只存在于 iPad / Mac 的分栏界面（`SplitContainerViewController` 的右栏）。
/// iPhone 是导航栈，一次只显示一页，没有 Tab 可恢复 —— 那边开关虽然也是开的，但没有宿主去读写存档，等于什么都不做。
enum MarkdownTabRestoration {

    // MARK: - 接入

    /// 在 App 启动时调用一次，把「怎么按 id 找内容」交给库。
    ///
    /// 必须早于右侧详情宿主第一次加载（也就是建窗口、建 `WorkspaceCoordinator` 之前）。
    /// 宿主是在自己的 `viewDidLoad` 里读这份配置的，晚一步就赶不上，结果是一扇空窗口，而且不会报错，很容易误判成「存档没写进去」。
    static func install() {
        PPTabRestoration.enable(resolver: contentItem(forID:))
    }

    /// 这次冷启动有没有一份「看起来能恢复」的 Tab 存档。
    ///
    /// 左栏用它决定还要不要「自动打开第一份文档」。不判这一下的话会有两种尴尬：
    /// - 历史里没有预览 Tab（用户把它转成正式 Tab 或关掉了）→ 启动后凭空多出一个预览 Tab；
    /// - 历史里有预览 Tab → 恢复出来的那一个当场被换成列表里的第一份，看起来像「恢复错了」。
    ///
    /// 只检查「有数据 + tabs 非空」，不校验版本号：版本号是库的内部约定，在这边抄一遍迟早会跟它脱节。真遇上旧版本存档时库会忽略，代价只是右栏空着，用户点一份文档就打开了 —— 比起误判成「没有历史」当场开一份、把恢复入口挡掉，这个代价小得多。
    static var willRestoreTabsOnLaunch: Bool {
        guard PPTabRestoration.isEnabled,
              let data = UserDefaults.standard.data(forKey: PPTabRestoration.persistenceKey),
              let snapshot = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tabs = snapshot["tabs"] as? [Any] else {
            return false
        }
        return !tabs.isEmpty
    }

    // MARK: - 路径 → 内容项

    /// 把存档里的路径还原成一份内容项。
    ///
    /// - Returns: 文件读得出来就返回它；文件被删了、路径不再是文档、没权限读，一律返回 `nil`。库收到 `nil` 只会跳过这一条，其它 Tab 照常恢复，而且不会因此改写存档 —— 一次临时的读取失败不该把用户的历史永久删掉。
    static func contentItem(forID id: String) -> PPContentItem? {
        let url = URL(fileURLWithPath: id)

        // 先按扩展名挡一道：存档被改坏、或者以后 id 规则变了时，别把一张图片、一个目录当成文档塞进编辑器。
        guard DocumentsWorkspace.isDocument(url) else { return nil }

        // 容器外的文件要靠书签重新拿权限；文件在 Finder 里被改名 / 移走时，书签还会顺手把它解析到新位置。拿不到访问权就当这份没了。
        guard let readableURL = ExternalDocumentAccess.shared.readableURL(for: url) else {
            return nil
        }

        // 目录也可能叫 `xxx.md`，所以拿到访问权之后还要确认它真是普通文件。
        // 用 `readableURL` 而不是原路径查：原路径可能还没权限，属性读不出来会被当成不存在。
        guard (try? readableURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
              let text = DocumentsWorkspace.read(readableURL) else {
            return nil
        }

        let canonicalURL = ExternalDocumentAccess.shared.canonicalURL(for: readableURL)
        migrateRecentRecordIfMoved(from: url, to: canonicalURL)

        // 三个字段跟 `DocumentOpening.open` 里那套保持一致：id 用规范化后的完整路径（左栏高亮、最近记录都靠它对上），标题去掉扩展名（Tab 条上显示的就是它），body 就是文件内容。
        return PPContentItem(id: canonicalURL.path,
                             title: DocumentsWorkspace.displayName(for: readableURL),
                             body: text,
                             // 左栏是平铺列表，用不上分组；这个字段留着是为了以后要按子目录 / 标签分组时不用改协议
                             category: "Documents")
    }

    // MARK: - 内部

    /// 文件被改名 / 移走时，把「最近打开」里那条旧记录挪到新路径。
    ///
    /// ### 为什么只在路径真的变了时才动记录
    /// 路径没变就说明文件还在原地，此时写记录会刷新「最近打开」的排序 —— 冷启动恢复一批 Tab 就把整张列表的顺序重排一遍，没必要。
    ///
    /// ### 为什么不直接在恢复时记一笔「刚打开」
    /// 恢复出来的是上次就开着的文档，不是用户这次新点的。只有路径变了才需要迁移，因为旧路径那条记录再点会找不到文件。
    private static func migrateRecentRecordIfMoved(from oldURL: URL, to newURL: URL) {
        let access = ExternalDocumentAccess.shared
        let oldPath = access.canonicalPath(for: oldURL)
        guard oldPath != access.canonicalPath(for: newURL) else { return }

        RecentDocumentsStore.shared.remove(URL(fileURLWithPath: oldPath))
        RecentDocumentsStore.shared.record(newURL)
    }
}
