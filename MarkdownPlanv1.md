# iOS Markdown 编辑器架构方案 v1.0

我的需求：

使用https://github.com/swiftlang/swift-markdown 解析出 AST，遍历 AST 生成样式，然后使用UITextView或新建子类继承UITextView渲染，对于图片或者无序列表的小圆点等元素，使用`NSTextAttachment`，节点嵌入文本流，占 1 个字符位。增量更新使用分块（`MarkdownBlock`），只重新 parse/渲染受影响的块。复制粘贴的时候，使用源码映射表（`sourceSubRange`）+ 拦截 `copy(_:)`/`cut(_:)` 查表还原源码。

demo使用MarkdownEditorHy4.xcodeproj

源码放在MarkdownEditor目录。

支持Mac Catalyst  使用本机（arm64 Mac）编译测试，不要使用iOS模拟器运行调试。

暂时不编写UI测试。

本机HTTP代理服务器：127.0.0.1:1087

具体来说：

对于用户来说，体验就是："![示例图片](sample.png)"上方显示一个图片。在无序列表"-"的左边显示小圆点，只要选中复制后，引用和，粘贴到任何编辑器都不会显示图片，全选复制后的文本和源文件文本一模一样。

复杂节点（图片、列表圆点）成为 `NSTextAttachment`，插入到文本流中占据 1 个字符位。这样做的好处是：图片/圆点会跟随文本自然排版（换行、缩进都自动正确），但代价是：**文本流里的这个字符不再是源码字符**，而是一个特殊的"attachment 字符"。于是产生了一个新问题——用户全选复制时，系统默认行为会把这个 attachment 字符本身也复制出去（对图片来说，默认行为可能是复制图片本体或产生乱码占位符），而不是复制 `![alt](url)` 这段源码文本。

为了解决这个问题，v1.0 引入了一整套"源码映射表"机制：额外维护一张表，记录"文本流中第几个字符对应源码里的哪一段"，复制时不用系统默认行为，而是拦截 `copy(_:)`，查这张表，把"attachment 字符"翻译回它对应的源码文本（图片翻译回 `![alt](url)`），把"没有登记映射的 attachment"（比如列表圆点，它不对应任何源码字符，只是纯装饰）直接跳过不复制。

## 0. 技术选型结论（先给结论，避免走弯路）

| 决策点 | 选择 | 理由 |
|---|---|---|
| 文本引擎 | **TextKit 2**，基于 `UITextView` + `NSTextContentStorage`（标准实现，不自定义 NSTextContentManager） | 自定义 `NSTextContentManager` 官方明确不支持 UITextView/NSTextView，社区已踩坑确认，不要重造轮子 |
| Markdown 解析 | `swift-markdown`（swiftlang 官方库） | AST 节点带 `SourceRange`，天然支持"文本位置 ↔ AST 节点"映射 |
| 复杂节点渲染 | `NSTextAttachment` + `NSTextAttachmentViewProvider` | 官方支持内嵌真实 UIView，性能优于手绘 |
| 简单节点渲染（标题标记弱化等） | 纯 `NSAttributedString` 属性区间 | 字符仍在文本流里，编辑/复制/光标行为全部原生正确，零额外成本 |
| 增量解析/布局 | 分块（block-level）维护 + `NSTextContentStorage` 局部 `replaceContents` | 避免整文档重新 parse/渲染 |
| 复制/粘贴 | 完全自定义拦截，源码文本独立于渲染层维护 | 富文本层的"看起来是什么"和"复制出来是什么"必须解耦 |

---

## 1. 整体分层架构

