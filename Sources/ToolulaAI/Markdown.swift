import AppKit
import SwiftUI

// MARK: - 解析 (纯逻辑, 可单元测试)

enum MDAlign: Equatable { case leading, center, trailing }

struct MDListItem: Equatable {
    var ordered: Bool
    var number: Int
    var level: Int
    var checked: Bool?          // 任务列表 - [ ] / - [x]
    var text: String
}

indirect enum MDBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([MDListItem])
    case quote([MDBlock])
    case code(lang: String, text: String, closed: Bool)
    case table(header: [String], align: [MDAlign], rows: [[String]])
    case rule
    case math(String)
}

enum MarkdownParser {
    static func parse(_ text: String) -> [MDBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        return parse(lines: lines[...])
    }

    static func parse(lines: ArraySlice<String>) -> [MDBlock] {
        var out: [MDBlock] = []
        var para: [String] = []
        func flush() {
            let t = para.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(.paragraph(t)) }
            para = []
        }
        var i = lines.startIndex
        while i < lines.endIndex {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 代码块 ``` 或 ~~~
            if let fence = fenceMarker(trimmed) {
                flush()
                let lang = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces).lowercased()
                var body: [String] = []
                var j = i + 1
                var closed = false
                while j < lines.endIndex {
                    if lines[j].trimmingCharacters(in: .whitespaces).hasPrefix(fence) && lines[j].trimmingCharacters(in: .whitespaces).allSatisfy({ $0 == fence.first }) { closed = true; break }
                    body.append(lines[j]); j += 1
                }
                out.append(.code(lang: lang.split(separator: " ").first.map(String.init) ?? "", text: body.joined(separator: "\n"), closed: closed))
                i = closed ? j + 1 : j
                continue
            }
            // 块级公式 $$ ... $$ 或 \[ ... \]
            if trimmed.hasPrefix("$$") || trimmed.hasPrefix("\\[") {
                let close = trimmed.hasPrefix("$$") ? "$$" : "\\]"
                let rest = String(trimmed.dropFirst(2))
                if let r = rest.range(of: close) {       // 同一行写完
                    flush(); out.append(.math(String(rest[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)))
                    i += 1; continue
                }
                var body = rest.isEmpty ? [] : [rest]
                var j = i + 1
                while j < lines.endIndex, !lines[j].contains(close) { body.append(lines[j]); j += 1 }
                if j < lines.endIndex, let r = lines[j].range(of: close) {
                    let before = String(lines[j][..<r.lowerBound])
                    if !before.trimmingCharacters(in: .whitespaces).isEmpty { body.append(before) }
                }
                flush(); out.append(.math(body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
                i = min(j + 1, lines.endIndex)
                continue
            }
            if trimmed.isEmpty { flush(); i += 1; continue }
            // 标题
            if let h = heading(trimmed) { flush(); out.append(.heading(level: h.0, text: h.1)); i += 1; continue }
            // 分隔线
            if isRule(trimmed) { flush(); out.append(.rule); i += 1; continue }
            // 表格: 这一行有 |, 下一行是 |---|:--:| 这样的分隔行
            if trimmed.contains("|"), i + 1 < lines.endIndex, let align = delimiterRow(lines[i + 1]) {
                let header = cells(trimmed)
                if header.count == align.count || (header.count > 0 && align.count > 0) {
                    flush()
                    var rows: [[String]] = []
                    var j = i + 2
                    while j < lines.endIndex {
                        let t = lines[j].trimmingCharacters(in: .whitespaces)
                        guard !t.isEmpty, t.contains("|") else { break }
                        var r = cells(t)
                        if r.count < header.count { r += Array(repeating: "", count: header.count - r.count) }
                        rows.append(Array(r.prefix(header.count)))
                        j += 1
                    }
                    let a = (align + Array(repeating: MDAlign.leading, count: max(0, header.count - align.count))).prefix(header.count)
                    out.append(.table(header: header, align: Array(a), rows: rows))
                    i = j
                    continue
                }
            }
            // 引用
            if trimmed.hasPrefix(">") {
                flush()
                var inner: [String] = []
                var j = i
                while j < lines.endIndex {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    var s = t.dropFirst()
                    if s.hasPrefix(" ") { s = s.dropFirst() }
                    inner.append(String(s)); j += 1
                }
                out.append(.quote(parse(lines: inner[...])))
                i = j
                continue
            }
            // 列表
            if listItem(line) != nil {
                flush()
                var items: [MDListItem] = []
                var j = i
                while j < lines.endIndex {
                    let l = lines[j]
                    if let it = listItem(l) { items.append(it); j += 1; continue }
                    let t = l.trimmingCharacters(in: .whitespaces)
                    if t.isEmpty {
                        // 空行后面还是列表项就继续
                        if j + 1 < lines.endIndex, listItem(lines[j + 1]) != nil { j += 1; continue }
                        break
                    }
                    // 缩进的续行: 接到上一项
                    if l.hasPrefix("  ") || l.hasPrefix("\t"), !items.isEmpty {
                        items[items.count - 1].text += "\n" + t; j += 1; continue
                    }
                    break
                }
                out.append(.list(items))
                i = j
                continue
            }
            para.append(line)
            i += 1
        }
        flush()
        return out
    }

    static func fenceMarker(_ t: String) -> String? {
        if t.hasPrefix("```") { return String(t.prefix { $0 == "`" }) }
        if t.hasPrefix("~~~") { return String(t.prefix { $0 == "~" }) }
        return nil
    }

    static func heading(_ t: String) -> (Int, String)? {
        let hashes = t.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = t.dropFirst(hashes)
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        var s = rest.trimmingCharacters(in: .whitespaces)
        while s.hasSuffix("#") { s.removeLast() }
        return (hashes, s.trimmingCharacters(in: .whitespaces))
    }

    static func isRule(_ t: String) -> Bool {
        let s = t.replacingOccurrences(of: " ", with: "")
        guard s.count >= 3, let c = s.first, "-*_".contains(c) else { return false }
        return s.allSatisfy { $0 == c }
    }

    /// | :--- | :---: | ---: |  -> 对齐方式; 不是分隔行返回 nil
    static func delimiterRow(_ line: String) -> [MDAlign]? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.allSatisfy({ "|:- \t".contains($0) }) else { return nil }
        let cs = cells(t)
        guard !cs.isEmpty else { return nil }
        var out: [MDAlign] = []
        for c in cs {
            let x = c.trimmingCharacters(in: .whitespaces)
            guard x.contains("-") else { return nil }
            let l = x.hasPrefix(":"), r = x.hasSuffix(":")
            out.append(l && r ? .center : r ? .trailing : .leading)
        }
        return out
    }

    /// 拆表格的一行; 支持 \| 转义和 `代码里的 |`
    static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
        var out: [String] = []
        var cur = ""
        var inCode = false
        var prev: Character = " "
        for ch in t {
            if ch == "`" { inCode.toggle() }
            if ch == "|" && !inCode && prev != "\\" { out.append(cur); cur = ""; prev = ch; continue }
            if ch == "|" && prev == "\\" { cur.removeLast() }
            cur.append(ch); prev = ch
        }
        out.append(cur)
        return out.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func listItem(_ line: String) -> MDListItem? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let t = line.drop { $0 == " " || $0 == "\t" }
        var ordered = false
        var number = 0
        var rest: Substring
        if let c = t.first, "-*+".contains(c), t.dropFirst().first == " " {
            rest = t.dropFirst(2)
        } else {
            let digits = t.prefix { $0.isNumber }
            guard !digits.isEmpty, digits.count <= 9 else { return nil }
            let after = t.dropFirst(digits.count)
            guard let d = after.first, d == "." || d == ")", after.dropFirst().first == " " else { return nil }
            ordered = true
            number = Int(digits) ?? 1
            rest = after.dropFirst(2)
        }
        var checked: Bool?
        if !ordered {
            if rest.hasPrefix("[ ] ") { checked = false; rest = rest.dropFirst(4) }
            else if rest.lowercased().hasPrefix("[x] ") { checked = true; rest = rest.dropFirst(4) }
        }
        return MDListItem(ordered: ordered, number: number, level: indent / 2, checked: checked,
                          text: String(rest).trimmingCharacters(in: .whitespaces))
    }
}

