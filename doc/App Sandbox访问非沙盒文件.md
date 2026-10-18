
Mac Catalyst 应用默认开启 **App Sandbox**。沙盒应用只能直接访问：

- 自己的容器（`~/Library/Containers/<bundle id>/Data/` 下，比如 `Documents`）
- 用户**明确授权**过的文件（通过打开面板、拖拽、"打开方式"等）
- Entitlements 里额外声明的目录

`/Users/xxx/Project/iOSDemo/222.md` 不在容器里，也没有授权，所以直接用路径 `Data(contentsOf:)` 会报 "没有权限"（`NSCocoaErrorDomain Code=257`）。即使你自己的账号对这个文件有读权限也一样，沙盒是在用户权限之上再加一层限制。

## 推荐做法：让用户选，并保存 security-scoped bookmark

对笔记 App 来说，这是最标准的方案。

### 1. 打开文件（或文件夹）

```swift
let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.plainText, UTType(filenameExtension: "md")!].compactMap { $0 })
picker.delegate = self
present(picker, animated: true)
```

笔记类 App 更常见的是**让用户选一个文件夹**作为笔记库，授权一次，整个目录树都能访问：

```swift
let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
```

### 2. 访问时开启 security scope

```swift
func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let url = urls.first else { return }

    guard url.startAccessingSecurityScopedResource() else { return }
    defer { url.stopAccessingSecurityScopedResource() }

    let text = try? String(contentsOf: url, encoding: .utf8)
    // 保存 bookmark（见下一步）
}
```

注意 `startAccessing` 和 `stopAccessing` 必须成对调用。如果是文件夹，需要在整个使用期间保持 access 打开，或者每次读写时包一层。

### 3. 保存 bookmark，下次启动免再选

```swift
// 保存。Catalyst 上用 .withSecurityScope
let data = try url.bookmarkData(options: .withSecurityScope,
                                includingResourceValuesForKeys: nil,
                                relativeTo: nil)
UserDefaults.standard.set(data, forKey: "libraryBookmark")

// 恢复
var isStale = false
let url = try URL(resolvingBookmarkData: data,
                  options: .withSecurityScope,
                  relativeTo: nil,
                  bookmarkDataIsStale: &isStale)
if isStale { /* 重新生成 bookmark 并保存 */ }
_ = url.startAccessingSecurityScopedResource()
```

Catalyst 上要用 `.withSecurityScope`（macOS 风格）。iOS 上这个选项不可用，需要用 `[]` 或 `.minimalBookmark`，所以如果工程同时编 iOS，要用 `#if targetEnvironment(macCatalyst)` 区分。

### 4. 打开 Entitlements 权限

在 Signing & Capabilities 的 App Sandbox 里勾选：

- **User Selected File: Read/Write**（`com.apple.security.files.user-selected.read-write`）：没有这项，用户选了也读不了
- 要持久访问还需要 `com.apple.security.files.bookmarks.app-scope`

## 其他方案对比

| 方案 | 适用 | 说明 |
| --- | --- | --- |
| 文件选择器 + bookmark | 绝大多数笔记 App | 推荐，合规，可上架 Mac App Store |
| 把文件**复制**进沙盒 | 导入式笔记 | 简单，但原文件和副本会不同步，不适合"直接编辑磁盘上的 md" |
| 使用 iCloud Drive 容器 | 需要多端同步 | 要配 iCloud 能力，文件在 iCloud 容器里 |
| 关闭 App Sandbox | 仅自用、不上架 | Catalyst 可以取消勾选 sandbox，就能随意访问，但无法上架 Mac App Store，也不推荐 |
| 加 `temporary-exception` 路径 | 不建议 | 能写死目录访问，但 App Store 审核基本会拒 |

## 补充几点

- 如果你想用 Finder 双击 md 或"打开方式"到你的 App，需要在 Info.plist 里声明 `CFBundleDocumentTypes` / `UTImportedTypeDeclarations` 支持 `.md`，系统传进来的 URL 自带临时授权，同样要用 `startAccessingSecurityScopedResource`。
- 如果是 Xcode 调试时的 `iOSDemo` 工程文件，用硬编码路径只能在你这台机器上调试时偶然生效，换环境就失效，建议统一走选择器流程。
- 想做外部编辑器同步（别的软件改了 md，笔记 App 自动刷新），可以对授权后的 URL 用 `NSFilePresenter` 或 `DispatchSource` 监听，同样需要在 scope 内。

如果你的产品形态是"用户指定一个笔记目录"，我可以帮你把"选目录 → 存 bookmark → 启动恢复 → 遍历 md 文件"这一套封装成一个 `LibraryAccess` 类。