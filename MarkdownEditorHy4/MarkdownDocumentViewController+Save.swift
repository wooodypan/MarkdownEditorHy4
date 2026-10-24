//
//  MarkdownDocumentViewController+Save.swift
//  MarkdownEditorHy4
//
//  ⌘S 那一串：占位名先问名字、改名、写盘、失败提示。
//
//  ⚠️ 从 `MarkdownDocumentViewController.swift` 拆出来的：代码原样搬过来，只去掉了 `private`
//  （Swift 的 private 只在本文件可见，跨文件就调不到）。
//

import UIKit

extension MarkdownDocumentViewController {

    // MARK: 保存

    /// ⌘S：写回这个 Tab 对应的文件。
    ///
    /// 正常一定有文件可写（每个 Tab 都是被一份文件开出来的）。真没有就只弹个提示：新建的文档是左侧栏先在磁盘上建好的，不存在「草稿没有文件」这种中间态。
    ///
    /// ### 新建的文档会先问一句名字
    /// 从「＋」或 ⌘N 建出来的文档，磁盘上先是 `未命名.md` 之类的占位名。
    /// 在它上面第一次按 ⌘S 会弹输入框请用户起名字。这是 Mac 上「新文档第一次保存要问文件名」的老规矩，也是不让文稿目录攒下一串「未命名 7.md」的唯一机会。
    /// 起过名字之后 ⌘S 直接写回，不再问。
    ///
    /// 这里刻意不加 private：菜单栏的「存储」项要引用它的 selector，修饰符是 private 的话，AppDelegate 里 `#selector(...)` 取不到
    @objc func saveDocument() {
        guard let url = openedFileURL else {
            showAlert(title: "没有可保存的文件",
                      message: "这一页没有对应到磁盘上的文件，没法保存。在左侧栏点一份文档，或者在「文件」App 里把 .md 放进来。")
            return
        }

        // 还顶着占位名就先请用户起名字，别把一堆「未命名 5.md」留给用户
        guard !needsFileNameBeforeSaving else {
            promptForFileName(startingFrom: url)
            return
        }

        writeCurrentSource(to: url)
    }

    /// 「这一页是不是还没起过名字、保存前得先问一句」。
    ///
    /// 判断本身在 `DocumentsWorkspace.isUntitled` 里（只看文件名），这里多包一层是为了能单测：弹框那一步在单测里走不起来，但「该不该弹」这条逻辑值得单独钉住。
    var needsFileNameBeforeSaving: Bool {
        guard let url = openedFileURL else { return false }
        return DocumentsWorkspace.isUntitled(url)
    }

    /// 把编辑器里的内容写进指定文件。
    ///
    /// - Returns: 写成功了回 true。失败会弹提示，让用户知道「没存上」
    @discardableResult
    func writeCurrentSource(to url: URL) -> Bool {
        // 容器外的文件可能在这次打开之前就丢了访问权（比如用户从「最近」点开、
        // 书签又没保存成功）。保存前再要一次权限，能解析书签就顺手解析。
        guard let readableURL = ExternalDocumentAccess.shared.readableURL(for: url) else {
            showAlert(title: "保存失败",
                      message: "「\(url.lastPathComponent)」现在没有访问权限。\n\n"
                             + "请重新打开这份文件，或者选择把它复制进 App。")
            return false
        }

        let source = editor.markdownSource
        do {
            try DocumentsWorkspace.write(source, to: readableURL)
        } catch {
            showAlert(title: "保存失败",
                      message: "\(url.lastPathComponent)\n\n\(error.localizedDescription)")
            return false
        }

        savedSource = source
        // 存盘是个天然的存档时机：用户按 ⌘S 就是明确说"这一版我要留住"，顺手往历史里也存一份
        snapshotHistory(reason: .autoSave)
        // 说一声，让左侧栏重新扫一遍目录。
        // 左栏每一行上显示着文档首行的预览和修改日期，不通知的话用户按完 ⌘S 左边那几行还是旧的。Mac 上左栏一直看得见，这个陈旧会更明显。
        // 照旧走通知，别在这儿直接去刷别的视图控制器
        NotificationCenter.default.post(name: DocumentsWorkspace.didChangeNotification, object: nil)
        // 存盘是个天然的「我读到这儿了」的时间点，顺手记一次
        rememberCurrentScrollPosition()
        refreshStatus()
        updateWindowTitle()
        flashStatus("已保存 \(url.lastPathComponent)")

        // 返回时选的「保存」：到这儿才算真的存完了，可以把这一页弹回去。
        // ⚠️ 等一拍再弹：此刻还在保存这条调用链上，链尾（`save(from:as:)` 那边）接着还要用 self 收尾，当场把页面弹掉会让那些动作落在已经拆掉的界面上
        if popAfterSaving {
            popAfterSaving = false
            DispatchQueue.main.async { [weak self] in
                self?.popBack()
            }
        }
        return true
    }

