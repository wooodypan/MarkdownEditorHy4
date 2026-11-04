//
//  MarkdownCallbackCenter.swift
//  MarkdownEditorHy4
//
//  x-callback-url 的执行层：认领 `xmark://` 请求、按动作干活、把结果回给调用方。
//
//  ### 为什么要有队列
//  冷启动时系统可能在界面还没搭好就把 URL 递进来（用户从别的 App 点了一个链接）。
//  那时候既没有路由（开不了 Tab），也没有窗口（弹不了确认框），直接执行会静默失败。
//  所以先攒在 `pending` 里，等 `SceneDelegate` 建完工作区、把路由和根控制器交过来再放行。
//
//  ### 为什么串行
//  同一个 `add-text` 撞上冲突提示时得等用户点按钮，后面再来一条请求不能挤进来抢着写同一个文件。
//  一次只跑一条，跑完再取下一条。
//

import UIKit
import MultiTabController

final class MarkdownCallbackCenter {

    static let shared = MarkdownCallbackCenter()

    /// 弹确认框、开 Tab 时用的根控制器（由 `SceneDelegate` 交过来）
    private weak var presenter: UIViewController?

    /// 把内容送到右侧的那条路由（左栏和它共用一条）
    private var router: PPContentRouting?

    /// 还没执行的请求，按到达顺序排队
    private var pending: [MarkdownCallbackURL.Parsed] = []

    /// 当前有没有请求正在跑
    private var isRunning = false

    /// 回调里 `modified` 用的时间格式
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// `read` 最多回这么多字符。再长就截断并标 `truncated=yes`
    private static let readCharacterLimit = 100_000

    private init() {}

    // MARK: - 入口

    /// 把「谁来执行」交给回调中心。`SceneDelegate` 建完工作区后调一次。
    ///
    /// 交过来之前到达的请求会排队，这里顺手放行。
    func attach(router: PPContentRouting?, presenter: UIViewController) {
        self.router = router
        self.presenter = presenter
        pump()
    }

    /// 收到一个 URL。认领了返回 true（调用方就不用再当文件 URL 处理）。
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard MarkdownCallbackURL.isCallbackURL(url) else { return false }
        // 连动作名都拆不出来时无处回话，安静放弃
        guard let parsed = MarkdownCallbackURL.parse(url) else { return true }

