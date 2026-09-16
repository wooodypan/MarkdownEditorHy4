//
//  DocumentSaveAsTests.swift
//  MarkdownEditorHy4Tests
//
//  「新建的文档第一次按 ⌘S，弹框问名字再存」这条链路的验收测试。
//
//  拆成两层看：
//  1. **判据层**（`DocumentsWorkspace`）：这个名字算不算占位名、用户敲进来的字
//     能不能当文件名、改名会不会误伤别人 —— 这几条是真会出错的地方；
//  2. **动作层**（`MarkdownDocumentViewController.save(from:as:)`）：改名 + 写盘 +
//     本页从此认新路径，整条串起来跑一遍。
//
//  ⚠️ 全部用**临时目录**里的假文件，绝不碰 App 沙盒里的 Documents 目录 ——
//  那儿躺着用户自己的文档和那份示例。
//

import XCTest
import MultiTabController
@testable import MarkdownEditorHy4

@MainActor
final class DocumentSaveAsTests: XCTestCase {

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentSaveAsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    @discardableResult
    private func writeDocument(_ name: String, content: String = "", in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - 判据：这个名字算不算「占位名」

    /// 「未命名」「未命名 2」都该被认成占位名 —— 前者是第一次新建，后者是连着新建
    func testUntitledRecognizesPlaceholderNames() {
        for name in ["未命名.md", "未命名 2.md", "未命名 12.md"] {
            XCTAssertTrue(DocumentsWorkspace.isUntitled(URL(fileURLWithPath: "/tmp/\(name)")),
                          "「\(name)」是新建时系统给的占位名，该问用户要名字")
        }
    }

    /// 用户自己起的名字不能被当占位名，否则每按一次 ⌘S 都弹框，烦死人
    func testUntitledIgnoresRealNames() {
        for name in ["笔记.md", "未命名abc.md", "未命名 2 副本.md", "memo.md", "未命名x.md"] {
            XCTAssertFalse(DocumentsWorkspace.isUntitled(URL(fileURLWithPath: "/tmp/\(name)")),
                           "「\(name)」是正经名字，不该再弹框问")
        }
    }

    // MARK: - 判据：用户敲的字能不能当文件名

    /// 用户是随手输的，这里得宽容：空白、顺手打的后缀、非法字符都要收拾掉
    func testSanitizedFileNameCleansUserInput() {
        // 前后空白
        XCTAssertEqual(DocumentsWorkspace.sanitizedFileName("  我的笔记  "), "我的笔记")
        // 顺手把后缀也打上了
        XCTAssertEqual(DocumentsWorkspace.sanitizedFileName("我的笔记.md"), "我的笔记")
        XCTAssertEqual(DocumentsWorkspace.sanitizedFileName("我的笔记.MD"), "我的笔记")
        // 后缀和空白叠在一起
        XCTAssertEqual(DocumentsWorkspace.sanitizedFileName("我的笔记 .md"), "我的笔记")
        // Mac 文件名里不合法的两个字符换掉，而不是报错把用户打回去
        XCTAssertEqual(DocumentsWorkspace.sanitizedFileName("2026/09/16"), "2026-09-16")
        XCTAssertEqual(DocumentsWorkspace.sanitizedFileName("a:b"), "a-b")
        // 开头的点会变成隐藏文件，去掉
        XCTAssertEqual(DocumentsWorkspace.sanitizedFileName(".hidden"), "hidden")
        // 中间的点是正经内容，不许动（`deletingPathExtension` 会把 v2 当扩展名吃掉）
        XCTAssertEqual(DocumentsWorkspace.sanitizedFileName("设计稿 v2.1"), "设计稿 v2.1")
    }

    /// 全是空白 / 点号的名字，收拾完应该是空的，好让上层拦下来
    func testSanitizedFileNameCanEndUpEmpty() {
        XCTAssertEqual(DocumentsWorkspace.sanitizedFileName("   "), "")
        XCTAssertEqual(DocumentsWorkspace.sanitizedFileName("..."), "")
        XCTAssertEqual(DocumentsWorkspace.sanitizedFileName(".md"), "")
    }

    // MARK: - 动作：改名

    /// 改名之后：新名字在、旧名字没了、内容一字不差跟着走
    func testRenameMovesFileAndKeepsContent() throws {
        let directory = try makeTempDirectory()
        let url = try writeDocument("未命名.md", content: "# 草稿\n正文\n", in: directory)

        let newURL = try DocumentsWorkspace.rename(url, toBaseName: "我的笔记")

        XCTAssertEqual(newURL.lastPathComponent, "我的笔记.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "旧名字还占着")
        XCTAssertEqual(try String(contentsOf: newURL, encoding: .utf8), "# 草稿\n正文\n",
                       "改完名内容对不上 —— 改名把用户写的东西弄丢了")
    }

    /// 用户敲进 `.md` 时不能变成 `笔记.md.md`
    func testRenameAppendsExtensionOnlyOnce() throws {
        let directory = try makeTempDirectory()
        let url = try writeDocument("未命名.md", in: directory)

        let newURL = try DocumentsWorkspace.rename(url, toBaseName: "笔记.md")

        XCTAssertEqual(newURL.lastPathComponent, "笔记.md")
    }

    /// 名字没变（用户直接点了「保存」，接受了「未命名」）→ 原地不动，也不报错
    func testRenameToSameNameIsNoOp() throws {
        let directory = try makeTempDirectory()
        let url = try writeDocument("未命名.md", content: "x", in: directory)

        let newURL = try DocumentsWorkspace.rename(url, toBaseName: "未命名")

        XCTAssertEqual(newURL.path, url.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// ⚠️ 最重要的一条：**重名时必须报错，绝不能把别人那份覆盖掉**。
    /// 用户以为在「另存」，结果抹掉了已有文档，是这个功能最容易出的严重事故。
    func testRenameRefusesExistingName() throws {
        let directory = try makeTempDirectory()
        let source = try writeDocument("未命名.md", content: "新的内容", in: directory)
        let existing = try writeDocument("笔记.md", content: "原有的重要内容", in: directory)

        XCTAssertThrowsError(try DocumentsWorkspace.rename(source, toBaseName: "笔记")) { error in
            XCTAssertEqual(error as? WorkspaceError, .nameTaken("笔记"))
        }

        // 两份文件都还在，而且谁的内容都没被换掉
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "原有的重要内容",
                       "把已有文档的内容覆盖了 —— 这是数据事故")
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "新的内容",
                       "名字被占用时不该动原文件")
    }

    /// 空名字要抛错，让界面提示「名字不能是空的」，而不是建出一个 `.md` 来
    func testRenameRefusesEmptyName() throws {
        let directory = try makeTempDirectory()
        let url = try writeDocument("未命名.md", in: directory)

        XCTAssertThrowsError(try DocumentsWorkspace.rename(url, toBaseName: "   ")) { error in
            XCTAssertEqual(error as? WorkspaceError, WorkspaceError.emptyName)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "报错之后原文件该还在")
    }

    /// 错误话术是直接显示给用户看的，不能出现英文系统错误的痕迹
    func testWorkspaceErrorMessagesAreReadable() {
        XCTAssertTrue(WorkspaceError.emptyName.localizedDescription.contains("名字"))
        XCTAssertTrue(WorkspaceError.nameTaken("笔记").localizedDescription.contains("笔记"),
                      "重名提示里该带上撞的那个名字，用户才知道换成什么")
    }

    // MARK: - 动作：内容页这一层

    /// 把一份「未命名.md」装进内容页，返回这个页面
    private func makeLoadedController(for url: URL, body: String) -> MarkdownDocumentViewController {
        let controller = MarkdownDocumentViewController()
        // 触发 viewDidLoad：宿主也是先创建、后配置的，这里照那个顺序来
        _ = controller.view
        controller.configure(with: PPContentItem(id: url.path,
                                                 title: DocumentsWorkspace.displayName(for: url),
                                                 body: body,
                                                 category: "Documents"))
        return controller
    }

    /// 新建出来的文档，⌘S 该走「先问名字」那条路
    func testUntitledDocumentAsksForFileNameBeforeSaving() throws {
        let directory = try makeTempDirectory()
        let url = try writeDocument("未命名.md", in: directory)
        let controller = makeLoadedController(for: url, body: "")

        XCTAssertTrue(controller.needsFileNameBeforeSaving,
                      "新建的文档按 ⌘S 应该先弹框问名字，不能直接存成「未命名.md」")
    }

    /// 起过名字的文档，⌘S 直接写回，不再打扰
    func testNamedDocumentSavesDirectly() throws {
        let directory = try makeTempDirectory()
        let url = try writeDocument("笔记.md", content: "# 笔记\n", in: directory)
        let controller = makeLoadedController(for: url, body: "# 笔记\n")

        XCTAssertFalse(controller.needsFileNameBeforeSaving,
                       "已经有正经名字了还弹框，等于每存一次烦一次")
    }

    /// 起名保存：文件改名 + 内容写进新文件 + 这一页从此认新路径
    func testSaveAsRenamesAndWritesContent() throws {
        let directory = try makeTempDirectory()
        let url = try writeDocument("未命名.md", in: directory)
        let controller = makeLoadedController(for: url, body: "写进去的内容")
        // 直接模拟「用户输入了名字，点了保存」那一步
        let newURL = controller.save(from: url, as: "我的笔记")

        XCTAssertEqual(newURL?.lastPathComponent, "我的笔记.md")
        XCTAssertEqual(try String(contentsOf: try XCTUnwrap(newURL), encoding: .utf8), "写进去的内容",
                       "改名之后内容没写进新文件")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "旧占位文件该没了")

        // 这一页从此认新路径：再按 ⌘S 不该又弹框
        XCTAssertFalse(controller.needsFileNameBeforeSaving,
                       "存完名字后这一页还认为自己是未命名 —— 下次 ⌘S 会白弹一次框")
    }

    /// 重名被打回来时：回 nil、不写盘、两份文件都完好（用户换个名字就能接着存）
    func testSaveAsReportsFailureOnTakenName() throws {
        let directory = try makeTempDirectory()
        let url = try writeDocument("未命名.md", in: directory)
        try writeDocument("笔记.md", content: "别人写的", in: directory)
        let controller = makeLoadedController(for: url, body: "我的内容")

        let result = controller.save(from: url, as: "笔记")

        XCTAssertNil(result, "重名了该回 nil，让界面提示用户换名字")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "",
                       "失败时不该往原文件里写东西")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("笔记.md"),
                                  encoding: .utf8), "别人写的")
        // 名字没改成，下次 ⌘S 还是该问
        XCTAssertTrue(controller.needsFileNameBeforeSaving)
    }
}
