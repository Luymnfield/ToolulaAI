#!/usr/bin/env python3
"""把翻译表生成为 App 里各语言的 Localizable.strings.

用法: python3 make_strings.py <App 的 Resources 目录>
key 就是界面里的简体中文原文; 简体中文版直接显示 key, 所以 zh-Hans 只需要一个空表.
- translations.json: {中文: [English, Deutsch]}
- <语言>.json (zh-Hant / ja / ko / fr / es / pt / ru): {中文: 译文}
某种语言缺某条时用英文顶上 (不会显示成中文).
"""
import json
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
res = sys.argv[1]
table = json.load(open(os.path.join(here, "translations.json"), encoding="utf-8"))

# 语言文件 -> 写到哪些 .lproj (葡萄牙语: 巴西 pt-BR, 葡萄牙 pt-PT 会回退到 pt)
EXTRA = {"zh-Hant": ["zh-Hant"], "ja": ["ja"], "ko": ["ko"], "fr": ["fr"], "es": ["es"], "pt": ["pt-BR", "pt"], "ru": ["ru"]}


def esc(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def write(lproj, mapping):
    d = os.path.join(res, lproj + ".lproj")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "Localizable.strings"), "w", encoding="utf-8") as f:
        for k in sorted(mapping):
            f.write('"%s" = "%s";\n' % (esc(k), esc(mapping[k])))


en = {k: v[0] for k, v in table.items()}
write("en", en)
write("de", {k: v[1] for k, v in table.items()})
done = ["en", "de", "zh-Hans"]
for code, lprojs in EXTRA.items():
    p = os.path.join(here, code + ".json")
    if not os.path.exists(p):
        continue
    tr = json.load(open(p, encoding="utf-8"))
    merged = {k: tr.get(k) or en[k] for k in table}
    for l in lprojs:
        write(l, merged)
        done.append(l)

zh = os.path.join(res, "zh-Hans.lproj")
os.makedirs(zh, exist_ok=True)
with open(os.path.join(zh, "Localizable.strings"), "w", encoding="utf-8") as f:
    f.write("/* 中文: 直接使用源代码里的原文 */\n")
print("strings: %d keys -> %s" % (len(table), ", ".join(done)))
