//
//  SandboxWorkspaceTests.swift
//  MarkdownEditorHy4Tests
//
//  守住一条底线：**文档目录必须是 App 自己容器里的，不能是用户真实的「文稿」目录。**
//
//  背景：Mac Catalyst 上的沙盒是「选入式」的 —— 靠 project.pbxproj 里那条
//  `CODE_SIGN_ENTITLEMENTS[sdk=macosx*]` 挂上 entitlements 才生效。
//  哪天有人把这条设置删了（或者新建 target 时忘了抄），App 表面上一切正常，
//  实际上新建的每一份文档都会落进 /Users/<用户名>/Documents/ —— 用户自己的文稿堆里。
//  这种回归编译期看不出来，只能靠这里断言。
//
//  ⚠️ 这些用例**只读路径 + 只在确认过「已经在容器里」之后才写文件**，
//  绝不会往用户真实的文稿目录里写东西。
//

import XCTest
@testable import MarkdownEditorHy4

@MainActor
final class SandboxWorkspaceTests: XCTestCase {

    /// 文档目录是不是落在 App 容器里。
    ///
    /// - Mac（含 Catalyst）开了沙盒：`~/Library/Containers/<bundle id>/Data/Documents`
    /// - Mac 没开沙盒：`~/Documents` ← 就是我们要防的那种情况
    private var workspaceIsSandboxed: Bool {
        DocumentsWorkspace.folderURL.path.contains("/Library/Containers/")
    }

    /// Catalyst 上文档目录必须在容器里
    func testWorkspaceFolderStaysInsideAppContainer() throws {
        let path = DocumentsWorkspace.folderURL.path

        #if targetEnvironment(macCatalyst)
        XCTAssertTrue(workspaceIsSandboxed,
                      "Mac 上的文档目录跑到了容器外面：\(path)\n"
                      + "说明 App Sandbox 没生效 —— 去查 project.pbxproj 里 "
                      + "CODE_SIGN_ENTITLEMENTS[sdk=macosx*] 和 MarkdownEditorHy4.entitlements 还在不在。")
        #else
        // iOS 的沙盒是系统强制的，容器路径长这样：
        //   /var/mobile/Containers/Data/Application/<UUID>/Documents
        // 这里只确认「目录取得到、不是空的」，具体形状交给系统保证
        XCTAssertFalse(path.isEmpty)
        #endif
    }

    /// 容器里能正常读写、能删干净（走的是 App 真正用的那套 API）
    func testWorkspaceIsReadWriteInsideContainer() throws {
        // 没开沙盒就直接跳过：这时候写文件会写进用户的真实文稿目录，测试不干这种事
        try XCTSkipUnless(workspaceIsSandboxed,
                          "当前不在沙盒里，跳过 —— 免得往用户真实的文稿目录里写测试文件")

        // 1. 新建（createEmptyDocument 会在文档目录里造一份 `未命名.md`）
        let url = try DocumentsWorkspace.createEmptyDocument()
        defer {
            // 不管断言过不过，都把这个临时产物清掉（putInTrashFirst: false ——
            // 别往用户废纸篓里丢东西）
            try? DocumentsWorkspace.delete(url, putInTrashFirst: false)
        }

        XCTAssertTrue(url.path.contains("/Library/Containers/"),
                      "新建的文件没落在容器里：\(url.path)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "新建完磁盘上没有这个文件")

        // 2. 写进去 / 再读出来
        try DocumentsWorkspace.write("# 沙盒自检\n", to: url)
        XCTAssertEqual(DocumentsWorkspace.read(url), "# 沙盒自检\n",
                       "写进去的内容读回来对不上")

        // 3. 删掉
        try DocumentsWorkspace.delete(url, putInTrashFirst: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "删完文件还在")
    }

    /// 在**真实的容器目录**里走一遍「新建 → 起名字」。
    ///
    /// 临时目录里改名能成，不代表沙盒里也能成 —— 沙盒对文件操作有一套自己的
    /// 约束（能不能移动、能不能改后缀）。这条用例走的就是用户按 ⌘S 起名时的
    /// 那条路，只是名字换成不会撞车的自检名。
    func testRenameWorksInsideContainer() throws {
        try XCTSkipUnless(workspaceIsSandboxed,
                          "当前不在沙盒里，跳过 —— 免得往用户真实的文稿目录里写测试文件")

        let url = try DocumentsWorkspace.createEmptyDocument()
        // 用 UUID 尾巴当名字：容器里可能躺着用户自己的文档和那份示例，别撞上
        let name = "沙盒自检-\(UUID().uuidString.prefix(8))"
        var renamed: URL?
        defer {
            // 不管断言过不过，两个可能的位置都清一遍（putInTrashFirst: false ——
            // 别往用户废纸篓里丢东西）
            try? DocumentsWorkspace.delete(url, putInTrashFirst: false)
            if let renamed { try? DocumentsWorkspace.delete(renamed, putInTrashFirst: false) }
        }

        XCTAssertTrue(DocumentsWorkspace.isUntitled(url),
                      "新建出来的该是占位名，不然 ⌘S 不会问用户要名字")

        renamed = try DocumentsWorkspace.rename(url, toBaseName: name)
        let newURL = try XCTUnwrap(renamed)

        XCTAssertEqual(newURL.lastPathComponent, "\(name).md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "旧占位名还占着")
        XCTAssertTrue(newURL.path.contains("/Library/Containers/"),
                      "改完名跑到容器外面去了：\(newURL.path)")
        XCTAssertFalse(DocumentsWorkspace.isUntitled(newURL),
                       "起过名字了还被当成未命名 —— 下次 ⌘S 会白弹一次框")
        XCTAssertTrue(DocumentsWorkspace.documentURLs().contains(newURL),
                      "改完名的文件该能被左侧栏列出来")
    }

}
