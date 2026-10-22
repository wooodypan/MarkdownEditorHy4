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

    // MARK: - 列表里的一行：文档还是文件夹

    /// 左栏列表的一行。
    ///
    /// ### 为什么不直接用 `URL`
    /// 「这是文件夹还是文档」要现查磁盘，而排序、搜索、填 cell 时每条路径都要问好几次；名字也不一样 —— 文件要去掉 `.md`，文件夹必须原样（`v1.0` 砍掉尾巴就成了 `v1`）。
    /// 这些都算好放进结构体，上层拿去直接用，不用每条路径都重算一遍。
    struct Entry: Equatable {
        let url: URL
        /// 文件夹（能进去）还是文档（能打开）
        let isDirectory: Bool
        /// 界面上显示的名字
        let name: String
        /// 修改时间。**扫描目录时顺手读到的**，不用上层再 stat 一次
        let modifiedDate: Date?
        /// 创建时间，同上
        let createdDate: Date?

        init(url: URL,
             isDirectory: Bool,
             name: String,
             modifiedDate: Date? = nil,
             createdDate: Date? = nil) {
            self.url = url
            self.isDirectory = isDirectory
            self.name = name
            self.modifiedDate = modifiedDate
            self.createdDate = createdDate
        }
    }

    /// 列一个目录里的一层东西：文件夹 + 认得出的文档。
    ///
    /// 排序交给调用方（左栏有「目录优先」和用户选的排序方式），这里只按名字排一份稳定顺序。
    ///
    /// ⚠️ **判断顺序是「先看是不是目录」**，不是「先看扩展名」：`xxx.md` 这种名字的文件夹在磁盘上确实能存在，按扩展名先判会把它当成一份打不开的文档。
    static func entries(in directory: URL) -> [Entry] {
        let manager = FileManager.default
        // ⚠️ 时间也一并要过来：`contentsOfDirectory` 会在**同一次枚举**里把属性读好，之后 `resourceValues` 直接命中缓存。少了这两个键，每份文档都要单独 stat 一次
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey,
                                      .contentModificationDateKey, .creationDateKey]
        let urls = (try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls.compactMap { url -> Entry? in
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                return Entry(url: url,
                             isDirectory: true,
                             name: url.lastPathComponent,
                             modifiedDate: values?.contentModificationDate,
                             createdDate: values?.creationDate)
            }
            guard isDocument(url), values?.isRegularFile == true else { return nil }
            return Entry(url: url,
                         isDirectory: false,
                         name: displayName(for: url),
                         modifiedDate: values?.contentModificationDate,
                         createdDate: values?.creationDate)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 这个 URL 现在是不是一个目录。
    ///
    /// 右键菜单、重命名、删除都要按它分流：同一个动作对「文件」和「文件夹」做的事不一样。
    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    /// 按 URL 现造一个列表行（不知道是文件还是文件夹时用）。
    static func entry(for url: URL) -> Entry {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey,
                                                      .contentModificationDateKey,
                                                      .creationDateKey])
        return values?.isDirectory == true
            ? Entry(url: url,
                    isDirectory: true,
                    name: url.lastPathComponent,
                    modifiedDate: values?.contentModificationDate,
                    createdDate: values?.creationDate)
            : Entry(url: url,
                    isDirectory: false,
                    name: displayName(for: url),
                    modifiedDate: values?.contentModificationDate,
                    createdDate: values?.creationDate)
    }

    /// 文件夹里有几份文档、几个子文件夹。只看这一层：数字用来填列表副标题，递归数会慢得没必要。
    static func summary(ofDirectory url: URL) -> (documents: Int, folders: Int) {
        let items = entries(in: url)
        return (items.filter { !$0.isDirectory }.count, items.filter { $0.isDirectory }.count)
    }

    /// 这个目录里（含所有子文件夹）到底有没有文档。
    ///
    /// ### 为什么不能只看顶层
    /// 用户把文档都整理进子文件夹之后，顶层一份都没有。按顶层判空的话，下次启动会以为「这是个空目录」，又塞一份示例文档进来。
    static func containsAnyDocument(in directory: URL) -> Bool {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return false }

        for case let url as URL in enumerator where isDocument(url) {
            if isRegularFile(url, manager: manager) { return true }
        }
        return false
    }

    /// 递归搜索：从 `directory` 往下找名字匹配的文档。
    ///
    /// - Parameters:
    ///   - query: 关键词，忽略大小写和重音
    ///   - maxDepth: 最多往下钻几层。误建出来的深目录不该把主线程拖住
    ///   - limit: 最多返回多少条
    /// - Returns: 命中的行（文件夹和文档都算），`name` 是**相对 `directory` 的路径**
    ///   （`日记/2026-10`）—— 子文件夹里有同名文件时，光看文件名分不出是哪一个
    static func searchDocuments(in directory: URL,
                                matching query: String,
                                maxDepth: Int = 8,
                                limit: Int = 2000) -> [Entry] {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey,
                                      .contentModificationDateKey, .creationDateKey]
        guard let enumerator = manager.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        func matches(_ text: String) -> Bool {
            text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }

        var results: [Entry] = []
        for case let url as URL in enumerator {
            // 太深的层级整枝跳过，省得一条条比下去
            if enumerator.level > maxDepth {
                enumerator.skipDescendants()
                continue
            }

            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                // 文件夹也参与匹配：用户搜「日记」很可能就是在找那个文件夹。
                // 它的名字用相对路径，且**不去扩展名**（`v2.0` 是名字的一部分）
                let relative = relativePath(of: url, in: directory)
                if matches(relative) {
                    results.append(Entry(url: url,
                                         isDirectory: true,
                                         name: relative,
                                         modifiedDate: values?.contentModificationDate,
                                         createdDate: values?.creationDate))
                }
                continue
            }

            guard isDocument(url), values?.isRegularFile == true else { continue }
            let relative = relativeDisplayName(of: url, in: directory)
            guard matches(relative) else { continue }
            results.append(Entry(url: url,
                                 isDirectory: false,
                                 name: relative,
                                 modifiedDate: values?.contentModificationDate,
                                 createdDate: values?.creationDate))
            if results.count >= limit { break }
        }
        return results
    }

    /// `directory` 底下这份东西的相对路径（原样，不动扩展名）。
    static func relativePath(of url: URL, in directory: URL) -> String {
        let base = directory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base + "/")
            ? String(path.dropFirst(base.count + 1))
            : url.lastPathComponent
    }

    /// `directory` 底下这份文档的相对路径（去掉扩展名）。
    static func relativeDisplayName(of url: URL, in directory: URL) -> String {
        (relativePath(of: url, in: directory) as NSString).deletingPathExtension
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
    /// 而且这个「没有」是**递归**判的：用户把文档都整理进子文件夹之后，顶层是空的，但那是他自己整理出来的，不该再给他塞一份示例。
    ///
    /// - Returns: 复制出来的文件地址；什么都没做（本来就有文档 / 包里的示例丢了）时返回 nil
    @discardableResult
    static func installSampleIfNeeded() -> URL? {
        guard !containsAnyDocument(in: folderURL) else { return nil }
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
    ///
    /// - Parameter directory: 建到哪个目录里。默认文档根目录；用户进了子文件夹就传那个文件夹，新建的文档才会落在眼前这一层，而不是又跑回根目录去。
    static func uniqueFileURL(in directory: URL = folderURL, baseName: String? = nil) -> URL {
        let base = baseName ?? untitledBaseName
        let manager = FileManager.default
        var candidate = directory.appendingPathComponent("\(base).md")
        var sequence = 2
        while manager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(sequence).md")
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

        // ⚠️ 改名这件事必须报出去：右侧要是正开着这份文档，它手里记的还是**旧路径**，那一按 ⌘S 就会把旧名字的文件又写回来 —— 磁盘上凭空多出一份重复的。
        // 报出去之后由编辑页把路径换成新的（见 `MarkdownDocumentViewController.documentDidRename`）。
        NotificationCenter.default.post(name: didRenameNotification,
                                        object: nil,
                                        userInfo: [renameFromURLKey: url, renameToURLKey: destination])
        return destination
    }

    /// 把**文件夹**改成另一个名字（整棵子树跟着走）。
    ///
    /// ### 和 `rename(_:toBaseName:)` 的两点不同
    /// - 不补 `.md` 后缀（文件夹不是文档）；
    /// - 名字以 `.md` 结尾也不砍（`草稿.md` 是个合法的文件夹名）。
    ///
    /// ⚠️ 改名一换，**里面所有文档的路径都变了**。正在编辑的子文档、按路径存的「最近打开」和「读到哪儿」都会对不上，所以这里必须把新旧目录一起报出去 —— 而且报的是**目录**，接收方要按前缀替换，不是像文件改名那样用等号比。
    ///
    /// - Returns: 改名后的新地址。名字没变时原样返回（不白跑一趟移动）。
    /// - Throws: 名字是空的时候抛 `.emptyName`；同名文件夹已存在时抛 `.nameTaken`。
    @discardableResult
    static func renameDirectory(_ url: URL, toBaseName rawName: String) throws -> URL {
        let name = sanitizedFolderName(rawName)
        guard !name.isEmpty else { throw WorkspaceError.emptyName }

        let destination = url.deletingLastPathComponent()
            .appendingPathComponent(name, isDirectory: true)
        guard destination.path != url.path else { return url }

        // 和文件改名同一条规矩：重名必须报错，绝不能悄悄把另一个文件夹盖掉
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw WorkspaceError.nameTaken(name)
        }

        try FileManager.default.moveItem(at: url, to: destination)

        NotificationCenter.default.post(name: didRenameDirectoryNotification,
                                        object: nil,
                                        userInfo: [renameFromURLKey: url, renameToURLKey: destination])
        return destination
    }

    /// 把用户输的名字收拾成能当**文件夹**名用的样子。
    ///
    /// 规则比文件名的 `sanitizedFileName` 少一条：不碰 `.md` 后缀 —— 文件夹叫 `v2.0` 或者 `草稿.md` 都合法，砍掉尾巴反而把它改成了别的名字。
    static func sanitizedFolderName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.replacingOccurrences(of: "/", with: "-")
        name = name.replacingOccurrences(of: ":", with: "-")
        // 点开头的是隐藏文件夹，用户在列表里看不见它，建了也找不回来
        while name.hasPrefix(".") {
            name.removeFirst()
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 新建一份空白文档。
    ///
    /// 先在磁盘上把文件建出来（而不是先摆一份内存里的草稿）：
    /// 这样左侧栏立刻就能看到它，⌘S 也就永远有地方可写。
    ///
    /// 建出来的是**占位名**（`未命名.md`）—— 用户第一次按 ⌘S 时，
    /// 编辑页会请他起个正式名字，那时调 `rename(_:toBaseName:)`。
    ///
    /// - Parameter directory: 建到哪个目录里。默认文档根目录；用户正停在某个子文件夹里时传它。
    @discardableResult
    static func createEmptyDocument(in directory: URL = folderURL) throws -> URL {
        let url = uniqueFileURL(in: directory)
        try "".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 把一份容器外的文件复制进文档目录。
    ///
    /// 这是 iOS 上「复制并打开」那条路用的。复制完，副本就是一份普通的容器内文档，
    /// 预览、改名、删除、重启后打开都跟 App 自己建的文档一样，不需要再管授权。
    ///
    /// ⚠️ 调用前必须先拿到源文件的访问权（见 `ExternalDocumentAccess.readableURL(for:)`）。
    ///
    /// - Returns: 复制出来的新文件地址。重名时自动变成「文档 2.md」这种。
    static func importDocument(from sourceURL: URL) throws -> URL {
        let destination = uniqueFileURL(baseName: displayName(for: sourceURL))
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
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

    // MARK: - 列表行上那两行附加信息

    /// 为了拿「首行」最多读这么多字节。
    ///
    /// 只想要第一行文字，没必要把整份文档读进来 —— 一份几百 KB 的笔记，首行一定在前 4 KB 之内。
    /// 这里是**一遍真读盘**（开文件 + 读 + 解码），所以调用方不能在 `cellForRowAt` 里同步调它，缓存和后台读取都归左栏的 `DocumentListRowCache` 管。
    private static let previewByteLimit = 4 * 1024

    /// 列表行上那行浅灰预览：文档的**首行文字**。
    ///
    /// ### 为什么取的是「第一个非空行」而不是字面意义上的第 1 行
    /// 不少文档第一行是空行（标题前面习惯空一行），照字面取会得到一片空白，
    /// 那一行就白占了。所以跳过空行，取第一个真有内容的行。
    ///
    /// 读不出来（权限、文件刚被删掉）返回空串，界面那边会用「空文档」这类占位文字顶上。
    static func previewText(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        // defer：不管从哪条分支出去，句柄都得还回去，不然文件一直被占着
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: previewByteLimit), !data.isEmpty else { return "" }

        // 跟 read(_:) 用同一种解码方式：遇到不合法的字节换成替换字符，总比整篇读不出来强
        var text = String(decoding: data, as: UTF8.self)
        // 正好在第 4096 个字节把一个字切成两半时，尾巴上会留一个替换字符 —— 去掉它
        while text.hasSuffix("\u{FFFD}") { text.removeLast() }

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    /// 文件的修改时间。
    ///
    /// 取不到（文件刚被删、没权限）返回 nil —— 界面拿它决定最下面那行日期显不显示。
    static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// 文件的创建时间（「按创建时间」排序用）。
    ///
    /// 有些文件系统 / 同步盘取不到这个值，返回 nil —— 排序那边会把它当「最旧」处理。
    static func creationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
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

    /// 有人把一份文档**改了名**（在 `rename` 里发）。
    ///
    /// 为什么要专门发一条：改名换的是文件路径，而正开着这份文档的编辑页把路径记在自己身上（那是它 ⌘S 要写回的地方）。不通知的话它会继续往旧路径写，等于把文件「改回去 + 留一份重复」。
    static let didRenameNotification = Notification.Name("MarkdownDocumentDidRename")

    /// 有人把**文件夹**改了名（在 `renameDirectory` 里发）。
    ///
    /// 和 `didRenameNotification` 分开是有原因的：那条带的是一对一的新旧**文件**路径，编辑页用等号就能判断「改的是不是我」；文件夹改名换的是整棵子树的前缀，编辑页得按「我的路径是不是以旧目录开头」来换，判断方式不一样。
    static let didRenameDirectoryNotification = Notification.Name("MarkdownDocumentDirectoryDidRename")

    /// `didRenameNotification` 里旧路径用的键（`userInfo` 里是个 `URL`）
    static let renameFromURLKey = "fromURL"

    /// `didRenameNotification` 里新路径用的键（同上）
    static let renameToURLKey = "toURL"
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