        pending.append(parsed)
        pump()
        return true
    }

    /// 现在能不能执行：有路由、而且窗口真的挂上了（弹框才不会丢）
    private var isReady: Bool {
        router != nil && presenter?.view.window != nil
    }

    /// 取下一条来跑。跑完在 `execute` 的 completion 里再调一次。
    private func pump() {
        guard !isRunning, isReady, !pending.isEmpty else { return }
        let request = pending.removeFirst()
        isRunning = true
        execute(request) { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.pump()
        }
    }

    private func execute(_ request: MarkdownCallbackURL.Parsed,
                         completion: @escaping () -> Void) {
        switch request.action.lowercased() {
        case "open-note":
            performOpenNote(request)
            completion()
        case "create":
            performCreate(request)
            completion()
        case "add-text":
            performAddText(request, completion: completion)
        case "read":
            performRead(request)
            completion()
        default:
            respondError(request, .invalidParam("不认识的动作「\(request.action)」"))
            completion()
        }
    }

    // MARK: - open-note

    private func performOpenNote(_ request: MarkdownCallbackURL.Parsed) {
        do {
            let id = try request.requires("id")
            let url = try MarkdownCallbackPaths.documentURL(forID: id)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw MarkdownCallbackError.notFound(id)
            }
            guard ExternalDocumentAccess.shared.readableURL(for: url) != nil else {
                throw MarkdownCallbackError.permissionDenied("「\(id)」在 App 目录外面，现在没有访问权限")
            }
            let mode = try openMode(request)
            guard let opened = DocumentOpening.open(url, mode: mode, using: router) else {
                throw MarkdownCallbackError.notFound(id)
            }
            respondSuccess(request, params: metadata(for: opened))
            if request.flag("edit") {
                focusEditor(for: opened)
            }
        } catch let error as MarkdownCallbackError {
            respondError(request, error)
        } catch {
            respondError(request, .invalidParam(error.localizedDescription))
        }
    }

    // MARK: - create

    private func performCreate(_ request: MarkdownCallbackURL.Parsed) {
        do {
            let folder = try MarkdownCallbackPaths.folderURL(forRelative: request.parameters["folder"])
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                throw MarkdownCallbackError.writeFailed("建不了目录：\(error.localizedDescription)")
            }

            let rawTitle = request.value("title") ?? ""
            let sanitized = DocumentsWorkspace.sanitizedFileName(rawTitle)
            let baseName = sanitized.isEmpty ? DocumentsWorkspace.untitledBaseName : sanitized
            let url = DocumentsWorkspace.uniqueFileURL(in: folder, baseName: baseName)

            do {
                try DocumentsWorkspace.write(request.parameters["text"] ?? "", to: url)
            } catch {
                throw MarkdownCallbackError.writeFailed(error.localizedDescription)
            }
            // 左栏的行是扫目录扫出来的，不通知就还是旧的
            NotificationCenter.default.post(name: DocumentsWorkspace.didChangeNotification, object: nil)

            // ⚠️ 刻意不调 `DocumentsWorkspace.registerFreshDocument`：
            // 那个账是给「用户新建、还没起名字」用的，登记了之后用户第一次按 ⌘S 会被追问文件名
            if shouldOpen(request, default: true) {
                DocumentOpening.open(url, mode: .newTab, using: router)
            }
            respondSuccess(request, params: metadata(for: url))
        } catch let error as MarkdownCallbackError {
            respondError(request, error)
        } catch {
            respondError(request, .writeFailed(error.localizedDescription))
        }
    }

    // MARK: - add-text

    private func performAddText(_ request: MarkdownCallbackURL.Parsed,
                                completion: @escaping () -> Void) {
        do {
            let id = try request.requires("id")
            let text = try request.requires("text")
            let mode = try textMode(request)
            let url = try MarkdownCallbackPaths.documentURL(forID: id)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw MarkdownCallbackError.notFound(id)
            }
            guard let readable = ExternalDocumentAccess.shared.readableURL(for: url) else {
                throw MarkdownCallbackError.permissionDenied("「\(id)」在 App 目录外面，现在没有访问权限")
            }

            let controller = MarkdownDocumentRegistry.shared.controller(for: readable)
            // 正开着、还有没保存的修改：不能直接写盘，否则用户一按 ⌘S 就把刚写进去的盖掉
            if let controller, controller.isDirty {
                askBeforeWriting(controller: controller,
                                 url: readable,
                                 text: text,
                                 mode: mode,
                                 request: request,
                                 completion: completion)
                return
            }

            let length = try write(text, mode: mode, to: readable, refreshing: controller)
            var params = metadata(for: readable)
            params["length"] = String(length)
            respondSuccess(request, params: params)
            if shouldOpen(request, default: false) {
                DocumentOpening.open(readable, mode: .newTab, using: router)
            }
            completion()
        } catch let error as MarkdownCallbackError {
            respondError(request, error)
            completion()
        } catch {
            respondError(request, .writeFailed(error.localizedDescription))
            completion()
        }
    }

    private enum TextMode {
        case append
        case prepend
        case replaceAll
    }

    private func textMode(_ request: MarkdownCallbackURL.Parsed) throws -> TextMode {
        switch (request.value("mode") ?? "append").lowercased() {
        case "append": return .append
        case "prepend": return .prepend
        case "replace_all": return .replaceAll
        default:
            throw MarkdownCallbackError.invalidParam("mode 只认 append / prepend / replace_all")
        }
    }

    /// 真正写盘，并把新内容刷进开着的编辑器。
    ///
    /// - Returns: 写完之后整篇内容的字符数（给回调里的 `length`）
    private func write(_ text: String,
                       mode: TextMode,
                       to url: URL,
                       refreshing controller: MarkdownDocumentViewController?) throws -> Int {
        let current = DocumentsWorkspace.read(url) ?? ""

        let updated: String
        switch mode {
        case .append:
            var body = current
            // 补一个换行，别把新内容粘在上一行的尾巴上
            if !body.isEmpty, !body.hasSuffix("\n") { body += "\n" }
            body += text
            updated = body
        case .prepend:
            var body = text
            if !current.isEmpty, !body.hasSuffix("\n") { body += "\n" }
            body += current
            updated = body
        case .replaceAll:
            updated = text
        }

        do {
            try DocumentsWorkspace.write(updated, to: url)
        } catch {
            throw MarkdownCallbackError.writeFailed(error.localizedDescription)
        }
        NotificationCenter.default.post(name: DocumentsWorkspace.didChangeNotification, object: nil)

        refresh(controller, with: updated, at: url)
        return updated.count
    }

    /// 把写好的内容刷进已经开着的那一页。
    ///
    /// ⚠️ 刷新前手动清一次撤销栈：`apply` 对「同一份文档」是刻意不清的（它要在预览 Tab 复用回自己时保住撤销历史），而这里换掉的是整篇内容，旧账留着会让 ⌘Z 恢复出半新半旧的文本。
    private func refresh(_ controller: MarkdownDocumentViewController?,
                         with content: String,
                         at url: URL) {
        guard let controller, let opened = controller.openedFileURL else { return }
        guard ExternalDocumentAccess.shared.canonicalPath(for: opened)
                == ExternalDocumentAccess.shared.canonicalPath(for: url) else { return }

        let item = PPContentItem(id: opened.path,
                                 title: DocumentsWorkspace.displayName(for: opened),
                                 body: content,
                                 category: "Documents")
        controller.editor.resetUndoHistory()
        controller.apply(item)
    }

    /// 弹确认框：这份笔记有未保存的修改，先保存再写，还是算了。
    ///
    /// 弹不出来（已经有别的弹窗挡着）就直接按「忙」回绝，不能闷头写盘。
    private func askBeforeWriting(controller: MarkdownDocumentViewController,
                                  url: URL,
                                  text: String,
                                  mode: TextMode,
                                  request: MarkdownCallbackURL.Parsed,
                                  completion: @escaping () -> Void) {
        let host = controller.view.window != nil ? controller : presenter
        guard let host, host.presentedViewController == nil else {
            respondError(request, .busy("这份笔记正在 App 里编辑，现在弹不出确认框，这次写入已取消"))
            completion()
            return
        }

        let name = DocumentsWorkspace.displayName(for: url)
        let alert = UIAlertController(
            title: "《\(name)》有未保存的修改",
            message: "一个外部请求要往这份笔记里写内容。先保存当前的修改，再写进去？",
            preferredStyle: .alert)

        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
            self?.respondError(request, .canceled())
            completion()
        })
        alert.addAction(UIAlertAction(title: "保存并写入", style: .default) { [weak self] _ in
            guard let self else { return }
            // 直接写这个文件，不走 `saveDocument()`：那条路会为了「新建还没起名字」弹输入框，弹出来之后这次回调就永远回不去了
            guard controller.writeCurrentSource(to: url) else {
                self.respondError(request, .busy("这份笔记保存失败了，这次写入已取消"))
                completion()
                return
            }
            do {
                let length = try self.write(text, mode: mode, to: url, refreshing: controller)
                var params = self.metadata(for: url)
                params["length"] = String(length)
                self.respondSuccess(request, params: params)
            } catch let error as MarkdownCallbackError {
                self.respondError(request, error)
            } catch {
                self.respondError(request, .writeFailed(error.localizedDescription))
            }
            completion()
        })

        host.present(alert, animated: true)
    }

    // MARK: - read

    private func performRead(_ request: MarkdownCallbackURL.Parsed) {
        do {
            let id = try request.requires("id")
            let url = try MarkdownCallbackPaths.documentURL(forID: id)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw MarkdownCallbackError.notFound(id)
            }
            guard let readable = ExternalDocumentAccess.shared.readableURL(for: url) else {
                throw MarkdownCallbackError.permissionDenied("「\(id)」在 App 目录外面，现在没有访问权限")
            }
            guard let text = DocumentsWorkspace.read(readable) else {
                throw MarkdownCallbackError.notFound(id)
            }

            var params = metadata(for: readable)
            if text.count > Self.readCharacterLimit {
                params["note"] = String(text.prefix(Self.readCharacterLimit))
                params["truncated"] = "yes"
            } else {
                params["note"] = text
            }
            // 编辑器里还有没保存的修改时提醒一句：读到的不是用户屏幕上那一版
            if let controller = MarkdownDocumentRegistry.shared.controller(for: readable),
               controller.isDirty {
                params["unsaved"] = "yes"
            }
            respondSuccess(request, params: params)
        } catch let error as MarkdownCallbackError {
            respondError(request, error)
        } catch {
            respondError(request, .invalidParam(error.localizedDescription))
        }
    }

    // MARK: - 小工具

    private func openMode(_ request: MarkdownCallbackURL.Parsed) throws -> PPContentOpenMode {
        guard let raw = request.value("mode")?.lowercased() else { return .newTab }
        switch raw {
        case "tab", "newtab": return .newTab
        case "preview": return .preview
        default:
            throw MarkdownCallbackError.invalidParam("mode 只认 tab 或 preview")
        }
    }

    /// `open` 参数：不给就用调用方指定的默认值
    private func shouldOpen(_ request: MarkdownCallbackURL.Parsed, default defaultValue: Bool) -> Bool {
        switch request.parameters["open"]?.lowercased() {
        case "yes": return true
        case "no": return false
        default: return defaultValue
        }
    }

    /// 回调里那组元信息
    private func metadata(for url: URL) -> [String: String] {
        var params: [String: String] = [
            "identifier": MarkdownCallbackPaths.identifier(for: url),
            "title": DocumentsWorkspace.displayName(for: url),
            "path": url.path
        ]
        if let date = DocumentsWorkspace.modificationDate(of: url) {
            params["modified"] = Self.isoFormatter.string(from: date)
        }
        return params
    }

    /// `edit=yes`：等那个 Tab 真的上屏之后把光标放进正文。
    ///
    /// 刚开出来的 Tab 可能连 view 都还没加载，当场 `becomeFirstResponder` 是白调。
    /// 所以隔一小会儿再找一次，最多试几轮。
    private func focusEditor(for url: URL, attempt: Int = 0) {
        guard attempt < 8 else { return }
        if let controller = MarkdownDocumentRegistry.shared.controller(for: url),
           controller.view.window != nil {
            controller.editor.becomeFirstResponder()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.focusEditor(for: url, attempt: attempt + 1)
        }
    }

    private func respondSuccess(_ request: MarkdownCallbackURL.Parsed, params: [String: String]) {
        respond(to: request.successURL, params: params)
    }

    private func respondError(_ request: MarkdownCallbackURL.Parsed, _ error: MarkdownCallbackError) {
        respond(to: request.errorURL,
                params: ["error-code": String(error.code), "error-message": error.message])
    }

    /// 把参数追加到调用方给的地址后面再打开。
    ///
    /// 用 `URLComponents` 拼而不是手写字符串：值里的空格、中文、`&` 都由它转义，手拼十有八九会漏掉某一处。
    private func respond(to base: URL?, params: [String: String]) {
        guard let base,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return }
        var items = components.queryItems ?? []
        // 排一下序，纯粹是让回调地址每次长得一样，方便对着日志看
        for (key, value) in params.sorted(by: { $0.key < $1.key }) {
            items.append(URLQueryItem(name: key, value: value))
        }
        components.queryItems = items
        guard let url = components.url else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    nonisolated deinit {}
}
