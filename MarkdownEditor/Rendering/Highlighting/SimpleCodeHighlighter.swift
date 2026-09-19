//
//  SimpleCodeHighlighter.swift
//  MarkdownEditorHy4
//
//  手写单遍扫描的轻量高亮器：支持 JavaScript / Python / Swift
//

import Foundation

/// 一个「够看就行」的高亮器。
///
/// ### 为什么手写扫描而不用正则
/// 用 `NSRegularExpression` 的话，每遇到一种 token 都要在整个字符串上跑一遍匹配，
/// 三种语言各有 6~8 条规则，等于把代码从头到尾扫 8 遍；而且每条规则都要
/// 把匹配结果的 `Range<String.Index>` 折算回 `NSRange`，来回换算很贵。
///
/// 这里的实现是**一次遍历**：每个字符只看一眼就决定它属于哪一类，看一眼走一格，
/// 除了标识符本身要拼成 String（查关键字表用）以外几乎不分配内存。
/// 代价是精度（嵌套块注释、模板字符串插值这类一律不精细处理），
/// 但这个编辑器里的高亮本来就是给眼睛看的 —— 判错了顶多颜色不对，不影响编辑和复制。
///
/// ### 无状态
/// 整个类型是纯函数式的：输入代码串，输出 token 数组。
/// 渲染可能被多处同时调用，留可变状态是自找麻烦。
struct SimpleCodeHighlighter: CodeHighlighting {
    /// 单次最多扫多少个字符（按 Unicode 标量算，约等于字符数）。超过就整段放弃高亮。
    ///
    /// ### 为什么要有这个上限
    /// 高亮是在**每次重渲染**时跑的 —— 在一个代码块里敲一个字，整块都要重新扫一遍。
    /// 万一贴进来一段几万行的日志或者机器生成的代码，每次按键都要全扫，
    /// 输入就开始发顿了。到那个量级也没人在乎颜色，不如直接按纯文本显示保帧率。
    var maximumLength: Int

    init(maximumLength: Int = 20_000) {
        self.maximumLength = maximumLength
    }

    // MARK: CodeHighlighting

    func supportsLanguage(_ language: String) -> Bool {
        CodeLanguageProfile.profile(forLanguage: language) != nil
    }

    func highlight(_ code: String, language: String) -> [HighlightToken] {
        guard let profile = CodeLanguageProfile.profile(forLanguage: language) else { return [] }
        let scalars = Array(code.unicodeScalars)
        guard !scalars.isEmpty, scalars.count <= maximumLength else { return [] }
        return Lexer(scalars: scalars, profile: profile).run()
    }
}

// MARK: - 扫描器

/// 真正干活的那部分。
///
/// 拆成一个内部类型是为了让扫描过程中那些「当前扫到哪了」的状态有个地方放，
/// 不至于让 `highlight` 里一堆递归参数。
private struct Lexer {
    /// 代码拆成标量后的数组。数组下标随机访问是 O(1)，比反复 `String.index(_:offsetBy:)` 快得多
    let scalars: [Unicode.Scalar]
    let profile: CodeLanguageProfile
    /// `offsets[i]` = `scalars[i]` 对应的 **UTF-16 偏移**（这个才是 NSAttributedString 要的坐标）。
    ///
    /// ### 为什么要这张表
    /// 单个标量在 UTF-16 里占 1 个还是 2 个单元（汉字占 1 个、emoji 占 2 个），
    /// 不能靠下标乘常量算出来。一次性把每个位置的偏移算好，
    /// 后面取任意区间的 NSRange 都是 O(1)，扫描时用不着小心翼翼地累加。
    /// 代价是多一次遍历 + 一个 Int 数组（code 有多长就有多长，扫完就释放）。
    let offsets: [Int]

    init(scalars: [Unicode.Scalar], profile: CodeLanguageProfile) {
        self.scalars = scalars
        self.profile = profile

        var table: [Int] = []
        table.reserveCapacity(scalars.count + 1)
        var offset = 0
        for scalar in scalars {
            table.append(offset)
            // BMP 之外的标量（增补平面，比如 emoji）在 UTF-16 里要占一对代理项
            offset += scalar.value > 0xFFFF ? 2 : 1
        }
        // 末位哨兵：收尾字符的结束偏移也能直接取到
        table.append(offset)
        self.offsets = table
    }

    private var count: Int { scalars.count }

