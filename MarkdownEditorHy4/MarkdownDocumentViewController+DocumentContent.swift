//
//  MarkdownDocumentViewController+DocumentContent.swift
//  MarkdownEditorHy4
//
//  宿主送来的内容项怎么装进编辑器，以及「这份文档读到哪儿了」「文件被改名了」两件事。
//
//  ⚠️ 从 `MarkdownDocumentViewController.swift` 拆出来的：代码原样搬过来，只去掉了 `private`
//  （Swift 的 private 只在本文件可见，跨文件就调不到）。
//

import UIKit
import MultiTabController

extension MarkdownDocumentViewController {

    // MARK: 记住「这份文档读到哪儿了」

    /// 这份文档在阅读位置里的钥匙，就是文件路径。
    ///
    /// 现在每一页都对应磁盘上一份文件，不再有「内置示例 / 空白草稿」那两种没有文件可记的情形。
    /// 真没有文件就返回 nil，等于不记。
    var documentScrollKey: String? {
        openedFileURL?.path
    }

    /// 离开当前文档之前，把它读到哪儿记下来。
    /// 三个时机调用：换文档之前、按 ⌘S 保存之后、App 失去焦点或进后台时
    func rememberCurrentScrollPosition() {
        guard settings.remembersScrollPosition, let key = documentScrollKey else { return }
        scrollMemory.remember(sourceOffset: editor.topVisibleSourceOffset, for: key)
    }

    /// 换完文档之后，回到上次读到的位置。
    ///
    /// 关掉「记住滚动位置」时什么都不做，打开就是文档开头。
    /// 滚动本身在编辑器内部是异步收敛的（TextKit 2 一次滚不到位），这里只管发出指令
    func restoreScrollPositionIfNeeded() {
        guard settings.remembersScrollPosition, let key = documentScrollKey else { return }
        guard let offset = scrollMemory.sourceOffset(for: key) else { return }
        editor.restoreScrollPosition(sourceOffset: offset)
    }

    /// App 被切走或进后台时也记一次，用户很可能随手切出去就再也没回来
    func observeAppLifecycle() {
        let center = NotificationCenter.default
        center.addObserver(self,
                           selector: #selector(appWillLeaveForeground),
                           name: UIApplication.willResignActiveNotification,
                           object: nil)
        center.addObserver(self,
                           selector: #selector(appWillLeaveForeground),
                           name: UIApplication.didEnterBackgroundNotification,
                           object: nil)
    }

    @objc func appWillLeaveForeground() {
        rememberCurrentScrollPosition()
    }

