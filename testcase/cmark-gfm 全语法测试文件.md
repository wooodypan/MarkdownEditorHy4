# cmark-gfm Markdown Comprehensive Test

我：给我一个生成一个markdown测试文件，尽可能地多包含 cmark-gfm 支持的所有语法

ChatGPT：

> 这是一个尽可能覆盖 **cmark-gfm / GitHub Flavored Markdown** 语法的测试文件。
>
> 用于测试 Markdown parser、AST、HTML renderer、编辑器等。

---

## 1. Headings

# Heading 1

## Heading 2

### Heading 3

#### Heading 4

##### Heading 5

###### Heading 6

Setext Heading 1
================

Setext Heading 2
----------------

---

## 2. Paragraphs

这是一个普通段落。

这是另一个段落。

这一行包含  
一个显式换行。

这一行末尾有两个空格  
因此应该产生 `<br>`。

---

## 3. Emphasis

*italic*

_italic_

**bold**

__bold__

***bold italic***

___bold italic___

**bold and *nested italic***

*italic and **nested bold***

~~strikethrough~~

**bold ~~strikethrough~~**

~~*italic*~~

~~**bold**~~

---

## 4. Inline Code

`inline code`

`` `code with backtick` ``

```
literal backticks: `
```

```` 
code containing ```
````

---

## 5. Links

