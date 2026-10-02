#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 Bear 的 .theme 主题文件转换成 MarkdownEditorHy4 能直接吃进去的配色 JSON。

### 为什么要写这么个东西
`doc/BTheme/` 里放着 39 份 Bear 的主题（`.theme` 后缀），本 App 认的是
`MarkdownColorPalette` 那套键名（见 `doc/theme-example.json`），两边的键名完全不一样，
一份一份手工抄太容易抄错，所以写个脚本一次性全转掉。

### 怎么跑
```bash
python3 doc/tools/bear_theme_to_palette.py
```
默认就是「读 `doc/BTheme/*.theme`，写到 `doc/themebear/*.json`」，
想看别的目录就加 `--src` / `--dst`。脚本只用标准库，不装任何东西。

### .theme 文件到底是什么
就是一份 JSON 文本（39 份全都解析得动，没有例外），里面分 `base` / `editor` / `sidebar` /
`notes` / `placeholder` 几大块，颜色写成 `"#RRGGBB"` 的字符串。

### ⚠️ 最要命的一点：它是「基主题 + 增量覆盖」两层
一份主题自己可能只写了三五个颜色，剩下全靠 `meta.base theme` 指名的**基主题**兜底 ——
比如 `Academia.theme` 全文只有 8 个色，写着 `"base theme": "Dark Graphite"`。
所以脚本必须先把基主题读进来合并，**不合并的话转出来的 JSON 缺一大半键**，
在 App 里选上它就是「一堆颜色没变」，看着像坏了。

### 四种写法都要处理
1. `"#C7B3A8"` —— 实实在在的色值，直接用；
2. `"$base.text color"` —— 引用同一个文件里别的键，要翻译成那个键的值（`$` 后面那串就是键路径，键名里的空格是键名的一部分，不是分隔符）；
3. `"value"` 为空、或者键压根没写 —— 交给下一层兜底（没基主题就跳过这个调色键）；
4. 数字 / 字符串（`"text size": 15`、`"text size font": "BearSansUI-Regular"`）—— 这些不是颜色，脚本不看。

### 键是怎么对应的（左边是本 App 的键，右边是 Bear 的键，按顺序取第一个有值的）
Bear 有 100 个叶子键，本 App 的配色表只有 28 个格子，所以这是一张「有损」的对照表。

| 本 App（MarkdownColorPalette） | Bear 来源（依次优先） | 说明 |
|---|---|---|
| editorBackground | `editor.background color` → `base.background color` | 编辑区底色，深色主题全靠它 |
| text | `editor.text color` → `base.text color` | 正文 |
| marker | `editor.marker color` → `base.text tertiary color` | 语法标记，两边语义一样 |
| orderedListMarker | `editor.list marker color` → `base.accent color` | 有序列表序号 |
| bullet | `editor.list marker color` → `base.accent color` | 无序列表圆点（Bear 里和序号同色） |
| link | `editor.link color` → `base.accent color` | 链接 |
| inlineCode | `editor.code.text color` → `base.text color` | 行内代码正文 |
| inlineCodeBacktick | `editor.code.border color` → `base.text tertiary color` | 反引号（Bear 的 code 边框色正好是「淡一档」的那个色） |
| inlineCodeBackground | `editor.code.background color` → `base.background secondary color`，**要反解成半透明** | 见下面「为什么要反解」 |
| codeBlockBackground | `editor.code.background color` → `base.background secondary color` | 代码块整块底色，原样给 |
| quoteText | `base.text color` | Bear 没有引用块配色，跟着正文走 |
| quoteBar | `base.accent color` | 推导：主色当引用竖条，和内置 vue 的做法一致 |
| separator | `editor.separator.border color` → `base.stroke color` | 分隔线 |
| searchMatchBackground | `base.search primary color` | 查找命中 |
| searchCurrentMatchBackground | `base.search primary color` + 85% 透明度 | 推导：Bear 没有「当前命中」，用命中色加深一档 |
| lineNumber | `base.text tertiary color` | 推导：行号要淡，取最低一档的文字色 |
| collapsedPlaceholder | `base.text tertiary color` | 推导：同上 |
| keyword / string / comment / number | `editor.code.syntax highlight.*` 同名键 | comment 兜底 `base.text secondary color`；number 兜底 `constant` |
| type | `editor.code.syntax highlight.entity`；它和 keyword 同色时改取 `function` | 推导：Bear 没有「类型」这个角色，TextMate 里 `entity.name.type` 正好就是类型名那个作用域；但有几份主题（Dark Graphite 那一系）把 entity 配得和 keyword 一个色，那在 App 里类型和关键字会糊成一个色，所以退到 function |
| tableHeaderBackground | `editor.table.cell alternate background color` → `base.background secondary color` | 表头底色 |
| tableBorder | `editor.table.border color` → `base.stroke color` | 表格线 |
| tableSourceText | `base.text tertiary color` | 推导：表格源码是附属物，压到最淡 |
| taskChecked | `editor.task.check color` → `base.accent color` | 勾选后的填充色 |
| taskUncheckedBorder | `editor.task.border color` → `base.stroke color` | 未勾选边框 |
| taskCheckmark | 按填充色亮度自动选黑或白 | 推导：Bear 的对勾色（`task.check color`）已经当填充色用掉了，为了看得见只能自己算对比色 |

