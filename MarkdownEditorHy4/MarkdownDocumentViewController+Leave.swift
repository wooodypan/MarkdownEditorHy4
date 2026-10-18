//
//  MarkdownDocumentViewController+Leave.swift
//  MarkdownEditorHy4
//
//  离开这一页之前的确认（返回按钮和左边缘滑动两条路），以及手势代理的接管与归还。
//
//  ⚠️ 从 `MarkdownDocumentViewController.swift` 拆出来的：代码原样搬过来，只去掉了 `private`
//  （Swift 的 private 只在本文件可见，跨文件就调不到）。
//

import UIKit

extension MarkdownDocumentViewController {

    // MARK: 返回前的确认

    /// 导航栏左上角「返回」被点了一下。
    ///
    /// 没改过就直接回去，改过就先问一句「存 / 不存 / 算了」。
    @objc func handleBackTapped() {
        guard isDirty else {
            popBack()
            return
        }
        promptSaveBeforeLeaving()
    }

    /// 有改动没存时，走之前问一句要怎么办。
    ///
    /// ### 为什么是三个选项
    /// - 保存：存完再走（存盘可能要绕一趟「起名字」，见 `saveThenLeave`）；
    /// - 不保存：改动丢掉，用 `destructive` 红字，防手滑；
    /// - 取消：留在这一页接着改。加这一个，是因为返回键太好按了，只有「存 / 不存」的话，手滑一下就得二选一，改动白丢。
    ///
    /// 返回按钮和「从左边缘滑回去」两条路都走这里（见 `gestureRecognizerShouldBegin`），所以「带着改动离开」这个规矩只有一处。
    func promptSaveBeforeLeaving() {
        // 已经弹着东西了（比如用户连滑两下）就不再叠一个
        guard presentedViewController == nil else { return }

        let name = openedFileURL?.lastPathComponent ?? "这份文档"
        let alert = UIAlertController(title: "要保存改动吗？",
                                      message: "「\(name)」改了还没存，返回就没了。",
                                      preferredStyle: .alert)

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "不保存", style: .destructive) { [weak self] _ in
            self?.popBack()
        })
        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self] _ in
            self?.saveThenLeave()
        })

        present(alert, animated: true)
    }

    /// 返回时选了「保存」：存完就把这一页弹回去。
    ///
    /// ### 为什么这里只挂个标记，不直接存完再弹
    /// 存盘这一下可能不是终点：新建的文档还顶着占位名，`saveDocument()` 会先弹框请用户起名字（见 `promptForFileName`），输完名字才算真的存完。
    /// 所以这里先挂一笔「存完就走」，由 `writeCurrentSource` 在真正写成功那一次执行；用户中途取消（不起名字了）就把标记抹掉，人留在原地。
    func saveThenLeave() {
        guard openedFileURL != nil else {
            // 没有对应文件（宿主没送内容项），存不了。
            // 走正常保存那条路把提示弹出来就行，别顺手设标记：没地方可存，也就没有「存完」那一刻
            saveDocument()
            return
        }
        popAfterSaving = true
        saveDocument()
    }

    /// 把这一页从导航栈里弹回去（等于按了返回）。
    func popBack() {
        navigationController?.popViewController(animated: true)
    }

    /// 把「从左边缘滑回去」那个手势的代理接过来（只在 iPhone 上）。
    ///
    /// ### 为什么要管这个手势
    /// 返回按钮拦住了，可用户还能从左边缘一滑，那条路一样会静默 pop，改动照样丢，等于只堵了一半。接了代理就能在 `gestureRecognizerShouldBegin` 里先看一眼改过没有，改过就不让滑，改成问一句。
    ///
    /// ### 为什么要把原来那个代理存下来
    /// 这个手势的代理本来是导航控制器自己，它靠代理做两件事：拦下「栈里只有一页时的手势」（不然会滑出半截卡住的动画），以及驱动交互式转场。
    /// 本页离开时必须原样还回去，直接把代理置空，下一个页面就要出怪事。
    func takeOverPopGestureIfNeeded() {
        guard usesNavigationBarMenuButton,
              let gesture = navigationController?.interactivePopGestureRecognizer,
              gesture.delegate !== self else { return }
        popGesturePreviousDelegate = gesture.delegate
        gesture.delegate = self
    }

    /// 把「左边缘滑回去」手势的代理还回去。
    func giveBackPopGesture() {
        guard let gesture = navigationController?.interactivePopGestureRecognizer,
              gesture.delegate === self else { return }
        gesture.delegate = popGesturePreviousDelegate
        popGesturePreviousDelegate = nil
    }
}

extension MarkdownDocumentViewController: UIGestureRecognizerDelegate {

    /// 「从左边缘滑回去」这个手势要不要开始。
    ///
    /// 两条判据，缺一不可：
    /// 1. 栈里得真有两页以上。这是导航控制器自己原来那条判据，接代理时最容易漏。漏了的话在根页（左侧栏）上也能滑，滑出来是个卡住的半截动画，导航条从此不吃点击；
    /// 2. 没有未保存的改动。滑完就直接 pop 走了，中间没有插话的机会，所以改过就不让它滑：这一下先拒掉（免得留下半截动画），再把返回按钮那个确认框弹出来，两条路的规矩保持一致。
    ///
    /// 代理只装在「左边缘滑回去」这一个手势上（见 `takeOverPopGestureIfNeeded`），别的手势不会走到这儿来。
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // 根页不许滑：不然后面没有可返回的页面，手势会滑出一个卡死的半截动画
        guard (navigationController?.viewControllers.count ?? 0) > 1 else { return false }
        guard isDirty else { return true }

        // 等这一下手势处理完再弹框：在 `shouldBegin` 里当场 present，会和正在收尾的手势状态撞上
        DispatchQueue.main.async { [weak self] in
            self?.promptSaveBeforeLeaving()
        }
        return false
    }
}

