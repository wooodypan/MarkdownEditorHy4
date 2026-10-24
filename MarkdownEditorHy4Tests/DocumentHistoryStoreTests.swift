//
//  DocumentHistoryStoreTests.swift
//  MarkdownEditorHy4Tests
//
//  历史版本的验收测试：存了会不会重复、满了丢哪一版、能不能恢复、改名搬不搬家，还有最要命的那条 —— **删历史绝不能把父目录一起删掉**。
//
//  大白话：这一组测试就是替用户先"试摔"一遍，确认存档柜不会丢东西、更不会删错东西。
//
//  ⚠️ 全部用**临时目录**里的假文件，绝不碰 App 沙盒里那份真历史。
//
//  ### 为什么 `removeHistoryDirectory` 那几条是本文件最重要的测试
//  因为"删错东西"是唯一没法挽回的事故：文件删了还能重写，整个目录被端掉就真的没了。
//
//  历史文件夹的名字如果是用户能控制的东西（文件名、路径片段），一份叫 `..` 的文档就能让"删这份文档的历史"变成"删掉整个 Application Support"：`MarkdownHistory/..` 解析出来正是 Application Support 本身。
//  现在文件夹名是路径算出来的哈希（只可能是 0-9a-f），删之前还要再验一遍目标在根目录里面，下面这几条测试就是把这两道闸钉死的。
//

import XCTest
@testable import MarkdownEditorHy4

@MainActor
final class DocumentHistoryStoreTests: XCTestCase {

    /// 造一个临时目录，并登记「跑完删掉它」
    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// 临时目录里的一份假文档（文件本身不用真存在，留档只认路径）
    private func documentURL(named name: String, in directory: URL) -> URL {
        directory.appendingPathComponent(name)
    }

    // MARK: - 留档

    /// 内容没变就不该多出一版：不然每敲一个字都留一版，50 个名额一下就被占满
    func testSameContentIsNotSavedTwice() throws {
        let directory = try makeTempDirectory()
        let store = DocumentHistoryStore(rootURL: directory.appendingPathComponent("History"))
        let url = documentURL(named: "笔记.md", in: directory)

        XCTAssertNotNil(try store.saveSnapshot(fileAt: url, content: "第一版", reason: .autoSave))
        XCTAssertNil(try store.saveSnapshot(fileAt: url, content: "第一版", reason: .autoSave),
                     "内容没变却留了一版，历史会被一堆重复版本挤爆")
        XCTAssertEqual(try store.versions(fileAt: url).count, 1)
    }

    /// 内容变了就该多出一版，而且列表是「新的在前」
    func testChangedContentCreatesNewVersionNewestFirst() throws {
        let directory = try makeTempDirectory()
        let store = DocumentHistoryStore(rootURL: directory.appendingPathComponent("History"))
        let url = documentURL(named: "笔记.md", in: directory)

        try store.saveSnapshot(fileAt: url, content: "第一版", reason: .autoSave)
        try store.saveSnapshot(fileAt: url, content: "第二版", reason: .autoSave)

        let versions = try store.versions(fileAt: url)
        XCTAssertEqual(versions.count, 2)
        XCTAssertGreaterThan(versions[0].sequence, versions[1].sequence, "最新的该排在最前面")
        XCTAssertEqual(try store.content(fileAt: url, versionID: versions[0].id), "第二版")
        XCTAssertEqual(try store.content(fileAt: url, versionID: versions[1].id), "第一版")
    }

    /// 手动保存：内容和最新版一样时把它**转正**，不产生重复文件
    func testManualVersionPromotesLatestAutoVersion() throws {
        let directory = try makeTempDirectory()
        let store = DocumentHistoryStore(rootURL: directory.appendingPathComponent("History"))
        let url = documentURL(named: "笔记.md", in: directory)

        try store.saveSnapshot(fileAt: url, content: "定稿", reason: .autoSave)
        try store.saveManualVersion(fileAt: url, content: "定稿")

        let versions = try store.versions(fileAt: url)
        XCTAssertEqual(versions.count, 1, "内容一样不该多出一版，只要把那一版标成手动的")
        XCTAssertEqual(versions.first?.reason, .manual)
    }

    /// 手动保存两次同样的内容：不报错，也不多出版本
    func testManualVersionTwiceIsIdempotent() throws {
        let directory = try makeTempDirectory()
        let store = DocumentHistoryStore(rootURL: directory.appendingPathComponent("History"))
        let url = documentURL(named: "笔记.md", in: directory)

        try store.saveManualVersion(fileAt: url, content: "里程碑")
        try store.saveManualVersion(fileAt: url, content: "里程碑")

        XCTAssertEqual(try store.versions(fileAt: url).count, 1)
    }