没被用上的（界面里没有对应位置）：`sidebar.*`（App 是单编辑区，没有侧栏）、`notes.*`（目录页配色）、
`placeholder.*`（预览卡片的占位图）、`editor.cursor color`、`editor.selection*`（系统选中高亮的色，
App 用系统自己的）、`editor.highlighter.*`（Bear 的荧光笔标记，App 还没有这个功能）、
所有 `font` / `size` / `multiplier`（本 App 换配色时**只换颜色**，字号行高是用户自己在设置页调的）。

### ⚠️ 为什么 inlineCodeBackground 要「反解」
App 里行内代码的底色是挂在文字上的 `.backgroundColor`（跟着文字一起画，会盖住系统选中高亮），
所以配色表里这一项**必须半透明**。而 Bear 给的是一个不透明的实色，直接抄进去，
在 App 里框选行内代码就会像没选中。

反解的做法：设 Bear 的目标色是 C、编辑区底色是 B、最终存成 alpha = a 的颜色 C'，
那么铺上去看到的颜色是 `a·C' + (1-a)·B`。让这个结果**正好等于 C**，就能做到
「颜色和 Bear 一模一样，同时又是半透明的」：
```
C' = B + (C - B) / a
```
a 取多少：至少要 `max(|C-B|) / 255`（否则 C' 会超出 0~255 被夹掉、就对不上了），
再抬到 28% 保底（太小了半透明没意义）、封顶 90%（100% 就退化成不透明了）。
色差本来就不大的主题（Bear 的主题大多如此），这一步出来是**逐通道精确相等**的。

