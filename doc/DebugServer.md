# 本机测试执行服务

## 什么时候用得着

在 AI 编程工具里让它跑 Mac Catalyst 单元测试，最常见的结局是干等六分半钟，最后拿到一句 `The test runner hung before establishing connection.`，退出码 65。同一条命令换到 iTerm 里手敲，六十多秒就 653 条全绿。差别出在执行环境上。

这份文档记的是把 Catalyst 测试从「只能人手敲」变成「AI 也能自己跑」的那套东西，以及它为什么能成。装好以后一轮全量大约 78 秒（含首次编译与签名），增量 61 秒，零失败。

需要三个条件。本机装好 Xcode，这份文档实测的是 27.0。工程待在 `/Users/pan/Project/iOSDemo/MarkdownEditorHy4`，服务里的路径是硬编码的，换机器要改 `tools/devserver/server.py` 顶部的 `PROJECT_DIR`。再就是一个能敲 `open` 命令的终端。

最容易卡住的地方只有一个，别在终端里 `python3 server.py &`。

## 直接起服务为什么没用

WorkBuddy 这类工具执行 shell 命令时，会给命令套一层系统沙盒（toybox，本质是 Seatbelt profile）。这个沙盒限定了能写哪些文件、能看见哪些进程。`&` 只是把进程丢到后台，它仍然是当前 shell 的子进程，环境变量和沙盒身份原样继承。在沙盒里再起一个 Python，等于在原地套一层壳，xcodebuild 该失败还是失败。

判断自己有没有在沙盒里，三条命令立刻见分晓。`/usr/bin/log show --last 1m` 如果回 `log: Cannot run while sandboxed`，`ps -o pid,ppid,command -p $$` 如果回 `operation not permitted`，环境变量里又全是 `TOYBOX_SANDBOX_SOCK` 和 `CODEBUDDY_SANDBOX_*`，那就跑在沙盒里面。

真正的失败机理藏得比较深。这批单测是以「宿主 App 型」跑的，xcodebuild 要把测试包注入 `MarkdownEditorHy4.app`，再由 `testmanagerd` 完成握手。沙盒里这一步没有发生，去读宿主的 `KERN_PROCARGS2` 能看到二十个环境变量里没有一条 `DYLD_INSERT_*` 或 `XCTest*`。xcodebuild 不报原因，只是等，等到 388 秒超时。

## 为什么 open -n 能出去

macOS 上每个 GUI 会话都有一个进程管家 launchd，`open` 命令是请它来启动东西。用 `open -n` 打开一个 `.app`，新进程的父亲是 launchd，跟我这条 shell 没有血缘关系，沙盒环境和环境变量都不会继承过去。

同样的思路试过四种，只有这一种通。

| 做法 | 结果 | 原因 |
| --- | --- | --- |
| `launchctl submit` | 静默无任务，什么都没起来 | 沙盒里拿不到那个 domain 的控制权 |
| `open -a Terminal /tmp/x.sh` | LaunchServices 报 -10820 | 需要跨 App 启动的授权 |
| `osascript` 让 Terminal 执行 | Apple Events 报 -10004 权限违例 | 需要自动化授权 |
| `open -n` 打开自建 .app | 成功 | launchd 直接跑我自己的可执行文件，不涉及求别的 App 帮忙 |

这四种做法的差别，按我看到的现场是这样。前三种都要借道，`launchctl submit` 要摸到 launchd 的注册接口，`open -a` 和 `osascript` 要过 LaunchServices 或 Apple Events 的授权，沙盒把这几处全挡住了。第四种是自己写好可执行文件交给 launchd 启动，没有中间人。这个解释我只验证到现象这一层，没有去翻内核日志，但四种做法的对比足够稳定，重复过多次都是这个结果。

`.app` 不需要界面，也不需要签名证书。`Info.plist` 里设 `LSBackgroundOnly` 和 `LSUIElement`，它就在后台待着，不进 Dock，不抢焦点。`Contents/MacOS/TestRunnerServer` 是一个 bash 脚本，职责只有挑一个能用的 Python 然后 exec 过去。

## 服务怎么设计

一开始想得简单，接口收到请求就同步跑完再把结果吐回去。真跑起来发现不行，全量测试六十秒以上，HTTP 那边一直挂着容易断，而且中间看不到任何进度。改成异步提交。

`POST /run` 立刻返回一个任务号，xcodebuild 的输出直接重定向到 `build/devserver/<任务号>.log`，不经过内存。跑完由后台线程写回退出码。要进度就 `GET /job?id=...&tail=20` 取日志尾部，要全量就 `GET /log?id=...&offset=...` 按字节偏移增量读。

日志落盘这件事顺便解决了另一个老问题。xcodebuild 会派生子进程，那些子进程各自持有旧的写偏移，直接用 `> file` 重定向容易把日志写花，中间加一根管道才稳。现在由 Python 持有文件句柄，输出顺序就正常了。

几条防护顺手加了。只接受项目根目录和 `tools/` 下真实存在的 `.sh`，防止这个服务变成万能后门。同一时刻只允许一个任务，第二个请求直接回 409。默认超时 1800 秒，到点按进程组一起杀。xcodebuild 干活时会派生出编译器、签名工具、测试运行器一长串子进程，只杀最外面那个，剩下的会继续占着 CPU 和 Xcode 的编译缓存，下一轮跑起来就被它们挡住。任务状态写进 `build/devserver/<任务号>.json`，服务重启后还能查到历史，上次没跑完的标记成 `interrupted`。