```
┌─────────────────────────────────────────────────────────┐
│  UI 层：MarkdownEditorView (UIViewRepresentable/UIView)   │
│  内部持有 UITextView (TextKit2 模式)                      │
└─────────────────────────────────────────────────────────┘
                          │
┌─────────────────────────────────────────────────────────┐
│  编辑控制层：MarkdownEditController                        │
│  - 监听 UITextViewDelegate 编辑事件                        │
│  - 判定"脏块"（哪些块的源码变了）                            │
│  - 派发增量渲染任务                                         │
└─────────────────────────────────────────────────────────┘
                          │
        ┌─────────────────┴─────────────────┐
        ▼                                     ▼
┌───────────────────────┐         ┌───────────────────────────┐
│  文档模型层              │         │  渲染层                     │
│  MarkdownDocumentStore │         │  MarkupToAttributedRenderer│
│  - 分块源码存储           │         │  - MarkupVisitor 实现       │
│  - 块级 AST 缓存         │         │  - Attachment 工厂          │
│  - 源码↔渲染位置映射表    │         │  - 属性样式表 (Theme)        │
└───────────────────────┘         └───────────────────────────┘
        │                                     │
        ▼                                     ▼
┌───────────────────────┐         ┌───────────────────────────┐
│  解析层                 │         │  Attachment 层              │
│  swift-markdown         │         │  ImageAttachment            │
│  Document(parsing:)     │         │  BulletAttachment           │
│                        │         │  CodeBlockAttachment(可选)  │
└───────────────────────┘         └───────────────────────────┘
                          │
┌─────────────────────────────────────────────────────────┐
│  剪贴板层：MarkdownPasteboardController                    │
│  - 拦截 copy/cut/paste                                     │
│  - 选区 → 源码范围反查 → 输出纯 markdown 文本                │
└─────────────────────────────────────────────────────────┘
```

---

## 2. 文档模型层设计（核心，决定增量性能）

### 2.1 分块策略

不要把整篇 markdown 当成一个 `Document` 来 parse。按**顶层块级元素**（`BlockMarkup`：段落、标题、列表、代码块、表格、引用块等）切分：

```swift
/// 一个顶层块的完整状态
final class MarkdownBlock {
    let id: UUID
    var sourceText: String              // 该块的原始 markdown 源码
    var sourceRange: Range<Int>         // 在整篇文档字符偏移中的范围
    var renderedRange: NSRange          // 在渲染后 NSAttributedString 中的范围
    var astNode: any Markup             // swift-markdown 解析出的节点
    var attachments: [UUID: BlockAttachmentInfo] // 该块内的 attachment 及其源码子范围
    var isDirty: Bool = false
}

/// 记录一个 attachment 对应的源码子范围（图片这种"有源码"的场景需要）
struct BlockAttachmentInfo {
    let attachmentID: UUID
    let sourceSubRange: Range<Int>?  // nil 表示纯装饰（如列表圆点），不对应任何源码字符
}
```

```swift
final class MarkdownDocumentStore {
    private(set) var blocks: [MarkdownBlock] = []
    
    /// 首次全量加载
    func load(fullMarkdown: String) {
        let document = Document(parsing: fullMarkdown)
        blocks = document.children.compactMap { child in
            guard let block = child as? BlockMarkup else { return nil }
            return MarkdownBlock(astNode: block, ...)
        }
    }
    
    /// 增量更新：给定编辑发生的字符范围和替换文本，定位受影响的块
    func applyEdit(in range: NSRange, replacementText: String) -> [MarkdownBlock] {
        let affectedBlocks = blocksIntersecting(range: range)
        
        // 关键：如果编辑跨越了块边界（如把两段合并、插入分隔符产生新块），
        // 需要以"受影响块的原始文本范围的并集"为单位重新 parse，
        // 而不是整篇文档重新 parse
        let mergedSourceRange = mergedRange(of: affectedBlocks)
        let newSubSource = applyReplacement(to: mergedSourceRange, text: replacementText)
        
        let subDocument = Document(parsing: newSubSource)
        let newBlocks = subDocument.children.compactMap { $0 as? BlockMarkup }
            .map { MarkdownBlock(astNode: $0, ...) }
        
        replaceBlocks(affectedBlocks, with: newBlocks)
        return newBlocks  // 返回需要重新渲染的块，供渲染层使用
    }
}
```

**要点**：
- 每次输入触发的是"局部 parse"，parse 范围 = 受影响块的源码区间，通常几十到几百字符，而不是整篇文档
- 块的物理边界变化（比如用户在两个段落中间按回车/删除产生合并）需要正确处理，这是分块策略里最容易出 bug 的地方，务必写好边界测试用例（连续输入、跨块删除、粘贴多块内容三类场景）

---

## 3. 渲染层设计