特例：如果代码底色和编辑区底色**一模一样**（色差为 0），说明这份主题压根没打算区分行内代码，
那就不写这一项（留空 = 交给 App 自带的淡灰），比写一个「和背景同色」的假值更诚实。
"""

import argparse
import json
import math
import os
import sys

# ---------------------------------------------------------------------------
# 一、读文件：JSON 解析 + 顺着基主题一路合并
# ---------------------------------------------------------------------------

# 一个主题的「基主题」最多往上层找几层，防着文件互相指来指去把脚本转死
MAX_BASE_DEPTH = 8


def read_theme_json(path):
    """读一份 .theme 文件，返回解析好的字典（读不动就返回 None）。"""
    try:
        # 用 utf-8-sig 而不是 utf-8：有的文件开头带着 BOM（看不见的三个字节），
        # 用 utf-8 读会把它当成正文的第一个字符，JSON 直接解析失败
        with open(path, "r", encoding="utf-8-sig") as handle:
            return json.load(handle)
    except (OSError, ValueError) as error:
        print("  ! 读不动 %s：%s" % (path, error))
        return None


def theme_file_for(name, search_dirs):
    """按主题名找到对应的 .theme 文件；找不到返回 None。"""
    for directory in search_dirs:
        candidate = os.path.join(directory, name + ".theme")
        if os.path.isfile(candidate):
            return candidate
    return None


def deep_merge(base, override):
    """把 override 盖在 base 上（深合并）：两边都有且都是字典就继续往里合，否则 override 说了算。"""
    result = dict(base)
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = value
    return result


def load_theme_with_base(name, search_dirs, chain=None):
    """读一份主题，并把它声明的基主题一起合并好。

    返回 `(合并后的字典, 基主题名列表)`；基主题名列表按「从上到下」排，用来在 JSON 里写一行来历。
    """
    chain = chain or []
    if len(chain) > MAX_BASE_DEPTH:
        print("  ! 基主题套得太深了（超过 %d 层），后面的不再往上找" % MAX_BASE_DEPTH)
        return {}, chain

    path = theme_file_for(name, search_dirs)
    if path is None:
        print("  ! 找不到主题文件：%s.theme" % name)
        return {}, chain

    data = read_theme_json(path)
    if data is None:
        return {}, chain

    base_name = (data.get("meta") or {}).get("base theme")
    if not base_name or base_name in chain:
        # 没有基主题，或者绕回来了（防死循环），就到此为止
        return data, chain

    base_data, chain = load_theme_with_base(base_name, search_dirs, chain + [base_name])
    return deep_merge(base_data, data), chain


# ---------------------------------------------------------------------------
# 二、铺平 + 解引用
# ---------------------------------------------------------------------------


def flatten(node, prefix=""):
    """把嵌套的字典铺成「一条路径 → 一个值」，路径拿点号连接，比如 `editor.code.text color`。

    ⚠️ 键名里本身带空格（`text color`），但**不带点号**，所以拿点号当分隔符是安全的
    —— 不会出现「本来是一个键，被拆成两个」的情况。
    """
    flat = {}
    for key, value in node.items():
        if prefix == "" and key == "meta":
            continue  # meta 里只有「基主题叫啥」这类说明，不是颜色
        path = key if prefix == "" else prefix + "." + key
        if isinstance(value, dict):
            flat.update(flatten(value, path))
        else:
            flat[path] = value
    return flat


def resolve_references(flat):
    """把 `"$base.text color"` 这种「引用别的键」翻译成那个键真正的值。

    引用可以链式（A 引用 B、B 引用 C），所以用递归 + 缓存；顺便挡掉互相引用的死循环。
    """
    cache = {}
    visiting = set()

    def resolve(path):
        if path in cache:
            return cache[path]
        if path in visiting:
            return None  # 绕回来了，当成「没这个值」
        raw = flat.get(path)
        if isinstance(raw, str) and raw.startswith("$"):
            visiting.add(path)
            result = resolve(raw[1:])
            visiting.discard(path)
        else:
            result = raw
        cache[path] = result
        return result

    return {path: resolve(path) for path in flat}


def first_value(flat, *paths):
    """按顺序取第一个「存在、是字符串、而且是色值」的值；都没取到返回 None。"""
    for path in paths:
        value = flat.get(path)
        if isinstance(value, str) and value.startswith("#"):
            return value
    return None


# ---------------------------------------------------------------------------
# 三、色值：规范化 / 反解半透明 / 算对比色
# ---------------------------------------------------------------------------


def parse_hex(text):
    """把 `#RGB` / `#RRGGBB` 解析成 `(r, g, b)`（0~255）；解析不了返回 None。"""
    if not isinstance(text, str):
        return None
    body = text.strip().lstrip("#")
    if len(body) == 3:  # 三位简写先展开成六位，后面就只用管六位这一种情况
        body = "".join(ch * 2 for ch in body)
    if len(body) != 6:
        return None
    try:
        value = int(body, 16)
    except ValueError:
        return None
    return ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)


def format_hex(rgb, alpha=None):
    """把 `(r, g, b)` 写回小写十六进制；给了 alpha 就写成 8 位的 `#rrggbbaa`。"""
    text = "#%02x%02x%02x" % rgb
    if alpha is None:
        return text
    return text + "%02x" % int(round(alpha * 255))


def normalise_hex(text):
    """把色值统一成小写 `#rrggbb`。"""
    rgb = parse_hex(text)
    if rgb is None:
        return None
    return format_hex(rgb)


def relative_luminance(rgb):
    """算亮度（0 = 纯黑，1 = 纯白）。用来判断「这个底上该配黑字还是白字」。"""
    channels = []
    for value in rgb:
        unit = value / 255.0
        # sRGB 的亮度不是简单平均：人眼对绿色最敏感、蓝色最迟钝，所以加权系数不一样
        channels.append(unit / 12.92 if unit <= 0.03928 else ((unit + 0.055) / 1.055) ** 2.4)
    return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]


def translucent_equivalent(target_hex, background_hex):
    """把不透明色反解成「铺在背景上看着一样」的半透明色（原理见文件开头那段说明）。

    返回 8 位的 `#rrggbbaa`；目标色和背景色一模一样时返回 None（这种情况不写这一项）。
    """
    target = parse_hex(target_hex)
    background = parse_hex(background_hex)
    if target is None or background is None:
        return None

    deltas = [target[i] - background[i] for i in range(3)]
    # alpha 至少得让「差值 / alpha」落在 0~255 里，否则反解出来的颜色会被夹掉、就对不上了
    needed = max(abs(delta) for delta in deltas) / 255.0
    alpha = max(0.28, needed)  # 28% 保底：太小了「半透明」就没意义
    alpha = min(0.90, alpha)  # 90% 封顶：到 100% 就退化成不透明了，又会盖住选中高亮

    if max(abs(delta) for delta in deltas) == 0:
        return None  # 色差为零，说明这份主题没打算区分行内代码，留空让 App 用自带的

    stored = []
    for index in range(3):
        value = background[index] + deltas[index] / alpha
        stored.append(int(round(min(255.0, max(0.0, value)))))
    return format_hex(tuple(stored), alpha)


def contrast_text_color(fill_hex):
    """给一个填充色，挑一个「在上面对比度够」的文字色（白或近黑）。"""
    rgb = parse_hex(fill_hex)
    if rgb is None:
        return "#ffffff"
    return "#1c1c1e" if relative_luminance(rgb) > 0.55 else "#ffffff"


# ---------------------------------------------------------------------------
# 四、映射：Bear 的键 → 本 App 配色表的键
# ---------------------------------------------------------------------------

# 输出顺序照着 MarkdownColorPalette 的文件顺序来，方便和 `theme-example.json` 对着看。
PALETTE_KEY_ORDER = [
    "editorBackground", "text", "marker", "orderedListMarker", "link",
    "inlineCode", "inlineCodeBacktick", "inlineCodeBackground", "codeBlockBackground",
    "quoteText", "quoteBar", "bullet", "separator",
    "searchMatchBackground", "searchCurrentMatchBackground",
    "lineNumber", "collapsedPlaceholder",
    "keyword", "string", "comment", "number", "type",
    "tableHeaderBackground", "tableBorder", "tableSourceText",
    "taskChecked", "taskUncheckedBorder", "taskCheckmark",
]


def build_palette(flat):
    """把一份铺平（且引用已解析）的主题字典，翻译成本 App 的配色表。

    返回 `(配色字典, 备注列表)`；备注是给写进 JSON 的那几行 `"//"` 注释用的。
    """
    def take(*paths):
        value = first_value(flat, *paths)
        return normalise_hex(value) if value else None

    palette = {}
    palette["editorBackground"] = take("editor.background color", "base.background color")
    palette["text"] = take("editor.text color", "base.text color")
    palette["marker"] = take("editor.marker color", "base.text tertiary color")
    palette["orderedListMarker"] = take("editor.list marker color", "base.accent color")
    palette["link"] = take("editor.link color", "base.accent color")
    palette["inlineCode"] = take("editor.code.text color", "base.text color")
    palette["inlineCodeBacktick"] = take("editor.code.border color", "base.text tertiary color")

    # 行内代码底色要反解成半透明，代码块底色原样保留 —— 两者在 Bear 里是同一个色
    code_background = take("editor.code.background color", "base.background secondary color")
    if code_background and palette["editorBackground"]:
        palette["inlineCodeBackground"] = translucent_equivalent(code_background, palette["editorBackground"])
    else:
        palette["inlineCodeBackground"] = None
    palette["codeBlockBackground"] = code_background

    palette["quoteText"] = take("base.text color")
    palette["quoteBar"] = take("base.accent color")
    palette["bullet"] = take("editor.list marker color", "base.accent color")
    palette["separator"] = take("editor.separator.border color", "base.stroke color")

    search_primary = take("base.search primary color")
    palette["searchMatchBackground"] = search_primary
    # 当前命中：Bear 没有这个概念，用命中色加深到 85%（内置的 vue 配色也是这么干的）
    if search_primary:
        palette["searchCurrentMatchBackground"] = search_primary + "d9"
    else:
        palette["searchCurrentMatchBackground"] = None

    palette["lineNumber"] = take("base.text tertiary color")
    palette["collapsedPlaceholder"] = take("base.text tertiary color")

    palette["keyword"] = take("editor.code.syntax highlight.keyword")
    palette["string"] = take("editor.code.syntax highlight.string")
    palette["comment"] = take("editor.code.syntax highlight.comment", "base.text secondary color")
    palette["number"] = take("editor.code.syntax highlight.number", "editor.code.syntax highlight.constant")
    # 类型色：先用 entity（TextMate 的 entity.name.type 就是「类型名」那个作用域），
    # 但有几份主题把 entity 配得和 keyword 一模一样，那在 App 里「类型」就和「关键字」糊成一个色了
    # —— 这种主题退到 function（它也是「一批名字」的语义，而且和关键字分得开）
    entity_color = take("editor.code.syntax highlight.entity")
    if entity_color and entity_color != palette["keyword"]:
        palette["type"] = entity_color
    else:
        palette["type"] = take("editor.code.syntax highlight.function") or entity_color

    palette["tableHeaderBackground"] = take("editor.table.cell alternate background color", "base.background secondary color")
    palette["tableBorder"] = take("editor.table.border color", "base.stroke color")
    palette["tableSourceText"] = take("base.text tertiary color")

    palette["taskChecked"] = take("editor.task.check color", "base.accent color")
    palette["taskUncheckedBorder"] = take("editor.task.border color", "base.stroke color")
    # 对勾色：Bear 那个 task.check color 已经当填充色用了，对比色只能自己按亮度算
    palette["taskCheckmark"] = contrast_text_color(palette["taskChecked"]) if palette["taskChecked"] else None

    notes = []
    if not palette["inlineCodeBackground"]:
        notes.append("行内代码底色：主题里和编辑区底色一样（或没给），本项留空、用 App 自带的淡灰")
    return palette, notes


# ---------------------------------------------------------------------------
# 五、写文件
# ---------------------------------------------------------------------------


def write_palette(path, palette, theme_name, base_chain, is_merged, notes):
    """把配色表写成 JSON 文件。

    那些以 `//` 开头的键是**注释**：App 那边用的是 `JSONDecoder`，认不出这些键名会直接跳过，
    所以写进去既能留个来历、又不影响读取（`doc/theme-example.json` 就是这么写的）。
    """
    payload = {
        "//": "由 doc/tools/bear_theme_to_palette.py 从 doc/BTheme/%s.theme 自动转换生成，勿手工编辑。" % theme_name,
        "//用法": "在 App 的设置页里挑这个文件即可；只写了本 App 配色表认识的键，其余键沿用你当前所选的内置主题。",
        "//写法": "十六进制，#RGB / #RRGGBB / #RRGGBBAA 都行；下面斜线开头的几行是注释，会被忽略。",
    }
    if is_merged:
        payload["//基主题"] = "%s（已合并进来，Bear 的 .theme 是「基主题 + 增量覆盖」两层结构）" % " → ".join(base_chain)
    if notes:
        payload["//说明"] = "；".join(notes)

    payload.update({key: palette[key] for key in PALETTE_KEY_ORDER if palette.get(key)})
    # 没映射到的键**不写**：配色表是「覆盖表」，没写 = 继续用所选内置主题的颜色，
    # 写一个猜出来的色反而会把它盖掉
    payload["//未映射"] = "Bear 的 sidebar / notes / placeholder / cursor / selection / highlighter 等键本 App 没有对应位置，未转换。"

    with open(path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2)
        handle.write("\n")


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(os.path.dirname(here))  # doc/tools/ → doc/ → 项目根

    parser = argparse.ArgumentParser(description="把 Bear 的 .theme 主题转换成 MarkdownEditorHy4 的配色 JSON")
    parser.add_argument("--src", default=os.path.join(project_root, "doc", "BTheme"), help=".theme 文件所在目录")
    parser.add_argument("--dst", default=os.path.join(project_root, "doc", "themebear"), help="JSON 输出目录")
    args = parser.parse_args()

    src_dir, dst_dir = os.path.abspath(args.src), os.path.abspath(args.dst)
    if not os.path.isdir(src_dir):
        print("找不到源目录：%s" % src_dir)
        return 1
    os.makedirs(dst_dir, exist_ok=True)

    # 基主题和主题文件放在同一个目录里（Dark Graphite / Red Graphite / Dieci / Solarized Light 都在），
    # 项目根目录再兜一道，以防哪天有人把基主题单拎出去
    search_dirs = [src_dir, project_root]

    names = sorted(name[: -len(".theme")] for name in os.listdir(src_dir) if name.endswith(".theme"))
    print("读到 %d 份主题：%s" % (len(names), src_dir))
    written, failed = 0, []

    for name in names:
        print("- %s" % name)
        merged, base_chain = load_theme_with_base(name, search_dirs)
        if not merged:
            failed.append(name)
            continue
        flat = resolve_references(flatten(merged))
        palette, notes = build_palette(flat)
        filled = sum(1 for key in PALETTE_KEY_ORDER if palette.get(key))
        out_path = os.path.join(dst_dir, name + ".json")
        write_palette(out_path, palette, name, base_chain, bool(base_chain), notes)
        print("    基主题：%s｜写了 %d/%d 个色 → %s" % (" → ".join(base_chain) if base_chain else "无", filled, len(PALETTE_KEY_ORDER), os.path.basename(out_path)))
        written += 1

    print("\n完成：%d 份写入 %s" % (written, dst_dir))
    if failed:
        print("失败：%s" % "、".join(failed))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
