# App Sandbox 下怎么打开容器外的磁盘文件

这个 App 的 Mac Catalyst 版本开了 App Sandbox。容器里的文件，比如

```
~/Library/Containers/com.yijian.mirror/Data/Documents/111.md
```

读写都很顺。容器外的文件，比如项目里的

```
/Users/pan/Project/iOSDemo/MarkdownEditorHy4/doc/Bear-table-render-edit-reverse-engineering.md
```

直接 `Data(contentsOf:)` 会报 `NSCocoaErrorDomain Code=257`。哪怕当前登录的 macOS 账号对这份文件有读写权限，沙盒这一层也会先把它拦住。

这份文档记录现在的处理方式。Mac Catalyst 上走系统选择器、security scope 和书签，让外部文件在重启之后还能从「最近」打开。iOS 上没法保存这种跨启动权限，打开外部文件时会先问一句要不要复制进 App。下面写的都是已经落在代码里的行为，涉及的入口和函数名可以直接在工程里搜到。

## 沙盒的限制到底在哪

沙盒 App 默认只能自由访问自己的容器。容器里的 `Documents` 就是 `DocumentsWorkspace.folderURL` 指向的位置，左侧「文档」页列的是它，新建文件也落在它里面。

用户主动递进来的文件属于例外。通过打开面板选中的文件、Finder 里双击或用「打开方式」交给 App 的文件、从「文件」App 送到 iOS 版的文件，系统会附带一份临时授权。App 可以对这份 URL 调

```swift
url.startAccessingSecurityScopedResource()
```

拿到这一次运行期间的访问权。用完之后要调 `stopAccessingSecurityScopedResource()` 归还。这份授权和进程绑定，App 退出就没了，下次启动还得重新向用户要。

Mac Catalyst 可以用 security-scoped bookmark 把授权存成一段数据。下次启动解析这段数据，系统会重新把访问权发下来，用户不用再选一次。iOS 上的 `URL.BookmarkCreationOptions.withSecurityScope` 不可用，所以 iOS 版没有这条跨启动的路。

项目里还有一个 QuickLook 扩展，它有自己的 `MarkdownQuicklookHy4/MarkdownQuicklookHy4.entitlements`，只申请了用户选中文件的只读权限。它和主 App 的权限配置是两份，本文主要讲主 App。

## 代码里的分工

文档文件的权限管理集中在 `MarkdownEditorHy4/ExternalDocumentAccess.swift`。打开、保存、列预览、解析书签都从这里走，避免申请和归还不成对。主题 JSON 是另一条路，`MarkdownThemeFileImport.palette(from:)` 读完就结束，自己申请、自己用 `defer` 归还，不需要把授权留到 App 退出。

### 两种 URL，各管一件事

`canonicalURL(for:)` 把系统可能给的「文件引用 URL」转成真实路径，再做标准化和符号链接解析。

文件引用 URL 长这样

```
file:///.file/id=6571367.12345
```

它的 `path` 不是磁盘上的真实路径，原样存进「最近」或书签，下次一定对不上。判断文件身份时，统一用 `canonicalURL` 的结果。书签和最近记录的 key 都是它的 `path`。

`accessURL(for:)` 只做 `filePathURL` 和标准化，不解析符号链接。读文件、写文件都用它返回的地址。

两个 URL 分开的原因在授权上。系统发的 security scope 是挂在用户选中的那个 URL 上的。如果先把路径解析成符号链接的目标，再对目标调 `startAccessingSecurityScopedResource()`，沙盒扩展可能根本不认这个新路径，申请会失败。所以申请权限用原始 URL，读写用 `accessURL`，身份判断才用 `canonicalURL`。

### 申请访问权的顺序

`readableURL(for:)` 是所有读写之前都会调的方法。它的顺序是

1. 文件在容器里，直接返回 `accessURL`，不需要授权。
2. 这次运行里已经申请过，返回 `activeURLs` 里记下的可读写 URL。
3. Mac Catalyst 上查有没有存过书签，能解析就解析并申请访问权。
4. 都没有，就对**原始 URL** 调 `startAccessingSecurityScopedResource()`。这一步负责打开面板和 Finder 刚递进来的文件。
5. 如果第 4 步返回 `false`，再试着直接读一次。Finder 打开事件有时会让这一步返回 `false`，但系统实际上已经放行，读一次文件才判断得准。

第 4 步拿到的授权会记进 `activeURLs`。真正调用过 `startAccessing` 的那个 URL 另存在 `scopedURLs` 里。退出时只对 `scopedURLs` 里的 URL 调 `stopAccessing`。申请时用的是原始地址，读写时用的是转过一道手的路径 URL，归还时把两者混用会出错。

授权一直保持到 App 退出。用户可能开着文档随时按 ⌘S，中途归还的话保存会失败。退出时由

```
AppDelegate.applicationWillTerminate
  → MarkdownDocumentOpener.stopAccessing()
  → ExternalDocumentAccess.stopAccessingAll()
```

统一归还。

### 书签存在哪

