//
//  MarkdownDocumentViewController+FloatingEditButton.swift
//  MarkdownEditorHy4
//
//  悬浮编辑按钮（半透明小圆点）的装配，以及「图片」那一下的挑图 + 落盘 + 插入。
//
//  ⚠️ 从 `MarkdownDocumentViewController.swift` 拆出来的：代码原样搬过来，只去掉了 `private`
//  （Swift 的 private 只在本文件可见，跨文件就调不到）。
//

import UIKit

extension MarkdownDocumentViewController {

    /// 悬浮编辑按钮：一个能被拖着走的半透明小圆点，点开是常用的那几个排版动作。
    ///
    /// ### 为什么接两根线就够了
    /// 按钮本身不认识编辑器内部，也不认识 markdown 语法：「哪个按钮对应哪几个字符」写在 `MarkdownQuickAction` 里，这里只告诉它动作施加到 `editor` 上。
    func setupFloatingEditButton() {
        floatingEditButton.textView = editor
        // 「图片」这一下要弹系统选择器，按钮层不认识相册和文件，所以只把请求转过来。
        // 选择器、落盘、把路径交给编辑器，全部收在下面 `chooseImageToInsert` 里
        floatingEditButton.onRequestInsertImage = { [weak self] in
            self?.chooseImageToInsert()
        }
        view.addSubview(floatingEditButton)
    }

    /// 悬浮按钮上「图片」那一下：挑一张图，按「插入图片」那组设置落盘，再把路径交给编辑器。
    ///
    /// ### 为什么选择器和落盘都在这一层
    /// `MarkdownEditor/` 将来要单独开源，它只提供 `insertImageMarkdown(path:alt:)`：给它路径，它负责插进 markdown。
    /// 从相册或文件里挑图、图片存到哪个目录，都是 App 自己的事，组件里不出现任何图库 API。
    ///
    /// ### 为什么挑完还要 `becomeFirstResponder`
    /// 系统面板一弹，编辑器就丢焦点了。插完把焦点还回去，用户接着敲字才会落在图片后面，不用再点一下正文。
    func chooseImageToInsert() {
        // 只读模式下编辑器会拦下插入，提前说一声，免得用户挑完图才看到没反应
        guard !editor.isReadOnly else {
            flashStatus("只读模式下不能插入图片")
            return
        }

        let picker = MarkdownImagePicker(presenter: self) { [weak self] selection in
            guard let self else { return }
            // 不管挑没挑成，这次选择都结束了。不置空的话每插一次就多留一个对象
            self.imagePicker = nil
            // nil = 用户取消（或者没读出数据），当什么都没发生
            guard let selection else { return }

            // 和粘贴图片走同一套设置：存哪儿、文件叫什么名字都听「插入图片」那一组
            let outcome = ImageAssetStore.write(selection.data,
                                                for: self.openedFileURL,
                                                originalFileName: selection.originalFileName)
            if let note = outcome.note { self.flashStatus(note) }
            guard let path = outcome.path else {
                self.showAlert(title: "插入图片失败",
                               message: "这张图片没能存到笔记旁边。检查一下笔记所在的目录是不是还能写。")
                return
            }

            // 替代文字用图片原来的名字（没有就用「图片」）。文件名里的方括号由组件负责去掉
            let alt = selection.originalFileName.map { ($0 as NSString).deletingPathExtension } ?? "图片"
            guard self.editor.insertImageMarkdown(path: path, alt: alt) else { return }

            self.editor.becomeFirstResponder()
            self.flashStatus("已插入图片 \(path)")
        }
        imagePicker = picker
        picker.start()
    }
}

