//
//  DocumentsWorkspace.swift
//  MarkdownEditorHy4
//
//  App 沙盒里那个「Documents」目录：列文件、首启放示例、新建文件、读写内容。
//

import Foundation

/// 「文档工作区」—— 就是 App 沙盒的 Documents 目录。
///
/// ### 为什么整个 App 只认这一个目录
/// 新架构下右侧每个 Tab 编辑的都是**磁盘上的一份真文件**：
/// - 左侧栏列的，就是这个目录里的文档；
/// - 新建 = 在这个目录里建一份新文件；
/// - ⌘S 永远写回原文件（不再有「新建的草稿没有文件、得先另存为」那种中间态）。
///
/// 这样「左侧看到的东西」和「右侧正在编辑的东西」永远对得上。
/// 顺带的好处：用户在「文件」App（iOS）/ Finder（Mac Catalyst）里也能直接看到这些文件、
/// 往里丢新的 `.md`，回来重新扫一遍目录就能看到。
enum DocumentsWorkspace {

    /// App 包里那份示例文档的资源名（不带扩展名）
    private static let sampleResourceName = "sample"

    /// 认得出的文档扩展名。
    ///
    /// 跟 `Info.plist` 里声明的那些保持一致，另外带上 `txt` ——
    /// 打开面板（⌘O）本来就允许挑纯文本，既然能编辑，左侧栏也就该列出来。
    private static let documentExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "mdwn", "mdtext", "mdtxt", "txt"
    ]

    /// Documents 目录。
    ///
    /// 沙盒里这个目录一定存在，取不到才退到临时目录（那种情况下整个工作区是空的，
    /// 但不至于崩）。
    static var folderURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    // MARK: - 列文件

    /// 目录里的文档，按文件名排序。
    ///
    /// 排序用 `localizedStandardCompare` 而不是 `<`：后者按 Unicode 码位比，
    /// 中文名会排得莫名其妙，而且「第 10 章」会被排到「第 2 章」前面。
    static func documentURLs() -> [URL] {
        let manager = FileManager.default
        let entries = (try? manager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return entries
            .filter { isDocument($0) && isRegularFile($0, manager: manager) }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
    }

    /// 这个是能编辑的文档吗（按扩展名认）
    static func isDocument(_ url: URL) -> Bool {
        documentExtensions.contains(url.pathExtension.lowercased())
    }

    /// 文件名（**去掉扩展名**）。左侧栏和 Tab 上都显示它 ——
    /// 满屏 `.md` 后缀看着很吵，而这里所有文件都是 `.md`
    static func displayName(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    private static func isRegularFile(_ url: URL, manager: FileManager) -> Bool {
        // 目录也可能叫 `xxx.md`，得排掉；取不到属性时按「不是普通文件」处理，宁缺勿滥
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
    }

    // MARK: - 首次启动：把 App 包里的示例文档放进来

    /// Documents 里一份文档都没有时，把 App 包里的 `sample.md` 复制过去。
    ///
    /// ### 「空」判定的取舍
    /// 判据取的是「一份**文档**都没有」，而不是「目录里一个文件都没有」。
    /// 因为 Documents 里可能已经躺着别的东西 —— 编辑器粘贴图片时会存 png 进来 ——
    /// 那种情况下列表仍然是空的，还是该给一份示例。
    ///
    /// - Returns: 复制出来的文件地址；什么都没做（本来就有文档 / 包里的示例丢了）时返回 nil
    @discardableResult
    static func installSampleIfNeeded() -> URL? {
        guard documentURLs().isEmpty else { return nil }
        guard let sourceURL = Bundle.main.url(forResource: sampleResourceName, withExtension: "md") else {
            return nil
        }

        let destination = folderURL.appendingPathComponent("sample.md")
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            return destination
        } catch {
            // 复制不进去也不该影响启动：列表空着就空着，顶多少一份示例
            return nil
        }
    }

    // MARK: - 新建 / 起名 / 读写

    /// 新建文档时用的**占位名**。
    ///
    /// 新建的文档先顶着这个名字落到磁盘上（`未命名.md`、`未命名 2.md`……），
    /// 等用户第一次按 ⌘S 时再请他起个正式名字（判据见 `isUntitled`）。
    static let untitledBaseName = "未命名"

    /// 造一个还没被占用的文件名：`未命名.md`、`未命名 2.md`、`未命名 3.md`……
    static func uniqueFileURL(baseName: String? = nil) -> URL {
        let base = baseName ?? untitledBaseName
        let manager = FileManager.default
        var candidate = folderURL.appendingPathComponent("\(base).md")
        var sequence = 2
        while manager.fileExists(atPath: candidate.path) {
            candidate = folderURL.appendingPathComponent("\(base) \(sequence).md")
            sequence += 1
        }
        return candidate
    }

    /// 这份文档是不是**还顶着占位名** —— 也就是「新建出来、用户还没给它起过名字」。
    ///
    /// ### 为什么只看文件名，不额外记一个状态
    /// 记状态就得多存一份数据、还得跟着文件的生命周期同步（改名、删除、
    /// 从「文件」App 里手动改过名……），任何一处漏了就会错。
    /// 文件名本身就是最可靠的那份状态：App 重启过、文件被重新打开，
    /// 这个判断的结果依然是对的。
    ///
    /// 认这三种：`未命名`、`未命名 2`、`未命名 12`（`uniqueFileURL` 造出来的那些）；
    /// 不认 `未命名abc`、`未命名 2 副本` 这类用户自己起的名字。
    static func isUntitled(_ url: URL) -> Bool {
        let name = displayName(for: url)
        if name == untitledBaseName { return true }
        let prefix = untitledBaseName + " "
        guard name.hasPrefix(prefix),
              let sequence = Int(name.dropFirst(prefix.count)) else { return false }
        return sequence > 0
    }

    /// 把用户敲进来的一串字，收拾成能当文件名用的样子。
    ///
    /// 用户是随手输的，这里得宽容一点，别动不动就甩一句「含非法字符」：
    /// - **前后空白去掉**：手滑多敲的空格不该进文件名；
    /// - **结尾的 `.md` 去掉一层**：用户常顺手把后缀也打上，不去掉会变成 `笔记.md.md`；
    /// - **`/` 和 `:` 换成 `-`**：这两个在 Mac 的文件名里不合法
    ///   （Finder 里输 `/` 会被它悄悄换成 `:`），与其让文件建不出来，不如替用户换掉；
    /// - **开头的 `.` 去掉**：`.` 开头的文件在 Mac 上是隐藏文件，用户建完就找不到它了。
    static func sanitizedFileName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if name.lowercased().hasSuffix(".md") {
            name = String(name.dropLast(3))
        }
        name = name.replacingOccurrences(of: "/", with: "-")
        name = name.replacingOccurrences(of: ":", with: "-")
        // 去掉后缀后可能又露出尾随空格（比如用户输的是「笔记 .md」），再收一次
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") {
            name.removeFirst()
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 把一份文档改成另一个名字（同目录内移动，内容跟着走）。
    ///
    /// ### 为什么用 `moveItem` 而不是「新建 + 复制内容 + 删旧的」
    /// 移动是文件系统层面的一个动作，要么成功要么没动过；
    /// 复制那条路中途失败会留下半份文件，用户看到两个都像真的。
    ///
    /// - Returns: 改名后的新地址。名字没变时原样返回（不白跑一趟移动）。
    /// - Throws: 名字是空的时候抛 `.emptyName`；目标同名文件已存在时抛 `.nameTaken`。
    @discardableResult
    static func rename(_ url: URL, toBaseName rawName: String) throws -> URL {
        let name = sanitizedFileName(rawName)
        guard !name.isEmpty else { throw WorkspaceError.emptyName }

        // 一律以 .md 结尾：这个 App 管的都是 markdown 文档
        let destination = url.deletingLastPathComponent().appendingPathComponent("\(name).md")
        // 名字没变（用户直接点了「保存」，接受了占位名）→ 什么都不用做
        guard destination.path != url.path else { return url }

        // ⚠️ 重名要**报错**，不能悄悄覆盖：用户以为在「另存」却把别人那份抹了，
        // 是这个功能最容易出的严重事故
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw WorkspaceError.nameTaken(name)
        }

        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    /// 新建一份空白文档。
    ///
    /// 先在磁盘上把文件建出来（而不是先摆一份内存里的草稿）：
    /// 这样左侧栏立刻就能看到它，⌘S 也就永远有地方可写。
    ///
    /// 建出来的是**占位名**（`未命名.md`）—— 用户第一次按 ⌘S 时，
    /// 编辑页会请他起个正式名字，那时调 `rename(_:toBaseName:)`。
    @discardableResult
    static func createEmptyDocument() throws -> URL {
        let url = uniqueFileURL()
        try "".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 读文件内容。读不出来（权限、编码、文件被删）返回 nil，由调用方决定怎么提示
    static func read(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        // 按 UTF-8 解码：遇到不合法的字节会换成替换字符，总比整篇打不开强
        return String(decoding: data, as: UTF8.self)
    }

    /// 写回文件
    static func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - 删除

    /// 删掉一份文档。
    ///
    /// ### 先试「丢进废纸篓」，不行再真删
    /// Mac 上有废纸篓：`FileManager.trashItem` 会把文件挪到 `~/.Trash`，
    /// 用户删错了还能捞回来（Finder → 废纸篓 → 右键「放回原处」）。
    /// iPhone / iPad 上没有这个概念（这个调用会直接报错），那就退回到「真删」。
    /// 两条路走到最后，「这个文件已经不在原来的位置」这个结果是一样的。
    ///
    /// - Parameter putInTrashFirst: 要不要先试着丢废纸篓。
    ///   ⚠️ **测试里必须传 `false`** —— 不然每跑一次测试就往用户的废纸篓里丢一个临时文件，
    ///   跑几十次废纸篓就堆满了。
    static func delete(_ url: URL, putInTrashFirst: Bool = deletionGoesToTrash) throws {
        // `try?` 返回 nil 就代表「废纸篓这条路走不通」，接着往下真删
        if putInTrashFirst, (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil {
            return
        }
        try FileManager.default.removeItem(at: url)
    }

    /// 这个平台上「删除」到底是进废纸篓还是直接抹掉。
    ///
    /// 界面拿它决定确认框里的说法 —— 别跟用户说「还能捞回来」，结果捞不回来。
    static var deletionGoesToTrash: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }

    // MARK: - 通知

    /// 目录里的文件增删改了 → 左侧栏据此重新扫一遍
    static let didChangeNotification = Notification.Name("MarkdownDocumentsDidChange")

    /// 有人请求「新建一份文档」（object 无）→ 由左侧栏建文件、开新 Tab
    static let newDocumentRequestedNotification = Notification.Name("MarkdownNewDocumentRequested")
}

/// 文档工作区里能出的那几种错。
///
/// 定义成 `LocalizedError` 而不是随手抛一个 `NSError`：界面是把
/// `error.localizedDescription` 直接显示给用户看的，
/// 这里写好的话术就是用户最终读到的那句话，不该是一串英文系统错误。
enum WorkspaceError: LocalizedError, Equatable {
    /// 名字是空的（用户把输入框清空了）
    case emptyName
    /// 文档目录里已经有同名的文档了
    case nameTaken(String)

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "名字不能是空的，给这份文档起个名字吧。"
        case .nameTaken(let name):
            return "文档目录里已经有一份叫「\(name)」的文档了，换个名字吧。"
        }
    }
}
