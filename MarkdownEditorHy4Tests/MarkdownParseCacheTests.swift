//
//  MarkdownParseCacheTests.swift
//  MarkdownEditorHy4Tests
//
//  解析缓存：源码一个字符没变，就不该再把 cmark 跑一遍（换主题、改窗口宽度走的就是这条路）
//

import XCTest
// 这个文件要直接摸 AST（`childCount` / `debugDescription()`），那些成员定义在 swift-markdown 的 `Markdown` 模块里 ——
// 不显式 import 的话 Swift 6 的 MemberImportVisibility 会拦下来（报「missing import of defining module」）
import Markdown
@testable import MarkdownEditorHy4

@MainActor
final class MarkdownParseCacheTests: XCTestCase {

    private let markdown = """
    # 标题一

    段落一，里面有 **粗体** 和 `行内代码`。

    - 列表项一
    - 列表项二

    ```swift
    let answer = 42
    ```

    > 引用块

    段落二收尾。
    """

    // MARK: 缓存本身

    func testSameSourceIsParsedOnlyOnce() {
        let cache = MarkdownParseCache()
        _ = cache.document(for: "# 甲\n\n正文")
        _ = cache.document(for: "# 甲\n\n正文")

        XCTAssertEqual(cache.missCount, 1, "同一份源码第二次该命中缓存，不该再解析")
        XCTAssertEqual(cache.hitCount, 1)
    }

    func testDifferentSourceIsParsed() {
        let cache = MarkdownParseCache()
        _ = cache.document(for: "# 甲")
        _ = cache.document(for: "# 乙")

        XCTAssertEqual(cache.missCount, 2)
        XCTAssertEqual(cache.hitCount, 0)
    }

    /// 命中还回来的那棵 AST 必须**真的能用** —— 结构和现解析的一模一样。
    func testCachedASTIsUsable() {
        let cache = MarkdownParseCache()
        let first = cache.document(for: markdown)
        let second = cache.document(for: markdown)

        XCTAssertEqual(second.childCount, first.childCount)
        XCTAssertEqual(second.debugDescription(), first.debugDescription())
    }

    func testCapacityEvictsLeastRecentlyUsed() {
        let cache = MarkdownParseCache(capacity: 20)
        _ = cache.document(for: "一二三四五六七八九十")   // 10 字符
        _ = cache.document(for: "甲乙丙丁戊己庚辛壬癸")   // 10 字符，合计 20，还没超
        _ = cache.document(for: "ABCDEFGHIJKLMNOP")     // 16 字符 → 超容量，最久没用的那份被丢掉

        let missesBefore = cache.missCount
        _ = cache.document(for: "一二三四五六七八九十")
        XCTAssertEqual(cache.missCount, missesBefore + 1, "被挤出去的那份再取该重新解析")
    }

    /// 刚放进来那份不能被自己这轮淘汰掉 —— 否则一篇超过容量的大文档等于没缓存
    func testInsertedEntrySurvivesItsOwnEviction() {
        let cache = MarkdownParseCache(capacity: 10)
        let source = "一二三四五六七八九十十一十二十三十四"   // 17 字符，本身就超容量
        _ = cache.document(for: source)

        let missesBefore = cache.missCount
        _ = cache.document(for: source)
        XCTAssertEqual(cache.missCount, missesBefore, "刚解析完就被自己挤出去的话，缓存等于白做")
    }

    func testRemoveAllDropsEverything() {
        let cache = MarkdownParseCache()
        _ = cache.document(for: "# 甲")
        cache.removeAll()
        _ = cache.document(for: "# 甲")

        XCTAssertEqual(cache.missCount, 2, "清空之后该重新解析")
        XCTAssertEqual(cache.hitCount, 0)
    }

    // MARK: 整篇重排（换主题 / 改宽度）

    /// 换主题、拉窗口改宽度走的是同一个入口 `load(markdown:containerWidth:)`，源码一个字都没动。
    func testReloadWithSameSourceDoesNotReparse() {
        let store = MarkdownDocumentStore()
        store.load(markdown: markdown, containerWidth: 600)
        let missesAfterFirstLoad = store.renderer.parseCache.missCount
        XCTAssertGreaterThan(missesAfterFirstLoad, 0, "第一次加载当然要解析")

        store.load(markdown: markdown, containerWidth: 480)

        XCTAssertEqual(store.renderer.parseCache.missCount, missesAfterFirstLoad,
                       "源码一字未变，第二次加载不该再解析任何东西")
        XCTAssertGreaterThan(store.renderer.parseCache.hitCount, 0)
    }

    /// 缓存的是 AST，**不是**渲染结果：换主题之后颜色必须照样跟着变。
    func testThemeChangeStillChangesRendering() {
        let store = MarkdownDocumentStore()
        // 纯正文：第 0 个字符就是正文色（换成标题的话第 0 个是 `#`，那刷的是语法标记色）
        store.load(markdown: "正文段落", containerWidth: 600)
        let before = store.textColorAttribute()

        store.renderer.theme.textColor = .red
        store.load(markdown: "正文段落", containerWidth: 600)
        let after = store.textColorAttribute()

        XCTAssertNotNil(before, "正文该带前景色属性")
        XCTAssertNotNil(after, "换主题后正文仍该带前景色属性")
        XCTAssertFalse(before?.isEqual(after) ?? true, "缓存只缓存 AST，换主题后正文颜色必须跟着变")
    }

    /// 命中缓存不能改变渲染结果（缓存的是解析，不是渲染）
    func testCachedParseKeepsRenderingIdentical() {
        let store = MarkdownDocumentStore()
        store.load(markdown: markdown, containerWidth: 600)
        let first = store.attributedDocument

        store.load(markdown: markdown, containerWidth: 600)

        XCTAssertEqual(store.attributedDocument.string, first.string)
        XCTAssertEqual(store.renderedString, first.string)
    }
}

@MainActor
private extension MarkdownDocumentStore {
    /// 正文第一个字符的颜色（用它验证「换主题有没有真的生效」）
    func textColorAttribute() -> UIColor? {
        let text = attributedDocument
        guard text.length > 0 else { return nil }
        return text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
    }
}
