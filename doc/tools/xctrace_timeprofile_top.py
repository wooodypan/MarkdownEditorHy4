#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 xctrace 导出的 time-profile XML 变成「打开这份文档，时间都花在谁身上」。

### 完整三步（Mac Catalyst 上剖析「打开一份 md」）

```bash
# 1) 录：全系统采 25 秒，同时用「打开方式」把文档交给 App（App 要是 Release 构建）
xcrun xctrace record --template 'Time Profiler' --all-processes --no-prompt --time-limit 25s \
    --output /tmp/open.trace &
sleep 5
open -n -a <DerivedData>/Build/Products/Release-maccatalyst/MarkdownEditorHy4.app "/abs/path/文档.md"
wait

# 2) 从 TOC 里找出 App 的 pid（注意：xctrace 的导出是「首次出现定义、之后用 ref 引用」的格式）
xcrun xctrace export --input /tmp/open.trace --toc | grep -A1 MarkdownEditorHy4

# 3) 导出采样表 → 跑本脚本
xcrun xctrace export --input /tmp/open.trace \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' --output /tmp/tp.xml
python3 doc/tools/xctrace_timeprofile_top.py /tmp/tp.xml <pid> MarkdownEditorHy4
```

也可以直接把 /tmp/open.trace 拖进 Instruments 看（Call Tree 上勾 Invert Call Tree + Hide System Libraries）。

xctrace 导出的不是普通 XML：元素**第一次出现时定义**（带 id / 内容），之后只写 `<xxx ref="N"/>` 引用。
所以先把「定义」全扫一遍，再回填每一行采样。

每次采样（row）= 一个 1ms 采样点，带完整调用栈（leaf 在最前）。
三种视角：
  1. 自身耗时（Self Weight）—— Instruments 默认那一列；
  2. 反向归因（Invert Call Tree）：把每个采样记到「调用栈上最内层的自家函数」；
  3. 时间线自动切阶段 + 单独框出「打开文档」那一段。