// MARK: - 公式: 常见 LaTeX 换成 Unicode, 至少能看清

enum MathText {
    static let symbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε", "zeta": "ζ", "eta": "η",
        "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π",
        "rho": "ρ", "sigma": "σ", "tau": "τ", "upsilon": "υ", "phi": "φ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        "times": "×", "cdot": "·", "div": "÷", "pm": "±", "mp": "∓", "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠",
        "approx": "≈", "equiv": "≡", "sim": "∼", "propto": "∝", "infty": "∞", "sum": "∑", "prod": "∏", "int": "∫", "oint": "∮",
        "partial": "∂", "nabla": "∇", "to": "→", "rightarrow": "→", "leftarrow": "←", "Rightarrow": "⇒", "Leftarrow": "⇐",
        "leftrightarrow": "↔", "Leftrightarrow": "⇔", "mapsto": "↦", "in": "∈", "notin": "∉", "subset": "⊂", "subseteq": "⊆",
        "supset": "⊃", "cup": "∪", "cap": "∩", "emptyset": "∅", "forall": "∀", "exists": "∃", "neg": "¬", "land": "∧", "lor": "∨",
        "ldots": "…", "cdots": "⋯", "dots": "…", "circ": "∘", "degree": "°", "angle": "∠", "perp": "⊥", "parallel": "∥",
        "quad": "  ", "qquad": "    ", ",": " ", ";": " ", ":": " ", "!": "", " ": " ", "{": "{", "}": "}", "%": "%", "$": "$",
        "lim": "lim", "log": "log", "ln": "ln", "sin": "sin", "cos": "cos", "tan": "tan", "exp": "exp", "max": "max", "min": "min",
        "left": "", "right": "", "big": "", "Big": "", "displaystyle": "", "langle": "⟨", "rangle": "⟩", "lfloor": "⌊", "rfloor": "⌋",
        "lceil": "⌈", "rceil": "⌉", "hbar": "ℏ", "ell": "ℓ", "Re": "ℜ", "Im": "ℑ", "aleph": "ℵ", "star": "⋆", "ast": "∗",
    ]
    static let sup: [Character: Character] = ["0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
                                               "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ", "x": "ˣ", "T": "ᵀ", "k": "ᵏ", "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "m": "ᵐ", "t": "ᵗ"]
    static let sub: [Character: Character] = ["0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
                                               "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎", "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "n": "ₙ", "m": "ₘ", "x": "ₓ", "a": "ₐ", "e": "ₑ", "o": "ₒ", "t": "ₜ"]

    static func render(_ latex: String) -> String {
        var s = Array(latex)
        var i = 0
        return convert(&s, &i, stopAt: nil)
    }

    /// 读一个参数: {…} 或单个字符/命令
    private static func argument(_ s: inout [Character], _ i: inout Int) -> String {
        while i < s.count, s[i] == " " { i += 1 }
        guard i < s.count else { return "" }
        if s[i] == "{" { i += 1; return convert(&s, &i, stopAt: "}") }
        if s[i] == "\\" { return command(&s, &i) }
        defer { i += 1 }
        return String(s[i])
    }

    private static func command(_ s: inout [Character], _ i: inout Int) -> String {
        i += 1   // 跳过 \
        guard i < s.count else { return "\\" }
        var name = ""
        if s[i].isLetter { while i < s.count, s[i].isLetter { name.append(s[i]); i += 1 } } else { name = String(s[i]); i += 1 }
        switch name {
        case "frac", "dfrac", "tfrac":
            let a = argument(&s, &i), b = argument(&s, &i)
            return "\(wrap(a))/\(wrap(b))"
        case "sqrt":
            var n = ""
            if i < s.count, s[i] == "[" { i += 1; while i < s.count, s[i] != "]" { n.append(s[i]); i += 1 }; i += 1 }
            let a = argument(&s, &i)
            return (n.isEmpty ? "" : String(n.compactMap { sup[$0] })) + "√" + wrap(a)
        case "text", "mathrm", "mathbf", "mathit", "mathsf", "mathtt", "operatorname", "textbf", "textit", "mathbb", "mathcal", "boldsymbol":
            let a = argument(&s, &i)
            if name == "mathbb" { return a.map { bb[$0].map(String.init) ?? String($0) }.joined() }
            return a
        case "vec": return argument(&s, &i) + "⃗"
        case "hat": return argument(&s, &i) + "̂"
        case "bar", "overline": return argument(&s, &i) + "̄"
        case "dot": return argument(&s, &i) + "̇"
        case "begin", "end": _ = argument(&s, &i); return ""
        case "\\": return "\n"
        default: return symbols[name] ?? "\\" + name
        }
    }

    static let bb: [Character: Character] = ["R": "ℝ", "N": "ℕ", "Z": "ℤ", "Q": "ℚ", "C": "ℂ", "P": "ℙ"]

    private static func wrap(_ a: String) -> String {
        a.count <= 1 || a.allSatisfy({ $0.isNumber || $0.isLetter }) ? a : "(\(a))"
    }

    private static func script(_ a: String, _ table: [Character: Character], _ mark: String) -> String {
        let mapped = a.compactMap { table[$0] }
        return mapped.count == a.count && !a.isEmpty ? String(mapped) : "\(mark)\(wrap(a))"
    }

    private static func convert(_ s: inout [Character], _ i: inout Int, stopAt: Character?) -> String {
        var out = ""
        while i < s.count {
            let c = s[i]
            if let stopAt, c == stopAt { i += 1; return out }
            switch c {
            case "\\": out += command(&s, &i)
            case "^": i += 1; out += script(argument(&s, &i), sup, "^")
            case "_": i += 1; out += script(argument(&s, &i), sub, "_")
            case "{": i += 1; out += convert(&s, &i, stopAt: "}")
            case "&": i += 1; out += "  "
            default: out.append(c); i += 1
            }
        }
        return out
    }

    /// 行内公式: \( … \) 和 $…$ (像价格 "$5 和 $10" 的不当成公式)
    static func inline(_ text: String) -> String {
        guard text.contains("$") || text.contains("\\(") else { return text }
        var t = text
        // \( ... \)
        while let a = t.range(of: "\\("), let b = t.range(of: "\\)", range: a.upperBound..<t.endIndex) {
            t.replaceSubrange(a.lowerBound..<b.upperBound, with: "`" + render(String(t[a.upperBound..<b.lowerBound])) + "`")
        }
        guard t.contains("$") else { return t }
        var out = ""
        var rest = Substring(t)
        while let a = rest.firstIndex(of: "$") {
            let afterA = rest.index(after: a)
            // 跳过 `代码` 里的
            let before = rest[..<a]
            if before.filter({ $0 == "`" }).count % 2 == 1, let tick = rest[a...].firstIndex(of: "`") {
                out += rest[...tick]; rest = rest[rest.index(after: tick)...]; continue
            }
            guard afterA < rest.endIndex, let b = rest[afterA...].firstIndex(of: "$") else { break }
            let inner = rest[afterA..<b]
            let afterB = rest.index(after: b)
            let looksMath = !inner.isEmpty && inner.first != " " && inner.last != " " && !inner.contains("\n")
                && !(afterB < rest.endIndex && rest[afterB].isNumber)
                && !(inner.first!.isNumber && inner.allSatisfy { $0.isNumber || $0 == "." || $0 == "," })
            if looksMath {
                out += before + "`" + render(String(inner)) + "`"
                rest = rest[afterB...]
            } else {
                out += rest[...a]
                rest = rest[afterA...]
            }
        }
        return out + rest
    }
}

// MARK: - 代码高亮 (轻量, 按语言的关键字 + 字符串 + 注释 + 数字)

enum SyntaxHighlighter {
    enum Token: Equatable { case keyword, string, comment, number, type, key, plain }

    static let keywords: [String: Set<String>] = [
        "swift": ["func", "let", "var", "if", "else", "guard", "return", "for", "in", "while", "struct", "class", "enum", "protocol", "extension",
                  "import", "switch", "case", "default", "break", "continue", "private", "public", "internal", "fileprivate", "static", "self",
                  "Self", "init", "deinit", "throws", "throw", "try", "catch", "do", "async", "await", "some", "any", "nil", "true", "false",
                  "where", "as", "is", "inout", "mutating", "override", "final", "lazy", "weak", "unowned", "defer", "repeat", "typealias", "actor", "nonisolated", "@MainActor"],
        "python": ["def", "class", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "return", "import", "from", "as", "with",
                   "try", "except", "finally", "raise", "pass", "break", "continue", "lambda", "yield", "None", "True", "False", "is",
                   "global", "nonlocal", "async", "await", "del", "assert", "self", "print"],
        "js": ["function", "const", "let", "var", "if", "else", "for", "while", "return", "class", "extends", "new", "this", "import",
               "export", "from", "default", "async", "await", "try", "catch", "finally", "throw", "typeof", "instanceof", "null",
               "undefined", "true", "false", "switch", "case", "break", "continue", "of", "in", "interface", "type", "enum", "implements",
               "public", "private", "protected", "readonly", "as", "yield", "delete", "void"],
        "shell": ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "in", "function", "return", "export",
                  "local", "echo", "cd", "sudo", "set", "unset", "source", "exit", "brew", "git", "ls", "cp", "mv", "rm", "mkdir", "cat",
                  "grep", "find", "curl", "pip", "python3", "npm", "swift", "open", "chmod", "defaults"],
        "json": ["true", "false", "null"],
        "c": ["int", "char", "float", "double", "void", "if", "else", "for", "while", "return", "struct", "typedef", "const", "static",
              "include", "define", "unsigned", "long", "short", "switch", "case", "break", "continue", "sizeof", "NULL", "class",
              "public", "private", "namespace", "template", "auto", "nullptr", "true", "false", "new", "delete", "fn", "let", "mut", "impl",
              "use", "pub", "match", "func", "package", "go", "defer", "type", "interface", "map", "range", "var"],
        "sql": ["select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table", "drop", "alter",
                "join", "left", "right", "inner", "outer", "on", "group", "by", "order", "having", "limit", "and", "or", "not", "null",
                "as", "distinct", "count", "primary", "key", "index"],
    ]

    static func family(_ lang: String) -> String {
        switch lang.lowercased() {
        case "swift": return "swift"
        case "py", "python", "python3": return "python"
        case "js", "javascript", "ts", "typescript", "jsx", "tsx", "node", "mjs": return "js"
        case "sh", "bash", "zsh", "shell", "console", "terminal", "fish": return "shell"
        case "json", "jsonc", "json5": return "json"
        case "c", "cpp", "c++", "h", "hpp", "objc", "objective-c", "java", "kotlin", "rust", "rs", "go", "golang", "cs", "csharp": return "c"
        case "sql": return "sql"
        default: return ""
        }
    }

    /// 返回 (范围, 类型) 列表, 只标非普通的部分
    static func tokens(_ code: String, lang: String) -> [(Range<String.Index>, Token)] {
        let fam = family(lang)
        guard !fam.isEmpty else { return [] }
        let kws = keywords[fam] ?? []
        let lineComment: [String] = fam == "python" || fam == "shell" ? ["#"] : fam == "sql" ? ["--"] : fam == "json" ? [] : ["//"]
        let blockComment = fam == "swift" || fam == "js" || fam == "c" || fam == "sql"
        var out: [(Range<String.Index>, Token)] = []
        var i = code.startIndex
        let end = code.endIndex
        func peek(_ s: String) -> Bool { code[i...].hasPrefix(s) }
        while i < end {
            let c = code[i]
            if let lc = lineComment.first(where: { peek($0) }), !(fam == "shell" && lc == "#" && i > code.startIndex && !code[code.index(before: i)].isWhitespace) {
                let e = code[i...].firstIndex(of: "\n") ?? end
                out.append((i..<e, .comment)); i = e; continue
            }
            if blockComment && peek("/*") {
                let e = code.range(of: "*/", range: code.index(i, offsetBy: 2)..<end)?.upperBound ?? end
                out.append((i..<e, .comment)); i = e; continue
            }
            if fam == "python" && (peek("\"\"\"") || peek("'''")) {
                let q = String(code[i..<code.index(i, offsetBy: 3)])
                let e = code.range(of: q, range: code.index(i, offsetBy: 3)..<end)?.upperBound ?? end
                out.append((i..<e, .string)); i = e; continue
            }
            if c == "\"" || c == "'" || (c == "`" && fam == "js") {
                var j = code.index(after: i)
                while j < end, code[j] != c, !(code[j] == "\n" && c != "`") {
                    if code[j] == "\\" { j = code.index(after: j); if j == end { break } }
                    j = code.index(after: j)
                }
                let e = j < end && code[j] == c ? code.index(after: j) : j
                // JSON 里后面跟冒号的是键
                var k = e
                while k < end, code[k] == " " { k = code.index(after: k) }
                let isKey = fam == "json" && k < end && code[k] == ":"
                out.append((i..<e, isKey ? .key : .string)); i = e; continue
            }
            if c.isNumber, i == code.startIndex || !(code[code.index(before: i)].isLetter || code[code.index(before: i)] == "_") {
                var j = i
                while j < end, code[j].isHexDigit || code[j] == "." || code[j] == "x" || code[j] == "_" { j = code.index(after: j) }
                out.append((i..<j, .number)); i = j; continue
            }
            if c.isLetter || c == "_" || c == "@" || (c == "$" && fam == "shell") {
                var j = code.index(after: i)
                while j < end, code[j].isLetter || code[j].isNumber || code[j] == "_" || (c == "$" && code[j] == "{") { j = code.index(after: j) }
                let w = String(code[i..<j])
                if c == "$" { out.append((i..<j, .type)) }
                else if kws.contains(fam == "sql" ? w.lowercased() : w) { out.append((i..<j, .keyword)) }
                else if w.first!.isUppercase && fam != "shell" && fam != "sql" { out.append((i..<j, .type)) }
                i = j; continue
            }
            i = code.index(after: i)
        }
        return out
    }

    static func color(_ t: Token) -> NSColor {
        switch t {
        case .keyword: return .systemPink
        case .string: return .systemRed
        case .comment: return .systemGray
        case .number: return .systemBlue
        case .type: return .systemTeal
        case .key: return .systemPurple
        case .plain: return .labelColor
        }
    }

    nonisolated(unsafe) static let cache: NSCache<NSString, NSAttributedStringBox> = { let c = NSCache<NSString, NSAttributedStringBox>(); c.countLimit = 200; return c }()

    static func highlight(_ code: String, lang: String) -> AttributedString {
        let key = "\(lang)\u{0}\(code)" as NSString
        if let a = cache.object(forKey: key) { return a.value }
        var a = AttributedString(code)
        for (r, t) in tokens(code, lang: lang) {
            guard let lo = AttributedString.Index(r.lowerBound, within: a), let hi = AttributedString.Index(r.upperBound, within: a) else { continue }
            a[lo..<hi].foregroundColor = Color(nsColor: color(t))
            if t == .comment { a[lo..<hi].font = .system(.callout, design: .monospaced).italic() }
        }
        cache.setObject(NSAttributedStringBox(a), forKey: key)
        return a
    }
}

