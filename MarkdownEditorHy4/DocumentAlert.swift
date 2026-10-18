//
//  DocumentAlert.swift
//  MarkdownEditorHy4
//
//  弹一个只有「好」按钮的提示框，全 App 共用。
//
//  原来每个控制器都自己写一份「造 alert、加按钮、present」。复制时最容易漏的是那句时序判断
//  （见 `show(title:message:from:)`），漏了就会在冷启动时静默失效。
//
//  从 `MarkdownDocumentViewController` 抽出来的，逻辑没变。
//

import UIKit

enum DocumentAlert {

    /// 弹一个只有「好」按钮的提示框。
    ///
    /// ### 为什么要判断 `view.window == nil`
    /// 冷启动时（比如「打开文档」这条链路里出错），控制器的 view 可能还没挂到窗口上，
    /// 这时 `present` 会**静默失败**，用户什么都看不到，还以为程序没反应。
    /// 挂不上就等下一拍再弹，那时候窗口通常已经有了。
    ///
    /// - Parameters:
    ///   - title: 标题，一句话说清出了什么事
    ///   - message: 正文，给用户看的原因和下一步怎么办
    ///   - controller: 从谁身上弹（谁在前台就是谁）
    static func show(title: String, message: String, from controller: UIViewController) {
        // 闭包里只弱引用控制器：等下一拍的那条路上，控制器可能已经被关掉了
        let presentBlock = { [weak controller] in
            guard let controller else { return }
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default))
            controller.present(alert, animated: true)
        }
        if controller.view.window == nil {
            DispatchQueue.main.async(execute: presentBlock)
        } else {
            presentBlock()
        }
    }
}
