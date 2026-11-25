#!/usr/bin/env python3
"""把 translations.json 生成为 App 里的 en.lproj / de.lproj / zh-Hans.lproj 语言文件.

用法: python3 make_strings.py <App 的 Resources 目录>
key 就是界面里的中文原文; 中文版直接显示 key, 所以 zh-Hans 只需要一个空表.
"""
import json
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
res = sys.argv[1]
table = json.load(open(os.path.join(here, "translations.json"), encoding="utf-8"))


def esc(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


for idx, lang in [(0, "en"), (1, "de")]:
    d = os.path.join(res, lang + ".lproj")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "Localizable.strings"), "w", encoding="utf-8") as f:
        for k in sorted(table):
            f.write('"%s" = "%s";\n' % (esc(k), esc(table[k][idx])))

zh = os.path.join(res, "zh-Hans.lproj")
os.makedirs(zh, exist_ok=True)
with open(os.path.join(zh, "Localizable.strings"), "w", encoding="utf-8") as f:
    f.write("/* 中文: 直接使用源代码里的原文 */\n")
print("strings: %d keys -> en, de, zh-Hans" % len(table))