final class NSAttributedStringBox { let value: AttributedString; init(_ v: AttributedString) { value = v } }

// MARK: - 显示

/// Markdown: 标题、列表、引用、分隔线、表格、代码块 (高亮 + 复制)、公式。
/// 同一段文字只解析一次 (cache); 流式输出时每次只多解析一遍新文字, 代码高亮按代码块单独缓存。
struct MarkdownText: View {
    let text: String

    final class Parsed { let blocks: [MDBlock]; init(_ b: [MDBlock]) { blocks = b } }
    nonisolated(unsafe) static let cache: NSCache<NSString, Parsed> = { let c = NSCache<NSString, Parsed>(); c.countLimit = 400; return c }()
    nonisolated(unsafe) static let inlineCache: NSCache<NSString, NSAttributedStringBox> = { let c = NSCache<NSString, NSAttributedStringBox>(); c.countLimit = 2000; return c }()

    var parsed: Parsed {
        if let p = Self.cache.object(forKey: text as NSString) { return p }
        let p = Parsed(MarkdownParser.parse(text))
        Self.cache.setObject(p, forKey: text as NSString)
        return p
    }

    var body: some View {
        MDBlocksView(blocks: parsed.blocks)
    }

    /// 行内格式 (粗体、斜体、`代码`、链接、行内公式)
    static func inline(_ s: String) -> AttributedString {
        if let a = inlineCache.object(forKey: s as NSString) { return a.value }
        let t = MathText.inline(s)
        let a = (try? AttributedString(markdown: t, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(t)
        inlineCache.setObject(NSAttributedStringBox(a), forKey: s as NSString)
        return a
    }
}

struct MDBlocksView: View {
    let blocks: [MDBlock]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in MDBlockView(block: b) }
        }
    }
}