用法：hy4_analyze_trace.py <tp.xml> <pid> [app_binary_name]
"""

import re
import sys
from collections import Counter, defaultdict

path = sys.argv[1]
target_pid = int(sys.argv[2])
app_bin = sys.argv[3] if len(sys.argv) > 3 else "MarkdownEditorHy4"

data = open(path, "rb").read().decode("utf-8", "replace")

ENT = [("&lt;", "<"), ("&gt;", ">"), ("&quot;", '"'), ("&#10;", "\n"), ("&apos;", "'"), ("&amp;", "&")]


def unescape(s):
    for a, b in ENT:
        s = s.replace(a, b)
    return s


# ---------- 1. 扫定义 ----------
weight_of = {m.group(1): int(m.group(2)) for m in re.finditer(r'<weight id="(\d+)"[^>]*>(\d+)</weight>', data)}
bin_of = {m.group(1): unescape(m.group(2)) for m in re.finditer(r'<binary id="(\d+)" name="([^"]*)"', data)}

frame_of = {}
for m in re.finditer(r"<frame id=\"(\d+)\"([^>]*)>(.*?)</frame>", data, re.S):
    fid, attrs, inner = m.group(1), m.group(2), m.group(3)
    nm = re.search(r'name="([^"]*)"', attrs)
    b_inline = re.search(r'<binary id="\d+" name="([^"]*)"', inner)
    b_ref = re.search(r'<binary ref="(\d+)"', inner)
    bname = unescape(b_inline.group(1)) if b_inline else (bin_of.get(b_ref.group(1), "?") if b_ref else "?")
    frame_of[fid] = (unescape(nm.group(1)) if nm else "?", bname)

bt_of = {}
for m in re.finditer(r"<tagged-backtrace id=\"(\d+)\">(.*?)</tagged-backtrace>", data, re.S):
    ids = []
    for t in re.finditer(r"<frame ([^>]*?)/?>", m.group(2)):
        r = re.search(r'ref="(\d+)"', t.group(1)) or re.search(r'id="(\d+)"', t.group(1))
        if r:
            ids.append(r.group(1))
    bt_of[m.group(1)] = ids

pid_of_proc = {m.group(1): int(m.group(2))
               for m in re.finditer(r'<process id="(\d+)"[^>]*>\s*<pid id="\d+"[^>]*>(\d+)</pid>', data)}
thread_fmt = {m.group(1): unescape(m.group(2))
              for m in re.finditer(r'<thread id="(\d+)" fmt="([^"]*)"', data)}


def ref_of(row, tag):
    m = re.search(r'<%s ref="(\d+)"' % tag, row) or re.search(r'<%s id="(\d+)"' % tag, row)
    return m.group(1) if m else None


# ---------- 2. 回填每一行采样 ----------
samples = []
for row in re.finditer(r"<row>(.*?)</row>", data, re.S):
    row = row.group(1)
    if pid_of_proc.get(ref_of(row, "process")) != target_pid:
        continue
    w = weight_of.get(ref_of(row, "weight"))
    ts = re.search(r"<sample-time[^>]*>(\d+)</sample-time>", row)
    bt = bt_of.get(ref_of(row, "tagged-backtrace"))
    if w is None or ts is None or not bt:
        continue
    samples.append((int(ts.group(1)), w, "Main Thread" in thread_fmt.get(ref_of(row, "thread"), ""),
                    [frame_of.get(f, ("?", "?")) for f in bt]))
samples.sort()
t0 = samples[0][0]

total = sum(s[1] for s in samples)
main_total = sum(s[1] for s in samples if s[2])
print(f"pid={target_pid}（{app_bin}）采到 {len(samples)} 个样本 = {total/1e6:.0f} ms CPU（主线程 {main_total/1e6:.0f} ms）")
print(f"时间跨度 {(samples[-1][0]-t0)/1e9:.2f} s")


def ms(ns):
    return ns / 1e6


# 「main / UIApplicationDelegate.main」这类根 thunk 不算「自家函数」——它在栈上只是说明这些活是 App 的进程在主线程上干的
ROOT_HINTS = ("UIApplicationDelegate.main()", "AppDelegate.$main()", " specializer", "main")


def own_frames(frames):
    out = []
    for sym, b in frames:
        if b != app_bin or sym == "<deduplicated_symbol>":
            continue
        if sym == "main" or "UIApplicationDelegate.main()" in sym or "AppDelegate.$main()" in sym:
            continue
        out.append(sym)
    return out


def charge(frames, main_only_note=""):
    own = own_frames(frames)
    if not own:
        return "<纯系统：栈上没有自家函数>"
    return own[0]          # leaf 方向最靠内的自家函数


# ---------- 3. 反向归因 ----------
charge_main = Counter()
sys_only = 0
for ts, w, is_main, frames in samples:
    if not is_main:
        continue
    k = charge(frames)
    charge_main[k] += w
    if k.startswith("<纯系统"):
        sys_only += w

print("\n### 反向归因 · 主线程：时间该记在哪个自家函数头上（= Instruments 的 Invert Call Tree）")
for k, ns in charge_main.most_common(18):
    print(f"{ms(ns):8.1f} ms {100*ns/main_total:6.1f}%  {k}")
print(f"→ 「栈上没有自家函数」的占主线程 {100*sys_only/main_total:.1f}%："
      f"这些活是 UIKit / CoreText / CoreGraphics 自己在干，我们只是把数据交给它")

# 纯系统那部分到底在干嘛：看 leaf 的「父帧」
sys_pairs = Counter()
for ts, w, is_main, frames in samples:
    if is_main and charge(frames).startswith("<纯系统"):
        parent = frames[1][0] if len(frames) > 1 else "?"
        grand = frames[2][0] if len(frames) > 2 else "?"
        sys_pairs[(parent, grand, frames[0][0])] += w
print("\n### 「纯系统」那部分在干嘛（父帧 → 祖父帧 → 自身）")
for (p, g, l), ns in sys_pairs.most_common(10):
    print(f"{ms(ns):8.1f} ms  {p[:70]}  ←  {g[:50]}\n             自身：{l[:80]}")

# 自检：断言「纯系统」桶里真的没有自家函数（排除解析失误）
pure = [s for s in samples if s[2] and charge(s[3]).startswith("<纯系统")]
with_own = [s for s in pure if own_frames(s[3])]
print(f"\n[自检] 「纯系统」桶 {len(pure)} 个采样；其中栈上另有自家函数的 {len(with_own)} 个"
      f"（{sum(s[1] for s in with_own)/1e6:.0f} ms）")

leaf_main = Counter()
for ts, w, is_main, frames in samples:
    if is_main:
        leaf_main[(frames[0][1], frames[0][0])] += w
print("\n### 自身耗时 Top15 · 主线程（Self Weight 列）")
for (b, sym), ns in leaf_main.most_common(15):
    print(f"{ms(ns):8.1f} ms {100*ns/main_total:6.1f}%  [{b}] {sym[:90]}")

# ---------- 4. 时间线 ----------
BUCKET = 0.5
buckets = defaultdict(int)
for ts, w, is_main, frames in samples:
    buckets[ts // int(BUCKET * 1e9)] += w
base = min(buckets)
print("\n### 时间线（每 500ms 一格，主线程 CPU）")
for k in sorted(buckets):
    print(f"  t={(k-base)*BUCKET:6.1f}s {ms(buckets[k]):7.1f} ms  " + "#" * int(ms(buckets[k]) / 30))

# 「打开文档」那一段：栈上出现渲染管线关键函数就算
DOC_HINTS = ("MarkdownDocumentStore", "MarkupToAttributedRenderer", "setMarkdown", "replaceWholeStorage",
             "MarkdownTextView.render", "MarkdownDocumentViewController.apply")
doc_samples = [s for s in samples if any(h in f[0] for f in s[3] for h in DOC_HINTS)]
if doc_samples:
    wall = (doc_samples[-1][0] - doc_samples[0][0]) / 1e9
    cpu = sum(s[1] for s in doc_samples)
    print(f"\n### 「打开文档」这一段（栈上出现解析 / 渲染管线）")
    print(f"  从 t={(doc_samples[0][0]-t0)/1e9:.1f}s 起，铺开约 {wall:.1f} s；"
          f"这段里 App 烧了 {cpu/1e6:.0f} ms CPU（{100*cpu/total:.0f}% 的全部 CPU）")
    ch = Counter()
    lf = Counter()
    own_c = Counter()
    for ts, w, is_main, frames in doc_samples:
        ch[charge(frames)] += w
        lf[(frames[0][1], frames[0][0])] += w
        own = own_frames(frames)
        if own:
            own_c[own[0]] += w
    print("  [记在谁头上]")
    for k, ns in ch.most_common(12):
        print(f"    {ms(ns):8.1f} ms {100*ns/cpu:6.1f}%  {k}")
    print("  [自身耗时 top8]")
    for (b, sym), ns in lf.most_common(8):
        print(f"    {ms(ns):8.1f} ms {100*ns/cpu:6.1f}%  [{b}] {sym[:80]}")
