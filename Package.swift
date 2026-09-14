// swift-tools-version:6.2
//
// 「MarkdownEditor」开源组件的包定义。
//
// ### 源码不挪窝
// target 的 path 直接指向仓库里的 MarkdownEditor/ 目录，App 工程（MarkdownEditorHy4）
// 继续用文件系统同步组编同一批文件，两边互不影响。
// 注意：**不要**把本包也加进 App 的 Xcode 工程依赖，否则同一批源码会被编两遍（符号重复）。
//
// ### 和 App 工程保持一致的编译行为
// - 语言模式 5（对应 App 工程的 SWIFT_VERSION = 5.0）
// - 所有类型默认 @MainActor（对应 App 工程的 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor）

import PackageDescription

let package = Package(
    name: "MarkdownEditor",
    platforms: [
        // TextKit 2 在 UITextView 里实际可用要到 iOS 16，这是组件的现实下限
        .iOS(.v16),
        .macCatalyst(.v16)
    ],
    products: [
        .library(name: "MarkdownEditor", targets: ["MarkdownEditor"])
    ],
    dependencies: [
        // Apple 官方 markdown 解析库（AST），版本跟 App 工程锁的 0.8.0 对齐
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.8.0")
    ],
    targets: [
        .target(
            name: "MarkdownEditor",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown")
            ],
            path: "MarkdownEditor",
            swiftSettings: [
                // 复刻 App 工程的全局设置：所有类型默认标 @MainActor
                .defaultIsolation(MainActor.self)
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