struct MDBlockView: View {
    let block: MDBlock

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(MarkdownText.inline(text))
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : level == 3 ? .headline : .subheadline.bold())
                .padding(.top, level <= 2 ? 6 : 2)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(MarkdownText.inline(text)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Group {
                            if let c = it.checked {
                                Image(systemName: c ? "checkmark.square.fill" : "square").foregroundStyle(c ? Color.toolula : .secondary)
                                    .accessibilityLabel(c ? Text("已完成") : Text("未完成"))
                            } else if it.ordered {
                                Text("\(it.number).").monospacedDigit()
                            } else {
                                Text(it.level == 0 ? "•" : it.level == 1 ? "◦" : "▪")
                            }
                        }
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 16, alignment: .trailing)
                        Text(MarkdownText.inline(it.text)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(it.level) * 18)
                }
            }
        case .quote(let inner):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(Color.toolula.opacity(0.6)).frame(width: 3)
                MDBlocksView(blocks: inner).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Divider().padding(.vertical, 4)
        case .code(let lang, let text, _):
            CodeBlockView(lang: lang, code: text)
        case .table(let header, let align, let rows):
            MDTableView(header: header, align: align, rows: rows)
        case .math(let tex):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(MathText.render(tex))
                    .font(.system(.title3, design: .serif).italic())
                    .textSelection(.enabled)
                    .padding(.vertical, 6).padding(.horizontal, 12)
            }
            .frame(maxWidth: .infinity)
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel(Text("公式：\(tex)"))
        }
    }
}

struct CodeBlockView: View {
    let lang: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(lang.isEmpty ? String(localized: "代码") : lang).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? String(localized: "已复制") : String(localized: "复制"), systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("复制代码"))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.primary.opacity(0.05))
            ScrollView(.horizontal) {
                Text(SyntaxHighlighter.highlight(code, lang: lang))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(Color.black.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
    }
}

struct MDTableView: View {
    let header: [String]
    let align: [MDAlign]
    let rows: [[String]]

    func alignment(_ i: Int) -> Alignment {
        switch align.indices.contains(i) ? align[i] : .leading {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(header.indices, id: \.self) { i in
                        cell(header[i], i).font(.body.bold()).background(Color.primary.opacity(0.06))
                    }
                }
                ForEach(rows.indices, id: \.self) { r in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(header.indices, id: \.self) { i in
                            cell(rows[r].indices.contains(i) ? rows[r][i] : "", i)
                                .background(r % 2 == 1 ? Color.primary.opacity(0.025) : .clear)
                        }
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    func cell(_ s: String, _ i: Int) -> some View {
        Text(MarkdownText.inline(s))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: 40, maxWidth: 360, alignment: alignment(i))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .overlay(alignment: .trailing) { if i < header.count - 1 { Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1) } }
    }
}
