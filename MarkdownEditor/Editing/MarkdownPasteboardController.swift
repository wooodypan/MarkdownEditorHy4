//
//  MarkdownPasteboardController.swift
//  MarkdownEditorHy4
//
//  剪贴板层：拦截 copy / cut / paste
//
//  ### 核心原则
//  **渲染出来的 NSAttributedString 和「复制时应该产出的文本」是两套独立数据。**
//  永远不要指望从 attributed string 反推源码，一律查 `MarkdownDocumentStore` 的源码映射表。
//

import ImageIO
import UIKit
import UniformTypeIdentifiers

/// 剪贴板控制器。
final class MarkdownPasteboardController {

    weak var textView: MarkdownTextView?

    /// App 层注入的「剪贴板富文本 → markdown 源码」转换器。默认 `nil`（= 不转换）。
    ///
    /// ### 为什么是一个回调，而不是直接调 App 里的转换器
    /// `MarkdownEditor/` 这一层将来要单独开源：它不该认识 App 的任何类型（设置页、SwiftSoup、剪贴板策略），也不该为了「转 HTML」去依赖一个 HTML 解析库。
    /// 所以这里只留一个口子 —— 由 App 在装配编辑器时把「怎么转」塞进来（见 `MarkdownDocumentViewController.setupEditor`），组件自己只管在粘贴时问一句。
    ///
    /// - parameter pasteboard: 要读的那个剪贴板
    /// - returns: 转出来的源码；`nil` = 这一步不接管，粘贴继续走纯文本那条路
    var richTextConverter: ((UIPasteboard) -> String?)?

    /// App 层注入的「图片存到哪儿、markdown 里写什么路径」。默认 `nil`（= 用本类自带的默认方式）。
    ///
    /// ### 为什么又是一个回调
    /// 和上面 `richTextConverter` 完全同一个理由：`MarkdownEditor/` 这一层将来要单独开源，
    /// 它不该认识 App 的设置页，也不该知道「笔记旁边有没有一个 assets 文件夹」这种规矩 ——
    /// 「存哪儿」是 App 层用户选出来的，所以只留一个口子由 App 接管。
    ///
    /// ### 不注入时走什么
    /// 存到 `Documents/attachments/<内容 md5>.<后缀>`，markdown 里写 `attachments/<内容 md5>.<后缀>` ——
    /// 组件单独拿去用（没有 App 的设置页）时，粘贴图片照样能用。
    ///
    /// - parameter data: 图片的**原始字节**（剪贴板里是什么格式就是什么格式，我们不做转码）
    /// - returns: markdown 里要写的图片路径（相对路径 / 绝对路径都行）；`nil` = 这次没存下，粘贴不再由本类接管
    var imageFileWriter: ((Data) -> String?)?

    /// ### 为什么这里要显式写 `nonisolated deinit`（很重要，别删）
    /// 原因和 `MarkdownBlock` 里那段注释完全一样：app target 开了
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，本类的隐式 deinit 也是
    /// 「actor 隔离的 deinit」，Swift 6.2 运行时释放它时会先切回 MainActor 执行器
    /// （`swift_task_deinitOnExecutorImpl`），而这个函数维护的 task-local 作用域
    /// 在某些释放时机下会 free 一个野指针 → `malloc: pointer being freed was not allocated`。
    ///
    /// ### 实测踩坑（ASan 堆栈，2026-09-13）
    /// 本类是 `MarkdownTextView` 的一个存储属性，编辑器释放时会依次销毁各 ivar。
    /// 只要这次释放发生在 RunLoop / dispatch 回调里，就会崩：
    /// ```
    /// free ← TaskLocal::StopLookupScope::~StopLookupScope
    ///      ← swift_task_deinitOnExecutorImpl
    ///      ← MarkdownPasteboardController.__deallocating_deinit
    ///      ← MarkdownTextView.__ivar_destroyer ← UITextView dealloc
    /// ```
    /// 本类只持有一个 `weak` 引用，销毁时不需要任何主线程状态，所以声明成
    /// `nonisolated` 不走执行器切换，从根上避免。
    ///
    /// ⚠️ 同类问题请一并检查 `MarkdownEditController`、`FoldAnchorInfo`
    /// —— 凡是「非 UI 的类」都应该带上这一行。
    nonisolated deinit {}

    // MARK: 复制

    /// 把选区对应的 **markdown 源码** 放进剪贴板。
    /// - returns: `true` 表示已经接管，`false` 表示没接管（交给系统默认行为）
    @discardableResult
    func handleCopy() -> Bool {
        guard let textView else { return false }

        let range = textView.selectedRange
        guard range.length > 0 else { return false }

        // 查映射表还原源码：
        // - 图片占位符 → 还原成 ![alt](url)
        // - 列表圆点   → 还原成源码里的 `- `
        // - 纯装饰字符 → 直接跳过
        let source = textView.documentStore.sourceText(forRenderedRange: range)
        guard !source.isEmpty else { return false }

        // 只放纯文本，不放富文本。
        // 这样粘到任何编辑器（VS Code、微信、备忘录…）拿到的都是 markdown 源码，
        // 不会出现「粘过去变成一张图」的情况。
        UIPasteboard.general.string = source
        return true
    }