### 3.1 MarkupVisitor 实现（AST → NSAttributedString）

```swift
struct MarkdownTheme {
    let markerColor: UIColor = .tertiaryLabel   // # 弱化色
    let headingFonts: [Int: UIFont]             // level -> font
    let bodyFont: UIFont
    let codeFont: UIFont
    let bulletColor: UIColor
    let bulletDiameter: CGFloat = 5
    let listIndent: CGFloat = 20
}

final class MarkupToAttributedRenderer: MarkupVisitor {
    typealias Result = NSAttributedString
    
    let theme: MarkdownTheme
    /// 输出：本次渲染中新产生的 attachment 信息，供 DocumentStore 记录源码映射
    private(set) var producedAttachments: [BlockAttachmentInfo] = []
    
    // MARK: 标题 —— 纯属性区间方案
    func visitHeading(_ heading: Heading) -> NSAttributedString {
        let result = NSMutableAttributedString()
        
        let markerText = String(repeating: "#", count: heading.level) + " "
        result.append(NSAttributedString(string: markerText, attributes: [
            .foregroundColor: theme.markerColor,
            .font: theme.bodyFont,
            .markdownRole: MarkdownRole.headingMarker   // 自定义 key，供光标/删除逻辑识别
        ]))
        
        let content = defaultVisit(heading)
        let styled = NSMutableAttributedString(attributedString: content)
        styled.addAttributes([
            .font: theme.headingFonts[heading.level] ?? theme.bodyFont,
            .foregroundColor: UIColor.label
        ], range: NSRange(location: 0, length: styled.length))
        result.append(styled)
        
        return result
    }
    
    // MARK: 图片 —— Attachment 方案
    func visitImage(_ image: Image) -> NSAttributedString {
        guard let source = image.source, let url = resolveImageURL(source) else {
            return defaultVisit(image)  // 降级为纯文本
        }
        let attachment = ImageAttachment(
            id: UUID(),
            sourceMarkdown: image.format(),   // swift-markdown 提供 AST 节点转回源码文本的能力
            imageURL: url
        )
        producedAttachments.append(BlockAttachmentInfo(
            attachmentID: attachment.id,
            sourceSubRange: sourceRange(of: image)  // 用 image.range 换算成块内偏移
        ))
        
        let attrStr = NSMutableAttributedString(attachment: attachment)
        attrStr.addAttribute(.markdownRole, value: MarkdownRole.image, range: NSRange(location: 0, length: 1))
        return attrStr
    }
    
    // MARK: 无序列表 —— Attachment 方案，但不注册源码范围
    func visitUnorderedList(_ list: UnorderedList) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for item in list.listItems {
            let bullet = BulletAttachment(diameter: theme.bulletDiameter, color: theme.bulletColor)
            let bulletStr = NSMutableAttributedString(attachment: bullet)
            // 关键：不加入 producedAttachments 的 sourceSubRange 记录 —— 
            // 复制逻辑天然找不到它对应的源码字符，不会被带入剪贴板
            
            let itemContent = defaultVisit(item)
            let styledItem = NSMutableAttributedString(attributedString: itemContent)
            
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.headIndent = theme.listIndent
            paragraphStyle.firstLineHeadIndent = 0
            styledItem.addAttribute(.paragraphStyle, value: paragraphStyle,
                                     range: NSRange(location: 0, length: styledItem.length))
            
            result.append(bulletStr)
            result.append(styledItem)
            result.append(NSAttributedString(string: "\n"))
        }
        return result
    }
    
    // MARK: 代码块 —— 建议同样走 Attachment（承载语法高亮 + 圆角背景 + 复制按钮）
    func visitCodeBlock(_ codeBlock: CodeBlock) -> NSAttributedString {
        let attachment = CodeBlockAttachment(
            id: UUID(),
            code: codeBlock.code,
            language: codeBlock.language
        )
        producedAttachments.append(BlockAttachmentInfo(
            attachmentID: attachment.id,
            sourceSubRange: sourceRange(of: codeBlock)
        ))
        return NSAttributedString(attachment: attachment)
    }
}

/// 自定义属性 key，标记渲染出的文本片段对应的 markdown 语义角色
/// 用于：光标移动策略、退格删除策略、复制逻辑识别
extension NSAttributedString.Key {
    static let markdownRole = NSAttributedString.Key("markdownRole")
}
enum MarkdownRole {
    case headingMarker, image, bullet, codeBlock
}
```

