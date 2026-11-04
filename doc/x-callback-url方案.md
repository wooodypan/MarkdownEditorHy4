# x-callback-url 方案

给「别的 App / 快捷指令 / 网页」一个入口，让它能打开、创建、追加、读取本 App 的笔记。协议照 Bear 的 x-callback-url 来，参数名尽量对齐，能少记一套。

## 1. URL 格式

```
xmark://x-callback-url/<action>?<参数>&x-success=<回调 URL>&x-error=<回调 URL>
```

- scheme 固定 `xmark`，是 `Info.plist` 的 `CFBundleURLTypes` 里注册的。
- `<action>` 只认四个：`open-note`、`create`、`add-text`、`read`。
- `x-success` / `x-error` 可选。不给就干完活悄悄结束，不回话。
- 也接受简写 `xmark://<action>?...`，省掉 `x-callback-url` 那一段，方便手敲和调试。两种写法行为完全一样。

参数一律 percent 编码（UTF-8）。空格写 `%20`，不要写 `+`（`+` 会被当成加号本身）。换行写 `%0A`。

## 2. 笔记怎么认（id）

`id` 是**相对 App 文档目录的路径**，扩展名可省。

| 写法 | 指向 |
| --- | --- |
| `id=收集箱.md` | `<Documents>/收集箱.md` |
| `id=日记/2026-11-04` | `<Documents>/日记/2026-11-04.md` |
| `id=%E6%97%A5%E8%AE%B0%2F2026-11-04.md` | 同上，编码后的另一种写法 |

规则：

- `/` 编不编码都认，解析时先整体 percent 解码一次。
- 不以 `/` 开头。带 `/` 开头按「绝对路径」拒绝，直接 `-1003`。
- 出现 `.`、`..` 或空的路径段 → `-1003`。
- 没有扩展名就补 `.md`；有扩展名但不是 `md / markdown / mdown / mkd / mdwn / mdtext / mdtxt / txt` 之一 → `-1003`。
- 拼出来的路径必须落在文档目录里面，校验用规范化路径（`/var` 和 `/private/var` 这种同义写法要抹平），越界 → `-1003`。
- `x-success` 里的 `identifier` 就是把绝对路径换算回这个相对路径，调用方存下来下次接着用。

## 3. 动作

### 3.1 open-note

打开一份已有笔记。

| 参数 | 必填 | 默认 | 说明 |
| --- | --- | --- | --- |
| `id` | 是 | - | 见上一节 |
| `mode` | 否 | `tab` | `tab` 开一个正式 Tab；`preview` 用预览位 |
| `edit` | 否 | `no` | `yes` 时把光标放进正文 |

`x-success` 参数：

| 字段 | 说明 |
| --- | --- |
| `identifier` | 相对路径 |
| `title` | 文件名去掉扩展名 |
| `path` | 绝对路径 |
| `modified` | 修改时间，ISO 8601 |

笔记已经开在某个 Tab 里时不会重复开，宿主会自动定位到那个 Tab。

### 3.2 create

新建一份笔记，落盘之后再决定要不要打开。

| 参数 | 必填 | 默认 | 说明 |
| --- | --- | --- | --- |
| `title` | 否 | `未命名` | 会做文件名清洗；重名自动变成「标题 2」 |
| `text` | 否 | 空 | 正文，换行写 `%0A` |
| `folder` | 否 | 根目录 | 相对子目录，不存在就一层层建出来 |
| `open` | 否 | `yes` | `no` 时只落盘，不切窗口 |

`x-success` 参数：`identifier`、`title`、`path`、`modified`。

注意：这里**不会**把新文档登记成「刚新建、还没起名字」。登记了的话用户第一次按 ⌘S 会被追问文件名，而这份笔记明明已经有名字了。

### 3.3 add-text

往指定笔记里写内容。