    // MARK: - 清理规则（纯函数）

    /// 超过名额的最旧版本被丢掉；手动版本既不删、也不占名额；保护名单里的不删
    func testVersionsToDeleteRespectsManualAndProtected() {
        let manual = DocumentVersion(id: UUID(), sequence: 1, createdAt: Date(),
                                     contentHash: "a", byteCount: 1, reason: .manual, note: nil)
        let old = DocumentVersion(id: UUID(), sequence: 2, createdAt: Date(),
                                  contentHash: "b", byteCount: 1, reason: .autoSave, note: nil)
        let middle = DocumentVersion(id: UUID(), sequence: 3, createdAt: Date(),
                                     contentHash: "c", byteCount: 1, reason: .autoSave, note: nil)
        let newest = DocumentVersion(id: UUID(), sequence: 4, createdAt: Date(),
                                     contentHash: "d", byteCount: 1, reason: .autoSave, note: nil)

        // 名额 2 个：手动的不占名额，所以自动的三版里只留最新的两版（middle / newest），old 该被丢掉
        let doomed = DocumentHistoryStore.versionsToDelete([manual, old, middle, newest],
                                                           retention: DocumentHistoryRetention(maxCount: 2,
                                                                                               manualVersionsExempt: true))
        XCTAssertEqual(doomed, [old.id], "手动版本不该被删，也不该占自动版本的名额")
        XCTAssertFalse(doomed.contains(newest.id))

        // 保护名单里的最旧版本也不能删（恢复旧版本时用它）
        let protected = DocumentHistoryStore.versionsToDelete([old, middle, newest],
                                                              retention: DocumentHistoryRetention(maxCount: 1,
                                                                                                  manualVersionsExempt: true),
                                                              protected: [old.id])
        XCTAssertFalse(protected.contains(old.id), "受保护的版本不该被清理掉")
        XCTAssertEqual(protected, [middle.id])
    }

    // MARK: - 恢复

    /// 恢复：拿到的是旧版内容；恢复前那份内容自动留了一版（后悔药）
    func testRestoreReturnsOldContentAndBacksUpCurrent() throws {
        let directory = try makeTempDirectory()
        let store = DocumentHistoryStore(rootURL: directory.appendingPathComponent("History"))
        let url = documentURL(named: "笔记.md", in: directory)

        try store.saveSnapshot(fileAt: url, content: "第一版", reason: .autoSave)
        try store.saveSnapshot(fileAt: url, content: "第二版", reason: .autoSave)
        let target = try XCTUnwrap(try store.versions(fileAt: url).last, "该有两版，最旧的是第一版")

        let result = try store.restore(fileAt: url, versionID: target.id, currentContent: "编辑器里正在写的")
        XCTAssertEqual(result.content, "第一版")
        XCTAssertNil(result.safetyBackupError)

        let after = try store.versions(fileAt: url)
        XCTAssertEqual(after.first?.contentHash, DocumentHistoryStore.contentHash("编辑器里正在写的"),
                       "恢复前那份内容该被留成最新的一版，好让人反悔")
        XCTAssertTrue(after.contains { $0.id == target.id }, "恢复用的那版本身不该被清理掉")
    }

    /// 版本存满之后恢复**最旧**的那一版：内容照样读得出来（这是最容易踩的一个坑）
    func testRestoreOldestVersionAfterRetentionKicksIn() throws {
        let directory = try makeTempDirectory()
        let store = DocumentHistoryStore(rootURL: directory.appendingPathComponent("History"),
                                         retention: DocumentHistoryRetention(maxCount: 2,
                                                                             manualVersionsExempt: false))
        let url = documentURL(named: "笔记.md", in: directory)

        try store.saveSnapshot(fileAt: url, content: "第一版", reason: .autoSave)
        try store.saveSnapshot(fileAt: url, content: "第二版", reason: .autoSave)
        try store.saveSnapshot(fileAt: url, content: "第三版", reason: .autoSave)

        // 名额只有 2 个，第一版已经被清理了；现在最旧的是第二版
        let remaining = try store.versions(fileAt: url)
        XCTAssertEqual(remaining.count, 2)
        let oldest = try XCTUnwrap(remaining.last)

        let result = try store.restore(fileAt: url, versionID: oldest.id, currentContent: "编辑器里正在写的")
        XCTAssertEqual(result.content, "第二版")
        XCTAssertTrue(try store.versions(fileAt: url).contains { $0.id == oldest.id },
                      "刚恢复的那一版不该被这一轮的清理带走")
    }

