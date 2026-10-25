//
//  DocumentHistoryStore.swift
//  MarkdownEditorHy4
//
//  历史版本仓库，相当于给每份文档配了一个「自动存档柜」。
//
//  大白话：你写着写着，它隔一会儿就往柜子里收一份副本；哪天改坏了、误删了，还能把以前某一份拿回来。
//
//  技术上的样子：每份文档一个文件夹，里面一份清单（manifest.json）+ 每个版本一份正文快照。
//  编辑页右上角「⋯」菜单里的「历史版本」就是读这里。
//
//  ## 为什么每次存一整份，而不是只存"这次改了哪几个字"
//  存一整份，坏了一份也只是少一版，别的照样能打开；只存改动片段的话，中间丢一段，后面几版就全串不起来了。
//  markdown 文件一般就几 KB 到几百 KB，再加上「每个文件只留最近十几版（默认 10 条，设置里最多可调到 100）」的清理规则，占不了多少地方。
//
//  ## 为什么不放 Caches 目录
//  Caches 是系统"缺空间就随时清"的地方，放那儿历史会莫名其妙消失。放 Application Support 不会。
//  这个目录还会被打上「不要备份」的标记：历史只在本机有用，没必要跟着 iCloud 备份和同步走。
//
//  ## ⚠️ 删目录这件事在这里特意收紧了
//  历史文件夹的名字是「文档路径算出来的一串哈希」，永远只可能是 0-9a-f，不可能出现 `/`、`..`、`.` 这类东西。
//  真要删之前还要再验一遍：目标确实在历史根目录**里面**，而且不能**就是**根目录本身。
//  两道都卡住，才不会出现「删一份文档的历史，结果把整个 Application Support 删掉」这种事。
//

import Foundation
import CryptoKit

// MARK: - 数据模型

/// 一个历史版本，相当于存档柜里的一格：清单上的某一行就是它。
///
/// 这里只记"什么时候存的、为什么存的、内容多大、指纹是多少"，真正的正文在隔壁另一个 `.md` 文件里，文件名就是这个版本的 `id`（一串 UUID）。这样清单可以整份重写，也不用把正文塞进 JSON 里。
struct DocumentVersion: Codable, Equatable, Identifiable {

    /// 这一版是"怎么来的"：自动攒的、离开时补的、用户手动存的、还是恢复前的保险。
    enum Reason: String, Codable {
        /// 停止输入一段时间后自己存的，用户没动手
        case autoSave
        /// 切走 App、退到后台时补存的
        case appBackground
        /// 用户点「保存当前版本」存的，这种永远不会被自动清理
        case manual
        /// 恢复旧版本之前，先给"当时那份内容"存的保险
        case beforeRestore

        /// 列表上给用户看的说法（直接显示这几个中文字）
        var displayName: String {
            switch self {
            case .autoSave: return "自动留档"
            case .appBackground: return "离开时留档"
            case .manual: return "手动保存"
            case .beforeRestore: return "恢复前备份"
            }
        }
    }

    let id: UUID
    /// 自增编号，像银行排队取号：号大的更新。比新旧只看它，不看时间 —— 同一秒里可能连着存两版
    let sequence: Int
    /// 存下来的时刻，只用来在列表上显示
    let createdAt: Date
    /// 内容的"指纹"（SHA-256）。下次存之前比一下，一样就不再存第二份
    let contentHash: String
    /// 正文有多少字节，列表上显示成「4 KB」
    let byteCount: Int
    /// 用 `var`：自动存的版本可以被用户「转正」成手动版本（只改这一个字段，不复制正文）
    var reason: Reason
    var note: String?

    /// 正文存在哪个文件里
    var fileName: String { "\(id.uuidString).md" }
}

/// 一份文档的版本清单，也就是 `manifest.json` 里装的东西。
///
/// 大白话：这是存档柜的"目录页"，写着里面一共存了哪几格、每格是什么时候存的。
struct DocumentHistoryManifest: Codable {

    /// 清单格式的版本号，将来结构变了靠它认出「这是不是我能读懂的格式」
    static let currentSchemaVersion = 1

