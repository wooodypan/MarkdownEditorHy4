//
//  ImageAssetStore.swift
//  MarkdownEditorHy4
//
//  粘贴 / 插入的图片**存到哪个文件夹、正文里写什么路径** —— 按设置页「插入图片」那一组的选择来。
//
//  编辑层（`MarkdownEditor/`）只管「把字节写成一个文件」，存哪儿这件事只在这儿做主，
//  通过 `MarkdownPasteboardController.imageFileWriter` 这个口子塞回去。
//

import Foundation

/// 图片落盘的落地策略。
enum ImageAssetStore {

    /// 一次落盘的结果。
    struct Outcome {
        /// 正文里要写的图片路径。`nil` = 这次没写进去（调用方按「没接管」处理）
        var path: String?
        /// 需要跟用户说一句的话。正常情况是 `nil`，只有「本来该存 A 但没写成、退到了 B」时才给
        var note: String?
    }

    /// 把一张图片按当前设置存下来，返回正文里该写的路径。
    ///
    /// - Parameters:
    ///   - data: 图片原始字节
    ///   - documentURL: 正在编辑的那份笔记的磁盘位置。传 `nil`（理论上不该出现，沙盒里每份笔记都是真文件）时退回 App 的 Documents 目录
    ///   - originalFileName: 图片原来的文件名（从 Finder 里复制的那张图才有）。设置选「用原始文件名」时拿它当名字
    static func write(_ data: Data, for documentURL: URL?, originalFileName: String? = nil) -> Outcome {
        let settings = MarkdownEditorSettings.shared
        // 相对路径的分母：笔记在哪个目录，图片就相对于哪个目录摆
        let documentDirectory = documentURL?.deletingLastPathComponent() ?? DocumentsWorkspace.folderURL
        // 名字规则一次算清，四条分支共用同一个 —— 免得以后加了新分支忘了带名字
        let naming = naming(for: settings.imageNameMode, originalFileName: originalFileName)

        switch settings.imageInsertionMode {
        case .currentFolder:
            // 图片和笔记并排躺在一起，正文里写文件名就行（不带任何目录）
            guard let name = MarkdownImageFileStore.store(data, in: documentDirectory, naming: naming) else {
                return Outcome()
            }
            return Outcome(path: name)

        case .assetsFolder:
            return writeToAssets(data, documentDirectory: documentDirectory, naming: naming)

        case .documentFolder:
            // 和笔记同名的一个文件夹：`游记.md` → `游记/`。
            // 笔记还没落盘、拿不到名字时退回 assets，总比散在目录里强
            guard let documentURL else {
                return writeToAssets(data, documentDirectory: documentDirectory, naming: naming)
            }
            let folderName = documentURL.deletingPathExtension().lastPathComponent
            guard !folderName.isEmpty else {
                return writeToAssets(data, documentDirectory: documentDirectory, naming: naming)
            }
            let directory = documentDirectory.appendingPathComponent(folderName, isDirectory: true)
            guard let name = MarkdownImageFileStore.store(data, in: directory, naming: naming) else { return Outcome() }
            return Outcome(path: "\(folderName)/\(name)")

        case .customFolder:
            // 用户自己挑的固定文件夹（只有 Mac 上能选）。
            // 它多半在笔记目录之外，相对路径表达不了，所以正文里写**完整路径**
            let fallback = writeToAssets(data, documentDirectory: documentDirectory, naming: naming)
            guard let folder = settings.imageCustomFolderURL else {
                return Outcome(path: fallback.path,
                               note: "还没选过「指定路径」的文件夹，这张先存到了 ./assets")
            }
            guard let name = MarkdownImageFileStore.store(data, in: folder, naming: naming) else {
                // 文件夹被删了 / 挪走了 / 没权限写 —— 不能就这么静默失败（粘贴会像「点了没反应」），
                // 退到 ./assets 保证图能插进来，同时明确告诉用户发生了什么
                return Outcome(path: fallback.path,
                               note: "写不进 \(folder.lastPathComponent)，这张先存到了 ./assets")
            }
            return Outcome(path: folder.appendingPathComponent(name).path)
        }
    }

    /// 设置页选的「文件名怎么起」→ 落盘那层认识的规则。
    ///
    /// ### 「用原始文件名」为什么可能变成哈希
    /// 只有从 Finder 里复制过来的图才带着原始文件名；截图、网页里的图、剪贴板里
    /// 只有一份解码后图片的，都没有名字可用。这时候退回内容哈希 ——
    /// 总比现编一个「图片 1」强（那种名字不但没意义，还得再记账才不重名）。
    ///
    /// ### 时间为什么不在这儿生成
    /// 时间名字由 `MarkdownImageFileStore` 自己现取，这里只把「用时间」这件事说出去 ——
    /// 少一个需要传下去的 `Date`，也少一个「拿哪个时刻」的疑问（就该是落盘那一下）。
    private static func naming(for mode: ImageNameMode, originalFileName: String?) -> MarkdownImageNaming {
        switch mode {
        case .originalName:
            guard let originalFileName, !originalFileName.isEmpty else { return .contentHash }
            return .originalFileName(originalFileName)
        case .timestamp:
            return .timestamp(Date())
        case .contentHash:
            return .contentHash
        }
    }

    /// 存进笔记旁边的 `./assets`。默认位置，也是「指定路径」出问题时退守的地方。
    private static func writeToAssets(_ data: Data,
                                      documentDirectory: URL,
                                      naming: MarkdownImageNaming) -> Outcome {
        let directory = documentDirectory.appendingPathComponent("assets", isDirectory: true)
        guard let name = MarkdownImageFileStore.store(data, in: directory, naming: naming) else { return Outcome() }
        return Outcome(path: "assets/\(name)")
    }
}