| 参数 | 必填 | 默认 | 说明 |
| --- | --- | --- | --- |
| `id` | 是 | - | 目标笔记 |
| `text` | 是 | - | 要写进去的文本，不能是空串 |
| `mode` | 否 | `append` | `append` 末尾追加 / `prepend` 开头插入 / `replace_all` 整篇替换 |
| `open` | 否 | `no` | `yes` 时把这篇笔记凑到前台 |

追加和插入会自动补一个换行，不会把内容粘在上一行的尾巴上。

`x-success` 参数：`identifier`、`title`、`path`、`modified`、`length`（写完后的字符数）。

笔记正开着的时候，写盘之后会把新内容刷进编辑器，用户不会看到一份旧内容然后一按 ⌘S 把刚写进去的东西覆盖掉。刷新会清掉撤销栈，这是刻意的取舍。

### 3.4 read

把正文读出来给调用方。

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `id` | 是 | 要读的笔记 |

`x-success` 参数：

| 字段 | 说明 |
| --- | --- |
| `identifier` / `title` / `path` / `modified` | 同 open-note |
| `note` | 正文 |
| `truncated` | 只有正文超过 10 万个字符时才出现，值是 `yes` |
| `unsaved` | 只有这份笔记正开着、且编辑器里有未保存的修改时才出现，值是 `yes` |

读的永远是磁盘上的内容。`unsaved=yes` 是在提醒调用方「你读到的不是用户屏幕上那一版」。

## 4. 回调约定

- 动作真正做完之后才发 `x-success`。写盘是同步的，所以只有「冲突提示等用户点按钮」那一条路是异步的。
- 出错只发 `x-error`，不会再发 `x-success`。
- 回调 URL 用 `UIApplication.open` 打开，参数以 query 形式追加到调用方给的地址后面。
- 调用方给的地址本身带 query 也能正确处理，参数是追加不是覆盖。
- 回调发不出去（地址不合法）就静默放弃，不弹任何提示。

## 5. 错误码

| code | 名字 | 什么情况 |
| --- | --- | --- |
| -1001 | `note_not_found` | 笔记不存在，或者读不出来 |
| -1002 | 保留 | 预留给「按标题查找」，本期没实现 |
| -1003 | `invalid_param` | 缺参数、`id` 为空或越界、`mode` 不认识、动作名不认识 |
| -1004 | `permission_denied` | 文件在容器外，拿不到访问权限 |
| -1005 | `note_busy` | 笔记有未保存修改，但当时没法弹框确认；或者用户选了保存、保存却失败了 |
| -1006 | `write_failed` | 写盘失败 |
| -1007 | `canceled` | 用户在冲突提示里点了取消 |

`x-error` 固定带两个参数：`error-code`（数字，字符串形式）、`error-message`（中文说明）。

## 6. 冲突处理

`add-text` 命中一份**正开着、而且有未保存修改**的笔记时：

1. 先不写盘，弹一个确认框：「《笔记名》有未保存的修改 / 一个外部请求要往这份笔记里写内容。先保存当前的修改，再写进去？」
2. 选「保存并写入」→ 对那个编辑器执行一次保存 → 再写盘 → 刷新编辑器 → 回 `x-success`。保存失败回 `-1005`。
3. 选「取消」→ 回 `-1007`，磁盘一个字节都不动。
4. 当时已经有别的弹窗挡着、弹不出确认框 → 直接回 `-1005`，让调用方去提示用户。

笔记开着但**没有**未保存修改时不用问，写盘后直接刷新编辑器就行。

## 7. 实现结构

### 新增文件

三个文件都放在 `MarkdownEditorHy4/x-callback-url/` 这个新目录里，跟 `Setting/` 一样按功能分堆，不跟根目录那几十个文件挤在一起。工程用的是「文件夹同步」，新建目录、往里挪文件都不用改 `project.pbxproj`。