    // MARK: 粘贴

    /// 剪贴板里是图片时，存成本地文件并插入 `![](路径)` 源码。
    ///
    /// 文件叫什么名字由 `MarkdownImageFileStore` 定（内容哈希 + 真实格式的后缀），
    /// 存到哪儿由 `imageFileWriter` 定（App 层按设置页的选择给）。
    ///
    /// - returns: `true` 表示已处理
    @discardableResult
    func handlePasteImage() -> Bool {
        guard let textView else { return false }
        // 「是不是图」这件事交给 `pasteboardImageData` 自己判断：它取不到图就返回 nil，
        // 那就是这次不接管，粘贴继续往下走别的路子（纯文本 / 富文本那条）
        guard let data = pasteboardImageData() else { return false }

        // App 没注入就用自己的默认存法，保证组件单独也能用
        let writer = imageFileWriter ?? Self.defaultImageFileWriter
        guard let path = writer(data) else { return false }

        // 图片插入同样走「可撤销」那条路：图片源码渲染出来是一个附件字符，
        // 和源码长度差得更远，交给系统记撤销会残留一串字符
        textView.insertMarkdownSourceUndoably("![粘贴的图片](\(path))")
        return true
    }

    /// 剪贴板里的**富文本**转成的 markdown 源码（没注入转换器、或者转不出来时返回 `nil`）。
    ///
    /// 它的优先级在图片之后、纯文本之前：
    /// 网页复制来的东西既有纯文本又有 HTML，HTML 那边带着标题、列表、表格这些结构，转换结果比纯文本那一份（里面混着菜单、页脚噪音）干净得多。
    func markdownFromRichText() -> String? {
        guard let converter = richTextConverter else { return nil }
        let markdown = converter(UIPasteboard.general)
        // 空串等于没转出来，别把「粘贴」变成「粘了个空」
        guard let markdown, !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return markdown
    }

