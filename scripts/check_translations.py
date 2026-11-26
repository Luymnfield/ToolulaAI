#!/usr/bin/env python3
"""检查界面文字有没有翻译。

扫描 Sources/ 和 Widget/ 里会被本地化的中文文字:
  String(localized: "…")、Text("…")、Button/Label/Toggle/Picker/Section/Menu/TextField/... ("…")、
  .help("…")、LocalizedStringKey("…")、"…".loc / .locKey、带 LocalizedStringKey 参数的自定义函数的实参、
  以及 enum 里 case x = "中文" 的原始值 (多数会用 .locKey 显示)。
带插值的文字按 Swift 的规则换成 %@ / %lld / %lf 再到 Localization/translations.json 里找。

故意不翻译的 (只给 AI 看的工具输出等) 写在 Localization/untranslated_whitelist.txt。

用法:
  scripts/check_translations.py            列出缺少的翻译 (有缺失时退出码 1)
  scripts/check_translations.py --json     以 JSON 输出缺少的 key (给补翻译用)
  scripts/check_translations.py --warn     只警告, 退出码总是 0 (build_app.sh 用)
"""
import itertools
import json
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SRC_DIRS = [os.path.join(ROOT, "Sources", "ToolulaAI"), os.path.join(ROOT, "Widget")]
TABLE = json.load(open(os.path.join(ROOT, "Localization", "translations.json"), encoding="utf-8"))
WL_FILE = os.path.join(ROOT, "Localization", "untranslated_whitelist.txt")

CJK = re.compile(r"[㐀-鿿豈-﫿　-〿＀-￯]")
HAN = re.compile(r"[㐀-鿿]")

# 第一个参数是会被本地化的文字的调用
CALLS = ["Text", "Button", "Label", "Toggle", "Picker", "Section", "Menu", "TextField", "SecureField", "Stepper",
         "LabeledContent", "Link", "DisclosureGroup", "CommandMenu", "GroupBox", "ProgressView", "Window", "WindowGroup",
         "LocalizedStringKey", "NSLocalizedString", "String.LocalizationValue", "Slider", "ShareLink", "ControlGroup",
         "ContentUnavailableView", "Tab", "SettingsLink"]
MODIFIERS = ["help", "navigationTitle", "alert", "confirmationDialog", "accessibilityLabel", "accessibilityHint",
             "accessibilityValue", "searchable", "badge", "keyboardShortcut_never"]


def load_whitelist():
    keys, files = set(), set()
    if os.path.exists(WL_FILE):
        for line in open(WL_FILE, encoding="utf-8"):
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            if line.startswith("file:"):
                files.add(line[5:].strip())
            else:
                keys.add(line)
    return keys, files


def read_literal(s, i):
    """s[i] == '"'. 返回 (原文, 结束位置) — 原文里保留 \\(...) 插值"""
    assert s[i] == '"'
    if s.startswith('"""', i):
        return None, s.find('"""', i + 3) + 3
    j = i + 1
    out = []
    while j < len(s):
        c = s[j]
        if c == "\\":
            if s[j + 1] == "(":
                # 插值: 找匹配的括号
                depth, k = 0, j + 1
                while k < len(s):
                    if s[k] == "(":
                        depth += 1
                    elif s[k] == ")":
                        depth -= 1
                        if depth == 0:
                            break
                    elif s[k] == '"':
                        _, k = read_literal(s, k)
                        continue
                    k += 1
                out.append(s[j:k + 1])
                j = k + 1
                continue
            esc = {"n": "\n", "t": "\t", '"': '"', "\\": "\\", "'": "'"}.get(s[j + 1], s[j + 1])
            out.append(esc)
            j += 2
            continue
        if c == '"':
            return "".join(out), j + 1
        if c == "\n":
            return None, j
        out.append(c)
        j += 1
    return None, j


def interp_kind(expr):
    """猜插值的类型: 返回候选格式"""
    e = expr.strip()
    if re.match(r"^String\(", e) or e.startswith('"') or "String(format:" in e:
        return ["%@"]
    if re.search(r"\.count$|Int\(|\bcount\b|Index|index|\bi\b|\bn\b", e):
        return ["%lld", "%@"]
    if "format:" in e:
        return ["%@"]
    return ["%@", "%lld", "%lf"]


def split_interp(lit):
    """把 "a\\(x)b" 拆成 ["a", ("x",), "b"] (支持嵌套括号)"""
    out, buf, i = [], "", 0
    while i < len(lit):
        if lit.startswith("\\(", i):
            depth, k = 0, i + 1
            while k < len(lit):
                if lit[k] == "(":
                    depth += 1
                elif lit[k] == ")":
                    depth -= 1
                    if depth == 0:
                        break
                k += 1
            out.append(buf); buf = ""
            out.append((lit[i + 2:k],))
            i = k + 1
            continue
        buf += lit[i]
        i += 1
    out.append(buf)
    return out


def candidates(lit):
    slots = []
    for p in split_interp(lit):
        slots.append(interp_kind(p[0]) if isinstance(p, tuple) else [p])
    if sum(1 for x in slots if len(x) > 1) > 8:
        return ["".join(x[0] for x in slots)]
    return ["".join(c) for c in itertools.product(*slots)]