Mac Catalyst 上，第一次拿到某份外部文件的访问权时会生成 security-scoped bookmark，存进

```
Application Support/MarkdownEditorHy4/external-file-bookmarks.json
```

这个文件是 `[路径: Data]` 的 JSON。放 Application Support 而不放 Caches，因为 Caches 会被系统清理，书签丢了就得重新授权。

书签生成失败不会弹提示。这一次仍然能正常编辑，只是下次打开需要重新选一次。

解析书签时如果 `bookmarkDataIsStale` 为 `true`，说明文件被移动或改过名，旧书签过期了。代码会在拿到访问权之后重新生成一份，同时把新路径和旧路径都存一份。旧路径那一份是为了让「最近」里还没刷新的旧记录也能解析到新位置。等这份文档真正打开后，`DocumentOpening.open` 会把旧路径的记录删掉，换成新路径。

## 一条外部文档是怎么打开的

### 从 ⌘O 或「文件 > 打开…」

`MarkdownDocumentViewController.openDocumentFromPanel()` 弹的是

```swift
UIDocumentPickerViewController(forOpeningContentTypes: [markdownType, .plainText],
                              asCopy: false)
```

`asCopy: false` 表示原地打开，不复制副本，这样 ⌘S 才能写回原文件。选完文件之后，代理不直接读，交给 `MarkdownDocumentOpener.shared.handle(url:)`。

`MarkdownDocumentOpener.handle` 会先拦掉 `.json` 主题文件，再对原始 URL 调一次 `ExternalDocumentAccess.readableURL`。拿到访问权后，把规范化路径存进 `pendingURL`，再发 `.markdownDocumentOpenRequested` 通知。冷启动时界面还没建好，`pendingURL` 先攒着，等 `DocumentListViewController.openInitialDocumentIfNeeded()` 来取。

### 从 Finder 双击、打开方式、拖到 Dock 图标

这几条路走 `SceneDelegate.scene(_:openURLContexts:)` 和 `scene(_:willConnectTo:options:)`，AppDelegate 里还有一个 `application(_:open:options:)` 的兜底。它们最终都调 `MarkdownDocumentOpener.shared.handle(url:)`，和 ⌘O 汇到同一处。`Info.plist` 里已经声明了 Markdown 文档类型，系统才愿意把这类文件交给 App。

### 从左侧「文档」或「最近」点开

两页共用 `DocumentListViewController`，打开动作都走 `DocumentOpening.open`。这个方法先拿访问权，再当场把内容读出来。读成功才记「最近打开」，读失败就返回 `nil`，不会留下一条点开就报错的记录。

读到的内容交给路由开 Tab。内容项的 `id` 用规范化路径，左侧列表的行也用规范化路径，右边切 Tab 时高亮才能对上。

### 最近记录和外部文件

`RecentDocumentsStore` 存的也是规范化路径。判断一条记录还算不算数时，容器内的文件直接看文件在不在。容器外的文件只要还有书签就先留着，因为列表阶段没申请授权，直接 `fileExists` 也会返回 `false`，不能拿它当「文件已删除」。

列表里某一行的文件拿不到访问权时，第二行预览会显示「需要重新授权」，不会显示成「空文档」。点开这一行会弹出失败提示，Mac 上的提示会让用户用「文件 > 打开…」重新选一次，系统会重新授权。

从「最近」里删掉一行会同时清掉这份文件的书签。清空全部记录会清空所有书签。书签不跟着记录一起清的话，会留下一些用户看不见的长期授权。

### 保存

`MarkdownDocumentViewController+Save.swift` 在写回之前会再调一次 `readableURL`。这次运行里打开过的文件会命中 `activeURLs`，重启后打开的文件会走书签解析。拿不到权限时不会硬写，而是提示

> 「文件名」现在没有访问权限。
>
> 请重新打开这份文件，或者选择把它复制进 App。

## iOS 上先问要不要复制

iOS 版在 `DocumentListViewController.open` 里有一段只在非 Catalyst 编译的检查。文件不在容器里时，不直接打开，先弹选择框。标题是「这份文件在 App 外面」，正文说明复制和直接打开的区别，按钮有三个

- 「复制并打开」，默认高亮
- 「直接打开」
- 「取消」

选「复制并打开」时走 `copyExternalDocumentAndOpen`。它先拿到源文件的访问权，再调 `DocumentsWorkspace.importDocument(from:)`，用 `copyItem` 把文件复制进容器里的 `Documents`。重名时用 `uniqueFileURL(baseName:)` 自动加序号，比如「游记 2.md」。复制完成后，原路径的最近记录会被删掉，发一条目录变化通知，然后打开副本。副本从此就是一份普通的容器内文档，改名、删除、重启后打开都不再需要授权。

选「直接打开」时只借用这一次运行的临时权限。`Info.plist` 里 `LSSupportsOpeningDocumentsInPlace` 为 `true`，从「文件」App 原地打开的外部文件会走这个分支。App 退出后这份授权消失，下次启动时「最近」里对应的记录会因为文件不可见而在 `pruneMissingFiles()` 里被清掉。

