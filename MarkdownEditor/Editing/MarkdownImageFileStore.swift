//
//  MarkdownImageFileStore.swift
//  MarkdownEditorHy4
//
//  图片落盘的小工具：算文件名、认扩展名、把字节写进指定目录。
//
//  这一层刻意不认识 App 的设置页 —— 它只回答「这份图片数据该叫什么名字」「怎么写进这个目录」，
//  「写到哪个目录」「markdown 里写什么路径」是调用方的事（见 `MarkdownPasteboardController.imageFileWriter`）。
//

import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 把一张图片写进磁盘时用的命名和落盘工具。
///
/// ### 为什么每个方法都写 `nonisolated`
/// 全项目默认所有类型都隔离在主线程（`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`），
/// 而这一组方法只是算哈希、认格式、写文件 —— 一行 UI 都不碰，也没有共享状态，
/// 没有任何理由必须待在主线程。反过来，不写 `nonisolated` 的话，
/// 主线程之外的调用方（比如将来把写图挪到后台队列）就调不动它了。
enum MarkdownImageFileStore {

    // MARK: 命名

    /// 给图片数据算一个文件名：`<内容 md5>.<后缀>`。
    ///
    /// ### 为什么用内容算出来的哈希，而不是随机 UUID
    /// 同一张图被粘贴两次会落到**同一个文件名**上：磁盘上不会出现两份一模一样的图，
    /// 正文里引用的也还是同一份文件。第二次写进来的内容和第一次完全一样，覆盖掉也没有任何影响，
    /// 所以下面 `store` 遇到同名文件会直接跳过、省掉一次写盘（大图尤其明显）。
    ///
    /// - returns: 文件名；数据不是能认出来的图片时返回 nil
    nonisolated static func fileName(for data: Data) -> String? {
        guard let hash = md5Hex(of: data) else { return nil }
        return "\(hash).\(fileExtension(for: data))"
    }

    // MARK: 落盘

    /// 把图片写进目录，返回写好的文件名。
    ///
    /// - returns: 文件名；数据不是图片、或者磁盘写不进去时返回 `nil`（调用方据此判断这次没成）
    @discardableResult
    nonisolated static func store(_ data: Data, in directory: URL) -> String? {
        guard let name = fileName(for: data) else { return nil }
        let url = directory.appendingPathComponent(name)
        // 目录可能还不存在（第一次往 ./assets 里存），先建出来。
        // ⚠️ 已经存在时不报错，所以这里不用管返回值
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 文件名就是内容哈希 —— 同名等于同一份内容，没必要再写一遍。
        // ⚠️ 判据是**字节数对不对**，不是「文件在不在」：磁盘上可能留着一个 0 字节的同名残骸
        // （上一次写到一半失败留下的）。只判存在的话，就会一直把这张空文件当成品交出去，
        // 正文里插进去的图永远打不开，而且怎么重粘都还是它
        if fileSize(at: url) == data.count { return name }
        do {
            try data.write(to: url)
        } catch {
            return nil
        }
        // 写完再核一遍：要是写盘没报错、落下去的东西却不对，宁可当成「这次没存成」，
        // 也别把一条指向坏文件的路径插进正文（那种坏法最难查）
        guard fileSize(at: url) == data.count else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return name
    }

    // MARK: 内部

    /// 文件有多少字节。不存在、或者读不出属性时返回 `nil`
    private nonisolated static func fileSize(at url: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return attributes[.size] as? Int
    }

    /// 图片的真实格式 → 文件后缀。
    ///
    /// ### 为什么不能一律写成 `.png`
    /// 从剪贴板里拿到的常常是 JPEG 或 HEIC（截图、网页图片多是这两种），
    /// 而我们**不重新编码**、直接把原始字节写下去，所以后缀必须跟内容对得上，
    /// 否则别的程序看见 `.png` 却解不动，会当成坏文件。
    ///
    /// ### 「分析图片元数据」在这儿指的是什么
    /// 具体分析的就是图片的**容器格式**：交给系统 ImageIO 认一遍，它给出的结果就是权威答案。
    private nonisolated static func fileExtension(for data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              // ImageIO 给的是 UTI（`public.png` / `public.jpeg` / `com.compuserve.gif`…），再让系统换成后缀名
              let type = CGImageSourceGetType(source) as String?,
              let ext = UTType(type)?.preferredFilenameExtension else {
            // 认不出来时保守写 png：数据坏了也好、是系统不认识的冷门格式也好，至少图片读不出来时不会连累别的
            return "png"
        }
        return commonExtension(for: ext)
    }

    /// 系统给的后缀换成平时更常见的写法。
    ///
    /// 现在只有一处要换：JPEG 的官方后缀是 `jpeg`，而大家电脑里的文件基本都叫 `.jpg`。
    private nonisolated static func commonExtension(for ext: String) -> String {
        let lowered = ext.lowercased()
        return lowered == "jpeg" ? "jpg" : lowered
    }

    /// 数据的 MD5，小写十六进制字符串。
    private nonisolated static func md5Hex(of data: Data) -> String? {
        // 空数据算出来的哈希没有意义（而且那不是一张图），挡在这儿
        guard !data.isEmpty else { return nil }
        return Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
