这份文档给没用过 GitHub Actions 的人看。读完之后你会做三件事：看懂本项目的那个配置文件在干什么，用一条命令让 GitHub 替你把 Mac Catalyst 版编出来，在网页上下到编好的 zip。

前提只有两个：代码已经推到 GitHub 上，本机装了 git。不需要 Apple 开发者账号，也不需要证书。

新手最容易卡在三处，先记一下：推 main 分支不会触发（要打标签）、下载的包第一次打开会被系统拦一下、Actions 里的产物 90 天后过期。

## GitHub Actions 是什么

一句话：GitHub 免费借你一台电脑，跑你在配置文件里写好的命令，跑完就把这台电脑销毁。

平时你编这个项目，用的是自己这台 Mac、自己的 Xcode、自己装的一堆东西。换台机器就得重来一遍。GitHub Actions 把这件事挪到云上：你推一次代码或者打一个标签，GitHub 临时开一台干净的 Mac，把工程拉下来、装好依赖、执行编译，然后把编出来的东西交给你，最后把机器删掉。每次跑都是同一台干净机器、同一个 Xcode 版本，不会出现「我这儿能编，你那儿编不了」。

配置就是一个放在 `.github/workflows/` 目录里的 YAML 文件。本项目只有一个：`.github/workflows/macos-catalyst.yml`。

## 先认五个名词

| 名词 | 说白了是什么 | 本项目里是谁 |
| --- | --- | --- |
| workflow（工作流） | 一整个 YAML 文件，描述「什么时候、干什么」 | `macos-catalyst.yml` |
| 触发条件（`on:`） | 什么情况下开始跑 | 推 `v*` 标签时，或在网页上手动点 |
| job（任务） | 工作流里的一段活，各自在一台独立机器上跑 | `build`（编译）和 `release`（发版） |
| step（步骤） | 任务里的一条条命令，从上到下顺序执行 | `build` 里那 7 条 |
| runner（运行器） | 干活的那台机器，按系统选 | `macos-26` 和 `ubuntu-latest` |

运行器这一行（`runs-on:`）写的就是要哪种机器。`macos-26` 是 GitHub 现在最新的 macOS 镜像，上面装的是 Xcode 26，能编 Catalyst。

## 本项目这个文件在干什么

### 什么时候跑

```yaml
on:
  push:
    tags: ["v*"]        # 只认标签，推 main 不触发
  workflow_dispatch:    # 保留网页上的手动按钮
```

推 main 分支不跑，只有打形如 `v1.0.0` 的标签才跑。这样做是因为这台 macOS 机器很贵也慢，改一个错别字不值得等它三分钟。临时想试，可以在仓库 Actions 页面选这个工作流，点右边的 Run workflow 手动触发。

### 一次出三个包

`build` 任务用了矩阵：写一份配置，让 GitHub 并行开三台机器各编一遍，只把架构参数换掉。

| 变体 | 编译参数 | 产物 |
| --- | --- | --- |
| Universal | `ARCHS="arm64 x86_64"` | `MarkdownEditorHy4-universal.zip` |
| Arm64 | `ARCHS="arm64"` | `MarkdownEditorHy4-arm64.zip` |
| x86_64 | `ARCHS="x86_64"` | `MarkdownEditorHy4-x86_64.zip` |

arm64 是 Apple 芯片的 Mac，x86_64 是 Intel 芯片的 Mac。合体包两个架构各带一份代码，体积差不多是单架构包的两倍：实测合体约 17MB，单架构各约 11MB。知道对方机器类型时发单架构包更省。

编译那条命令里几个参数的意思：

```
CODE_SIGN_IDENTITY="-"      用临时签名（ad-hoc），不碰任何证书
CODE_SIGNING_REQUIRED=NO    不要求有效证书
ARCHS="..."                 要编哪些架构
ONLY_ACTIVE_ARCH=NO         不许偷懒只编本机架构
-derivedDataPath build      中间产物放哪儿（缓存也认这个路径）
```

### build 的七个步骤