[normal link](https://example.com)

[link with title](https://example.com "Example Title")

[relative link](/relative/path)

[mailto link](mailto:test@example.com)

<https://example.com>

<http://example.com>

<mailto:test@example.com>

<user@example.com>

---

## 6. Link Reference Definitions

[reference link][example]

[reference link][]

[collapsed reference][]

[example]: https://example.com "Example"

[collapsed reference]: https://example.org

---

## 7. Images

![Alt text](https://example.com/image.png)

![Alt text](https://example.com/image.png "Image title")

![Reference image][image-ref]

[image-ref]: https://example.com/image.png "Reference image"

---

## 8. Blockquotes

> This is a blockquote.

> Multiple lines
> in a blockquote.

> Nested blockquote:
>
> > Inner quote
> >
> > > Deeply nested quote

> Quote with **bold**
>
> Quote with `code`
>
> Quote with [link](https://example.com).

---

## 9. Unordered Lists

- Item 1
- Item 2
- Item 3

* Item A
* Item B
* Item C

+ Item X
+ Item Y
+ Item Z

---

## 10. Ordered Lists

1. First
2. Second
3. Third

1. First
1. Second
1. Third

3. Starts at three
4. Continues

---

## 11. Nested Lists

- Level 1
  - Level 2
    - Level 3
      - Level 4

1. Level 1
   1. Level 2
      1. Level 3
      2. Another item
   2. Second level 2 item
2. Back to level 1

- Mixed:
  1. Ordered item
  2. Another ordered item
     - Nested unordered
     - Another nested unordered
- Back to unordered

---

## 12. Task Lists

- [ ] Unchecked task
- [x] Checked task
- [X] Checked task with uppercase X
- [ ] Another unchecked task

Nested tasks:

- [ ] Parent task
  - [ ] Child task
  - [x] Completed child
- [x] Completed parent

---

## 13. Code Blocks

Indented code:

    function hello() {
        console.log("hello");
    }

Fenced code:

```
plain code block
```

```text
text code block
```

```javascript
function hello(name) {
    console.log(`Hello, ${name}!`);
}
```

```python
def hello(name):
    print(f"Hello, {name}!")
```

```json
{
  "name": "cmark-gfm",
  "version": "1.0.0",
  "enabled": true
}
```

```html
<div class="example">
  <strong>Hello</strong>
</div>
```

```bash
echo "Hello World"
```

```diff
- old line
+ new line
```

---

## 14. Fenced Code Block Variations

``` 
code fence with three backticks
```

~~~ 
tilde fenced code block
~~~

~~~javascript
const x = 42;
~~~

````markdown
# Markdown inside Markdown

```js
console.log("nested fence");
```
````

---

## 15. Horizontal Rules

---

***

___

- - -

* * *

_ _ _

---

## 16. Tables

| Name | Age | City |
|---|---:|:---:|
| Alice | 20 | Tokyo |
| Bob | 30 | New York |
| Charlie | 40 | London |

Alignment:

| Left | Center | Right |
|:---|:---:|---:|
| A | B | C |
| 1 | 2 | 3 |

Table with inline Markdown:

| Feature | Status | Link |
|---|---|---|
| **Bold** | ~~deprecated~~ | [Docs](https://example.com) |
| `code` | *working* | [Test](https://example.com/test) |
| [link](https://example.com) | **OK** | `value` |

Table with escaped pipe:

| Column 1 | Column 2 |
|---|---|
| `a \| b` | `c` |
| a \| b | c |

---

## 17. Autolinks

<https://www.example.com>

<http://www.example.com/path?q=1>

<mailto:hello@example.com>

<hello@example.com>

Plain URL:

https://www.example.com

www.example.com

---

## 18. Strikethrough

~~deleted text~~

~~**bold deleted text**~~

~~*italic deleted text*~~

~~`deleted code`~~

~~[deleted link](https://example.com)~~

---

## 19. Footnotes

Here is a footnote reference[^1].

Here is another footnote[^long-note].

Multiple references can appear[^1][^2].

[^1]: This is the first footnote.

[^2]: This is the second footnote.

[^long-note]: This is a longer footnote
    with multiple lines.

---

## 20. Footnotes with Formatting

This has **bold** footnote[^formatted].

[^formatted]: Footnote containing *italic*, **bold**,
    `inline code`, and [a link](https://example.com).

---

## 21. Escaping

\*not italic\*

\_not italic\_

\**not bold\**

\# not a heading

\[not a link\]

\> not a quote

\- not a list

\+ not a list

\. not an ordered list

\! not an image

\`not code\`

\~not strikethrough\~

\\ backslash

---

## 22. Special Characters

&copy;

&amp;

&lt;

&gt;

&quot;

&#123;

&#x7B;

---

## 23. HTML Inline

<span>inline HTML</span>

<strong>strong HTML</strong>

<em>emphasis HTML</em>

<kbd>Ctrl</kbd> + <kbd>C</kbd>

<mark>highlight</mark>

<sub>subscript</sub>

<sup>superscript</sup>

<br>

---

## 24. HTML Blocks

<div>
This is an HTML block.
</div>

<table>
<tr>
<th>Name</th>
<th>Value</th>
</tr>
<tr>
<td>foo</td>
<td>bar</td>
</tr>
</table>

<details>
<summary>Expandable section</summary>

This is inside a details element.

</details>

---

## 25. HTML Comments

<!-- This is an HTML comment -->

Text after the comment.

---

## 26. Entities

AT&amp;T

5 &lt; 10

10 &gt; 5

Tom &amp; Jerry

&nbsp;

---

## 27. Hard Line Breaks

Line one  
Line two

Line three\
Line four

Line five
Line six

---

## 28. Soft Line Breaks

This is line one
and this is line two.

This is another line
without hard break.

---

## 29. Whitespace

Text with multiple spaces.

Text with trailing spaces  
Next line.

Text with tabs:

	Text after tab.

---

## 30. Escaped Punctuation

\!

\"

\#

\$

\%

\&

\'

\(

\)

\*

\+

\,

\-

\.

\/

\:

\;

\<

\=

\>

\?

\@

\[

\\

\]

\^

\_

\`

\{

\|

\}

\~

---

## 31. Nested Inline Elements

***bold italic***

**bold *italic***

*italic **bold***

~~**bold**~~

~~*italic*~~

**~~bold strike~~**

***~~bold italic strike~~***

[`code link`](https://example.com)

**[bold link](https://example.com)**

*[italic link](https://example.com)*

~~[strikethrough link](https://example.com)~~

---

## 32. Links with Nested Content

[**bold**](https://example.com)

[*italic*](https://example.com)

[`code`](https://example.com)

[~~strike~~](https://example.com)

[**bold and *italic***](https://example.com)

---

## 33. Lists with Paragraphs

- First item

  Second paragraph in the first item.

- Second item

  Another paragraph.

1. First item

   Continuation paragraph.

2. Second item

   More content.

---

## 34. Lists with Blockquotes

- Item

  > Blockquote inside list.

- Another item

  > Another quote
  >
  > with multiple paragraphs.

---

## 35. Lists with Code Blocks

- JavaScript:

  ```javascript
  const answer = 42;
  console.log(answer);
  ```

- Python:

  ```python
  print("hello")
  ```

---

## 36. Blockquote with Lists

> - Item one
> - Item two
>
> 1. Ordered one
> 2. Ordered two

---

## 37. Blockquote with Code

> ```javascript
> console.log("inside quote");
> ```

---

## 38. Heading Edge Cases

# Heading with **bold**

## Heading with *italic*

### Heading with `code`

#### Heading with [link](https://example.com)

##### Heading with ~~strike~~

###### Heading with escaped \# character

---

## 39. Empty / Minimal Constructs

#

##

> 

-

*

+

1.

```

```

---

## 40. Long Paragraph

Lorem ipsum dolor sit amet, consectetur adipiscing elit. Vestibulum
vehicula, neque non consequat vulputate, lorem ipsum tincidunt magna,
at tincidunt neque justo vitae massa. **Bold text**, *italic text*,
~~deleted text~~, `inline code`, and [a link](https://example.com)
can all appear in the same paragraph.

---

## 41. Punctuation and Unicode

中文 Markdown 测试。

日本語のテスト。

한국어 Markdown 테스트.

Русский текст.

العربية.

עברית.

Emoji: 😀 😎 🚀 ❤️ 👍 🎉

Symbols: © ® ™ § ¶ † ‡ → ← ↑ ↓ ↔

Mathematical text: x² + y² = z²

---

## 42. CJK Text

这是一个**粗体**测试。

这是一个*斜体*测试。

这是一个~~删除线~~测试。

这是一个`代码`测试。

这是一个[链接](https://example.com)测试。

---

## 43. Emoji

:smile:

:rocket:

:+1:

:heart:

:warning:

> 注意：GitHub 的 emoji shortcode 支持并不是 CommonMark/cmark-gfm 核心语法的一部分，
> 具体是否解析取决于上层实现。

---

## 44. Math-like Text

x^2

x_2

E = mc^2

a*b*c

> 注意：普通 cmark-gfm 并不原生提供 LaTeX 数学公式语法。

Inline-looking math:

$E = mc^2$

$$
E = mc^2
$$

---

## 45. YAML-like Front Matter

---
title: cmark-gfm test
author: Test
tags:
  - markdown
  - gfm
---

# Content After Front Matter

> 注意：front matter 通常不是 CommonMark/cmark-gfm 核心语法，
> 不同实现处理方式不同。

---

## 46. Definition-like Text

Term
: Definition

Another term
: Another definition

> 注意：这种 definition list 语法不是标准 CommonMark/cmark-gfm 核心扩展。

---

## 47. Nested Everything

> - [x] **Completed task**
>   - [ ] Nested task
>   - `inline code`
>   - [link](https://example.com)
>
>   ```javascript
>   function test() {
>       return "**not markdown**";
>   }
>
> - [ ] Another task
>
>   | A | B |
>   |---|---|
>   | 1 | 2 |

---

## 48. Table with Complex Inline Content

| ID | Name | Description | Status |
|---:|:---|:---|:---:|
| 1 | **Alice** | *Developer* | [OK](https://example.com) |
| 2 | `Bob` | ~~Deprecated~~ | **FAIL** |
| 3 | [Charlie](https://example.com) | `Admin` | *Pending* |

---

## 49. Code Containing Markdown

```markdown
# This is not a real heading

**This is not bold**

[This is not a real link](https://example.com)

- This is not a real list
```

---

## 50. Code Containing Backticks

````markdown
```javascript
console.log("hello");
```
````

---

## 51. Backtick Edge Cases

`a`

``a``

```a```

`` ` ``

``a ` b``

`code with *asterisk*`

`code with **bold**`

`code with [link](url)`

---

## 52. Link Destination Edge Cases

[Example](https://example.com)

[Example](https://example.com/a_(b))

[Example](<https://example.com/a b>)

[Example](https://example.com?a=1&b=2)

---

## 53. Link Title Variations

[Title 1](https://example.com "Double quote")

[Title 2](https://example.com 'Single quote')

[Title 3](https://example.com (Parentheses))

---

## 54. Reference Links

[foo][bar]

[foo][]

[foo]

[bar]: https://example.com

---

## 55. Nested Blockquotes and Lists

> Level one
>
> - item
>   - nested item
>
>   > Nested quote
>
>   ```text
>   nested code
>   ```

---

## 56. Thematic Break Ambiguity

---

Paragraph

***

Paragraph

___

Paragraph

- - -

Paragraph

---

## 57. Ordered List Edge Cases

1. Item

10. Ten

11. Eleven

999. Large start number

---

## 58. Four-space Indentation

    This is a code block.
    
        More indentation.

---

## 59. Mixed Indentation

- Item
    - Nested item
        - Deep item

1. Item
   - Nested
     - Deep

---

## 60. Escaped List Markers

\- Not a list

\* Not a list

\+ Not a list

1\. Not an ordered list

---

## 61. Escaped Heading

\# This is not a heading

Text.

---

## 62. Literal HTML vs Markdown

<div>

**This Markdown may not be parsed as Markdown inside HTML block.**

</div>

---

## 63. HTML Inline Around Markdown

This is <span>inline **Markdown-like text**</span>.

---

## 64. URL and Email Edge Cases

<https://example.com/path/to/page>

<https://example.com/?foo=bar&baz=qux>

<user@example.com>

<first.last+tag@example.co.uk>

---

## 65. Unicode Links

[中文链接](https://example.com/中文)

[日本語](https://example.com/日本語)

[Emoji 😀](https://example.com/emoji)

---

## 66. Multiple Paragraph Footnotes

Text with a long footnote.[^multi]

[^multi]: First paragraph of the footnote.

    Second paragraph of the footnote.
    
    - List item inside footnote
    - Another item
    
    ```text
    Code inside footnote
    ```

---

## 67. Footnote Ordering

Reference A[^a].

Reference B[^b].

Reference C[^c].

[^c]: Defined first in source.

[^a]: Defined second in source.

[^b]: Defined third in source.

---

## 68. Duplicate Footnote References

First reference[^dup].

Second reference[^dup].

[^dup]: This footnote is referenced multiple times.

---

## 69. Footnote Labels

[^1]

[^abc]

[^ABC]

[^note-1]

[^note_with_underscore]

[^note.with.dot]

---

## 70. GFM Features Summary

### Supported by GFM / cmark-gfm extensions

- [x] Tables
- [x] Task list items
- [x] Strikethrough
- [x] Autolinks
- [x] Footnotes

### CommonMark core features

- [x] ATX headings
- [x] Setext headings
- [x] Paragraphs
- [x] Blockquotes
- [x] Ordered lists
- [x] Unordered lists
- [x] Code blocks
- [x] Fenced code blocks
- [x] Emphasis
- [x] Strong emphasis
- [x] Links
- [x] Images
- [x] Escapes
- [x] Entities
- [x] HTML
- [x] Thematic breaks

---

## 71. Full Mixed Test

# GFM Full Integration Test

> This block contains multiple Markdown constructs.

Here is **bold**, *italic*, ***bold italic***, ~~strikethrough~~,
`inline code`, an [inline link](https://example.com), and an
<https://example.com> autolink.

### Tasks

- [x] Parse paragraph
- [x] Parse **emphasis**
- [ ] Parse tables
- [ ] Parse footnotes[^integration]

### Table

| Feature | Example | Enabled |
|---|---|:---:|
| Emphasis | *italic* | ✅ |
| Strong | **bold** | ✅ |
| Strike | ~~strike~~ | ✅ |
| Code | `code` | ✅ |
| Link | [link](https://example.com) | ✅ |
| Task | - [x] done | ✅ |

### Quote

> A quoted paragraph with **bold**, *italic*, and `code`.
>
> - Nested list
> - Another item
>
> ```javascript
> const markdown = "GFM";
> console.log(markdown);
> ```

### HTML

<details>
<summary>Click to expand</summary>

Inside the HTML block.

- Markdown-looking list
- **Markdown-looking bold**

</details>

### Footnote

This section has a footnote.[^integration]

[^integration]: Integration-test footnote.

---

## 72. Final Stress Test

# Final Stress Test

> **Bold quote** with *italic*, `code`, ~~strike~~,
> [link](https://example.com), and <https://example.com>.
>
> - [x] Task
> - [ ] Task
>
> | A | B |
> |---|---:|
> | **bold** | `code` |
> | *italic* | ~~strike~~ |

1. Ordered item
   - Unordered nested item
   - [x] Nested task
   - [ ] Another task
   - [Nested link](https://example.com)

```javascript
function markdownTest() {
    const features = [
        "headings",
        "paragraphs",
        "emphasis",
        "strong",
        "links",
        "images",
        "code",
        "lists",
        "blockquotes",
        "tables",
        "tasks",
        "strikethrough",
        "autolinks",
        "footnotes"
    ];

    return features;
}
```

---

## 73. End Marker

**END OF CMARK-GFM TEST FILE**

---

<!--
  End of test document.
  This comment is intentionally included to test HTML comments.
-->