    /// 读一个清单里没有的版本要抛错，而不是返回空串糊弄过去
    func testContentOfUnknownVersionThrows() throws {
        let directory = try makeTempDirectory()
        let store = DocumentHistoryStore(rootURL: directory.appendingPathComponent("History"))
        let url = documentURL(named: "笔记.md", in: directory)

        XCTAssertThrowsError(try store.content(fileAt: url, versionID: UUID())) { error in
            XCTAssertTrue(error is DocumentHistoryError, "该抛自家定义好的错误，实际是 \(error)")
        }
    }

    /// 正文文件被人（或系统清理）删掉了：读的时候要报错，不能返回空内容当成「那一版是空的」
    func testContentOfMissingFileThrows() throws {
        let directory = try makeTempDirectory()
        let root = directory.appendingPathComponent("History")
        let store = DocumentHistoryStore(rootURL: root)
        let url = documentURL(named: "笔记.md", in: directory)

        try store.saveSnapshot(fileAt: url, content: "第一版", reason: .autoSave)
        let version = try XCTUnwrap(try store.versions(fileAt: url).first)

        // 绕过 store，直接把正文文件删掉，模拟「文件没了但清单还在」
        let folder = root.appendingPathComponent(DocumentHistoryStore.documentID(forFileAt: url))
        try FileManager.default.removeItem(at: folder.appendingPathComponent(version.fileName))

        XCTAssertThrowsError(try store.content(fileAt: url, versionID: version.id))
    }

    // MARK: - 🚨 删除绝不能连累父目录

