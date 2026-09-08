//
//  RenderedFragment.swift
//  MarkdownEditorHy4
//
//  渲染中间产物：一小段富文本 + 每个字符位的源码映射
//

import UIKit

/// 渲染过程中的一个片段。
///
/// 不变式：`text.length == mappings.count`，也就是渲染出的每一个字符位都有一条映射记录。
struct RenderedFragment {
    var text: NSMutableAttributedString
    var mappings: [CharMapping]

    static var empty: RenderedFragment {
        RenderedFragment(text: NSMutableAttributedString(), mappings: [])
    }

    init(text: NSMutableAttributedString, mappings: [CharMapping]) {
        self.text = text
        self.mappings = mappings
    }

    // MARK: 构造

    /// 用「源码切片」构造：渲染出来的每个字符，都逐一对应源码里的一个字符。
    /// - parameter string:      要显示的文本（直接取自源码，保证所见即所复制）
    /// - parameter sourceStart: 这段文本在「块源码」里的起始偏移
    static func sourceSliced(_ string: String, sourceStart: Int, attributes: [NSAttributedString.Key: Any]) -> RenderedFragment {
        guard !string.isEmpty else { return .empty }

        var mappings: [CharMapping] = []
        mappings.reserveCapacity(string.utf16.count)

        // 注意：要按 Character 遍历再展开成 UTF-16 单元。
        // 一个 emoji 在渲染串里占 2 个 UTF-16 单元，但源码里只算 1 个字符，
        // 所以同一个源码字符会生成 2 条映射（复制时会靠「上一条已输出到的位置」去重）。
        var sourceOffset = 0
        for character in string {
            let width = String(character).utf16.count
            for _ in 0..<width {
                mappings.append(CharMapping(sourceStart: sourceStart + sourceOffset, sourceLength: width))
            }
            sourceOffset += width
        }

        return RenderedFragment(
            text: NSMutableAttributedString(string: string, attributes: attributes),
            mappings: mappings
        )
    }

    /// 构造一段「纯装饰」文本：源码里没有对应字符，复制时会被跳过。
    static func decoration(_ string: String, attributes: [NSAttributedString.Key: Any]) -> RenderedFragment {
        guard !string.isEmpty else { return .empty }
        let count = string.utf16.count
        return RenderedFragment(
            text: NSMutableAttributedString(string: string, attributes: attributes),
            mappings: Array(repeating: .decoration, count: count)
        )
    }

    /// 构造一个 attachment：只占 1 个字符位，但吃掉了源码里 `sourceLength` 个字符（比如整段 `![alt](url)`）。
    static func attachment(_ attachment: NSTextAttachment,
                           sourceStart: Int,
                           sourceLength: Int,
                           attributes: [NSAttributedString.Key: Any]) -> RenderedFragment {
        let attributed = NSMutableAttributedString(attachment: attachment)
        // attachment 在 NSAttributedString 里的长度恒为 1
        attributed.addAttributes(attributes, range: NSRange(location: 0, length: attributed.length))
        return RenderedFragment(
            text: attributed,
            mappings: [CharMapping(sourceStart: sourceStart, sourceLength: max(1, sourceLength))]
        )
    }

    /// 构造一段「源码提示」：弱化显示的源文本。
    ///
    /// 用在两个地方：
    /// - 图片下面那行 `![alt](url)`，把被 attachment 吃掉的源码原样补回来展示
    /// - 无序列表圆点后面的 `- `
    ///
    /// ### 为什么映射是「装饰」（不占源码位置）
    /// 这些提示字符展示的那段源码，**已经由前面的 attachment 负责输出了**。给它们也标上源码映射
    /// 会带来两个麻烦：复制时会重复输出；退格时算出来的删除范围会变成 0 长度（因为提示字符
    /// 和 attachment 的 sourceStart 相同，`sourceCaret` 在相邻两个位置返回同一个偏移）。
    ///
    /// 标成装饰之后：
    /// - 复制：装饰字符直接跳过，源码由 attachment 输出一次，不重不漏；
    /// - 退格：光标删掉 attachment 那一个字符位，照样一次性删掉整段 `- ` 或 `![alt](url)`。
    static func sourceHint(_ string: String,
                           attributes: [NSAttributedString.Key: Any]) -> RenderedFragment {
        let count = string.utf16.count
        guard count > 0 else { return .empty }
        return RenderedFragment(
            text: NSMutableAttributedString(string: string, attributes: attributes),
            mappings: Array(repeating: .decoration, count: count)
        )
    }

    // MARK: 组合

    mutating func append(_ other: RenderedFragment) {
        guard other.text.length > 0 else { return }
        text.append(other.text)
        mappings.append(contentsOf: other.mappings)
    }

    func appending(_ other: RenderedFragment) -> RenderedFragment {
        var copy = self
        copy.append(other)
        return copy
    }

    // MARK: 改属性

    /// 强制覆盖一段范围内的属性
    mutating func setAttributes(_ attributes: [NSAttributedString.Key: Any], range: NSRange? = nil) {
        let target = range ?? NSRange(location: 0, length: text.length)
        guard target.length > 0 else { return }
        text.addAttributes(attributes, range: target)
    }

