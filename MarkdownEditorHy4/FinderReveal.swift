import Foundation

/// 让访达打开某个文件所在的文件夹，并把它选中（只在 Mac 上有实现）。
///
/// ### 为什么写得这么绕
/// Catalyst 工程不能 `import AppKit`，编译期写不出 `NSWorkspace` 这个名字，写上去直接编译报错。
/// 但 Catalyst 的 App 本质就是一个 macOS 程序，AppKit 在运行时确实躺在进程里，所以可以按字符串把类找出来，再按名字取方法、转成函数指针去调。
/// 开源库 Dynamic（github.com/mhdhejazi/Dynamic）走的就是这条路，这里只借它的做法，不引依赖：
/// 我们只需要一个方法调用，自己写十几行比多一个第三方包划算，而且 iOS 那半边能保证一行代码都不编进去。
///
/// ### 为什么不直接 objc_msgSend
/// Swift 不导出 `objc_msgSend`，拿不到那个符号。所以改成「取方法的 IMP，转成 C 函数指针再调」，这也正是 Dynamic 内部的做法。
enum FinderReveal {

    /// 这台机器上能不能用。iPhone / iPad 上永远是 false，菜单项据此藏掉。
    static var isAvailable: Bool {
        #if targetEnvironment(macCatalyst)
        return FinderBridge.shared != nil
        #else
        return false
        #endif
    }

    /// 打开 `url` 所在的文件夹并选中它。
    ///
    /// 调用方不用自己判断平台：非 Mac 上直接返回 false。
    /// 必须在主线程调 —— AppKit 的对象都不接受后台线程调用。
    ///
    /// - Returns: 有没有真的喊到访达。false 表示这台机器上没有 AppKit，或者方法签名对不上
    @discardableResult
    static func show(_ url: URL) -> Bool {
        #if targetEnvironment(macCatalyst)
        guard let bridge = FinderBridge.shared else { return false }
        return bridge.openInFinder(url)
        #else
        return false
        #endif
    }
}

#if targetEnvironment(macCatalyst)

import Darwin

/// 真正去调 AppKit 的那一层。
///
/// 找类、取 IMP 这些活只做一次，探好之后一直留着，所以收成一个 struct。
private struct FinderBridge {

    /// `activateFileViewerSelectingURLs:` 的函数签名：self + 选择子 + 一个 URL 数组
    typealias ActivateFunction = @convention(c) (AnyObject, Selector, NSArray) -> Void

    /// NSWorkspace 的单例。它的类型编译期不认识，只能当 AnyObject 抱着
    let workspace: AnyObject
    /// 调的时候要连着选择子一起传
    let activateSelector: Selector
    let activate: ActivateFunction

    /// 进程里只探一次（Swift 的 static let 自带「只初始化一次」的保证）。
    /// 探不到就是 nil，调用方据此把菜单项藏掉，而不是让用户点了没反应。
    static let shared: FinderBridge? = makeShared()

    private static func makeShared() -> FinderBridge? {
        // AppKit 在 Catalyst 进程里本来就加载着，这一步只是再确认一遍：已经加载过的 framework 再 dlopen 只是引用计数加一，代价可以忽略
        guard dlopen("/System/Library/Frameworks/AppKit.framework/AppKit", RTLD_NOW) != nil else { return nil }

        let sharedSelector = NSSelectorFromString("sharedWorkspace")
        let activateSelector = NSSelectorFromString("activateFileViewerSelectingURLs:")
        guard let workspaceClass = NSClassFromString("NSWorkspace"),
              let sharedMethod = class_getClassMethod(workspaceClass, sharedSelector),
              let activateMethod = class_getInstanceMethod(workspaceClass, activateSelector) else { return nil }

        // 类方法没法用 IMP 直接调，得手动把类对象当第一个参数塞进去；实例方法同理，调用时第一个参数传实例
        typealias SharedFunction = @convention(c) (AnyObject, Selector) -> AnyObject
        let sharedFunction = unsafeBitCast(method_getImplementation(sharedMethod), to: SharedFunction.self)
        let workspace = sharedFunction(workspaceClass as AnyObject, sharedSelector)

        return FinderBridge(workspace: workspace,
                            activateSelector: activateSelector,
                            activate: unsafeBitCast(method_getImplementation(activateMethod),
                                                    to: ActivateFunction.self))
    }

    func openInFinder(_ url: URL) -> Bool {
        // 沙盒里给的路径常是 /var/... 这种简化写法，访达那边认的是 /private/var/...，先换成真实路径
        let target = url.resolvingSymlinksInPath()
        activate(workspace, activateSelector, [target] as NSArray)
        return true
    }
}

#endif
