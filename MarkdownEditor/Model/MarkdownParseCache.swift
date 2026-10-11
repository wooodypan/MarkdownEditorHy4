//
//  MarkdownParseCache.swift
//  MarkdownEditorHy4
//
//  cmark 解析结果缓存：同一份源码不重复解析
//

import Markdown

/// swift-markdown（`Document(parsing:)`）的解析结果缓存：源码当 key，源码没变就直接把上次的 AST 还回来。
///
/// ### 为什么需要它
/// 一篇文档在**内容一个字都没改**的情况下会被反复解析：
/// 换主题 / 换配色、拉窗口改宽度（图片要按新宽度重算）、折叠整篇、切回文档时补的那次重排 —— 这些路径都要走一遍 `MarkdownDocumentStore.load`，于是整篇重新丢给 cmark。
/// 而且一份源码要被解析**两遍**：`buildBlocks` 按「受影响的区域」解析一次用来切块，`MarkupToAttributedRenderer.render` 再按「单个块」解析一次用来渲染（即「每块 parse 两遍」）。
///
/// 缓存之后，源码没变的那些路径解析次数直接降到 0。
///
/// ### key 只有源码，不含主题 / 宽度
/// 主题、容器宽度只影响「AST → 富文本」那一步，不影响 AST 本身。
/// 把它们掺进 key，换主题时就会全部失效 —— 而那恰恰是最该命中的场景。
///
/// ### 为什么可以安全地共用一棵 AST
/// `Document` 是 struct（底层是引用计数的 `_MarkupData`），渲染过程只是**读**它的 `children` / `range`，不修改。
/// 缓存的是值本身，谁拿到都是同一份只读数据。
///
/// ### 上限怎么定
/// AST 比源码大得多（每个节点都是对象），所以按**缓存的源码字符数**封顶，超了就丢掉最久没用的那批。
/// 默认 200 万字符 ≈ 2 MB 源码：日常文档（几万字符）离上限很远；真撞上上限也只是退化成「不缓存」，结果不会错。
final class MarkdownParseCache {

    /// 缓存的源码字符数上限
    let capacity: Int

    /// 命中次数（测试和调效看它，不参与任何逻辑判断）
    private(set) var hitCount = 0
    /// 未命中（真去解析）的次数
    private(set) var missCount = 0

    private struct Entry {
        let document: Document
        /// 这段源码占的字符数，按它算容量
        let size: Int
        /// 最近一次被用到的时刻（数字越大越新）
        var lastUsed: UInt64
    }

    private var entries: [String: Entry] = [:]
    /// 单调递增的逻辑时钟，用来挑出「最久没用的」—— 比记时间戳省事，也不受系统时间影响
    private var clock: UInt64 = 0
    private var cachedCharacters = 0

    /// 原因见 `MarkdownBlock` 里 `nonisolated deinit` 的注释：
    /// 隔离 deinit 一旦嵌套就会踩 Swift 6.2 运行时的野指针 free。
    nonisolated deinit {}

    init(capacity: Int = 2_000_000) {
        self.capacity = capacity
    }

    /// 取 `source` 对应的 AST。命中就直接还回上次那棵，没命中才解析并存起来。
    func document(for source: String) -> Document {
        clock += 1
        if let entry = entries[source] {
            // 原地改 lastUsed（字典取值是拷贝，改完要写回去）
            entries[source]?.lastUsed = clock
            hitCount += 1
            return entry.document
        }

        missCount += 1
        let document = Document(parsing: source)
        let size = source.count
        entries[source] = Entry(document: document, size: size, lastUsed: clock)
        cachedCharacters += size
        evictIfNeeded(protecting: source)
        return document
    }

    /// 清空缓存（换文档时用：旧文档那批 AST 一个都用不上了）。
    ///
    /// ⚠️ 只清缓存，**不动** hit / miss 计数 —— 统计是给调效看的，清空一次缓存不该把之前攒的数字抹掉。
    func removeAll() {
        entries.removeAll()
        cachedCharacters = 0
    }

    /// 超容量就丢掉最久没用的那一批，一直丢到只剩一半为止（一次只丢一个的话，下一次插入马上又要排一遍序）。
    ///
    /// - parameter source: 刚放进来那份的 key。**它不能被自己这轮淘汰掉** ——
    ///   否则一篇超过容量的大文档会「刚解析完就被挤出去」，缓存等于白做。
    private func evictIfNeeded(protecting source: String) {
        guard cachedCharacters > capacity else { return }
        let victims = entries
            .filter { $0.key != source }
            .sorted { $0.value.lastUsed < $1.value.lastUsed }
        var freed = 0
        for (key, entry) in victims {
            guard cachedCharacters - freed > capacity / 2 else { break }
            entries.removeValue(forKey: key)
            freed += entry.size
        }
        cachedCharacters -= freed
    }
}