    /// 剪贴板里的纯文本（没有、或者只有空白时返回 nil）。
    ///
    /// ### 为什么只「取出来」，不在这里插入
    /// 插入必须走 `MarkdownTextView.insertMarkdownSourceUndoably` ——
    /// 粘贴不能交给系统自带的撤销（原因见那个方法的注释：渲染文本和源码长度不等，
    /// 系统的撤销记录会失效，撤销后残留尾巴）。而「怎么插入」是编辑器的职责，
    /// 剪贴板层只负责把内容取出来，别越界。
    func pasteboardText() -> String? {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return nil }
        return text
    }

    /// 剪贴板里那张图的**原始字节**。
    ///
    /// ### 为什么要绕开 `UIPasteboard.general.image` 去翻剪贴板
    /// 那个属性给的是一张**解好码的 `UIImage`**，要是写完再 `pngData()`，就等于把图片重新编码了一遍：
    /// 复制来的 JPEG 会变成大好几倍的 PNG，动图（GIF）的后续帧也在解码那一步就没了。
    /// 所以只要有可能，就原样取出字节。
    ///
    /// ### 顺序为什么是这四步
    /// 从 Finder 里 ⌘C 复制一张图，剪贴板里放的**不是图片本身，而是文件地址** ——
    /// 所以第 ① 步先按地址去读原文件；剪贴板里另外十几种格式（PNG / TIFF / BMP…）都是系统现转的，
    /// 只有原文件那一份才是没动过的。地址读不到（沙箱没给权限等情况）再退而求其次，
    /// 按类型挨个问剪贴板要（② ③），最后才自己编码（④）。
    private func pasteboardImageData() -> Data? {
        let pasteboard = UIPasteboard.general

        // ① 剪贴板里是「文件地址」→ 直接读原文件
        let fileURL = pasteboardFileURL(pasteboard)
        if let fileURL, let data = readImageFile(at: fileURL) { return data }

        // ② 按「最可能拿到原始格式」的顺序，逐个类型问剪贴板要数据
        for type in candidateImageTypes(hintedBy: fileURL) {
            if let data = pasteboard.data(forPasteboardType: type), isImageData(data) { return data }
        }

        // ③ 还有些 App 会把图片放在很冷门的自定义类型里（`dyn.…`）。前面都没命中的话，
        //    把剩下的条目挨个试一遍 —— 这一遍同样得用 `isImageData` 把关
        for item in pasteboard.items {
            for (_, value) in item {
                guard let data = value as? Data, isImageData(data) else { continue }
                return data
            }
        }

        // ④ 实在取不到原始字节（有些 App 只往剪贴板里放一份解好码的图）再退回自己编码。
        //    这一条路上拿到的永远是 PNG，扩展名也就会跟着算成 png，这是没办法的事
        return pasteboard.image?.pngData()
    }

    /// 这份数据到底是不是图片。
    ///
    /// ### ⚠️ 为什么不能只判断 `CGImageSourceCreateWithData(...) != nil`（这个坑真吃过，2026-10-15）
    /// 那个函数是**懒解析**的：对**任何**非空数据都会先给你一个 source，你不动内容它就不报错。
    /// 实测把一段 `file:///…` 的纯文本喂给它，照样返回非 nil（`CGImageSourceGetType` 才是 nil）。
    /// 于是「翻剪贴板找图片」实际变成了「翻剪贴板找第一条非空数据」——
    /// 从 Finder 复制图片时第一条偏偏就是那串文件地址，结果 `.png` 里写进去的是一行路径文本：
    /// 文件在、名字对、大小也对不上图片，怎么点都打不开。
    /// 所以必须再问一句 `CGImageSourceGetType`：它答不出格式，就说明这根本不是图片。
    private func isImageData(_ data: Data) -> Bool {
        guard !data.isEmpty, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetType(source) != nil
    }

    /// 剪贴板里那个「文件地址」（`public.file-url`）。
    ///
    /// `public.file-url` 是 `public.url` 的子类型，所以 `url` 属性一般就够用；
    /// 但个别情况下它只以原始数据的形式出现，那就自己把那串地址解出来。
    private func pasteboardFileURL(_ pasteboard: UIPasteboard) -> URL? {
        if let url = pasteboard.url, url.isFileURL { return url }
        guard let raw = pasteboard.data(forPasteboardType: UTType.fileURL.identifier),
              let text = String(data: raw, encoding: .utf8),
              let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.isFileURL else { return nil }
        return url
    }

    /// 按地址把原文件读出来。读不到（沙箱没给访问权限、文件已删、是网络地址…）返回 `nil`，让调用方接着走别的路。
    private func readImageFile(at url: URL) -> Data? {
        // 别急着读：用户复制的可能是个几十 MB 的压缩包，先问一句「你是什么」——
        // 系统认得出它跟图片无关就直接跳过，省掉一次整文件读盘。
        // 认不出来（没后缀的图）时 `contentType` 是 nil，那就老老实实读一次再看内容
        let declared = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        if let declared, !declared.conforms(to: .image) { return nil }

        // 沙盒里从剪贴板拿到的地址未必带访问权限：按规矩问一句。拿不到也只是读不了，不会更糟
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), isImageData(data) else { return nil }
        return data
    }

    /// 「接下来按什么顺序问剪贴板要图片」。
    ///
    /// 手上知道原文件是什么格式时（②那条路拿到了地址），先要那个格式 ——
    /// 这是唯一有希望拿到「原封不动那份字节」的一种问法，也免得把原图是 JPEG 的硬转成 PNG（体积能差好几倍）。
    private func candidateImageTypes(hintedBy fileURL: URL?) -> [String] {
        var types: [String] = []
        if let ext = fileURL?.pathExtension, !ext.isEmpty, let hint = UTType(filenameExtension: ext)?.identifier {
            types.append(hint)
        }
        types.append(contentsOf: Self.preferredImageTypes)
        return types
    }

    /// 常见的图片类型，按「截图 / 网页里的图 / 手机相册照片」这几种最常见的情形排。
    ///
    /// 这里写成系统 UTI 字符串而不是 `UTType` 常量：剪贴板协议里用的就是这串名字，
    /// 而常量是随 SDK 版本时有时无的（比如 `UTType.icns` 在有些版本上根本没有），
    /// 拼错了编译期就报错、还会连累别的代码，不如直接写字面量实在。
    private static let preferredImageTypes = [
        "public.png",
        "public.jpeg",
        "public.heic",
        "public.heif",
        "com.compuserve.gif",
        "public.tiff",
        "com.microsoft.bmp",
        "public.avif",
    ]

    /// 没有 App 注入时用的默认存法：`Documents/attachments/<内容 md5>.<后缀>`。
    ///
    /// ⚠️ 标 `nonisolated` 是因为要把它**当成函数值**塞进 `imageFileWriter`（那个属性是普通函数类型）：
    /// 不标的话它跟着全项目默认隔离在主线程，赋值时编译器会警告「在非隔离上下文里引用主线程隔离的方法」。
    /// 它本身就只碰文件、不碰 UI，标了没有任何副作用。
    private nonisolated static func defaultImageFileWriter(_ data: Data) -> String? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = documents.appendingPathComponent("attachments", isDirectory: true)
        guard let name = MarkdownImageFileStore.store(data, in: directory) else { return nil }
        return "attachments/\(name)"
    }
}