### 3.2 Attachment 具体实现

**图片 Attachment**：

```swift
final class ImageAttachment: NSTextAttachment {
    let id: UUID
    let sourceMarkdown: String
    let imageURL: URL
    
    init(id: UUID, sourceMarkdown: String, imageURL: URL) {
        self.id = id
        self.sourceMarkdown = sourceMarkdown
        self.imageURL = imageURL
        super.init(data: nil, ofType: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    
    override func viewProvider(for parentView: UIView?, location: NSTextLocation,
                                textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        let provider = ImageAttachmentViewProvider(
            textAttachment: self, parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager, location: location
        )
        provider.tracksTextAttachmentViewBounds = true
        return provider
    }
}

final class ImageAttachmentViewProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.layer.cornerRadius = 6
        imageView.clipsToBounds = true
        self.view = imageView
        
        guard let attachment = textAttachment as? ImageAttachment else { return }
        ImageLoader.shared.load(attachment.imageURL) { [weak imageView, weak self] image in
            guard let image else { return }
            imageView?.image = image
            // 图片加载完成后，尺寸可能变化，需要通知布局系统重新计算该行高度
            self?.invalidateLayout()
        }
    }
    
    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any],
                                    location: NSTextLocation,
                                    textContainer: NSTextContainer?,
                                    proposedLineFragment: CGRect,
                                    position: CGPoint) -> CGRect {
        // 图片宽度不超过容器宽度，按宽高比计算高度，避免加载前后跳动过大
        let maxWidth = proposedLineFragment.width
        let aspectRatio: CGFloat = 9.0 / 16.0  // 加载前用占位比例
        return CGRect(x: 0, y: 0, width: maxWidth, height: maxWidth * aspectRatio)
    }
}
```

**列表圆点 Attachment**：

```swift
final class BulletAttachment: NSTextAttachment {
    let diameter: CGFloat
    let color: UIColor
    init(diameter: CGFloat, color: UIColor) {
        self.diameter = diameter; self.color = color
        super.init(data: nil, ofType: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    
    override func viewProvider(for parentView: UIView?, location: NSTextLocation,
                                textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        BulletViewProvider(textAttachment: self, parentView: parentView,
                            textLayoutManager: textContainer?.textLayoutManager, location: location)
    }
}

final class BulletViewProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        guard let attachment = textAttachment as? BulletAttachment else { return }
        let dot = UIView()
        dot.backgroundColor = attachment.color
        dot.layer.cornerRadius = attachment.diameter / 2
        self.view = dot
    }
    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any],
                                    location: NSTextLocation, textContainer: NSTextContainer?,
                                    proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        guard let attachment = textAttachment as? BulletAttachment else { return .zero }
        let d = attachment.diameter
        // y 偏移让圆点垂直居中对齐文本 x-height
        return CGRect(x: 0, y: -4, width: d + 8, height: d)
    }
}
```

---

## 4. 复制/粘贴层设计（重点，容易漏做）

### 4.1 核心原则
**渲染出的 `NSAttributedString` 和"复制时应该产出的文本"是两套独立数据，永远不要指望从 attributed string 反推源码。** 复制逻辑必须查 `MarkdownDocumentStore` 的源码映射表。

```swift
final class MarkdownPasteboardController: NSObject {
    weak var textView: UITextView?
    let documentStore: MarkdownDocumentStore
    
    /// 拦截系统复制行为
    func handleCopy() -> Bool {
        guard let selectedRange = textView?.selectedTextRange,
              let renderedNSRange = textView?.offset(from: textView!.beginningOfDocument, to: selectedRange.start)
                .map({ NSRange(location: $0, length: /* 计算长度 */ 0) })
        else { return false }
        
        let sourceText = documentStore.sourceText(forRenderedRange: renderedNSRange)
        UIPasteboard.general.string = sourceText
        return true  // 返回 true 表示已接管，阻止系统默认复制行为
    }
}
```

`MarkdownDocumentStore.sourceText(forRenderedRange:)` 的实现逻辑：