    /// 目录里的文件被改名了，我要是正开着那一份，得把「我对应哪个文件」换过来
    func observeWorkspaceChanges() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(documentDidRename(_:)),
                                               name: DocumentsWorkspace.didRenameNotification,
                                               object: nil)
    }

    /// 左栏右键「重命名」改的是磁盘上的路径，这边把路径记在 `openedFileURL` 里，当「⌘S 写回哪儿」用。
    ///
    /// ### 不跟着换会出什么事
    /// 文件已经叫新名字，这边还记着旧名字：用户回到正文按一次 ⌘S，内容就写进旧路径，磁盘上多出一份重复文件，新名字那份反而是旧的。
    /// 所以改完名要把路径、图片基准目录、阅读位置的钥匙、标题一起换过来。
    @objc func documentDidRename(_ notification: Notification) {
        guard let from = notification.userInfo?[DocumentsWorkspace.renameFromURLKey] as? URL,
              let to = notification.userInfo?[DocumentsWorkspace.renameToURLKey] as? URL,
              // 改的不是我这份（或者我根本没有文件），那就跟我没关系
              openedFileURL == from else { return }

        openedFileURL = to
        // 旧路径那条「读到哪儿」没人用了。文件名以后可能被重新用上，那时不该莫名跳到文档中间，所以要主动忘掉（和删除那份文档时做的是同一件事）
        scrollMemory.forget(key: from.path)

        // 界面还没建好（Tab 先建、后显示）时只改路径就够了，剩下的等 viewDidLoad 走正常流程
        guard isViewLoaded else { return }
        // 相对路径的图片基准目录也跟着换（文件改了名，目录一般没变，但别依赖「一般」）
        editor.imageBaseURL = to.deletingLastPathComponent()
        // 位置先在**新钥匙**下记一笔，免得刚改完名就被忘掉
        rememberCurrentScrollPosition()
        updateWindowTitle()
        refreshStatus()
        flashStatus("已改名为 \(DocumentsWorkspace.displayName(for: to))")
    }

    // MARK: - PPContentDisplaying（宿主 → 内容页）

    /// 宿主送来一份内容项：把这一页换成那份文档。
    ///
    /// ⚠️ 宿主可能在界面还没建好时就调用（Tab 是先创建、后显示）。
    /// 所以这里只把内容存下来，真正的加载留给 `viewDidLoad`
    func configure(with item: PPContentItem) {
        pendingItem = item
        guard isViewLoaded else { return }
        // 界面已经在了（比如同一个预览 Tab 被复用成另一份文档），当场换
        apply(item)
    }

    /// 把一份内容项装进编辑器。
    ///
    /// 文本从内容项里取（`item.body`），不自己去读盘：读文件那一步在左侧栏做完，读失败在那里就被拦住。
    /// 不然这里拿到空内容，用户一按 ⌘S 就把原文件清空了。
    func apply(_ item: PPContentItem) {
        let url = URL(fileURLWithPath: item.id)
        let isSameDocument = openedFileURL == url

        // 换文档 = 换一把「阅读位置」的钥匙。必须在改 openedFileURL 之前记，
        // 那之后 documentScrollKey 就已经指向新文档了
        if !isSameDocument { rememberCurrentScrollPosition() }

        openedFileURL = url
        savedSource = item.body
        // 换了一份文档，「我改过了」这件事重新从零算（新 Tab 该有新的机会被固定）
        didReportEdited = false
        // ⚠️ 换文档必须把撤销栈清空：栈里的旧账是按上一份文档的文本记的（范围、长度、整篇快照都是）。
        // 套到新文档上要么越界崩溃（实测：在空文档里 ⌘Z 弹出上一份文档的旧记录，直接 NSRangeException），
        // 要么把上一份文档的内容整篇灌进当前编辑器，再按一次 ⌘S 就把新文件覆盖掉了。
        // 只在这里清、不放进 setMarkdown：撤销和重做自己也靠 setMarkdown 整篇恢复，放进等于每撤销一次就清空一次。
        if !isSameDocument {
            editor.resetUndoHistory()
        }
        // md 里的图片多是相对路径，基准目录要指向文件所在目录，否则图片全裂
        editor.imageBaseURL = url.deletingLastPathComponent()
        // 同一份文档被重新配置（预览 Tab 复用回它自己）时，光标要留在原处。
        // `setMarkdown` 是「整篇换内容」，按约定会把光标归零（换文档时正需要这个效果）；
        // 这里先把当前光标换成源码坐标存一笔，装完再换算回去，用户正在读的地方不会被顶走。
        let caretSourceBeforeReload = isSameDocument
            ? editor.documentStore.sourceCaret(forRenderedOffset: editor.selectedRange.location)
            : nil
        editor.setMarkdown(item.body)
        if let caretSourceBeforeReload {
            let caret = editor.documentStore.renderedCaret(forSourceOffset: caretSourceBeforeReload)
            editor.selectedRange = NSRange(location: min(caret, (editor.text as NSString).length), length: 0)
        }

        refreshStatus()
        updateWindowTitle()
        // 换文档，大纲从「全部展开」开始（上一份文档折过什么，跟这一份没关系）
        outlineView.resetFolding()
        // 查找还开着的话，按原来那个词在新文档里重查一遍。换文档时编辑器已经把自己的命中清掉了，不补这一下，计数会停在上一份文档的旧数字上
        searchCoordinator.rerunIfNeeded()
        // 同一份文档被重新配置（预览 Tab 复用回它自己）就别乱滚，免得跳走
        if !isSameDocument { restoreScrollPositionIfNeeded() }
    }
}

