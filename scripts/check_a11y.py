#!/usr/bin/env python3
"""找出只有图标、没有 accessibilityLabel 的按钮 / 菜单 (粗略静态检查)。
用法: scripts/check_a11y.py  (有问题时退出码 1)"""
import re, sys, glob, os
root = os.path.join(os.path.dirname(__file__), '..', 'Sources', 'ToolulaAI')

def match_brace(s, i):
    depth = 0
    while i < len(s):
        c = s[i]
        if c == '{': depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0: return i
        elif c == '"':
            j = i + 1
            while j < len(s) and s[j] != '"':
                if s[j] == '\\': j += 1
                j += 1
            i = j
        i += 1
    return len(s) - 1

problems = []
for f in sorted(glob.glob(os.path.join(root, '*.swift'))):
    s = open(f, encoding='utf-8').read()
    for m in re.finditer(r'\b(Button|Menu)\s*(\(([^()]*)\))?\s*\{', s):
        if m.group(3) and m.group(3).strip().startswith(('"', 'String', 'Text', 'LocalizedStringKey')):
            continue  # Button("标题") { ... }
        if m.group(3) and 'role' not in m.group(3) and 'action' not in m.group(3):
            # Button(action: ...) 之类以外的带参数形式, 例如 Button(s.title) 也算有文字
            continue
        a = m.end() - 1
        b = match_brace(s, a)
        rest = s[b+1:b+400]
        lm = re.match(r'\s*label:\s*\{', rest)
        if not lm:
            continue  # 尾随闭包形式: Button(...) { } 已排除; 这里是 Button { action } 无 label? 跳过
        la = b + 1 + lm.end() - 1
        lb = match_brace(s, la)
        label = s[la+1:lb]
        if re.search(r'\bText\(|\bLabel\(|Text\(verbatim', label):
            continue
        if 'Image' not in label:
            continue
        tail = s[lb+1:lb+600]
        # 只看紧跟着的修饰符 (到下一个空行/新语句为止)
        mods = []
        for line in tail.split('\n')[0:8]:
            t = line.strip()
            if t.startswith('.') or t.startswith('}') or t == '' and not mods:
                mods.append(t)
                continue
            if mods: break
            mods.append(t)
        mods = '\n'.join(mods)
        if 'accessibilityLabel' in mods:
            continue
        line = s[:m.start()].count('\n') + 1
        problems.append(f"{os.path.relpath(f, root)}:{line}: {label.strip()[:70]}")

for p in problems: print(p)
print(f"{len(problems)} 个只有图标、没有 accessibilityLabel 的按钮", file=sys.stderr)
sys.exit(1 if problems else 0)
