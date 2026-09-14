//
//  OutlineTree.swift
//  MarkdownEditorHy4
//
//  目录的「标题树」：把扁平的标题列表变成 H1 套 H2、H2 套 H3……的层级结构，
//  并回答两个折叠功能必需的问题 ——「哪些行现在还看得见」「这一行被折起来之后该点亮谁」
//

import Foundation

/// 标题树的「下标版」结构。
///
/// ### 为什么是「一堆下标数组」而不是一棵 `class OutlineNode` 树
/// 常见写法是给每个节点建一个 `class`、带 `parent` / `children` 引用。
/// 本项目刻意没那么干，两个原因：
///
/// 1. **避开一个会崩的坑**：app target 开了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，
///    新增一个「不继承 UIView 的 class」就必须手写 `nonisolated deinit {}`，
///    否则 Swift 6.2 运行时会在特定释放时机 free 野指针直接崩（项目里已经踩过好几次，
///    详见 `MarkdownBlock` / `OutlineCoordinator` 里的长注释）。
///    这里全部用 `struct` + 整数下标，一个 `class` 都不引入，从根上不碰这个问题。
/// 2. **写测试更省事**：树是纯值类型，造一份、断言一下就行，不用管引用关系和内存。
///
/// ### 为什么下标之间能表示父子关系
/// `items` 按文档顺序排列（`sourceOffset` 递增），所以「某个标题的整棵子树」在数组里
/// 必然是一段**连续区间**。于是：
/// - `children[i]` 存 i 的直接子节点下标；
/// - `subtreeEnd[i]` 存「i 的子树」这段连续区间的结束位置（不含），
///   折叠第 i 行时直接跳到 `subtreeEnd[i]` 就跳过了它的全部后代。
struct OutlineTree {

    /// 全部条目，按文档顺序 —— 和传进来的数组同一个顺序，下标可以互相换算
    let items: [OutlineItem]

    /// 每个节点的父节点下标；根节点的父是 nil
    let parents: [Int?]

    /// 每个节点的直接子节点下标；叶子是空数组
    let children: [[Int]]

    /// 根节点下标（H1，或者「前面没有更浅标题」的那些）
    let roots: [Int]

    /// 「i 的整棵子树」在 `items` 里的结束位置（不含 i 自己）。
    /// 叶子节点的这个值等于 `i + 1`
    private let subtreeEnd: [Int]

    /// id → 下标。UI 层拿到的永远是条目的 id（点击、高亮都是 id），
    /// 而树里全部用下标算，所以要有一份反查表，免得每次都线性找一遍
    private let indexByID: [UUID: Int]

    // MARK: 构建

    /// 一次线性扫描把扁平列表攒成树。
    ///
    /// 做法用一个「栈」记录当前还没闭合的祖先链：
    /// 每读到一个标题，就把栈里所有「层级 >= 自己」的祖先弹掉（它们不可能再是父节点了），
    /// 弹完之后栈顶就是自己的父节点 —— 没有栈顶就是根。
    init(items: [OutlineItem]) {
        self.items = items

        var parents = [Int?](repeating: nil, count: items.count)
        var children = [[Int]](repeating: [], count: items.count)
        var roots: [Int] = []
        var stack: [Int] = []

        for index in items.indices {
            let level = items[index].level
            // 同级或更深的祖先都已经闭合（H3 后面又来了个 H2，那个 H3 就不可能是父了）
            while let top = stack.last, items[top].level >= level {
                stack.removeLast()
            }
            if let parent = stack.last {
                parents[index] = parent
                children[parent].append(index)
            } else {
                roots.append(index)
            }
            stack.append(index)
        }

        self.parents = parents
        self.children = children
        self.roots = roots
        self.subtreeEnd = Self.computeSubtreeEnds(items: items, children: children)
        self.indexByID = Dictionary(items.enumerated().map { ($0.element.id, $0.offset) },
                                    uniquingKeysWith: { first, _ in first })
    }

    // MARK: 按 id 查

    /// 这个 id 在 `items` 里排第几。列表里没有（比如是上一次编辑留下的旧 id）返回 nil
    func index(of id: UUID) -> Int? {
        indexByID[id]
    }

    /// 这一行有没有子标题 —— 有才配显示展开 / 折叠三角
    func hasChildren(at index: Int) -> Bool {
        !children[index].isEmpty
    }

    /// 这一行能不能折 —— 右边的展开 / 折叠三角只画在「能折的行」上。
    ///
    /// 两个条件缺一不可：
    /// 1. **层级在 H1-H5**：H6 是最深一级，不可能有下级（没有 H7）；
    /// 2. **底下确实还有标题**：叶子行折起来不会有任何东西消失，
    ///    画个三角在那儿，用户点了什么都不发生，反而像是坏了。
    ///
    /// 面板的三角显示、`toggleCollapse` 的守卫、以及标题栏那个
    /// 「全部折叠」要折哪些行，三处都走这一个判据，免得改了一处漏另一处
    func canCollapse(at index: Int) -> Bool {
        items[index].level <= 5 && hasChildren(at: index)
    }

    /// 所有能折的行的下标（顺序无关，调用方多半要转成 id 集合）
    var collapsibleIndices: [Int] {
        items.indices.filter { canCollapse(at: $0) }
    }

    /// 自底向上算出每个节点的 `subtreeEnd`。
    ///
    /// 从最后一个节点往前扫：它的整棵子树结束于「它所有孩子的 subtreeEnd 里最大的那个」，
    /// 没有孩子时就是自己后面一位。倒着扫保证用到的孩子值都算好了。
    private static func computeSubtreeEnds(items: [OutlineItem], children: [[Int]]) -> [Int] {
        var ends = [Int](repeating: 0, count: items.count)
        for index in items.indices.reversed() {
            ends[index] = children[index].reduce(index + 1) { max($0, ends[$1]) }
        }
        return ends
    }

