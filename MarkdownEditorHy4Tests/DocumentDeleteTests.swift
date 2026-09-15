//
//  DocumentDeleteTests.swift
//  MarkdownEditorHy4Tests
//
//  左栏「删除文档」这条链路的验收测试：文件真被删掉了、删不存在的文件会报错、
//  只删点中的那一份、右键菜单里确实有「删除」那一项。
//
//  ⚠️ 全部用**临时目录**里的假文件，绝不碰 App 沙盒里的 Documents 目录 ——
//  那儿躺着用户自己的文档和那份示例。
//

import XCTest
@testable import MarkdownEditorHy4

@MainActor
final class DocumentDeleteTests: XCTestCase {

    /// 造一个临时目录，并登记「跑完删掉它」
    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentDeleteTests-\(UUID().uuidString)", isDirectory: true)
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

    /// 删完，文件就该从原来的位置消失
    func testDeleteRemovesFile() throws {
        let directory = try makeTempDirectory()
        let url = try writeDocument("待删除.md", in: directory)

        // ⚠️ putInTrashFirst 传 false：测试不想往用户的废纸篓里丢临时文件
        // （测试一次跑几十条，跑几轮废纸篓就堆满了）
        try DocumentsWorkspace.delete(url, putInTrashFirst: false)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "文件还在原地，删除没生效")
    }

    /// 删一个已经不存在的文件要**抛错**，界面才能提示「删不掉」。
    /// 不能默默当成功 —— 那用户会以为删了。
    func testDeleteMissingFileThrows() throws {
        let directory = try makeTempDirectory()
        let url = try writeDocument("待删除.md", in: directory)
        try DocumentsWorkspace.delete(url, putInTrashFirst: false)

        XCTAssertThrowsError(try DocumentsWorkspace.delete(url, putInTrashFirst: false)) { error in
            XCTAssertTrue(error is CocoaError, "期望是文件系统的错误，实际抛的是 \(error)")
        }
    }

    /// 「删除」只删掉指定那一份，旁边的文件不能连带遭殃
    func testDeleteLeavesNeighbourAlone() throws {
        let directory = try makeTempDirectory()
        let target = try writeDocument("甲.md", in: directory)
        let neighbour = try writeDocument("乙.md", in: directory)

        try DocumentsWorkspace.delete(target, putInTrashFirst: false)

        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: neighbour.path),
                      "把旁边那份也删了 —— 删错文件比删不掉严重得多")
    }

    /// 右键菜单里必须**有且只有**一项「删除」，而且是 destructive 样式
    /// （destructive 在界面上是红的，等于提前告诉用户「这一步不可逆」）
    func testDeleteMenuHasOneDestructiveAction() {
        let controller = DocumentListViewController()
        let menu = controller.deleteMenu(for: URL(fileURLWithPath: "/tmp/示例文档.md"))

        XCTAssertEqual(menu.children.count, 1, "右键菜单现在应该只有「删除」一项")

        let action = menu.children.first as? UIAction
        XCTAssertEqual(action?.title, "删除")
        XCTAssertTrue(action?.attributes.contains(.destructive) ?? false,
                      "「删除」该是 destructive，不然界面上不会显示成红色")
        XCTAssertEqual(menu.title, "示例文档",
                       "菜单标题该用文件名（去掉 .md），好让用户确认右键点的是哪一份")
    }
}