    var schemaVersion = DocumentHistoryManifest.currentSchemaVersion
    /// 下一个要发出去的编号
    var nextSequence = 1
    /// 最近一次留档时这份文档的完整路径。
    ///
    /// 文件夹改名时要靠它认出「这份历史属于哪份文档」—— 文件夹名是路径算出来的哈希，光看哈希反推不出路径。
    var path = ""
    var versions: [DocumentVersion] = []

    /// 最新版本在数组里排第几个（编号最大的那个）
    var latestIndex: Int? {
        versions.indices.max { versions[$0].sequence < versions[$1].sequence }
    }

    var latest: DocumentVersion? { latestIndex.map { versions[$0] } }
}

/// 清理规则：自动版本最多留几份、手动版本要不要特殊对待。
///
/// 大白话：柜子只有固定几格，存满了就得挑最旧的扔掉；用户特意点"保存"的那些不扔。
struct DocumentHistoryRetention {
    /// 自动版本最多留多少个，超了就从最旧的开始丢（数只有几份由用户在设置里定，默认 10、最多 100）
    var maxCount = 10
    /// true：手动存的版本永久保留，而且不占上面那个名额
    var manualVersionsExempt = true
}

/// 恢复这件事的结果：内容一定有；`safetyBackupError` 不为空就说明「恢复前那份内容没存上」。
struct DocumentHistoryRestoreResult {
    let content: String
    let safetyBackupError: Error?
}

/// 历史这摊事可能出的几种错，每一种都配好了给用户看的一句中文。
///
/// 特意写成 `LocalizedError`：界面是直接把 `error.localizedDescription` 显示给用户看的，这里写的话术就是用户最终读到的那句话，不该冒出一串英文系统错误。
enum DocumentHistoryError: LocalizedError {
    /// 文档编号不是我们自己算出来的那种形状（纯防御，正常永远走不到）
    case invalidDocumentID(String)
    /// 清单里没这个版本，或者它的正文文件已经不在了
    case versionNotFound
    /// 正文读出来不是合法的 UTF-8 文字
    case contentUnreadable
    /// 清单文件坏了解析不出来
    case manifestUnreadable(underlying: Error)
    /// 想删的东西跑到历史根目录外面去了（纯防御：正常永远走不到，走到就是代码写错了）
    case outsideRoot(String)

    var errorDescription: String? {
        switch self {
        case .invalidDocumentID(let id):
            return "历史记录的编号不认识（\(id)），已跳过这次操作。"
        case .versionNotFound:
            return "找不到这个历史版本，它可能已经被清理掉了。"
        case .contentUnreadable:
            return "这个历史版本的正文读不出来（不是 UTF-8 文本）。"
        case .manifestUnreadable(let error):
            return "历史记录清单读不出来：\(error.localizedDescription)"
        case .outsideRoot(let path):
            return "这次删除的目标不在历史目录里（\(path)），已取消。"
        }
    }
}

// MARK: - 本体

/// 历史版本的读写入口：存一版、列版本、读正文、恢复、删除、改名搬家，都从这里过。
///
/// ### 为什么是普通 class，没用 actor
/// 工程开了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`（不写隔离的类默认都跑在主线程），而留档这件事很轻（几 KB 的文本写一次文件），主线程直接做完就行。
/// 用 actor 反而要把每个调用点都改成 `await`，界面那边一堆异步回调，划不来。
/// "同一时间只有一个人能进来改"这件事，由"默认都在主线程"这一点保证。
final class DocumentHistoryStore {

    /// App 里全局用这一个；单元测试会自己 new 一个指向临时目录的，绝不碰真数据。
    ///
    /// 「每个文件留几份」不在这儿定死：每次清理都现去设置里读（见 `retention`），用户拖完滑块不用重启 App。
    static let shared = DocumentHistoryStore(
        retentionProvider: {
            DocumentHistoryRetention(maxCount: Int(MarkdownEditorSettings.shared.historyVersionLimit.rounded()))
        }
    )