def localized_func_names(texts):
    """带 LocalizedStringKey 参数的自定义函数: 名字 -> 参数位置"""
    out = {}
    for s in texts:
        for m in re.finditer(r"func\s+(\w+)\s*\(([^)]*)\)", s):
            params = [p.strip() for p in m.group(2).split(",")]
            pos = [i for i, p in enumerate(params) if "LocalizedStringKey" in p or "LocalizationValue" in p]
            if pos:
                out[m.group(1)] = pos
    return out


def split_args(s, i):
    """s[i] == '(' -> 顶层参数的 (开始, 结束) 列表"""
    depth, start, args, j = 0, i + 1, [], i
    while j < len(s):
        c = s[j]
        if c == '"':
            _, j = read_literal(s, j)
            continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                args.append((start, j))
                return args
        elif c == "," and depth == 1:
            args.append((start, j))
            start = j + 1
        j += 1
    return args


def scan():
    wl_keys, wl_files = load_whitelist()
    files = []
    for d in SRC_DIRS:
        for f in sorted(os.listdir(d)):
            if f.endswith(".swift") and f not in wl_files:
                files.append(os.path.join(d, f))
    texts = {f: open(f, encoding="utf-8").read() for f in files}
    funcs = localized_func_names(texts.values())
    found = {}   # literal -> [位置]

    def add(lit, f, pos):
        if lit is None or not HAN.search(lit):
            return
        line = texts[f].count("\n", 0, pos) + 1
        found.setdefault(lit, []).append(f"{os.path.relpath(f, ROOT)}:{line}")

    call_re = re.compile(r"(?<![\w.])(" + "|".join(re.escape(c) for c in CALLS) + r")\s*\(")
    mod_re = re.compile(r"\.(" + "|".join(MODIFIERS) + r")\s*\(")
    for f, s in texts.items():
        # 注释去掉 (保持位置不变)
        s = re.sub(r"//[^\n]*", lambda m: " " * len(m.group(0)) if '"' not in m.group(0) else m.group(0), s)
        for m in itertools.chain(call_re.finditer(s), mod_re.finditer(s)):
            name = m.group(1)
            j = m.end()
            while j < len(s) and s[j] in " \n":
                j += 1
            if s.startswith("verbatim:", j):
                continue
            for lab in ("localized:", "title:", "label:", "text:"):
                if s.startswith(lab, j):
                    j += len(lab)
                    while s[j] == " ":
                        j += 1
            if j < len(s) and s[j] == '"':
                lit, _ = read_literal(s, j)
                add(lit, f, j)
                # Text("a") + Text("b") / Button("…") 之后的其他字面量由各自的调用处理
            if name in ("Text",) and s.startswith("(", m.end() - 1):
                pass
        # String(localized: "…")
        for m in re.finditer(r"String\(\s*localized:\s*\"", s):
            lit, _ = read_literal(s, m.end() - 1)
            add(lit, f, m.start())
        # "…".loc / .locKey
        for m in re.finditer(r"\"(?:[^\"\\\n]|\\.)*\"\.(loc|locKey)\b", s):
            lit, _ = read_literal(s, m.start())
            add(lit, f, m.start())
        # 返回 LocalizedStringKey 的计算属性/函数里 return 的文字
        for m in re.finditer(r"(?:->|:)\s*(?:LocalizedStringKey|String\.LocalizationValue)\s*\{", s):
            a = m.end() - 1
            depth, b = 0, a
            while b < len(s):
                if s[b] == "{": depth += 1
                elif s[b] == "}":
                    depth -= 1
                    if depth == 0: break
                elif s[b] == '"':
                    _, b = read_literal(s, b); continue
                b += 1
            body = s[a:b]
            for r in re.finditer(r"(?:return|:)\s*\"", body):
                lit, _ = read_literal(body, r.end() - 1)
                add(lit, f, a + r.start())
        # enum case x = "中文"
        for m in re.finditer(r"\bcase\s+\w+\s*=\s*\"", s):
            lit, _ = read_literal(s, m.end() - 1)
            add(lit, f, m.start())
        # 自定义函数的 LocalizedStringKey 参数
        for name, pos in funcs.items():
            for m in re.finditer(r"(?<![\w.])" + re.escape(name) + r"\s*\(", s):
                if s[max(0, m.start() - 5):m.start()].strip().endswith("func"):
                    continue
                args = split_args(s, m.end() - 1)
                for p in pos:
                    if p < len(args):
                        a, b = args[p]
                        seg = s[a:b]
                        k = seg.find('"')
                        if k >= 0 and seg[:k].strip() in ("",) or (k >= 0 and re.match(r"^\s*\w+:\s*$", seg[:k])):
                            lit, _ = read_literal(s, a + k)
                            add(lit, f, a + k)
    missing = {}
    for lit, where in found.items():
        if lit in wl_keys:
            continue
        cands = candidates(lit)
        if any(c in TABLE for c in cands) or lit in TABLE:
            continue
        if any(c in wl_keys for c in cands):
            continue
        missing[cands[0]] = where
    return found, missing


def main():
    found, missing = scan()
    if "--json" in sys.argv:
        json.dump({k: v for k, v in sorted(missing.items())}, sys.stdout, ensure_ascii=False, indent=1)
        print()
        return 0
    for k, where in sorted(missing.items(), key=lambda x: x[1][0]):
        print(f"{where[0]}: 缺少翻译: {k!r}" + (f" (另有 {len(where) - 1} 处)" if len(where) > 1 else ""))
    print(f"检查了 {len(found)} 条界面文字，缺少翻译 {len(missing)} 条", file=sys.stderr)
    if "--warn" in sys.argv:
        return 0
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
