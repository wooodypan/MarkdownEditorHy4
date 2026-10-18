//
//  MarkdownEditorHy4UITestsLaunchTests.swift
//  MarkdownEditorHy4UITests
//
//  Created by pan on 2026/8/31.
//

import XCTest

final class MarkdownEditorHy4UITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        // 不要切换到深色模式。这个开关会让 Xcode 针对「target App 的每种界面配置」各跑一遍 testLaunch()；在 iOS 上，这相当于切换模拟器的浅色与深色外观；在 Mac Catalyst 上，则会直接把你的 Mac 系统外观切成深色，跑完再切回来。因此现象是屏幕闪一下、整个桌面变深，然后恢复。
        false
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launch()

        // Insert steps here to perform after app launch but before taking a screenshot,
        // such as logging into a test account or navigating somewhere in the app

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