    /// 删一份文档的历史：只该扔掉它自己那一格，别人的和柜子本身都得原封不动
    func testDeleteHistoryOnlyRemovesThatDocument() throws {
        let directory = try makeTempDirectory()
        let root = directory.appendingPathComponent("History")
        let store = DocumentHistoryStore(rootURL: root)
        let 甲 = documentURL(named: "甲.md", in: directory)
        let 乙 = documentURL(named: "乙.md", in: directory)

        try store.saveSnapshot(fileAt: 甲, content: "甲的内容", reason: .autoSave)
        try store.saveSnapshot(fileAt: 乙, content: "乙的内容", reason: .autoSave)

        try store.deleteHistory(fileAt: 甲)

        XCTAssertEqual(try store.versions(fileAt: 甲).count, 0, "甲的历史该被清掉")
        XCTAssertEqual(try store.versions(fileAt: 乙).count, 1, "乙的历史被连带删了 —— 删错东西比删不掉严重得多")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path), "历史根目录被删了")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path), "父目录被删了")
    }

    /// 🚨 回归：拿 `..` / `.` / 空字符串这种路径来删，父目录和根目录一个都不能少。
    ///
    /// 大白话：这就是防"删一份文档的存档，结果把 App 所有数据一起删了"那类事故。
    func testDeleteHistoryWithTrickyPathsSparesParentDirectory() throws {
        let directory = try makeTempDirectory()
        let root = directory.appendingPathComponent("History")
        let store = DocumentHistoryStore(rootURL: root)
        try store.saveSnapshot(fileAt: documentURL(named: "笔记.md", in: directory),
                               content: "内容", reason: .autoSave)

        for tricky in ["..", ".", ""] {
            let url = URL(fileURLWithPath: tricky)
            XCTAssertNoThrow(try store.deleteHistory(fileAt: url), "「\(tricky)」这种路径不该抛错到界面上")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path), "历史根目录没了")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path), "父目录没了 —— 这正是要防的事故")
    }

    /// 🚨 删目录那道闸本身：只要目标不是根目录里面的东西，一律拒绝。
    ///
    /// 大白话：闸门自己也得测 —— 万一闸门形同虚设，上面那些"路径很刁钻"的测试也拦不住。
    func testRemoveDirectoryRejectsTargetsOutsideRoot() throws {
        let directory = try makeTempDirectory()
        let root = directory.appendingPathComponent("History")
        let store = DocumentHistoryStore(rootURL: root)
        try store.saveSnapshot(fileAt: documentURL(named: "笔记.md", in: directory),
                               content: "内容", reason: .autoSave)

        // 根目录自己、根目录的父目录、以及一个毫不相干的路径，三个都该被拒
        for target in [root, root.deletingLastPathComponent(), URL(fileURLWithPath: "/tmp")] {
            XCTAssertThrowsError(try store.removeHistoryDirectory(target),
                                 "「\(target.path)」不在历史根目录里面，该被拦下")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    /// 删整个文件夹：里面所有文档的历史一起清掉，别处的历史不受影响
    func testDeleteHistoryUnderDirectoryLeavesOthersAlone() throws {
        let directory = try makeTempDirectory()
        let folder = directory.appendingPathComponent("文件夹")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = DocumentHistoryStore(rootURL: directory.appendingPathComponent("History"))

        let inside = folder.appendingPathComponent("里面.md")
        let outside = directory.appendingPathComponent("外面.md")
        try store.saveSnapshot(fileAt: inside, content: "里面的", reason: .autoSave)
        try store.saveSnapshot(fileAt: outside, content: "外面的", reason: .autoSave)

        try store.deleteHistory(underDirectory: folder)

        XCTAssertEqual(try store.versions(fileAt: inside).count, 0)
        XCTAssertEqual(try store.versions(fileAt: outside).count, 1, "文件夹外面的历史被误删了")
    }

    // MARK: - 改名搬家

    /// 文档改了名：历史跟着搬过去，不能凭空消失
    func testRenameMigratesHistory() throws {
        let directory = try makeTempDirectory()
        let store = DocumentHistoryStore(rootURL: directory.appendingPathComponent("History"))
        let old = documentURL(named: "草稿.md", in: directory)
        let new = documentURL(named: "定稿.md", in: directory)

        try store.saveSnapshot(fileAt: old, content: "正文", reason: .autoSave)
        store.migrateHistory(fromFileAt: old, toFileAt: new)

        XCTAssertEqual(try store.versions(fileAt: old).count, 0, "旧名下不该还有历史")
        XCTAssertEqual(try store.versions(fileAt: new).count, 1, "改完名历史就找不回来了 —— 用户会觉得历史莫名消失")
    }

    /// 文件夹改了名：里面所有文档的历史一起搬
    func testDirectoryRenameMigratesHistory() throws {
        let directory = try makeTempDirectory()
        let oldFolder = directory.appendingPathComponent("旧目录")
        let newFolder = directory.appendingPathComponent("新目录")
        try FileManager.default.createDirectory(at: oldFolder, withIntermediateDirectories: true)
        let store = DocumentHistoryStore(rootURL: directory.appendingPathComponent("History"))

        let doc = oldFolder.appendingPathComponent("笔记.md")
        try store.saveSnapshot(fileAt: doc, content: "正文", reason: .autoSave)

        store.migrateHistory(fromDirectory: oldFolder, toDirectory: newFolder)

        let moved = newFolder.appendingPathComponent("笔记.md")
        XCTAssertEqual(try store.versions(fileAt: moved).count, 1, "文件夹改名后，里面的历史该跟着搬过去")
    }

    // MARK: - 存放位置

    /// 历史目录要打上「不要备份」：它是本机才用得上的东西，不该跟着 iCloud 备份和同步走
    func testHistoryDirectoryIsExcludedFromBackup() throws {
        let directory = try makeTempDirectory()
        let root = directory.appendingPathComponent("History")
        let store = DocumentHistoryStore(rootURL: root)

        try store.saveSnapshot(fileAt: documentURL(named: "笔记.md", in: directory),
                               content: "内容", reason: .autoSave)

        let values = try root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true, "历史目录没打「不要备份」标记，会被 iCloud 备份带走")
    }

    /// 只是打开列表看一眼，不该给「从没留过档」的文档凭空造出一个空文件夹
    func testReadingVersionsDoesNotCreateDirectory() throws {
        let directory = try makeTempDirectory()
        let root = directory.appendingPathComponent("History")
        let store = DocumentHistoryStore(rootURL: root)

        XCTAssertEqual(try store.versions(fileAt: documentURL(named: "没留过档.md", in: directory)).count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "只读一遍就建了目录，会攒下一堆空文件夹")
    }

    // MARK: - 菜单

    /// 编辑页「⋯」菜单里得有「历史版本」这一项
    func testActionMenuHasHistoryItem() {
        let controller = MarkdownDocumentViewController()
        let titles = controller.makeActionMenu().children.compactMap { ($0 as? UIAction)?.title }
        XCTAssertTrue(titles.contains("历史版本"), "菜单里缺「历史版本」，实际有 \(titles)")
    }
}
