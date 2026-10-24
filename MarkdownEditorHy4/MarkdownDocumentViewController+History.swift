//
//  MarkdownDocumentViewController+History.swift
//  MarkdownEditorHy4
//
//  历史版本这一摊：菜单里的「历史版本」入口、什么时候自动存一版、恢复出来的内容怎么填回编辑器。
//
//  大白话：这一页负责三件事——把"存档柜"的入口摆到菜单里、隔一会儿帮你存一份、以及把挑中的旧版本放回编辑器。
//
//  ⚠️ 从 `MarkdownDocumentViewController.swift` 拆出来的（和别的 `+XXX` 一个道理）：
//  存储属性放不进 extension，所以那个"等会儿再存"的定时任务留在主文件的属性区。
//
//  ### 什么时候会存一版
//  | 时机 | 说明 |
//  | --- | --- |
//  | 停止输入 30 秒 | 一直在敲字就不停地往后推，只在真停下来那一刻写文件 |
//  | 按 ⌘S 存盘 | 用户明确要留住的时刻，顺手存一版 |
//  | 切走 App / 进后台 | 进程随时可能被系统收走，必须立刻存 |
//  | 离开编辑页（返回 / 关标签 / 切 Tab） | 定时还没到点就走了，最后这段只有历史能救回来 |
//
//  四个时机都过同一道"内容和上一版一样就不存"的判据，所以不会攒下一堆重复版本。
//

import UIKit

extension MarkdownDocumentViewController {

    // MARK: 自动留档

    /// 停止输入多久之后自动存一版（秒）。
    ///
    /// 大白话：手停下来 30 秒才真正写文件，不然每敲一个字都往硬盘上写一遍，太费劲。
    ///
    /// 30 秒是个折中：太短会攒下一堆只差一两个字的版本，很快把 50 个名额占满，真正有用的旧版本反而被挤掉；太长的话"刚写的一大段崩没了"就找不回来。
    static let historyIdleSeconds: Double = 30

