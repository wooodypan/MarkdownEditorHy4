# Markdown 历史版本对比的推荐做法

**存每个版本的完整快照,查看时再实时计算 diff,用"行级 diff + 变更行内高亮"展示。** Markdown 是纯文本,按行对比就够用,不需要解析语法树。

## 第一步:行级 diff,生成完整视图

历史版本页面需要同时显示没变的行(提供上下文),而 `difference(from:)` 只返回增删。下面这段把它补成完整的行列表:

```swift
import Foundation

struct DiffRow: Identifiable {
    enum Kind { case same, added, removed }
    let id = UUID()
    let kind: Kind
    let text: String
}

func makeDiffRows(old: String, new: String) -> [DiffRow] {
    func lines(_ s: String) -> [String] {
        s.replacingOccurrences(of: "\r\n", with: "\n")
         .components(separatedBy: "\n")
    }
    let a = lines(old), b = lines(new)
    let diff = b.difference(from: a)

    var removed = Set<Int>(), inserted = Set<Int>()
    for change in diff {
        switch change {
        case .remove(let offset, _, _): removed.insert(offset)
        case .insert(let offset, _, _): inserted.insert(offset)
        }
    }

    var rows: [DiffRow] = []
    var i = 0, j = 0
    while i < a.count || j < b.count {
        if i < a.count, removed.contains(i) {
            rows.append(DiffRow(kind: .removed, text: a[i])); i += 1
        } else if j < b.count, inserted.contains(j) {
            rows.append(DiffRow(kind: .added, text: b[j])); j += 1
        } else {
            rows.append(DiffRow(kind: .same, text: b[j])); i += 1; j += 1
        }
    }
    return rows
}
```

## 第二步:SwiftUI 展示

```swift
import SwiftUI

struct DiffView: View {
    let rows: [DiffRow]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    HStack(alignment: .top, spacing: 6) {
                        Text(prefix(row.kind))
                            .foregroundStyle(.secondary)
                        Text(row.text.isEmpty ? " " : row.text)
                            .textSelection(.enabled)
                    }
                    .font(.system(.footnote, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(background(row.kind))
                }
            }
        }
    }

    func prefix(_ k: DiffRow.Kind) -> String {
        switch k { case .same: " "; case .added: "+"; case .removed: "-" }
    }
    func background(_ k: DiffRow.Kind) -> Color {
        switch k {
        case .same: .clear
        case .added: .green.opacity(0.18)
        case .removed: .red.opacity(0.18)
        }
    }
}
```

## 第三步(推荐):变更行的行内高亮

Markdown 的一个段落通常就是一整行,行级 diff 只能告诉你"这段变了",看不出改了哪几个字。做法是:

1. 找到相邻的"删除行 + 新增行"配对;
2. 对这一对用 **TextDiffing** 做词级(中文建议字符级)对比;
3. 把得到的 `AttributedString` 显示在对应行里。

中文没有空格分词,所以中文内容用字符粒度效果更好。

## 几个实用建议

- **存储**:每次保存存完整快照,不要存 diff 链。Markdown 文件通常很小,快照最简单也最可靠,任意两个版本之间都能直接对比。
- **性能**:Myers 算法对大文件也够快,但几千行以上建议放到后台线程(`Task.detached`)计算,再回主线程刷新。
- **折叠未变化区域**:长文档可以只显示变更行前后各 3 行,其余折叠成"展开 N 行未修改",和 GitHub 一样。
- **换行符**:上面已经统一了 `\r\n`,不同平台编辑过的文件不会出现整篇都被标红的情况。
- **想看渲染后的对比**:直接对渲染结果做 diff 很难做好,更实用的做法是提供"源码对比 / 预览"两个标签页切换。

需要的话,我可以把"相邻行配对 + 行内高亮"和"折叠未变化区域"两部分的完整代码补上。