    /// 只补「还没有的属性」，已有的保持不动。
    ///
    /// 用在 Emphasis / Strong 这类嵌套语法上：外层样式不该把内层行内代码的等宽字体覆盖掉。
    mutating func addAttributesIfAbsent(_ attributes: [NSAttributedString.Key: Any]) {
        guard text.length > 0, !attributes.isEmpty else { return }
        let full = NSRange(location: 0, length: text.length)
        var pending: [(NSRange, [NSAttributedString.Key: Any])] = []

        text.enumerateAttributes(in: full, options: []) { existing, range, _ in
            // 已有属性优先，新属性只填空
            var merged = attributes
            for (key, value) in existing { merged[key] = value }
            pending.append((range, merged))
        }

        for (range, merged) in pending {
            text.setAttributes(merged, range: range)
        }
    }

    // MARK: 源码补漏（保证「全选复制 === 源文件」的关键一步）

    /// 把「AST 没覆盖到的源码字符」按原顺序补进渲染结果。
    ///
    /// ### 为什么必须有这一步
    /// swift-markdown 只给 AST 节点标注范围，但 markdown 里有很多字符不属于任何节点，
    /// 比如引用块每一行开头的 `>`、闭合式标题结尾的 `###`、表格里的 `|`。
    /// 如果不管它们，全选复制出来的文本就会比源文件少字符，破坏「所见即源码」的承诺。
    ///
    /// 有了这个补漏步骤，就不需要为每种语法单独维护映射 —— **源码覆盖率由构造保证**。
    ///
    /// - parameter source:           完整的源码文本
    /// - parameter scope:            只保证这个范围内的源码被覆盖（默认整段都要覆盖）。
    ///                               块级节点（引用块、代码块）可以先在自己的范围内补漏，
    ///                               这样补进来的 `>`、``` 能拿到和正文一致的段落样式。
    /// - parameter orphanAttributes: 补进来的那些字符用什么样式（一般是弱化色）
    func reconciled(withSource source: String,
                    in scope: NSRange? = nil,
                    orphanAttributes: [NSAttributedString.Key: Any]) -> RenderedFragment {
        let lowerBound = scope?.location ?? 0
        let upperBound = scope.map { NSMaxRange($0) } ?? source.utf16Length

        // 快速路径：先扫一遍看有没有缺口，没有就直接返回，省掉重建开销
        if !hasGap(lowerBound: lowerBound, upperBound: upperBound) { return self }

        var out = RenderedFragment.empty
        var cursor = lowerBound   // 已经覆盖到的源码位置
        var index = 0

        while index < mappings.count {
            let mapping = mappings[index]

            // 一个「字符」在 UTF-16 里可能占多个单元（emoji 是 2 个），
            // 这些单元共享同一条映射。必须整块搬过去，
            // 否则会把一个 emoji 劈成两个孤立的代理项，渲染出来是乱码。
            let runLength = runLengthOfMappings(startingAt: index)
            let piece = NSMutableAttributedString(
                attributedString: text.attributedSubstring(from: NSRange(location: index, length: runLength))
            )
            let pieceMappings = Array(repeating: mapping, count: runLength)

            if mapping.isDecoration {
                // 装饰字符不消耗源码，原样搬过去
                out.append(RenderedFragment(text: piece, mappings: pieceMappings))
            } else {
                let start = max(mapping.sourceStart, cursor)

                // 这一段源码还没被任何节点认领 —— 补进去
                if start > cursor {
                    let missing = source.substring(utf16Offset: cursor, length: start - cursor)
                    out.append(.sourceSliced(missing, sourceStart: cursor, attributes: orphanAttributes))
                }

                out.append(RenderedFragment(text: piece, mappings: pieceMappings))
                cursor = max(cursor, mapping.sourceStart + mapping.sourceLength)
            }

            index += runLength
        }

        // 尾部剩下的源码（比如代码块结尾的 ```、段落后的空行）
        if cursor < upperBound {
            let missing = source.substring(utf16Offset: cursor, length: upperBound - cursor)
            out.append(.sourceSliced(missing, sourceStart: cursor, attributes: orphanAttributes))
        }

        return out
    }

    /// 判断映射表在 [lowerBound, upperBound) 之间有没有缺口
    private func hasGap(lowerBound: Int, upperBound: Int) -> Bool {
        var cursor = lowerBound
        var previous: CharMapping?

        for mapping in mappings {
            if mapping.isDecoration { continue }
            // 同一个字符的第 2、3… 个 UTF-16 单元，跳过（已经在第一个单元时算过了）
            if let previous,
               previous.sourceStart == mapping.sourceStart,
               previous.sourceLength == mapping.sourceLength { continue }

            if mapping.sourceStart != cursor { return true }
            cursor = mapping.sourceStart + mapping.sourceLength
            previous = mapping
        }
        return cursor != upperBound
    }

    /// 从 `index` 开始，有多少条连续的映射属于同一个「字符」（sourceStart + sourceLength 都一样）
    private func runLengthOfMappings(startingAt index: Int) -> Int {
        let first = mappings[index]
        var length = 1
        while index + length < mappings.count,
              mappings[index + length].sourceStart == first.sourceStart,
              mappings[index + length].sourceLength == first.sourceLength {
            length += 1
        }
        return length
    }
}