1. `actions/checkout@v4` —— 把仓库代码拉到这台机器上。
2. 挑一个装了的最新的 Xcode —— 镜像里并排装了好几个 Xcode，默认那个不一定最新，这步按版本号挑最新的，并排掉 beta 预览版。
3. `actions/cache@v4` —— 缓存下载好的 Swift 包，key 跟 `Package.resolved` 的哈希走，依赖没变就直接复用。
4. 编译 —— 就是上面那条 `xcodebuild` 命令。
5. 自检产物 —— 打印架构和签名权限，参数写错时当场看出来，别等下载完才发现不对。
6. `ditto` 压成 zip —— 不用 `zip` 命令，因为 `ditto` 能保住 App 包里的符号链接。
7. `actions/upload-artifact@v4` —— 把 zip 传上去，在 Actions 页面对应这次运行的底部能下载。

### release 任务：打标签时顺便发版

`release` 只在打标签时跑（`if: startsWith(github.ref, 'refs/tags/')`），而且必须等 `build` 三个变体全部成功（`needs: build`）。它把三个 zip 收下来，一次挂到仓库的 Releases 页面上。

这里分成两个任务是有原因的。三个矩阵任务是并行跑的，如果让它们各自去创建 Release，会同时往同一个版本上写，互相打架。所以编译归编译，发版单独一个任务收尾。

这个任务跑在 `ubuntu-latest` 上，因为它只收文件、调接口，不编译，用最便宜的机器就够。

注意：
去仓库 Settings → Actions → General → Workflow permissions 看一眼是不是 `Read and write`，`Read and write`权限只影响「打 tag 自动建 Release」那步，不影响出 .app

## 怎么用

改完代码，提交推上去，然后打标签：

```bash
git add .
git commit -m "改了什么"
git push
git tag v1.0.0
git push origin v1.0.0        # 这一下才触发
```

打完标签去仓库的 Actions 页面，能看到这次运行。点进去，左边是三个并行任务，点开任意一个能看到每一步的日志。页面底部 Artifacts 区域可以下载 zip，三个包都在。

再等一会儿，仓库的 Releases 页面会出现 `v1.0.0`，三个 zip 直接挂在那儿，长期可下，不用翻历史记录。

标签名随便起，只要以 `v` 开头。想试又不想占正式版本号，用 `v0.0.1-test` 也行。

## 下载下来怎么打开

这些包是临时签名的，别人下载后第一次打开会被 macOS 拦一下，提示「无法验证开发者」。两个办法：右键点 App 选「打开」，或者在终端里去掉隔离标记。

```bash
xattr -dr com.apple.quarantine /Applications/MarkdownEditorHy4.app
```

想彻底免掉这一步，就得买 Apple 开发者账号做正式签名和公证，每年 99 美元。本项目不走这条路。

## 花不花钱

仓库是公开的，标准运行器上不管跑多久都不花钱，macOS 也一样。这一点是这条路线的最大好处。

私有仓库就要算了：免费账号每月给 2000 分钟，但这个分钟数按 Linux 计，macOS 运行器乘 10 倍，等于实际能跑约 200 分钟。超出后按每分钟 0.062 美元计。这也是本项目不让每次推 main 都跑的原因之一。

| 项目 | 数值 |
| --- | --- |
| 公开仓库 | 无限、免费（含 macOS） |
| 私有仓库免费额度 | 每月 2000 分钟（Linux 口径） |
| macOS 倍率 | 10 倍（相当于约 200 分钟） |
| 超出后 macOS 单价 | 约 0.062 美元/分钟 |
| 单个任务最长 | 6 小时 |
| 免费账号并发任务数 | 20 个（本项目用 3 个） |

## 本项目踩过的坑

这几件事都真实发生过，也是最容易复现的。

本机 Xcode 版本比云端新。本机是 Xcode 27，GitHub 镜像最高到 26.6。绝大多数情况没影响，万一某条语法或某个构建设置对不上，报错会出现在日志里。workflow 的第二步会打印实际用的 Xcode 版本，方便对照。

Actions 里的产物会过期。默认保留 90 天，超时就自动删掉了。要长期能下载的版本，就用打标签发 Release 的方式，Release 里的文件不会过期。

## 这份配置故意没做的事

不上架 App Store 的话，下面这些一律不需要，别被网上教程带着配一堆：证书和描述文件、各类 Secrets、fastlane 那套打包脚本、导出 ipa 用的配置文件。本项目五个 Swift 包依赖全是公开仓库，`Package.resolved` 也已经提交，所以云端拉依赖不需要任何 token。