    /// 正文动了一下：把"等会儿存一版"这件事往后推 30 秒。
    ///
    /// 大白话：每敲一个字就重新掐一次表，只有你真的停下来了，才轮到存档。
    ///
    /// 这个做法叫"防抖"：每敲一个字都写一次文件的话，写一篇长文会多出几千次写盘。
    /// 一直敲就一直取消上一次的安排、重新计时，于是只在用户真的停下来那一刻写。
    func scheduleHistorySnapshot() {
        historySnapshotWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.snapshotHistory(reason: .autoSave)
        }
        historySnapshotWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.historyIdleSeconds, execute: work)
    }

    /// 立刻存一版（定时到点、⌘S 存盘、切走 App、离开页面都走这里）。
    ///
    /// 大白话：趁用户不注意悄悄存好；真出问题就在屏幕底下提一句，别弹框打断他写字。
    ///
    /// ### 失败只让状态栏说一句，不弹框
    /// 自动存档是后台悄悄做的动作，用户正在写东西，弹个框打断他不值当。
    /// 真失败了（磁盘满、目录没权限之类）让底下那条状态栏说一句就够了；
    /// 只有用户手动点「保存当前版本」失败才值得弹框 —— 那是他明确要求的操作。
    ///
    /// ### 空文档不存
    /// 存一堆空白版本只会把真正的历史挤掉，新建文档还没写字时不该有历史。
    func snapshotHistory(reason: DocumentVersion.Reason) {
        // 已经安排上的那一次不用再跑了：这一下已经把最新内容存进去了
        historySnapshotWork?.cancel()
        guard let url = openedFileURL else { return }
        let source = editor.markdownSource
        guard !source.isEmpty else { return }
        do {
            try DocumentHistoryStore.shared.saveSnapshot(fileAt: url, content: source, reason: reason)
        } catch {
            flashStatus("历史版本没存上：\(error.localizedDescription)")
        }
    }

    // MARK: 历史版本那一页

    /// 打开历史版本列表页。
    ///
    /// 大白话：把"存档柜"打开，让用户看看存过哪些版本、挑一份恢复。
    ///
    /// ### 为什么单独开一页，而不是做成菜单的子菜单
    /// 子菜单是"点开菜单那一刻就拍好照"的，而版本列表得真打开时才去读（用户可能刚刚才存了一版）；
    /// 而且列表要能看正文、能点「恢复」，这些都不适合塞在一层菜单里。
    func showHistory() {
        guard let url = openedFileURL else {
            showAlert(title: "还没有可留档的文件",
                      message: "这一页没有对应到磁盘上的文件。历史版本是按文件记的，先存成一份文件再来查。")
            return
        }

        let list = DocumentHistoryViewController(fileURL: url)
        // 存哪一版、恢复哪一版都交给编辑页决定（编辑器里此刻是什么内容，只有它知道）
        list.onSaveCurrentVersion = { [weak self] in self?.saveCurrentVersionToHistory() }
        list.onRestoreVersion = { [weak self] in self?.restoreHistoryVersion($0) }
        // 点进某一版时要跟编辑器里现在的内容比，用户才看得见"点恢复会改掉哪些行"
        list.currentContent = { [weak self] in self?.editor.markdownSource }
        // 包一层导航控制器：列表要能 push 进预览页，也要有「完成」能关掉
        present(UINavigationController(rootViewController: list), animated: true)
    }

    /// 用户点了「保存当前版本」：这一版会永久保留，自动清理不碰它。
    ///
    /// 大白话：用户特意按了"记住现在这份"，那就必须给他一个准信，不能悄悄什么都没发生。
    ///
    /// 这是手动操作，失败必须让用户知道。所以只回结果、不在这儿弹框：
    /// 历史页还盖在上面，从这一页 `present` 会被 UIKit 直接丢掉。
    ///
    /// - Returns: 交给历史页显示的结果
    @discardableResult
    func saveCurrentVersionToHistory() -> DocumentHistoryFeedback {
        guard let url = openedFileURL else {
            return .failed(title: "保存版本失败", message: "这一页没有对应到磁盘上的文件。")
        }
        do {
            let version = try DocumentHistoryStore.shared.saveManualVersion(fileAt: url,
                                                                            content: editor.markdownSource)
            return .saved(sequence: version.sequence)
        } catch {
            return .failed(title: "保存版本失败", message: error.localizedDescription)
        }
    }

    /// 把某个旧版本填回编辑器（还没存盘）。
    ///
    /// 大白话：把旧的那份内容搬回来，但先不覆盖磁盘上的文件，让用户自己看一眼、决定要不要按 ⌘S。
    ///
    /// ### 为什么恢复完不直接写盘
    /// 换完之后文档是"已修改、还没存"的状态，用户可以再看一眼、改两笔、或者反悔（恢复前那份内容已经在 `restore` 里自动存了一版）。直接替他写盘等于替他做了决定。
    ///
    /// ### 为什么要清撤销栈
    /// 撤销栈里的旧账是按**恢复前**那段文本记的（范围、长度都是照它算的），套到新文本上会越界。
    /// 真正的后悔药是历史里那一版「恢复前备份」，不是撤销。
    ///
    /// - Returns: 交给历史页显示的结果（理由同 `saveCurrentVersionToHistory`）
    @discardableResult
    func restoreHistoryVersion(_ versionID: UUID) -> DocumentHistoryFeedback {
        guard let url = openedFileURL else {
            return .failed(title: "恢复失败", message: "这一页没有对应到磁盘上的文件。")
        }
        do {
            let result = try DocumentHistoryStore.shared.restore(fileAt: url,
                                                                 versionID: versionID,
                                                                 currentContent: editor.markdownSource)
            editor.resetUndoHistory()
            editor.setMarkdown(result.content)
            // 整篇内容都换了：大纲里折叠过的标题、查找框里找到的那些位置，全都属于上一版，得重来一遍
            outlineView.resetFolding()
            searchCoordinator.rerunIfNeeded()
            refreshStatus()
            updateWindowTitle()

            if let backupError = result.safetyBackupError {
                return .restoredWithoutBackup(message: backupError.localizedDescription)
            }
            return .restored
        } catch {
            return .failed(title: "恢复失败", message: error.localizedDescription)
        }
    }
}