    /// 弹「给文档起个名字」的输入框。
    ///
    /// ### 为什么是 UIAlertController 加输入框，而不是系统存储面板
    /// Mac 上做这件事的正经办法是 `NSSavePanel`，但 Catalyst 把它标成 unavailable，编译器直接拦。
    /// 退一步用「一个输入框 + 保存 / 取消」：预填名字、能改、能取消，够用。
    ///
    /// - Parameter suggested: 预填进输入框的名字。第一次弹时是占位名（「未命名」）；用户因为重名被打回来重弹时，填他上一次输的名字，好改一个字接着来
    func promptForFileName(startingFrom url: URL, suggested: String? = nil) {
        let defaultName = suggested ?? DocumentsWorkspace.displayName(for: url)

        let alert = UIAlertController(
            title: "保存文档",
            message: "给这份文档起个名字，它会存在 App 的文档目录里。\n"
                   + "直接点「保存」也行，那就还叫「\(defaultName)」。",
            preferredStyle: .alert)

        alert.addTextField { field in
            field.text = defaultName
            field.placeholder = "文件名"
            field.clearButtonMode = .whileEditing
            field.returnKeyType = .done
        }

        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
            // 取消 = 这一下不存。正文还在编辑器里，标题上的「已修改」也还在，
            // 但得说一声，免得用户以为刚才那一下存过了
            self?.flashStatus("已取消保存")
            // 若这次保存是「返回」那条路发起的（选了保存、结果被问名字），取消就等于「别走了」，把标记抹掉，人留在原地
            self?.popAfterSaving = false
        })
        // `weak alert`：UIAlertController 持有 action、action 持有这个闭包，
        // 闭包里再强引用 alert 就绕成一个圈，弹框关了也放不掉
        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            self.save(from: url, as: alert?.textFields?.first?.text ?? "")
        })

        // 顺带把预填的名字整条选中：用户直接打字就等于「改掉它」，
        // 不用先自己全选删一遍。
        // 放在 present 的 completion 里做：弹框还没上屏时输入框不是第一响应者，
        // 那会儿设选中会被系统清掉
        present(alert, animated: true) {
            alert.textFields?.first?.selectAll(nil)
        }
    }

    /// 用户在命名框里点了「保存」之后真正要做的事：改名，再把内容写进去。
    ///
    /// 抽成独立方法而不是直接写在弹框的闭包体里，有两个原因：
    /// 1. 能单测。`UIAlertController` 那一步在单测里走不起来，而「改名 + 写盘 + 更新本页状态」才是真会出错的地方；
    /// 2. 失败提示要分得清是「名字不行」还是「写不进去」，两者的下一步动作不一样。
    ///
    /// - Returns: 存成功了回新的文件地址；名字是空的 / 被占用了则回 nil
    @discardableResult
    func save(from url: URL, as rawName: String) -> URL? {
        let newURL: URL
        do {
            newURL = try DocumentsWorkspace.rename(url, toBaseName: rawName)
        } catch {
            showNameRejectedAlert(error, from: url, triedName: rawName)
            return nil
        }

        // 改完名，这一页从此就认新路径了，之后的 ⌘S、窗口标题、「读到哪儿」的记录全都跟着走
        openedFileURL = newURL
        // 旧路径那条阅读位置的记录留着没用了（文件名以后可能被重新用上，那时候不该莫名跳到文档中间）
        DocumentScrollMemory.shared.forget(key: url.path)
        // 说一声，让左侧栏重新扫一遍目录。照旧走通知，别在这儿直接刷
        NotificationCenter.default.post(name: DocumentsWorkspace.didChangeNotification, object: nil)

        // 顺序是先改名、后写内容：改名最可能因为重名失败，那时宁可什么都还没动
        // （文件还在原来的占位名下，用户换个名字接着存）
        writeCurrentSource(to: newURL)
        return newURL
    }

    /// 名字用不了（空的或重名）时的提示，带一个「重新起名」的入口。
    ///
    /// 单独写一个而不复用 `showAlert`：只丢一句「保存失败」的话，用户得自己再按一次 ⌘S 才能重新输名字，多两步。
    func showNameRejectedAlert(_ error: Error, from url: URL, triedName: String) {
        let alert = UIAlertController(title: "这个名字用不了",
                                      message: error.localizedDescription,
                                      preferredStyle: .alert)
        // 预填的是用户上一次输入的那个名字，改一个字就能接着来
        alert.addAction(UIAlertAction(title: "重新起名", style: .default) { [weak self] _ in
            self?.promptForFileName(startingFrom: url, suggested: triedName)
        })
        alert.addAction(UIAlertAction(title: "好", style: .cancel) { [weak self] _ in
            // 名字一直定不下来，这一次保存就此作罢。
            // 若它是「返回」那条路发起的，这一下就等于放弃保存，别把页面弹走
            self?.popAfterSaving = false
        })
        present(alert, animated: true)
    }
}