    func run() -> [HighlightToken] {
        var tokens: [HighlightToken] = []
        // 粗估：正常代码里大概每 8~12 个字符出一个片段。先按 1/8 预留，省掉中途反复扩容
        tokens.reserveCapacity(count / 8 + 8)

        var i = 0
        while i < count {
            let c = scalars[i]

            // 1) 空白最常见，先最快地跳过（不上色 = 沿用代码块默认色）
            if c == " ", c == "\t", c == "\n", c == "\r" {
                i += 1
                continue
            }

            // 2) 注释
            if let end = lineCommentEnd(at: i) {
                tokens.append(token(i..<end, role: .comment))
                i = end
                continue
            }
            if let end = blockCommentEnd(at: i) {
                tokens.append(token(i..<end, role: .comment))
                i = end
                continue
            }

            // 3) 字符串
            if let end = stringEnd(at: i) {
                tokens.append(token(i..<end, role: .string))
                i = end
                continue
            }

            // 4) 数字（放在标识符前面：标识符不会以数字开头，两者不冲突）
            if let end = numberEnd(at: i) {
                tokens.append(token(i..<end, role: .number))
                i = end
                continue
            }

            // 5) 标识符 / 关键字
            if let matched = identifierEnd(at: i) {
                // 只有「需要上色」的角色才生成 token。普通标识符返回 nil role，
                // 这样 `addAttribute` 的调用次数能压到最少
                if let role = matched.role {
                    tokens.append(token(i..<matched.end, role: role))
                }
                i = matched.end
                continue
            }

            // 6) 其余（运算符、括号…）不上色，走一格
            i += 1
        }

        return tokens
    }

    // MARK: 构造 token

    /// 把 `[start, end)` 这段**标量区间**换算成 UTF-16 的 `NSRange`
    private func token(_ range: Range<Int>, role: SyntaxRole) -> HighlightToken {
        let lower = offsets[range.lowerBound]
        let upper = offsets[min(range.upperBound, count)]
        return HighlightToken(range: NSRange(location: lower, length: upper - lower), role: role)
    }

    // MARK: 注释

    private func lineCommentEnd(at start: Int) -> Int? {
        let prefix = profile.lineComment
        guard !prefix.isEmpty else { return nil }

        // 前缀一般是 1~2 个字符（`#` 或 `//`），逐个比对
        for (offset, scalar) in prefix.enumerated() {
            guard start + offset < count, scalars[start + offset] == scalar else { return nil }
        }

        // 一直吃到行尾（换行符本身不上色）
        var j = start + prefix.count
        while j < count, scalars[j] != "\n" { j += 1 }
        return j
    }

    private func blockCommentEnd(at start: Int) -> Int? {
        guard profile.supportsBlockComment,
              start + 1 < count,
              scalars[start] == "/",
              scalars[start + 1] == "*" else { return nil }

        // 找收尾的 `*/`。找不到（没写完的块注释）就把剩下全部算注释
        var j = start + 2
        while j + 1 < count {
            if scalars[j] == "*", scalars[j + 1] == "/" { return j + 2 }
            j += 1
        }
        return count
    }

    // MARK: 字符串

    /// 从引号字符 `start` 开始扫一个字符串字面量，返回**收尾引号之后**的下标。
    /// 不是引号开头就返回 nil（交给后面的分支处理）。
    private func stringEnd(at start: Int) -> Int? {
        let quote = scalars[start]
        let isTemplate = quote == "`" && profile.supportsTemplateLiteral
        guard quote == "\"" || quote == "'" || isTemplate else { return nil }

        // 三引号多行字符串（Python 的 """ / '''、Swift 的 """）
        if profile.supportsTripleQuotes,
           quote != "`",
           start + 2 < count,
           scalars[start + 1] == quote,
           scalars[start + 2] == quote {
            var j = start + 3
            while j + 2 < count {
                if scalars[j] == "\\" { j += 2; continue }          // 转义后的引号不算收尾
                if scalars[j] == quote,
                   scalars[j + 1] == quote,
                   scalars[j + 2] == quote { return j + 3 }
                j += 1
            }
            // 没收尾：剩下全当字符串，总好过把后面的代码染成别的颜色
            return count
        }

        // 单行字符串。
        // ⚠️ 模板字符串里的 `${ … }` 插值**整段都按字符串算**（不单独上色）——
        //    要做对得再嵌套一层扫描，收益不值。反正 JavaScript 里插值通常很短。
        var j = start + 1
        while j < count {
            let c = scalars[j]
            if c == "\\" { j += 2; continue }        // `"\""` 这种
            if c == quote { return j + 1 }
            // 遇到换行就收手：绝大多数语言里单行字符串不能跨行，
            // 提前收尾比把整篇糊成一个字符串色块好看得多
            if c == "\n" { return j }
            j += 1
        }
        return count
    }

    // MARK: 数字