## 权限配置

主 App 的 entitlements 在 `MarkdownEditorHy4/MarkdownEditorHy4.entitlements`

```xml
<key>com.apple.security.app-sandbox</key>
<true/>
<key>com.apple.security.files.user-selected.read-write</key>
<true/>
<key>com.apple.security.files.bookmarks.app-scope</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
<key>com.apple.security.network.server</key>
<true/>
```

其中两项和外部文件有关

- `com.apple.security.files.user-selected.read-write`，允许读写用户选中的文件。没有它，用户选了也读不了。
- `com.apple.security.files.bookmarks.app-scope`，允许保存 App 范围内的 security-scoped bookmark。没有它，重启后无法恢复。

这项配置只挂在 macOS 那份构建上。`project.pbxproj` 里写的是

```
"CODE_SIGN_ENTITLEMENTS[sdk=macosx*]" = MarkdownEditorHy4/MarkdownEditorHy4.entitlements;
```

iOS 版不会引用这个文件。iOS 的沙盒由系统统一管理，不需要这份 entitlements。

构建出 Catalyst 版本后，可以用下面这条命令确认权限真的签进去了

```bash
codesign -d --entitlements :- /path/to/MarkdownEditorHy4.app
```

## 怎么验证

Mac Catalyst

1. 用 ⌘O 选一份容器外的 `.md`，确认能在新 Tab 里打开。
2. 改几个字按 ⌘S，回到 Finder 确认原文件真的被改了。
3. 退出 App，重新启动，在左侧「最近」里点这一份，确认能直接打开，没有再让你选文件。
4. 打开 `~/Library/Containers/com.yijian.mirror/Data/Library/Application Support/MarkdownEditorHy4/external-file-bookmarks.json`，确认里面多了这条路径。
5. 在 Finder 里把这份文件改个名，再从「最近」点开，确认能解析到新位置，并且「最近」里的旧路径换成了新路径。

iOS

1. 在「文件」App 里长按一份 App 目录之外的 `.md`，选「共享」或「打开方式」，交给本 App。
2. 确认弹出「这份文件在 App 外面」的选择框。
3. 选「复制并打开」，确认左侧「文档」里出现了副本，编辑和保存都正常。
4. 完全退出 App 再启动，从「最近」打开这份副本，确认不需要再授权。

## 已知限制

**iOS 上跨启动的外部文件访问做不到。** 这是 iOS 平台本身的限制。用户选「直接打开」之后，这份文件只在本次运行里可用，重启后「最近」里的记录会被清理。需要长期编辑就选「复制并打开」。

**Mac 上被外部删掉的文件会留在「最近」里。** 只要书签还在，列表就认为这份文件可能还能解析。此时那一行显示「需要重新授权」，点开会报错。用户可以从右键菜单里把这行删掉。启动时不解析所有书签，是为了避免一启动就为几十份文件申请访问权。

**授权是按文件给的，不是按文件夹。** 在容器外的笔记里插入图片，图片默认写到笔记旁边的 `assets` 或同名文件夹，这些目录不在授权范围内，写入会失败。设置里的「指定路径」目前也只记了文件夹路径，没有保存书签，沙盒下同样写不进去。要让图片稳定落盘，可以把这份笔记复制进 App。把整个笔记库或者图片目录作为一个文件夹授权，是另一种设计，目前没有做。

**文件被移动到别的卷、或者原文件所在位置长期不可用时，书签会解析失败。** 这时同样会显示「需要重新授权」，用 ⌘O 重新选一次就能恢复。

**重装 App 或清空容器后，书签文件没了。** 之前记下的外部文件路径还在「最近」的 JSON 里也没用，因为没有对应的授权数据。重新选一次即可。

## 相关代码

| 文件 | 负责什么 |
| --- | --- |
| `MarkdownEditorHy4/ExternalDocumentAccess.swift` | 申请、保持、归还 security scope，保存和解析书签 |
| `MarkdownEditorHy4/MarkdownDocumentOpener.swift` | 接住 ⌘O、Finder、iOS 外部打开，冷启动暂存路径 |
| `MarkdownEditorHy4/DocumentOpening.swift` | 打开文档的统一入口，读内容、记最近、送路由 |
| `MarkdownEditorHy4/RecentDocumentsStore.swift` | 最近记录，外部文件的保留和清理 |
| `MarkdownEditorHy4/DocumentListViewController.swift` | 列表、搜索、排序、高亮，iOS 的复制选择框 |
| `MarkdownEditorHy4/DocumentsWorkspace.swift` | 容器内文档目录，复制外部文件进来 |
| `MarkdownEditorHy4/MarkdownDocumentViewController+Save.swift` | 保存前重新拿访问权 |
| `MarkdownEditorHy4/AppDelegate.swift` | 退出时归还所有授权 |
| `MarkdownEditorHy4/MarkdownEditorHy4.entitlements` | 主 App 的沙盒权限声明 |
| `MarkdownQuicklookHy4/MarkdownQuicklookHy4.entitlements` | QuickLook 扩展自己的只读权限 |
