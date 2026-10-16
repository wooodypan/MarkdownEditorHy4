在 Mac Catalyst 下拦下 ⌘W，让它关标签页而不是关应用

你写了个多标签页的详情界面，在 Mac 上按 ⌘W，本意是关掉当前那个标签页，结果整个 App 退出了。你之前在代码里加过 UIKeyCommand，声明"按 ⌘W 就关当前 Tab"，可那个方法一次都没被调到。这篇笔记把这件事讲明白，先讲为什么简单的写法不灵，再讲最后怎么解决的。

读完你会知道三件事。第一，⌘W 在 Mac 上到底走的是哪条路。第二，为什么 UIKeyCommand 在这一路里排不上号。第三，我们用了一个底层的"事件监视器"把它截住，以及那个监视器为什么必须写得绕一点。

## ⌘W 在 Mac 上不是普通按键

在 Mac 系统里，⌘W 老早就被登记进了菜单栏，挂在"文件"菜单的"关闭窗口"那一项上。你手指一按，系统把它理解成"点了关闭窗口"这件事，转头就去执行关闭当前窗口。窗口关掉了，应用又没有其他窗口，就退出了。这个行为来自 macOS 本身，跟你的代码写得对不对没有关系。

iPad 上不会有这个问题，iPad 没有"关闭窗口"的概念。问题只发生在 Mac Catalyst 把 App 搬到 Mac 上跑的时候。

## 你写的 UIKeyCommand 为什么没反应

iOS 上处理键盘快捷键的常规办法是 UIKeyCommand，你在控制器里声明"按下 ⌘W 时调用某个方法"，系统会在按键发生时把事件送到这条通道。

麻烦在于通道之间的顺序。键盘产生了一次按键，系统拿到之后，先去菜单栏里查"有没有哪个菜单项绑定了这个快捷键"。查到了"关闭窗口"，就直接去执行，窗口进入关闭流程。等到 UIKeyCommand 这一层被轮到的时候，窗口已经在关了，你的方法自然没有机会再跑。

UIKeyCommand 本身没有写错，它只是排在菜单快捷键这一层的后面。等它拿到事件，窗口已经关了，所以它永远拦不住 ⌘W。只靠这一层，没用。

这里要先讲清一点。⌘W 拦不住，是因为它刚好是系统必须马上执行的关闭指令。像 ⌘S 这种保存类的常规快捷键，系统没把它当紧急命令，UIKeyCommand 一般就能直接接住，写法见文末补充章节。

## 在更前面装一道监视器

AppKit 给了另一种机制，叫"本地事件监视器"。键盘事件一产生，在系统去匹配菜单快捷键之前，监视器先得到这个事件。监视器要返回值。把事件原样返回，系统就照常处理；返回一个空，事件就被丢弃，系统再也看不见它，关闭窗口这一步就不会发生。

我们借这个时机做两件事。先判断这个事件是不是 ⌘W，是的话，自己把当前选中的标签页关掉，然后返回空，把事件吃掉。系统没收到 ⌘W，就不会去关窗口，用户看到的就是"关掉一个标签页"。

这一层才是主力。UIKit 那边的 buildMenu 移除菜单项、canPerformAction 拦截 performClose:，我们仍然保留了，但它们只是补充。

## 拦路虎，Catalyst 工程不能直接用 AppKit

写监视器要调用 AppKit 的 NSEvent。问题在于，Catalyst 工程不能写 import AppKit。苹果没有把 AppKit 的头文件开放给 Catalyst 这一套编译环境，你直接写 NSEvent、NSApplication，编译阶段就会报错。

可是 Catalyst 的 App 本质还是跑在 macOS 上，AppKit 在程序运行起来的时候，实实在在加载在内存里。Dynamic 这个开源库（https://github.com/mhdhejazi/Dynamic）的核心思路就是利用这一点。不在编译期引用 AppKit，而是在运行期按名字去把它找出来。

## 按名字找到 AppKit，再直接调它

找不到类型，就用字符串去运行时要。整个过程四步。

第一步，按字符串"NSEvent"去运行时拿这个类，得到类对象。

第二步，按字符串"addLocalMonitorForEventsMatchingMask:handler:"去拿这个方法的入口。

第三步，取出这个方法的底层函数指针。

第四步，把这个指针转换成 Swift 能直接当 C 函数调用的形式，然后调用它，把"只看按键按下"这个过滤条件和我们的回调传进去。

这几步做完，监视器就装好了。代码里把这段封装在 CatalystKeyInterceptor 的 addLocalMonitor 方法里，只有 Mac Catalyst 编译时才会被包含进来，iOS 和 iPadOS 那部分直接是空的，那边交给 UIKeyCommand 处理。

## 拿到事件以后怎么读

回调里传来的对象，我们不能用 NSEvent 的类型去读它的字段，因为编译期根本不认识那个类型。改用 KVC 这种通用的取值方式，也就是 value(forKey:)。

读 modifierFlags，能知道当时有没有按住 Command 键。读 charactersIgnoringModifiers，能知道按的是哪个字母，而且不受 Shift 之类的修饰键影响，⌘W 读出来就是小写"w"。把这两个拼起来，就能确认这次按键就是 ⌘W。

这一套读取方法写在 CatalystKeyInterceptor 的 isCommandPressed 这类静态函数里，对外只暴露判断结果，调用方不用管底层怎么取值。

