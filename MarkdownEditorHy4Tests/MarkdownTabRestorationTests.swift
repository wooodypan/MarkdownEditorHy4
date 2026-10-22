//
//  MarkdownTabRestorationTests.swift
//  MarkdownEditorHy4Tests
//
//  「冷启动恢复上次打开的 Tab」里属于本 App 的那一段：路径能不能还原成内容项。
//  库怎么存快照、怎么重建 Tab 条不在这里测（那是 MultiTabController 自己的事）。
//

import XCTest
import MultiTabController
@testable import MarkdownEditorHy4

@MainActor
final class MarkdownTabRestorationTests: XCTestCase {

    /// 造一个临时目录，并登记「跑完删掉它」
    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownTabRestorationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    /// 在临时目录里真写一份文档
    @discardableResult
    private func writeDocument(_ name: String, content: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - 路径 → 内容项

    /// 文件还在：id 用规范化路径、标题去掉扩展名、内容一字不差
    func testRestoresExistingDocument() throws {
        let directory = try makeTempDirectory()
        let url = try writeDocument("会议记录.md", content: "# 周一\n\n讨论排期。\n", in: directory)

        let item = MarkdownTabRestoration.contentItem(forID: url.path)

        XCTAssertEqual(item?.id, ExternalDocumentAccess.shared.canonicalPath(for: url))
        XCTAssertEqual(item?.title, "会议记录")
        XCTAssertEqual(item?.body, "# 周一\n\n讨论排期。\n")
        XCTAssertEqual(item?.category, "Documents")
    }

    /// 文件被删了：返回 nil，让库跳过这一条
    func testMissingFileReturnsNil() throws {
        let directory = try makeTempDirectory()
        let url = directory.appendingPathComponent("已经删了.md")

        XCTAssertNil(MarkdownTabRestoration.contentItem(forID: url.path))
    }

    /// 存档里的路径不是文档（被改坏、或者是图片）：别硬塞进编辑器
    func testNonDocumentPathReturnsNil() throws {
        let directory = try makeTempDirectory()
        let url = try writeDocument("截图.png", content: "not a markdown", in: directory)

        XCTAssertNil(MarkdownTabRestoration.contentItem(forID: url.path))
    }

    /// 目录也可能叫 `xxx.md`：只认普通文件
    func testDirectoryNamedLikeDocumentReturnsNil() throws {
        let directory = try makeTempDirectory()
        let url = directory.appendingPathComponent("伪装成文档.md", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        XCTAssertNil(MarkdownTabRestoration.contentItem(forID: url.path))
    }

    /// 空文件是合法文档：返回空内容，不能当成「读失败」跳过
    func testEmptyDocumentIsStillRestorable() throws {
        let directory = try makeTempDirectory()
        let url = try writeDocument("空白.md", content: "", in: directory)

        let item = MarkdownTabRestoration.contentItem(forID: url.path)

        XCTAssertEqual(item?.body, "")
        XCTAssertEqual(item?.title, "空白")
    }

    // MARK: - 接入

    /// `install()` 打开的开关，真正指向「按路径还原内容」这件事
    func testInstallWiresResolverToContentRestoration() throws {
        // 用例跑完把全局配置还原，免得影响别的测试（这个单例是进程级的）
        defer {
            PPTabRestoration.disable()
            PPTabRestoration.contentResolver = nil
        }

        MarkdownTabRestoration.install()

        XCTAssertTrue(PPTabRestoration.isEnabled)
        XCTAssertFalse(PPTabRestoration.persistenceKey.isEmpty)

        let directory = try makeTempDirectory()
        let url = try writeDocument("接线检查.md", content: "正文\n", in: directory)

        // 通过库的入口反查一次：证明装进去的确实是上面那个实现，而不是随便一个非 nil 闭包
        let item = PPTabRestoration.contentResolver?(url.path)
        XCTAssertEqual(item?.id, ExternalDocumentAccess.shared.canonicalPath(for: url))
        XCTAssertEqual(item?.body, "正文\n")
    }

    /// 只有「存档里有 Tab」时，列表才不该自动打开第一份。
    ///
    /// 判错两边的代价不一样：误判成 false 会当场开一份、把恢复入口挡掉（历史全丢）；
    /// 误判成 true 最多是右栏空着，用户点一下就打开了。所以脏数据一律按「没有」处理。
    func testWillRestoreOnlyWhenSnapshotHasTabs() {
        PPTabRestoration.enable(resolver: { _ in nil })
        let key = PPTabRestoration.persistenceKey
        let defaults = UserDefaults.standard
        let original = defaults.data(forKey: key)
        defer {
            // 用例可能跑在 App 的宿主进程里，别把用户真实的 Tab 存档弄丢
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            PPTabRestoration.disable()
            PPTabRestoration.contentResolver = nil
        }

        defaults.removeObject(forKey: key)
        XCTAssertFalse(MarkdownTabRestoration.willRestoreTabsOnLaunch, "没有存档时不该说「要恢复」")

        defaults.set(Data("这不是 JSON".utf8), forKey: key)
        XCTAssertFalse(MarkdownTabRestoration.willRestoreTabsOnLaunch, "存档解不开时按「没有历史」处理")

        defaults.set(Data(#"{"version":1,"tabs":[],"selectedIndex":0}"#.utf8), forKey: key)
        XCTAssertFalse(MarkdownTabRestoration.willRestoreTabsOnLaunch, "空数组也要当成没有历史")

        defaults.set(Data(#"{"version":1,"tabs":[{"id":"/tmp/a.md","isPreview":false}],"selectedIndex":0}"#.utf8),
                     forKey: key)
        XCTAssertTrue(MarkdownTabRestoration.willRestoreTabsOnLaunch)
    }
}