```swift
extension MarkdownDocumentStore {
    /// 把渲染后的 NSRange 映射回源码文本
    func sourceText(forRenderedRange renderedRange: NSRange) -> String {
        var result = ""
        for block in blocksIntersecting(renderedRange: renderedRange) {
            let localRange = intersect(renderedRange, with: block.renderedRange)
            
            // 遍历该 range 内的 attachment
            var cursor = localRange.location
            while cursor < localRange.location + localRange.length {
                if let attachmentInfo = block.attachmentAt(renderedOffset: cursor) {
                    if let subRange = attachmentInfo.sourceSubRange {
                        // 有源码映射的 attachment（如图片）—— 输出源码
                        result += block.sourceText[subRange]
                    }
                    // 没有源码映射的 attachment（如列表圆点）—— 什么都不输出，直接跳过
                    cursor += 1  // attachment 在 NSAttributedString 中占 1 个字符位
                } else {
                    // 普通文本字符（含标题的 # 标记，因为它本身就是源码字符）—— 直接输出
                    let char = block.characterAtRenderedOffset(cursor)
                    result += String(char)
                    cursor += 1
                }
            }
        }
        return result
    }
}
```

**接入方式（UITextView 层面）**：

在 `UITextView` 子类里重写 `copy(_:)` 和 `cut(_:)`：

```swift
final class MarkdownTextView: UITextView {
    var pasteboardController: MarkdownPasteboardController?
    
    override func copy(_ sender: Any?) {
        if pasteboardController?.handleCopy() == true { return }
        super.copy(sender)  // 兜底，理论上不会走到
    }
    
    override func cut(_ sender: Any?) {
        if pasteboardController?.handleCopy() == true {
            deleteSelectedText()  // 复制成功后再执行删除，实现"剪切"
            return
        }
        super.cut(sender)
    }
    
    // 粘贴：如果剪贴板内容是本 App 复制出的 markdown 源码，走"插入源码文本 → 触发增量渲染"逻辑
    // 如果是外部富文本/图片，走对应的转换逻辑（如自动转成 ![](本地保存路径)）
    override func paste(_ sender: Any?) {
        if let text = UIPasteboard.general.string {
            insertMarkdownSource(text)  // 走 documentStore.applyEdit，正常增量渲染流程
            return
        }
        // 处理图片粘贴等场景...
    }
}
```

### 4.2 三种场景验证结果对照

| 场景 | 复制行为 | 实现依据 |
|---|---|---|
| 选中图片区域复制 | 输出 `![](demo.jpg)` 源码文本 | `sourceSubRange` 有值，查表输出 |
| 选中列表项复制 | 圆点不出现在结果里，只输出 `内容文字` （不含 `- `，因为 `- ` 本身也建议按 attachment 处理而非保留字符，见下方备注） | attachment 无 `sourceSubRange`，跳过 |
| 选中标题复制 | 输出完整 `# 标题内容`（含 `#`） | `#` 是普通字符，属性区间方案，直接输出 |

**备注**：无序列表的 `- `/`* ` 前缀字符如果你选择保留在文本流里（不做成 attachment，只做圆点是 attachment），那复制出来会包含 `- `，这其实也是合理的（是有效 markdown 语法）。如果你希望复制出的纯文本里也不包含 `- `（用户只想要内容本身），则连 `- ` 这几个源码字符也应该跳过复制、只保留在 `sourceText` 内部映射表里但不映射到渲染文本的可见字符。**这里需要和产品明确一次预期**，我建议默认保留 `- ` 前缀（因为它是合法且可再粘贴回其他 markdown 编辑器的语法），仅圆点这个纯视觉装饰不复制。

---

## 5. 增量渲染 & TextKit2 局部更新

