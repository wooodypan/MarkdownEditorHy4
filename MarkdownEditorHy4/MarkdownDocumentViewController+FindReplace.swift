//
//  MarkdownDocumentViewController+FindReplace.swift
//  MarkdownEditorHy4
//
//  「查找 / 替换」这一摊：铺查找条、开 / 收，把选中的字预填进查找框。
//
//  ⚠️ 从 `MarkdownDocumentViewController.swift` 拆出来的：代码原样搬过来，只去掉了 `private`
//  （Swift 的 private 只在本文件可见，跨文件就调不到）。
//

import UIKit

extension MarkdownDocumentViewController {

    // MARK: 查找 / 替换

    /// 铺查找条，并把编辑器、协调者、查找条三者接起来。
    ///
    /// 装配代码放在这里，理由和 `setupOutline` 一样：协调者不建在编辑器或查找条内部，否则两个组件就得互相持有对方。连接集中在这一处，两边初始化都不用对方的实例。
    ///
    /// ### 为什么出现 / 消失都不挪动正文
    /// 横条浮在正文上面：位置固定在菜单栏下面，显示与否只切 `isHidden`，高度不参与排版。
    /// 正文的上边钉在菜单栏下面（不挂在查找条下边），横条出现时正文不会动。代价是它会盖住正文最上面一小条，点查找时注意力在查找框上，影响不大。
    /// 两个前提别弄反：① 它必须在正文**之后**加进视图（后加的画在上面）；② 别再给它钉任何高度约束，高度由它自己里面的内容撑。
    func setupFindBar() {
        findBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(findBar)

        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: contentTopAnchor, constant: 2),
//            findBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            findBar.widthAnchor.constraint(equalToConstant: 350),
            findBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -60)
        ])

        // 三根线：数据源、展示方、以及编辑器往外报「内容变了」的出口
        searchCoordinator.searchDataSource = editor
        searchCoordinator.findBar = findBar
        findBar.delegate = searchCoordinator
        editor.searchEventSink = searchCoordinator

        // 「把自己藏起来」是容器的事（查找条自己不认识容器），所以出口交回这里
        findBar.onDismiss = { [weak self] in self?.hideFindBar() }
    }
}

extension MarkdownDocumentViewController {

    /// 显示查找条（⌘F / 菜单里的「查找」都走到这里）
    @objc func showFindBar() {
        guard findBar.isCollapsed else {
            // 已经开着：再按一次 ⌘F 只把焦点交还给查找框（常见的查找框行为）。
            // 选中文字照样要填进去：选了新词再按 ⌘F，多半就是想换一个词找
            fillQueryFromSelection()
            findBar.beginSearch()
            return
        }
        // 先取消隐藏，再淡入。位置固定，只动透明度，正文不会被挤
        findBar.setCollapsed(false)
        findBar.alpha = 0
        UIView.animate(withDuration: 0.15) { self.findBar.alpha = 1 }
        fillQueryFromSelection()
        findBar.beginSearch()
    }

    /// 把正文里选中的文字预填进查找框（没选中就什么都不做，保留上一次的查找词）
    func fillQueryFromSelection() {
        guard let selected = editor.selectedSourceText else { return }
        findBar.fillQuery(selected)
    }

    /// 收起查找条：先撤焦点（免得键盘一直挂在它上面），再直接藏起来。
    ///
    /// 标 `@objc` 是为了让测试能直接驱动它（查找框那条关闭链路是异步的，测起来不方便）
    @objc func hideFindBar() {
        guard !findBar.isCollapsed else { return }
        findBar.endSearch()
        findBar.setCollapsed(true)
        // 透明度还原成不透明，下次显示时才能从透明淡入
        findBar.alpha = 1
    }
}

