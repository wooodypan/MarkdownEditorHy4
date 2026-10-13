//
//  DocumentRenameTests.swift
//  MarkdownEditorHy4Tests
//
//  左栏「重命名文档」这条链路的验收测试：文件真换了名字、内容一字不差、旁边那份不能跟着动、撞重名 / 空名字要报错而不是把文件搞丢。
//
//  ⚠️ 全部用**临时目录**里的假文件，绝不碰 App 沙盒里的 Documents 目录 ——那儿躺着用户自己的文档和那份示例。
//

import XCTest
@testable import MarkdownEditorHy4

@MainActor
final class DocumentRenameTests: XCTestCase {

    /// 造一个临时目录，并登记「跑完删掉它」
    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentRenameTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    /// 在临时目录里真写一份文档出来
    @discardableResult
    private func writeDocument(_ name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try "# 标题\n正文\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 改完名：新名字那份在、旧名字那份不在、内容一字不差
    func testRenameMovesFileAndKeepsContent() throws {
        let directory = try makeTempDirectory()
        let url = try writeDocument("旧名字.md", in: directory)

        let newURL = try DocumentListViewController().rename(url, toBaseName: "新名字")

        XCTAssertEqual(newURL.lastPathComponent, "新名字.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path), "改完名新文件不在")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "旧名字那份还留着 —— 等于凭空多出一份重复文件")
        XCTAssertEqual(DocumentsWorkspace.read(newURL), "# 标题\n正文\n", "改名把内容弄丢了")
    }

    /// 名字没变（用户在输入框里什么都没改就点了「好」）→ 文件留在原地，不白跑一趟移动
    func testRenameToSameNameKeepsFileInPlace() throws {
        let directory = try makeTempDirectory()
        let url = try writeDocument("笔记.md", in: directory)

        let newURL = try DocumentListViewController().rename(url, toBaseName: "笔记")

        XCTAssertEqual(newURL, url, "名字没变时不该真去移一次文件")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// 撞上重名要**抛错**，而且两份文件都不许被动过—— 悄悄覆盖掉别人那份是这个功能最容易出的严重事故
    func testRenameToExistingNameThrowsAndKeepsBothFiles() throws {
        let directory = try makeTempDirectory()
        let target = try writeDocument("甲.md", in: directory)
        let neighbour = try writeDocument("乙.md", in: directory)

        XCTAssertThrowsError(try DocumentListViewController().rename(target, toBaseName: "乙")) { error in
            XCTAssertEqual(error as? WorkspaceError, .nameTaken("乙"),
                           "期望是「名字被占用」，实际抛的是 \(error)")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path), "改不动名时旧文件不该消失")
        XCTAssertTrue(FileManager.default.fileExists(atPath: neighbour.path), "把别人那份覆盖了")
        XCTAssertEqual(DocumentsWorkspace.read(neighbour), "# 标题\n正文\n")
    }

    /// 空名字要抛错（用户把输入框清空了），文件也必须还在原地
    func testRenameWithEmptyNameThrows() throws {
        let directory = try makeTempDirectory()
        let url = try writeDocument("笔记.md", in: directory)

        XCTAssertThrowsError(try DocumentListViewController().rename(url, toBaseName: "   ")) { error in
            XCTAssertEqual(error as? WorkspaceError, .emptyName,
                           "期望是「名字不能空」，实际抛的是 \(error)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// 最近一次「文档改名」通知里报出来的旧 / 新路径
    private var reportedFrom: URL?
    private var reportedTo: URL?

    /// 收通知用的。用 selector 这种老写法而不是闭包版：闭包版在 Swift 6 下是 `@Sendable` 的，往测试用例自己的属性里写值会被并发检查拦下
    @objc private func captureRename(_ notification: Notification) {
        reportedFrom = notification.userInfo?[DocumentsWorkspace.renameFromURLKey] as? URL
        reportedTo = notification.userInfo?[DocumentsWorkspace.renameToURLKey] as? URL
    }

    /// ⚠️ 回归测试：改名必须把**新旧路径**报出去。
    ///
    /// 右侧要是正开着这份文档，它手里记的路径就是它 ⌘S 要写回的地方。不报的话它会继续往旧路径写 ——磁盘上凭空多出一份重复文件，而新名字那份反而是旧的。
    func testRenamePostsNotificationWithBothPaths() throws {
        let directory = try makeTempDirectory()
        let url = try writeDocument("旧名字.md", in: directory)

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(captureRename(_:)),
                                               name: DocumentsWorkspace.didRenameNotification,
                                               object: nil)
        // defer：断言失败提前退出时观察者也摘掉，免得影响后面别的用例
        defer { NotificationCenter.default.removeObserver(self) }

        let newURL = try DocumentListViewController().rename(url, toBaseName: "新名字")

        XCTAssertEqual(reportedFrom, url, "没把旧路径报出去，编辑页就换不过去")
        XCTAssertEqual(reportedTo, newURL)
    }
}