## 一个差点让程序崩溃的坑

监视器的回调是一个 Objective-C 的 block。Swift 有个规矩。一个闭包如果捕获了外面的变量，编译器默认认为它“不会逃逸”，也就是用完就丢。可 AppKit 会把我们的 block 存起来，过一会儿再调用，这正是"逃逸"。两者撞在一起，程序运行到这里就崩溃，报错会说这个闭包本不该被保存。

解决办法是让传给 AppKit 的 block 什么都不捕获。这个 block 只负责把事件转交给一个全局的回调列表，由列表里的函数去干具体的活。这样 block 本身是安全的，业务逻辑写在列表项里，谁需要监听就往列表里加一项。代码里用一个静态的 monitorBlock 做转发，用 handlers 这个字典存具体的回调，全局只装一个监视器，防止同一事件被处理多次。

## 它接在哪、怎么用

在 DetailHostViewController 的 viewDidLoad 里，我们创建了 CatalystKeyInterceptor 的实例，并用一个强引用属性抱着它。实例活着，监视器就生效；实例被释放，监视器自动卸载。

对外只暴露了几个 bool 开关，用法很简单。showExitPromptWhenAllTabsClosed 控制"所有标签页都关掉以后，要不要弹一个是否退出 App 的确认框"。exitAction 让你自定义"退出"时到底做什么，比如回到首页，而不是真的杀掉应用。默认情况下，Mac 上按 ⌘W 关掉最后一个标签页会弹确认框，确认以后才退出。

如果你想让某个标签页的内容不被重复打开，deduplicateOpenedItems 默认就是开着的，再点已经打开过的那一项，会直接跳到已有的标签页，而不是开出第三个。

## 我们怎么确认它真的拦住了

光编译通过不够，我们在 Mac Catalyst 下做过构建，也单独写了运行时验证。造一个真实的 ⌘W 事件，确认能读到正确的修饰键和字符，确认监视器装得上、卸得掉，确认 ⌘W 事件确实被返回空、没有流到系统那边。iOS 模拟器和 Mac Catalyst 两个平台的构建都跑过，pod lib lint 在 iOS 12 的部署目标下也通过了。

## 补充，常规的 Command+S 用 UIKeyCommand 就够了

前面说了 ⌘W 特殊，要用底层监视器。你可能会问，那 ⌘S 呢。对大多数 Catalyst 项目，⌘S 走普通的 UIKeyCommand 就能接住，不需要前面那套绕来绕去的东西。

原因还是顺序。⌘W 被系统当成了"必须马上执行"的关闭命令，所以排在菜单那一层，UIKeyCommand 够不着。⌘S 一般没有这种待遇，系统不会把它当成非执行不可的紧急指令，于是 UIKeyCommand 这一层就能正常拿到事件。

下面是一段标准写法，把它放进你想接住快捷键的那个控制器里即可。

```swift
import UIKit

class DocumentViewController: UIViewController {

    // 第一步，告诉系统这个控制器支持哪些键盘快捷键
    override var keyCommands: [UIKeyCommand]? {
        let saveCommand = UIKeyCommand(
            input: "s",
            modifierFlags: .command,
            action: #selector(handleSave(_:))
        )
        // title 会显示在 Mac 菜单栏和长按 Command 键的快捷键面板里
        if #available(iOS 13.0, *) {
            saveCommand.title = "保存"
        }
        return [saveCommand]
    }

    // 第二步，让这个控制器能成为第一响应者，否则快捷键收不到
    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    // 第三步，Command+S 命中时执行的方法
    @objc private func handleSave(_ sender: UIKeyCommand) {
        saveCurrentDocument()
    }

    private func saveCurrentDocument() {
        // 这里写你自己的保存逻辑
        print("收到 ⌘S，执行保存")
    }
}
```

三段要齐。keyCommands 声明"按 ⌘S 调哪个方法"。canBecomeFirstResponder 返回 true，并在 viewDidAppear 里 becomeFirstResponder，让这个控制器进入响应链成为活跃对象，否则系统不会来问它有没有快捷键。

下面这张表把 ⌘W 和 ⌘S 摆在一起，方便你判断自己的场景该用哪套。

| 快捷键 | 系统态度 | 常规 UIKeyCommand 能拦住吗 | 该用什么 |
| --- | --- | --- | --- |
| ⌘W（关闭窗口） | 当成必须马上执行的关闭指令，排在菜单层 | 不能，永远轮不到 | 底层事件监视器（本文主线） |
| ⌘S（保存） | 一般没有紧急待遇 | 能，正常接住 | 上面这段 UIKeyCommand 即可 |

有一个边界要提醒你。如果你的 App 在主菜单里放了"保存"这一项，并且这一项本身就绑了 ⌘S（比如你实现了系统的 saveDocument:，或者用了 AppKit 提供的保存菜单），那 ⌘S 就和它一样被菜单那一层先拿走，UIKeyCommand 又排在后面了。这种情况的处理办法跟 ⌘W 一样。要么改用前面讲的那套事件监视器在更前面截住，要么在 buildMenu 里把那个菜单项移除或替换，让 ⌘S 落到你的 UIKeyCommand 上。（直接拦截 saveDocument: 这个动作，效果也一样。）