环境变量也重置了。launchd 给的 `PATH` 很短，服务里补成 `/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin`，再把 `LC_ALL` 固定成 `en_US.UTF-8`，中文日志不会乱码。

## 怎么用

下面的 curl 都带 `--noproxy '*'`。本机常开着 HTTP 代理，`127.0.0.1` 未必在 `no_proxy` 名单里，请求会被代理接走，后端明明没起来也能拿到一张错误页，判断全乱。

第一步起服务。

```bash
tools/devserver/start.sh
```

这个脚本先 curl 一下 `/health` 看服务在不在，已经在跑就打印现状，没跑就 `open -n` 拉起然后轮询等它。看到 `"sandboxed": false` 就对了，这个字段是服务自己按环境变量算的。

手动起也行，下面这条等价。

```bash
open -n "$(pwd)/tools/devserver/TestRunnerServer.app"
```

第二步触发测试。

```bash
curl -X POST --noproxy '*' "http://127.0.0.1:8765/run?script=tools/run-catalyst-tests.sh"
```

返回里有 `id` 和 `pid`，任务号长这样 `20261017-150915-ab4fb9`，后面查进度和读日志都用它。想连其他脚本就换 `script` 参数，凡是项目根目录或 `tools/` 下的 `.sh` 都认。`tools/run-catalyst-tests.sh` 开工前会先把在跑的 App 停掉，它只杀 `MarkdownEditorHy4.app` 那个主进程，不会碰别的。

第三步看进度。

```bash
curl --noproxy '*' "http://127.0.0.1:8765/job?id=20261017-150915-ab4fb9&tail=20"
```

`state` 是 `running` 就还在跑，变成 `finished` 表示结束，`exitCode` 为 0 就是全绿。`tail` 给多少就返回最后多少行。

第四步读结果。跑完的结果包固定在 `build/unit-catalyst.xcresult`，旧的会自动挪到 `build/unit-catalyst-prev.xcresult`，不会覆盖。

```bash
xcrun xcresulttool get test-results summary --path build/unit-catalyst.xcresult
```

想找具体哪条红了，用 `grep "Test case '.*' failed" build/devserver/<任务号>.log`，比在 xcresult 里翻快得多。

用完想关掉服务。

```bash
pkill -f TestRunnerServer
```

服务会一直挂着占一个 Python 进程，不会自己退出。下次用 `start.sh` 再拉起。

## 接口一览

| 方法与路径 | 作用 |
| --- | --- |
| `GET /health` | 存活检查，返回 pid 和 `sandboxed` |
| `GET /probe` | 沙盒自查，跑六条命令并汇总结果 |
| `POST /run?script=x.sh&timeout=1800` | 异步提交任务 |
| `GET /jobs` | 最近 20 个任务 |
| `GET /job?id=&tail=N` | 单任务状态加日志尾部 |
| `GET /log?id=&offset=N` | 增量读日志，返回 `chunk` 和 `nextOffset` |
| `POST /kill?id=` | 杀掉任务整组进程 |

`/probe` 是排查时最有用的一个。它会把环境变量计数、`log show`、`ps`、`xcodebuild -version`、`xcode-select -p`、`whoami` 六条命令各跑一遍，把原始输出原样贴回来。服务到底在不在沙盒外，看这一个接口就够了。

## 出问题先看这几处

| 现象 | 通常原因 | 处理 |
| --- | --- | --- |
| `start.sh` 报启动失败 | 端口被占，或者 `.app` 里的快捷方式断了 | 看 `/tmp/mdhy4-testrunner.log` 最后二十行 |
| `sandboxed` 返回 true | 服务是从沙盒里的 shell 直接起的 | `pkill -f TestRunnerServer` 之后用 `open -n` 重来 |
| `/run` 返回 409 | 上一个任务还没结束 | `GET /jobs` 看看，或者 `/kill` 掉 |
| `/run` 返回 400 | 脚本不在根目录或 `tools/` 下，或者不是 `.sh` | 把脚本挪到这两处之一 |
| 任务跑了很久没结束 | xcodebuild 卡在签名或钥匙串授权 | `/job` 看日志尾部，必要时 `/kill` |
| 结果包读不出来 | 上一轮被杀，包没写完 | 用同一条命令重跑一遍 |

服务自己的日志在 `/tmp/mdhy4-testrunner.log`，每次启动会打一行 `sandboxed=` 的判定，任务开始结束也各一行。这个文件重启不清空，翻历史比较方便。

## 边界

这套东西是给本机开发用的。只监听 `127.0.0.1`，外面的机器连不上，也不需要连。只跑项目根目录和 `tools/` 下的 `.sh`，不接受任意命令。同一时刻一个任务，不做并发调度。

`.app` 里 `Contents/Resources/server.py` 是一个软链，相当于 macOS 上的快捷方式，指回真正的文件。改代码改软链那头就行，不用碰 `.app` 里的。但也别把整个 `.app` 单独拷到别处用，快捷方式会断。

工程路径硬编码在 `server.py` 的 `PROJECT_DIR`。工程搬家要改这一行，`tools/run-catalyst-tests.sh` 里的相对路径不用动，它会 `cd` 到工程根目录再跑 xcodebuild。

这套通道跟人工在 iTerm 里敲命令不冲突，也不替代 `test.sh`。想看真实测试耗时就手敲，想让 AI 反复迭代就让它调接口。