    /// 历史版本的老巢（「不要备份」的标记在建目录时打上）。
    ///
    /// 用 `Application Support` 而不是 `Caches`：后者空间一紧就会被系统清掉。
    static var defaultRootURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("MarkdownEditorHy4", isDirectory: true)
            .appendingPathComponent("DocumentHistory", isDirectory: true)
    }

    private let rootURL: URL
    private let retentionProvider: () -> DocumentHistoryRetention
    private let fileManager = FileManager.default

    /// 现在这一套清理规则：App 里每次现读设置，测试里就是构造时传进来的那份固定值。
    ///
    /// 为什么做成「现问」而不是存一份：`shared` 只构造一次，存下来的话用户在设置里改完条数得重启才生效。
    private var retention: DocumentHistoryRetention { retentionProvider() }

    /// 清理规则在构造时定死。单元测试走这条，跑起来不受用户真实设置影响。
    ///
    /// - Parameters:
    ///   - rootURL: 历史根目录。测试传一个临时目录，绝不碰 App 自己的那一份
    ///   - retention: 清理规则
    init(rootURL: URL = DocumentHistoryStore.defaultRootURL,
         retention: DocumentHistoryRetention = DocumentHistoryRetention()) {
        self.rootURL = rootURL
        self.retentionProvider = { retention }
    }

    /// 每次清理现去读「留几份」。App 里走这条（用户改完设置立刻按新条数清理）。
    ///
    /// - Parameters:
    ///   - rootURL: 历史根目录
    ///   - retentionProvider: 现读清理规则；每次存档要清理时都会调一次
    init(rootURL: URL = DocumentHistoryStore.defaultRootURL,
         retentionProvider: @escaping () -> DocumentHistoryRetention) {
        self.rootURL = rootURL
        self.retentionProvider = retentionProvider
    }

    /// 原因见 `MarkdownBlock` / `OutlineCoordinator` 里 `nonisolated deinit` 那段长注释。
    /// 这个类持有的都是值类型或常量引用，声明成 nonisolated 完全安全。
    nonisolated deinit {}

    // MARK: 对外：留档

    /// 自动存一版（停止输入、进后台、按 ⌘S、离开页面这些时机都会调）。
    ///
    /// 大白话：动手存之前先看一眼"和最近那版一样吗"，一样就什么都不做，省得攒一堆重复的。
    ///
    /// 内容跟最新版一模一样时直接返回 nil：不然每敲一个字就多一版，很快把名额（默认 10 条）占满，真正有用的旧版本反而被挤掉了。
    ///
    /// - Returns: 新存下的版本；内容没变就是 nil
    /// - Parameter protecting: 这一轮清理不许动到的版本（恢复旧版本时传目标版本，见 `restore`）
    @discardableResult
    func saveSnapshot(fileAt url: URL,
                      content: String,
                      reason: DocumentVersion.Reason,
                      protecting: Set<UUID> = []) throws -> DocumentVersion? {
        let docID = Self.documentID(forFileAt: url)
        var manifest = try loadManifest(docID)
        let hash = Self.contentHash(content)
        guard manifest.latest?.contentHash != hash else { return nil }
        return try append(content: content, hash: hash, reason: reason, note: nil,
                          path: Self.canonicalPath(of: url),
                          to: &manifest, docID: docID, protecting: protecting)
    }

    /// 用户手动点「保存当前版本」：这一版会永久保留，自动清理不碰它。
    ///
    /// ### 为什么内容和最新版一样时不新建、也不报错
    /// 那说明"此刻这份内容"已经在柜子里了，把最新那一版**转正**成手动版就够了（只改 reason 字段，不复制正文）。
    /// 用户要的是"记住现在这份"，已经记住了就没必要再来一份一模一样的。
    @discardableResult
    func saveManualVersion(fileAt url: URL, content: String, note: String? = nil) throws -> DocumentVersion {
        let docID = Self.documentID(forFileAt: url)
        var manifest = try loadManifest(docID)
        let hash = Self.contentHash(content)

        if let index = manifest.latestIndex, manifest.versions[index].contentHash == hash {
            manifest.versions[index].reason = .manual
            if let note { manifest.versions[index].note = note }
            manifest.path = Self.canonicalPath(of: url)
            try saveManifest(manifest, docID)
            return manifest.versions[index]
        }
        return try append(content: content, hash: hash, reason: .manual, note: note,
                          path: Self.canonicalPath(of: url),
                          to: &manifest, docID: docID, protecting: [])
    }

    // MARK: 对外：查看 / 恢复

    /// 把这份文档存过的版本列出来，最新的排最前面（列表页直接用）。
    /// - Throws: 清单坏了读不出来时抛 `DocumentHistoryError.manifestUnreadable`
    func versions(fileAt url: URL) throws -> [DocumentVersion] {
        try loadManifest(Self.documentID(forFileAt: url)).versions.sorted { $0.sequence > $1.sequence }
    }

    /// 把某一版的正文读出来。
    ///
    /// 会先确认清单里真有这一版，再按它的文件名去隔壁文件里取；取不到就报错，绝不返回空串糊弄 —— 那会让人以为"那一版本来就是空的"。
    func content(fileAt url: URL, versionID: UUID) throws -> String {
        let docID = Self.documentID(forFileAt: url)
        let manifest = try loadManifest(docID)
        guard let version = manifest.versions.first(where: { $0.id == versionID }) else {
            throw DocumentHistoryError.versionNotFound
        }
        let file = try versionFileURL(named: version.fileName, docID: docID)
        guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) else {
            throw DocumentHistoryError.contentUnreadable
        }
        return text
    }

    /// 取回某一版：把它的正文交出去，同时给"现在编辑器里的内容"先存一份保险。
    ///
    /// 大白话：拿旧版本之前，先把眼前这份也收进柜子，万一拿回来发现拿错了，还能退回去。
    ///
    /// ### 三步的顺序是故意的
    /// 1. 先把目标版本读出来。读不到就直接抛错，此时磁盘上一个字节都没动过；
    /// 2. 再给"恢复前的这份内容"存一版保险，并把目标版本放进保护名单（免得它正好被清理规则丢掉）；
    /// 3. 保险没存上也要把恢复做完 —— 那是次要失败，通过 `safetyBackupError` 交给界面提示用户。
    func restore(fileAt url: URL,
                 versionID: UUID,
                 currentContent: String) throws -> DocumentHistoryRestoreResult {
        let target = try content(fileAt: url, versionID: versionID)

        var backupError: Error?
        do {
            try saveSnapshot(fileAt: url, content: currentContent,
                             reason: .beforeRestore, protecting: [versionID])
        } catch {
            backupError = error
        }
        return DocumentHistoryRestoreResult(content: target, safetyBackupError: backupError)
    }

    // MARK: 对外：删除 / 搬家

    /// 把这份文档的全部历史删掉（文档本身被删了、或者用户要清空历史时用）。
    ///
    /// 大白话：只扔掉这一份文档的存档，别人的一概不碰。
    ///
    /// ⚠️ 这里只删"这一份文档"那个文件夹，而且删之前要验一遍目标确实在历史根目录里面。
    /// 直接拿外部传进来的字符串拼路径去删的话，`..` 和 `.` 这种值会把父目录一起带走。
    func deleteHistory(fileAt url: URL) throws {
        try removeHistoryDirectory(rootURL.appendingPathComponent(Self.documentID(forFileAt: url), isDirectory: true))
    }

    /// 把某个文件夹（连带子文件夹）里所有文档的历史都删掉。
    ///
    /// 大白话：删掉一个文件夹时，里面那些文档的存档也一起扔掉，不留垃圾。
    ///
    /// 文件夹名是路径算出来的哈希，反推不出路径，所以只能一份一份打开清单，看它记的路径在不在旧目录下。
    /// 文档数量一般就几十份，全扫一遍很便宜。
    func deleteHistory(underDirectory url: URL) throws {
        let head = Self.canonicalPath(of: url) + "/"
        for docID in try documentIDs() {
            guard let manifest = try? loadManifest(docID),
                  manifest.path.hasPrefix(head) else { continue }
            try removeHistoryDirectory(rootURL.appendingPathComponent(docID, isDirectory: true))
        }
    }

    /// 文档改了名之后，把它的历史一起搬到新名字下。
    ///
    /// 大白话：改名相当于换门牌号，存档柜得跟着搬，不然界面上就"查无此档"了。
    ///
    /// 历史文件夹是按"路径的哈希"命名的，所以"搬"其实就是把这个文件夹换个名字。
    func migrateHistory(fromFileAt oldURL: URL, toFileAt newURL: URL) {
        let from = Self.documentID(forFileAt: oldURL)
        let to = Self.documentID(forFileAt: newURL)
        guard from != to else { return }

        let source = rootURL.appendingPathComponent(from, isDirectory: true)
        let target = rootURL.appendingPathComponent(to, isDirectory: true)
        // 旧的不在（这份文档还没留过档）或者新的已经在了（不该发生），都不动手
        guard fileManager.fileExists(atPath: source.path),
              !fileManager.fileExists(atPath: target.path) else { return }

        guard (try? fileManager.moveItem(at: source, to: target)) != nil else { return }
        // 搬完把清单里记的路径也改成新的，否则下次文件夹改名认不出它
        guard var manifest = try? loadManifest(to) else { return }
        manifest.path = Self.canonicalPath(of: newURL)
        try? saveManifest(manifest, to)
    }

    /// 整个文件夹改了名之后，把里面所有文档的历史一起搬过去。
    ///
    /// 大白话：上一层目录改名了，里面每份文档的"门牌号"全变了，得挨个把存档柜搬一遍。
    ///
    /// 没法从哈希反推出旧路径，所以只能扫一遍清单，看谁的路径以旧目录开头，再按新目录拼出新路径。
    func migrateHistory(fromDirectory oldURL: URL, toDirectory newURL: URL) {
        let oldHead = Self.canonicalPath(of: oldURL) + "/"
        let newHead = Self.canonicalPath(of: newURL) + "/"
        guard let docIDs = try? documentIDs() else { return }

        for docID in docIDs {
            guard var manifest = try? loadManifest(docID), manifest.path.hasPrefix(oldHead) else { continue }
            let movedPath = newHead + String(manifest.path.dropFirst(oldHead.count))
            let movedID = Self.documentID(forPath: movedPath)
            guard movedID != docID else {
                manifest.path = movedPath
                try? saveManifest(manifest, docID)
                continue
            }
            let target = rootURL.appendingPathComponent(movedID, isDirectory: true)
            guard !fileManager.fileExists(atPath: target.path) else { continue }
            guard (try? fileManager.moveItem(at: rootURL.appendingPathComponent(docID, isDirectory: true),
                                             to: target)) != nil else { continue }
            manifest.path = movedPath
            try? saveManifest(manifest, movedID)
        }
    }

    // MARK: 对外：算编号（纯函数，最好测）

    /// 这份文档的历史存在哪个文件夹里：它的路径算出来的一串哈希，就是这个文件夹的名字。
    ///
    /// 大白话：用一串"乱码"当文件夹名，谁也拼不出 `..` 这种能跑到上层去的东西。
    ///
    /// ### 为什么用哈希，不直接用文件名或路径
    /// 哈希永远只是一串 0-9a-f，既不会撞上 `/`、`.`、`..` 这些能把路径带跑的字符，也不会因为文件名里有中文、空格、引号出岔子。要是拿文件名当文件夹名，一份叫 `../..` 的文档就能让"删它的历史"变成"删历史目录外面去"。
    static func documentID(forFileAt url: URL) -> String {
        documentID(forPath: canonicalPath(of: url))
    }

    static func documentID(forPath path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 算出内容的"指纹"，用来快速判断"和上一版比，内容到底变没变"。
    ///
    /// 大白话：给每份内容算一个身份证号，两个号一样就说明内容一样，不用逐字比。
    static func contentHash(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 清理规则：这一轮该丢掉哪些版本。
    ///
    /// 大白话：柜子只有固定的几格（默认 10 格），满了就得先扔最旧的；但用户手动存的那些是"永久件"，不占格也不扔。
    ///
    /// 特意抽成**不碰文件系统**的纯函数，是为了能直接单测 —— 这条规则写错，症状是"用户手动存的版本莫名不见了"或者"刚恢复的那版立刻被清理掉"，很难复现。
    static func versionsToDelete(_ versions: [DocumentVersion],
                                 retention: DocumentHistoryRetention,
                                 protected: Set<UUID> = []) -> Set<UUID> {
        let countable = versions
            .filter { !(retention.manualVersionsExempt && $0.reason == .manual) }
            .sorted { $0.sequence > $1.sequence }             // 新 → 旧
        let overflow = countable.dropFirst(retention.maxCount) // 排在前 N 名之后的都是更旧的
        return Set(overflow.map(\.id)).subtracting(protected)
    }

    // MARK: 内部：新增一个版本

    /// 真的往柜子里塞一版：写正文 → 算该扔哪些 → 改清单 → 删旧文件。
    ///
    /// 大白话：先把副本放进格子，再更新目录页；等目录页写好了，才去扔旧的。
    ///
    /// ### 顺序是故意这么排的
    /// 新增时"先写正文，再改清单"：万一写清单时崩了，最多留一个没人引用的孤儿文件，清单永远不会指向一个不存在的文件。清理时"先改清单，再删文件"是同一个道理。
    private func append(content: String,
                        hash: String,
                        reason: DocumentVersion.Reason,
                        note: String?,
                        path: String,
                        to manifest: inout DocumentHistoryManifest,
                        docID: String,
                        protecting: Set<UUID>) throws -> DocumentVersion {
        let data = Data(content.utf8)
        let version = DocumentVersion(id: UUID(),
                                      sequence: manifest.nextSequence,
                                      createdAt: Date(),
                                      contentHash: hash,
                                      byteCount: data.count,
                                      reason: reason,
                                      note: note)

        let file = try documentDirectory(docID).appendingPathComponent(version.fileName)
        // `.atomic` 的意思是"先写临时文件，再整体换过去"：写到一半崩了也不会留下半截坏文件
        try data.write(to: file, options: .atomic)

        manifest.nextSequence += 1
        manifest.versions.append(version)
        // 记下这份文档现在的路径：以后文件夹改名时，要靠它认出"这份历史属于谁"
        manifest.path = path
        let doomed = Self.versionsToDelete(manifest.versions, retention: retention, protected: protecting)
        manifest.versions.removeAll { doomed.contains($0.id) }

        do {
            try saveManifest(manifest, docID)
        } catch {
            // 清单没写成，刚写的正文就成了没人认领的孤儿文件，顺手清掉
            try? fileManager.removeItem(at: file)
            throw error
        }

        // 清单已经更新过了，这一步失败只会留下孤儿文件，不影响正确性，所以不往上抛
        for id in doomed {
            try? removeVersionFile(named: "\(id.uuidString).md", docID: docID)
        }
        return version
    }

    // MARK: 内部：路径

    /// 这份文档的"存档格子"在哪，需要的话顺手把它建出来。
    ///
    /// - Parameter createIfMissing: 要不要顺手建。留档时要建；只是读一下、删一下就不必，
    ///   免得"打开历史列表看一眼"就给一份从没留过档的文档凭空造出一个空文件夹。
    private func documentDirectory(_ docID: String, createIfMissing: Bool = true) throws -> URL {
        guard Self.isValidDocumentID(docID) else { throw DocumentHistoryError.invalidDocumentID(docID) }
        let directory = rootURL.appendingPathComponent(docID, isDirectory: true)
        if createIfMissing, !fileManager.fileExists(atPath: directory.path) {
            try ensureRootDirectory()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            // 新建出来的目录要单独打一次"不要备份"：根目录那次标记管不到后来新建的子目录
            markExcludedFromBackup(directory)
        }
        return directory
    }

    /// 确认历史根目录在，并且只在**第一次建它**的时候打上「不要备份」的标记。
    private func ensureRootDirectory() throws {
        guard !fileManager.fileExists(atPath: rootURL.path) else { return }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        markExcludedFromBackup(rootURL)
    }

    /// 某一版的正文文件在哪。
    ///
    /// 大白话：文件名得对得上号才认，别让一个被改坏的清单把删除目标指到别处去。
    ///
    /// ⚠️ 名字是从清单里读出来的（清单躺在磁盘上，理论上可能被人改坏），所以这里再验一次格式：
    /// 只认 `UUID.md`，别的形状一律拒掉，免得一个坏清单把删除目标顶到这份文档的文件夹外面。
    private func versionFileURL(named fileName: String, docID: String) throws -> URL {
        let pattern = #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.md$"#
        guard fileName.range(of: pattern, options: .regularExpression) != nil else {
            throw DocumentHistoryError.versionNotFound
        }
        return try documentDirectory(docID, createIfMissing: false).appendingPathComponent(fileName)
    }

    /// 删掉某一版的正文文件（走同一道文件名检查，不合法就删不了）。
    private func removeVersionFile(named fileName: String, docID: String) throws {
        try fileManager.removeItem(at: versionFileURL(named: fileName, docID: docID))
    }

    /// 给目录打上「不要备份 / 不要同步」的标记。
    ///
    /// 大白话：相当于在文件夹上贴张条子——"这是我本机自己用的，别传上云"。
    ///
    /// 历史版本只在本机有用，跟着 iCloud 备份走只会白占空间。标记打在目录上，它下面所有文件一起生效，不用一个个去标。
    private func markExcludedFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        // `setResourceValues` 是个 mutating 方法，参数进来是 `let` 改不了，得先倒一手到 var
        var target = url
        try? target.setResourceValues(values)
    }

    /// 历史根目录里现在有哪些文档（只回文件夹名，而且只认合法的哈希名）。
    private func documentIDs() throws -> [String] {
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
        return try fileManager.contentsOfDirectory(atPath: rootURL.path).filter { Self.isValidDocumentID($0) }
    }

    /// 🚨 删目录的唯一出口，所有"删历史"的代码都必须从这里过。
    ///
    /// 大白话：动手删之前先看一眼——要删的必须真的在存档柜**里面**，而且不能是柜子本身。
    /// 这两条少一条，就可能把整个 Application Support（App 所有数据）一起删掉。
    ///
    /// 两条判据缺一不可：① 目标必须在历史根目录**里面**；② 它不能**就是**根目录本身。
    /// 举个例子：传进来的要是 `MarkdownHistory/..`，实际删掉的就是整个 Application Support。
    ///
    /// ⚠️ 不写 `private` 是为了让单测能直接拿 `..`、根目录这类值来试它（见 `DocumentHistoryStoreTests`）。
    func removeHistoryDirectory(_ url: URL) throws {
        let rootPath = rootURL.standardizedFileURL.path
        let targetPath = url.standardizedFileURL.path
        guard targetPath != rootPath, targetPath.hasPrefix(rootPath + "/") else {
            throw DocumentHistoryError.outsideRoot(targetPath)
        }
        guard fileManager.fileExists(atPath: targetPath) else { return }
        try fileManager.removeItem(at: url)
    }

    /// 我们只认自己算出来的那种编号：正好 64 个小写十六进制字符，多一个少一个都不认。
    static func isValidDocumentID(_ docID: String) -> Bool {
        docID.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
    }

    /// 把路径写成统一的样子：解开文件引用 URL、顺着符号链接找到真身，同一份文件永远算出同一个编号。
    static func canonicalPath(of url: URL) -> String {
        ExternalDocumentAccess.shared.canonicalPath(for: url)
    }

    // MARK: 内部：清单读写

    /// 清单文件的地址。
    ///
    /// ⚠️ 读的时候绝不建目录（走 `documentDirectory` 的 `createIfMissing: false`）：
    /// 不然"打开历史列表看一眼"就会给每份没留过档的文档凭空造一个空文件夹。
    private func manifestURL(_ docID: String, createIfMissing: Bool) throws -> URL {
        try documentDirectory(docID, createIfMissing: createIfMissing)
            .appendingPathComponent("manifest.json")
    }

    private func loadManifest(_ docID: String) throws -> DocumentHistoryManifest {
        let url = try manifestURL(docID, createIfMissing: false)
        guard fileManager.fileExists(atPath: url.path) else { return DocumentHistoryManifest() }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(DocumentHistoryManifest.self, from: Data(contentsOf: url))
        } catch {
            throw DocumentHistoryError.manifestUnreadable(underlying: error)
        }
    }

    /// 把清单写回磁盘。
    ///
    /// 读的时候文件不在了就当"还没有任何历史"（返回一份空清单）；写的时候目录必须存在，所以这里会建目录——第一次留档就是靠这一步把文件夹造出来的。
    private func saveManifest(_ manifest: DocumentHistoryManifest, _ docID: String) throws {
        let encoder = JSONEncoder()
        // 精确到秒就够了：这个时间只用来在列表上显示
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL(docID, createIfMissing: true), options: .atomic)
    }
}