```swift
final class MarkdownEditController: NSObject, UITextViewDelegate {
    let documentStore: MarkdownDocumentStore
    let renderer: MarkupToAttributedRenderer
    weak var textView: UITextView?
    
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange,
                  replacementText text: String) -> Bool {
        // 1. 定位受影响的块，增量重新 parse
        let dirtyBlocks = documentStore.applyEdit(in: range, replacementText: text)
        
        // 2. 只重新渲染这几个块
        for block in dirtyBlocks {
            let newAttrString = renderer.render(block: block)
            block.renderedContent = newAttrString
        }
        
        // 3. 局部替换 NSTextContentStorage 的内容，而不是整体 setAttributedText
        applyPartialUpdate(dirtyBlocks: dirtyBlocks)
        
        return false  // 我们自己接管了替换，阻止系统默认插入
    }
    
    private func applyPartialUpdate(dirtyBlocks: [MarkdownBlock]) {
        guard let textContentStorage = textView?.textLayoutManager?.textContentManager
                as? NSTextContentStorage else { return }
        
        for block in dirtyBlocks {
            guard let textRange = NSTextRange(block.renderedRange, in: textContentStorage) else { continue }
            
            textContentStorage.performEditingTransaction {
                textContentStorage.textStorage?.replaceCharacters(
                    in: block.renderedRange,
                    with: block.renderedContent
                )
            }
            // NSTextContentStorage 在 performEditingTransaction 内会自动
            // 触发 NSTextLayoutManager 的增量 invalidateLayout，不需要手动调用
        }
    }
}
```

**性能要点**：
- `performEditingTransaction` 内部完成的编辑，TextKit 2 会自动计算最小失效区域并增量重排，不要在每次编辑后手动 `setAttributedText(_:)` 整体赋值（这会导致全文档重新布局，长文档会掉帧）
- 图片异步加载完成后调用的 `invalidateLayout`，同样只应传入该 attachment 所在的局部 range，参考 `NSTextLayoutManager.invalidateLayout(for:)`

---

## 6. 光标与退格键的边界行为（容易被忽略但用户体感很重要）

需要单独处理的交互细节，建议列入测试用例：

1. **光标能否停在 `#` 和内容之间**：允许，因为 `#` 是真实字符，光标行为原生正确
2. **光标能否停在图片 attachment 内部**：不行（attachment 天然是一个不可分割字符），只能停在其前后；建议监听光标移动，若检测到试图进入 attachment 内部，自动跳到其后一个字符位置
3. **退格键删除图片**：删除 attachment 字符时，需要同步清理 `documentStore` 里该 attachment 的映射记录，并把 `sourceSubRange` 对应的源码文本一并从块源码中移除（否则源码和渲染会不一致）
4. **退格键删除列表圆点**：由于圆点不对应源码字符，用户实际上是在删除"这一行的列表标记"这个语义动作，需要在退格键逻辑里特殊拦截：光标在列表项开头按退格时，先删除 `- `/`* ` 前缀并连带圆点 attachment 一起消失，而不是让用户误以为在删普通字符
5. **标题降级**：光标在标题开头按退格，建议实现"先把 `## ` 变成 `# `，再变成普通段落"这种符合用户预期的降级动画，而非直接删字符

---

## 7. 建议的迭代顺序（给排期用）

| 阶段 | 交付物 | 预估复杂度 |
|---|---|---|
| P0 | 只读渲染：swift-markdown → NSAttributedString（属性区间方案覆盖标题/粗斜体/引用），跑通 TextKit2 展示 | 低 |
| P1 | 接入图片 Attachment（先不做复制逻辑），验证异步加载 + 布局失效 | 中 |
| P2 | 接入列表圆点 Attachment | 低（有 P1 经验后） |
| P3 | 文档分块 + 增量 parse/渲染，替换掉 P0 的整体渲染逻辑 | 高，这是性能核心，建议预留最多时间 |
| P4 | 复制/粘贴层完整实现（含源码映射表查询） | 中高 |
| P5 | 光标/退格边界行为打磨 | 中，且需要真机反复测试手感 |
| P6 | 代码块语法高亮（可选，接入 Splash/Highlightr） | 中 |

**风险提示给开发**：P3（分块增量策略）和 P4（复制映射表）是两个最容易返工的模块，建议先用一个简化 demo（比如只支持标题+段落+图片三种块）把这两块的数据流跑通，验证"编辑 → 局部 parse → 局部渲染 → TextKit2 局部更新 → 复制映射正确"这个闭环没问题，再逐步加其他 markdown 语法，避免语法覆盖越写越多之后才发现底层数据流有硬伤。