    private func numberEnd(at start: Int) -> Int? {
        var j = start

        // `.5` 这种以小数点开头的写法；单独一个 `.`（成员访问 `foo.bar`）不是数字
        if scalars[j] == "." {
            guard j + 1 < count, isDigit(scalars[j + 1]) else { return nil }
            j += 1
        }

        guard isDigit(scalars[j]) else { return nil }

        // 进制前缀（0x1F / 0b1010 / 0o777）。
        // ⚠️ 精度取舍：不管哪个进制，后面一律按「十六进制字符集」放行，
        //    所以 `0b12` 这种非法写法也会被整个吃掉 —— 反正本来就是错的（编译不过）
        if scalars[j] == "0", j + 1 < count, profile.radixPrefixes.contains(scalars[j + 1]) {
            j += 2
            while j < count, isDigit(scalars[j]) || isHexLetter(scalars[j]) || scalars[j] == "_" {
                j += 1
            }
            return j
        }

        while j < count, isDigit(scalars[j]) || scalars[j] == "_" { j += 1 }

        // 小数部分
        if j < count, scalars[j] == ".", j + 1 < count, isDigit(scalars[j + 1]) {
            j += 2
            while j < count, isDigit(scalars[j]) || scalars[j] == "_" { j += 1 }
        }

        // 科学计数法 `1e-8`
        if j < count, scalars[j] == "e" || scalars[j] == "E" {
            var k = j + 1
            if k < count, scalars[k] == "+" || scalars[k] == "-" { k += 1 }
            if k < count, isDigit(scalars[k]) {
                j = k
                while j < count, isDigit(scalars[j]) || scalars[j] == "_" { j += 1 }
            }
        }

        // Python 的虚数后缀 `3j`
        if j < count, scalars[j] == "j" || scalars[j] == "J" { j += 1 }

        return j
    }

    // MARK: 标识符

    /// 扫一个标识符，顺带处理 Python 那种 `f"..."` 字符串前缀。
    ///
    /// - returns: 结束下标 + 角色。**普通标识符的 role 是 nil**（表示不用上色）
    private func identifierEnd(at start: Int) -> (end: Int, role: SyntaxRole?)? {
        guard isIdentifierStart(scalars[start]) else { return nil }

        var j = start + 1
        while j < count, isIdentifierChar(scalars[j]) { j += 1 }

        // `r"..."` / `f'...'` 这类前缀 + 字符串：前缀很短（1~2 个字母）且后面紧跟引号。
        // 注意 token 要从**前缀字母**起算，否则 `f` 会被当成普通标识符、"…" 单独成一段，颜色会断
        if profile.stringPrefixes.count > 0, j - start <= 2, isAllFrom(scalars[start..<j], allowed: profile.stringPrefixes),
           j < count, let end = stringEnd(at: j) {
            return (end, .string)
        }

        let word = Self.string(from: scalars[start..<j])
        if profile.keywords.contains(word) { return (j, .keyword) }
        if profile.literals.contains(word) { return (j, .number) }

        // 大写开头的当类型名 —— 三种语言里类名/结构体名都这么写，命中率够高
        if profile.treatsCapitalizedAsType, isUppercaseASCII(scalars[start]) {
            return (j, .type)
        }

        // 普通标识符：返回 nil role，不生成 token（省一次属性赋值）
        return (j, nil)
    }

    // MARK: 字符判定

    private func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 48 && scalar.value <= 57          // 0~9
    }

    private func isHexLetter(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 97 && scalar.value <= 102)       // a~f
            || (scalar.value >= 65 && scalar.value <= 70) // A~F
    }

    private func isUppercaseASCII(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 65 && scalar.value <= 90          // A~Z
    }

    private func isIdentifierStart(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value < 128 {
            switch value {
            case 65...90, 97...122: return true           // A~Z, a~z
            case 95, 36: return true                      // _, $（JS 变量常见）
            default: return false
            }
        }
        // 中文变量名之类也算标识符。`isAlphabetic` 有点贵，
        // 但只在真正出现非 ASCII 字符时才走到这里，绝大多数情况下碰不到
        return scalar.properties.isAlphabetic
    }

    private func isIdentifierChar(_ scalar: Unicode.Scalar) -> Bool {
        isDigit(scalar) || isIdentifierStart(scalar)
    }

    /// 这一段里的字符是不是全都在允许列表里（判字符串前缀用的）
    private func isAllFrom(_ scalars: ArraySlice<Unicode.Scalar>, allowed: [Unicode.Scalar]) -> Bool {
        for scalar in scalars where !allowed.contains(scalar) { return false }
        return true
    }

    /// `[Unicode.Scalar]` → String。只有查关键字表时才用得上（标识符才会走到这里）。
    private static func string(from slice: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: slice)
        return String(view)
    }
}