| 文件 | 职责 |
| --- | --- |
| `MarkdownEditorHy4/x-callback-url/MarkdownCallbackURL.swift` | URL 解析、动作分发用的参数容器、错误类型、id 到路径的换算。纯逻辑，不碰界面 |
| `MarkdownEditorHy4/x-callback-url/MarkdownCallbackCenter.swift` | 四个动作的执行、请求排队、冲突弹框、拼回调 URL 并打开 |
| `MarkdownEditorHy4/x-callback-url/MarkdownDocumentRegistry.swift` | 「打开中的编辑器」弱引用表，key 是规范化路径 |

### 改动文件

| 文件 | 改什么 |
| --- | --- |
| `MarkdownEditorHy4/Info.plist` | 加 `CFBundleURLTypes`，注册 `xmark` |
| `MarkdownEditorHy4/SceneDelegate.swift` | 建好工作区之后把路由和根控制器交给回调中心；URL 分流时先问回调中心认不认 |
| `MarkdownEditorHy4/AppDelegate.swift` | 两条兜底路径（`application(_:open:options:)`、冷启动 `launchOptions[.url]`）同样先问回调中心 |
| `MarkdownEditorHy4/MarkdownDocumentViewController+DocumentContent.swift` | 装文档、改名的三处把控制器登记进弱引用表 |

### 为什么要有那张弱引用表

宿主只公开了「当前选中项」，没有「按 id 取控制器」的接口。要判断「这份笔记是不是正开着、脏不脏」，还要在写完之后刷新它，就必须自己攥一份登记。改成弱引用，控制器被回收时条目自然失效，不用写 deinit 去注销。

## 8. 边界与坑

| 坑 | 说明 |
| --- | --- |
| iOS 上只能操作 App 自己目录里的文件 | URL 里传得了路径，传不了安全作用域的授权。容器外的文件一律 `-1004` |
| Mac 上外部目录要看以前有没有授权 | 只有用户曾经用打开面板选过、留下书签的目录能写，否则同样 `-1004` |
| 冷启动时 URL 比界面先到 | 回调中心先排队，等 `SceneDelegate` 把路由和根控制器交过来再执行 |
| 网页也能触发这个协议 | 任意网页可以往笔记里灌内容。这一期靠「只能操作容器内文件」兜底，没有 token |
| 改 scheme 要重装 App | LaunchServices 会缓存，只改 `Info.plist` 不重装，旧 scheme 还在、新的不生效 |
| iPhone 上打开是 push | 连续调 `open-note` 会叠好几页。iPad / Mac 是 Tab，没这个问题 |
| 追加后刷新会清撤销栈 | `apply` 对同一份文档刻意不清撤销栈，所以刷新前手动清一次，避免 ⌘Z 恢复出半新半旧的内容 |
| 参数里带 `&` `#` `%` | 只按第一个 `&` 切参数，值整体 percent 解码一次，不再解第二次 |

## 9. 自测

命令行直接发（App 得先跑起来）：

```bash
open 'xmark://x-callback-url/create?title=%E6%B5%8B%E8%AF%95&text=hello'

open 'xmark://x-callback-url/add-text?id=%E6%B5%8B%E8%AF%95.md&text=world&mode=append'

open 'xmark://x-callback-url/open-note?id=%E6%B5%8B%E8%AF%95.md'

open 'xmark://x-callback-url/read?id=%E6%B5%8B%E8%AF%95.md'
```

验证清单：

1. `create` 之后左栏立刻多一行，文件真的在 `Documents` 里。
2. `add-text` 之后用 `open` 打开笔记，内容在末尾，和上一行之间有换行。
3. 笔记开着、编辑器里改一个字不保存，再 `add-text` → 弹确认框；点取消，磁盘内容不变。
4. 同上，点「保存并写入」→ 编辑器里的修改先落盘，追加内容出现在末尾。
5. `read` 拿到的 `note` 和磁盘一致；超长文档有 `truncated=yes`。
6. 给一个不存在的 `id` → 收到 `-1001`；给 `id=../x.md` → 收到 `-1003`。
7. 带 `x-success=https://example.com/ok` 调 `read`，回调地址上能看到参数。
