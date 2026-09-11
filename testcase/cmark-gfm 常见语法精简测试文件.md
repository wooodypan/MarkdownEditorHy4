# cmark-gfm 常见语法测试

作者：ChatGPT

这是一个用于测试 **cmark-gfm** 的精简 Markdown 文件。

目标：覆盖最常见的 Markdown / GFM 语法，每种语法最多包含两个例子：
- **常见**：日常 Markdown 中最常见的写法
- **特殊**：容易触发 parser 边界的写法

---

## 1. Heading

# 一级标题

### 三级标题

---

## 2. Paragraph

这是一个普通的 Markdown 段落。

这是第一行
这是第二行，属于同一个段落。

---

## 3. Emphasis

这是 *斜体* 和 **粗体**。

这是 ***粗斜体***，以及 **包含 *嵌套斜体* 的粗体**。

---

## 4. Strikethrough

这是 ~~删除线~~ 文本。

这是 ~~**粗体删除线**~~ 和 ~~`代码删除线`~~。

---

## 5. Inline Code

使用 `console.log()` 输出内容。

使用 `` `code` `` 表示包含反引号的代码。

---

## 6. Link

这是一个[普通链接](https://example.com)。

这是一个带标题的[特殊链接](https://example.com "Example")。

---

## 7. Autolink

访问 <https://example.com>。

发送邮件到 <user@example.com>。

---

## 8. Image

![示例图片](https://example.com/image.png)

![带标题的图片](https://example.com/image.png "Example image")

---

## 9. Unordered List

- 苹果
- 香蕉
- 橙子

- 一级
  - 二级
    - 三级

---

## 10. Ordered List

1. 第一项
2. 第二项
3. 第三项

1. 从 1 开始
3. 实际源码编号为 3
7. 但渲染通常按顺序显示

---

## 11. Task List

- [x] 已完成
- [ ] 未完成

- [X] 大写 X 也表示完成
  - [ ] 嵌套任务

---

## 12. Blockquote

> 这是一段引用文本。

> 外层引用
>
> > 内层引用

---

## 13. Fenced Code Block

```javascript
const message = "Hello, Markdown!";
console.log(message);
```

~~~python
def hello(name):
    return f"Hello, {name}"
~~~

---

## 14. Indented Code Block

    function hello() {
        return "Hello";
    }

---

## 15. Thematic Break

---

---

## 16. Hard Line Break

第一行  
第二行

第一行\
第二行

---

## 17. Soft Line Break

这是第一行
这是第二行。

---

## 18. Table

| Name | Age | City |
|---|---:|---|
| Alice | 20 | Tokyo |
| Bob | 30 | London |

| 左对齐 | 居中 | 右对齐 |
|:---|:---:|---:|
| A | B | C |
| **粗体** | *斜体* | `代码` |

---

## 19. Footnote

这是一个带脚注的文本[^1]。

这里有一个包含多行内容的脚注[^note]。

[^1]: 普通脚注。

[^note]: 特殊脚注，包含多行内容。
    第二行内容。

---

## 20. Link Reference

这是一个[引用链接][docs]。

这是一个[简写引用][]。

[docs]: https://example.com/docs "Documentation"
[简写引用]: https://example.com

---

## 21. Escaping

\*这不是斜体\*。

\# 这不是标题，\| 这也不是表格分隔符。

---

## 22. HTML

这是一个 <span>inline HTML</span>。

<div>
这是一个 HTML block。
</div>

---

## 23. HTML Comment

<!-- 这是一个 HTML 注释 -->

注释后面的普通 Markdown 文本。

---

## 24. Entity

Tom &amp; Jerry。

5 &lt; 10 &amp;&amp; 10 &gt; 5。

---

## 25. Nested List + Formatting

- **粗体项目**
- *斜体项目*
- `代码项目`
- [链接项目](https://example.com)

- 父项目
  1. 有序子项目
  2. 另一个子项目
     - **三级项目**

---

## 26. Mixed Blockquote

> **重要信息**
>
> 这是引用中的普通文本。
>
> - 引用中的列表
> - [引用中的链接](https://example.com)
>
> ```text
> 引用中的代码
> ```

---

## 27. Mixed Inline Syntax

普通文本包含 **粗体**、*斜体*、~~删除线~~、`代码` 和 [链接](https://example.com)。

特殊嵌套：***粗斜体***、**~~粗体删除线~~**、[`代码链接`](https://example.com)。

---

## 28. Special Backticks

普通代码：`hello world`。

包含反引号的代码：`` `hello` ``。

---

## 29. Special Link Destination

[普通链接](https://example.com/path)。

[包含括号的 URL](https://example.com/a_(b))。

---

## 30. Unicode

中文 **粗体**、日本語 *斜体*、한국어 `code`。

Emoji：😀 🚀 ❤️ 👍

---

## 31. Combined GFM Example

> ## Release Notes
>
> - [x] 新增 **Markdown parser**
> - [ ] 修复 ~~旧 bug~~
> - [x] 支持 `cmark-gfm`
>
> | Feature | Status |
> |---|---|
> | Tables | **Done** |
> | Tasks | *Done* |
> | Footnotes | `Done` |
>
> 详细信息请查看[项目文档](https://example.com/docs)。[^release]
>
> ```bash
> cmark-gfm README.md
> ```

[^release]: 这是一个综合测试中的脚注。

---

## 32. Final Stress Case

这是一个同时包含 **粗体、*嵌套斜体***、~~删除线~~、`inline code`、
[链接](https://example.com) 和 <https://example.com> 的段落。

- [x] Task
  - **Nested bold**
  - `Nested code`
  - [Nested link](https://example.com)

> 引用内容
>
> | A | B |
> |---|---|
> | **1** | `2` |
> | *3* | ~~4~~ |

```markdown
# Markdown inside code

**This is not bold.**
[This is not a link](https://example.com)
```

---

# End

测试文件结束。