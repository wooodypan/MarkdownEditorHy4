//
//  DocumentFolderAccess.swift
//  MarkdownEditorHy4
//
//  文档所在文件夹的权限：够不够用、有几张图因此读不到。
//

import Foundation

/// 检查一份文档所在文件夹的读写权限。
///
/// 大白话：App 像一个上了锁的办公室，用户从 Finder 里双击递进来的每份文件只带「它自己」的通行证，同一个文件夹里的图片、子目录都没带。
/// 于是笔记本身能打开能改，旁边的图却显示不出来、粘贴图片也存不进去 —— 用户看到的就是「图片坏了」。
///
/// 这里只负责回答「够不够用」「几张图读不到」这类问题，不会弹框、也不会要新权限。唯一会主动做的事：用户以前亲手给过某个文件夹的权限，这里能把存好的那份找回来（见 `restoreFolderAccess`）。
enum DocumentFolderAccess {

    /// 这个文件夹现在能不能读（能列出里面有什么就算能读）
    ///
    /// ### 为什么不用 `isReadableFile`
    /// 沙盒拒绝对一个目录的访问时，`isReadableFile` 和「目录不存在」都返回 false，分不出是哪种情况；
    /// 而列目录会真的抛错，拿得到错误类型，排查时能看出是不是权限问题。
    static func isReadable(_ directory: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) != nil
    }

    /// 这个文件夹现在能不能新建 / 覆盖文件
    ///
    /// 读和写分开问：只读授权的文件夹（比如从只读磁盘挂上来的）能看图但存不进新图。
    static func isWritable(_ directory: URL) -> Bool {
        FileManager.default.isWritableFile(atPath: directory.path)
    }

    /// 一份文档所在的文件夹现在够不够用（能读能写）
    ///
    /// 文档还没保存过（连自己的路径都没有）时算够用：那种情况下图片存进 App 自己的 Documents，谈不上权限。
    ///
    /// 第一次判断不通过时，会先把上次存好的文件夹通行证找回来，再判一次。App 一重启，系统就把权限收了回去，不找回来，用户每重启一次就得重新挑一次文件夹。
    static func isAvailable(forDocumentAt documentURL: URL?) -> Bool {
        guard let documentURL else { return true }
        let directory = documentURL.deletingLastPathComponent()
        if isUsable(directory) { return true }
        ExternalDocumentAccess.shared.restoreFolderAccess(for: directory)
        return isUsable(directory)
    }

    /// 能读又能写才算够用。只能读的文件夹，图能看，但新图存不进去
    private static func isUsable(_ directory: URL) -> Bool {
        isReadable(directory) && isWritable(directory)
    }

    /// 数一数：这份源码里引用的本地图片，有几张现在读不到。
    ///
    /// ### 为什么要在打开文档时就数一遍
    /// 图片读不到时渲染器会静默退化成源码原文（`![](./assets/x.png)` 一行字），用户只会觉得「图裂了」，
    /// 根本想不到是权限。先数出来，提示里就能说清楚「有 5 张图读不到，不是文件丢了」。
    ///
    /// - Parameters:
    ///   - source: 文档的 markdown 源码
    ///   - documentURL: 文档自己的位置，相对路径以它所在目录为基准
    static func unreadableImageCount(in source: String, documentURL: URL?) -> Int {
        guard let documentURL else { return 0 }
        let documentDirectory = documentURL.deletingLastPathComponent()
        return localImagePaths(in: source).reduce(into: 0) { count, path in
            if !isReadableImage(path, documentDirectory: documentDirectory) { count += 1 }
        }
    }

    /// 源码里所有本地图片的地址（网络地址、内嵌数据这些不算）。
    ///
    /// 地址有两种写法：普通的一串字符，或者用 `<…>` 包起来的（里面有空格时必须这么写）。
    /// 所以正则里分两个捕获组，谁有值取谁。
    private static func localImagePaths(in source: String) -> [String] {
        let pattern = #"!\[[^\]]*\]\(\s*(?:<([^>]*)>|([^)\s]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, range: fullRange).compactMap { match in
            // 两个捕获组只有一个会命中，另一个是 NSNotFound
            let captured = [match.range(at: 1), match.range(at: 2)].first { $0.location != NSNotFound }
            guard let range = captured.flatMap({ Range($0, in: source) }) else { return nil }
            let path = String(source[range])
            // 网络地址和内嵌数据不归这个文件夹管
            if path.contains("://") || path.hasPrefix("data:") { return nil }
            return path.isEmpty ? nil : path
        }
    }

    /// 一张本地图片现在能不能读到。
    ///
    /// 这里故意只用 `fileExists`：沙盒没权限时它返回 false，和「文件真的不存在」是同一个答案 ——
    /// 对用户来说这两种情况的结果一样（图看不到），提示里统一说「读不到」就够，不用分辨。
    private static func isReadableImage(_ path: String, documentDirectory: URL) -> Bool {
        let fileManager = FileManager.default
        if path.hasPrefix("/") {
            return fileManager.fileExists(atPath: path)
        }
        return fileManager.fileExists(atPath: documentDirectory.appendingPathComponent(path).path)
    }
}