    // MARK: 折叠相关查询

    /// 第 index 行折叠时，会把「到哪儿为止」的行藏起来 —— 也就是它的整棵子树。
    /// 返回的是「下一个该显示的行」的下标
    func endOfSubtree(at index: Int) -> Int {
        subtreeEnd[index]
    }

    /// 这一行现在看得见吗（自己或任意一层祖先被折叠 → 看不见）
    func isHidden(_ index: Int, collapsedIDs: Set<UUID>) -> Bool {
        representativeIndex(of: index, collapsedIDs: collapsedIDs) != index
    }

    /// 当前**看得见**的行，按文档顺序返回。
    ///
    /// 折叠一行时不用一行一行去 `isHidden`，直接跳过它那整段子树（连续区间），
    /// 所以整趟只跟「标题总数」成正比，跟树有多深没关系。
    func visibleIndices(collapsedIDs: Set<UUID>) -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(items.count)

        var index = 0
        while index < items.count {
            result.append(index)
            // 只有「真的折叠了、而且确实还有后代」才跳 —— 光有折叠标记但已经没有孩子的行
            // （比如用户把子标题删了）必须照常显示，否则那一行就永远消失了
            if collapsedIDs.contains(items[index].id), !children[index].isEmpty {
                index = subtreeEnd[index]
            } else {
                index += 1
            }
        }
        return result
    }

    /// 「这一行如果被折起来了，界面上应该点亮哪一行」——返回的是可见的代表行下标。
    ///
    /// ### 为什么高亮要往上找
    /// 光标停在某个被折叠的 H3 下面的正文里时，H3 那一行是不显示的。
    /// 这时要是还照着 H3 去点亮，用户根本看不到任何反馈（亮在了一个隐藏的行上）。
    /// 正确做法是往上找**最外层那个被折叠的祖先**，点亮它 —— 那才是用户眼里
    /// 「当前章节」所在的那一行。
    ///
    /// 取「最外层」而不是「最近的那一层」：祖先链上可能连着被折叠两层，
    /// 里层那层自己也是隐藏的，只有最外面那个是真正显示着的。
    func representativeIndex(of index: Int, collapsedIDs: Set<UUID>) -> Int {
        var result = index
        var current = parents[index]
        while let parent = current {
            if collapsedIDs.contains(items[parent].id) { result = parent }
            current = parents[parent]
        }
        return result
    }
}

// MARK: - 折叠状态怎么跨「列表重建」活下来

/// 折叠状态的新旧对账。
///
/// ### 为什么需要这么一层
/// `OutlineItem.id` 直接复用 `MarkdownBlock.id`（UUID），而编辑器每次增量编辑都会
/// **重新创建受影响的块**，UUID 跟着换新。所以「用户折叠了哪几个标题」这件事
/// 不能简单地存成一个 `Set<UUID>` 就完事 —— 编辑一下，里面存的 id 就全部失效了，
/// 用户会觉得「我折好的层级又自己弹开了」。
///
/// 项目里已经有同样问题的既有解法（`MarkdownDocumentStore.inheritCollapseStates`：
/// 按「源码起点相同」或「源码文本相同」把旧块的折叠状态传给新块），这里沿用同一套思路，
/// 只是在标题这个粒度上做。
///
/// ### 匹配规则
/// 1. **源码起点 + 层级都一样** → 同一个标题。覆盖「原地改标题文字」（位置不动）
///    和「在标题行内部编辑」这两种最常见的情况。
/// 2. **层级 + 标题文字都一样** → 同一个标题。覆盖「标题整体被上面的正文顶移了」，
///    这时候位置变了但文字没变。文字太短的（少于 2 个字）不参与，太容易跟别处撞车，
///    认错了比丢掉更烦人（用户会看到「折叠状态跑到别的标题上去了」）。
/// 3. 两条都匹配不上 → 这个标题在编辑里被删掉了，折叠状态跟着一起丢掉。
enum OutlineCollapseState {

    /// 把 `oldItems` 里那些「折叠着」的标题，对应到 `newItems` 里的新 id 上。
    ///
    /// - returns: 新的折叠 id 集合。旧集合为空时直接返回空集合，不做任何多余工作
    static func inherit(from oldItems: [OutlineItem],
                        collapsedIDs: Set<UUID>,
                        to newItems: [OutlineItem]) -> Set<UUID> {
        guard !collapsedIDs.isEmpty else { return [] }

        /// 已经被认领的新下标。一个旧标题只能认领一个新标题，
        /// 否则两个同名标题会双双继承同一份折叠状态
        var claimed = Set<Int>()
        func claim(_ matches: (OutlineItem) -> Bool) -> OutlineItem? {
            for index in newItems.indices where !claimed.contains(index) {
                if matches(newItems[index]) {
                    claimed.insert(index)
                    return newItems[index]
                }
            }
            return nil
        }

        var result: Set<UUID> = []
        for old in oldItems where collapsedIDs.contains(old.id) {
            // 规则 1：位置 + 层级都一致
            if let matched = claim({ $0.sourceOffset == old.sourceOffset && $0.level == old.level }) {
                result.insert(matched.id)
                continue
            }
            // 规则 2：被顶移了，但「层级 + 文字」还是老样子
            if old.title.count >= 2,
               let matched = claim({ $0.level == old.level && $0.title == old.title }) {
                result.insert(matched.id)
                continue
            }
            // 规则 3：认不出来 → 当作被删了，折叠状态不继承
        }
        return result
    }
}
