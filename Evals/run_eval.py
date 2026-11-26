#!/usr/bin/env python3
"""跑 Toolula 智能体评测, 算成功率, 和上一次比较。

    ./build_app.sh --selftest            # 先编自测版
    python3 Evals/run_eval.py            # 全部题目 (用设置里的对话模型 + 快慢分流)
    python3 Evals/run_eval.py --only fix_bug,edit_big_file --label 试试新提示词
    python3 Evals/run_eval.py --cat 代码 --model qwen/qwen3.8-27b

每道题在 /private/tmp/toolula-eval/<这次>/<题目> 里做 (对话的当前工作目录)。
结果在 Evals/results/<时间>-<标签>/: results.json、report.md; 没通过的题保留沙盒文件夹方便查看。
"""
import argparse
import glob
import json
import os
import shutil
import subprocess
import sys
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
from tasks import TASKS  # noqa: E402

DOMAIN = "com.toolula.ai-photo-edit"


def defaults_read(key):
    p = subprocess.run(["defaults", "read", DOMAIN, key], capture_output=True, text=True)
    return p.stdout.strip() if p.returncode == 0 else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", help="只跑这些题 (逗号分隔)")
    ap.add_argument("--cat", help="只跑这个分类")
    ap.add_argument("--model", help="主模型 (默认用设置里的对话模型)")
    ap.add_argument("--label", default="", help="这次的说明, 会写进文件夹名和报告")
    ap.add_argument("--app", default=os.path.join(ROOT, "build/selftest/Toolula AI.app"))
    ap.add_argument("--repeat", type=int, default=1, help="每道题跑几次 (本地模型每次结果会有差别)")
    args = ap.parse_args()

    tasks = TASKS
    if args.only:
        ids = args.only.split(",")
        tasks = [t for t in TASKS if t["id"] in ids]
    if args.cat:
        tasks = [t for t in tasks if t["cat"] == args.cat]
    if not tasks:
        sys.exit("没有要跑的题")
    if not os.path.exists(args.app):
        sys.exit(f"找不到自测版 App: {args.app}  (先运行 ./build_app.sh --selftest)")

    stamp = time.strftime("%Y%m%d-%H%M%S")
    name = stamp + (f"-{args.label}" if args.label else "")
    out_dir = os.path.join(HERE, "results", name)
    box_root = os.path.join("/private/tmp/toolula-eval", stamp)
    os.makedirs(out_dir, exist_ok=True)
    saved_section = defaults_read("section")
    model = args.model or defaults_read("chatModel") or ""
    print(f"评测 {len(tasks)} 题 × {args.repeat}，主模型 {model}，快模型 {defaults_read('fastModel') or '-'}")
    print(f"结果: {out_dir}")

    results = []
    t_all = time.time()
    try:
        for t in tasks:
            for rep in range(args.repeat):
                tid = t["id"] + (f"#{rep + 1}" if args.repeat > 1 else "")
                box = os.path.join(box_root, tid.replace("#", "-"))
                os.makedirs(box)
                row = dict(id=tid, cat=t["cat"], passed=False, note="", seconds=0, tool_calls=0, tool_errors=0, timed_out=False, denied=0)
                print(f"▸ {tid:<22}", end="", flush=True)
                try:
                    t["setup"](box)
                    spec = os.path.join(out_dir, f"{tid}.spec.json")
                    res_path = os.path.join(out_dir, f"{tid}.json")
                    with open(spec, "w", encoding="utf-8") as f:
                        json.dump(dict(prompt=t["prompt"], workdir=box, timeout=t["timeout"], out=res_path, model=args.model or ""), f, ensure_ascii=False)
                    try:
                        subprocess.run(["open", "-n", "-W", "-a", args.app, "--args", "--snapshot", os.path.join(out_dir, f"{tid}.png"),
                                        "--section", "chat", "--eval-task", spec, "-AppleLanguages", "(zh-Hans)", "-ApplePersistenceIgnoreState", "YES"],
                                       timeout=t["timeout"] + 120)
                    except subprocess.TimeoutExpired:
                        subprocess.run(["pkill", "-f", "build/selftest/Toolula AI.app"])
                    os.remove(spec)
                    if not os.path.exists(res_path):
                        raise RuntimeError("App 没有写出结果")
                    with open(res_path, encoding="utf-8") as f:
                        r = json.load(f)
                    row.update(seconds=round(r["seconds"], 1), tool_calls=r["tool_calls"], tool_errors=r["tool_errors"],
                               timed_out=r["timed_out"], denied=len(r["denied"]), models=r.get("models", []))
                    ok, note = t["check"](box, r)
                    row.update(passed=bool(ok), note=str(note))
                    if r.get("error"):
                        row["note"] += f" [模型出错: {r['error'][:80]}]"
                except Exception as e:
                    row["note"] = f"评测出错: {e}"
                    traceback.print_exc()
                print(("✅" if row["passed"] else "❌") + f" {row['seconds']:>6}s  工具 {row['tool_calls']:>2} 次  出错 {row['tool_errors']}  {row['note'][:70]}")
                if row["passed"]:
                    shutil.rmtree(box, ignore_errors=True)
                results.append(row)
    finally:
        if saved_section:
            subprocess.run(["defaults", "write", DOMAIN, "section", saved_section])

    total = time.time() - t_all
    with open(os.path.join(out_dir, "results.json"), "w", encoding="utf-8") as f:
        json.dump(dict(label=args.label, model=model, fast=defaults_read("fastModel"), seconds=total, results=results), f, ensure_ascii=False, indent=1)
    report = make_report(results, args.label, model, total, previous(out_dir))
    with open(os.path.join(out_dir, "report.md"), "w", encoding="utf-8") as f:
        f.write(report)
    print("\n" + report)
    if os.path.isdir(box_root) and not os.listdir(box_root):
        os.rmdir(box_root)


def previous(cur):
    runs = sorted(d for d in glob.glob(os.path.join(HERE, "results", "*")) if d != cur and os.path.exists(os.path.join(d, "results.json")))
    if not runs:
        return None
    with open(os.path.join(runs[-1], "results.json"), encoding="utf-8") as f:
        p = json.load(f)
    p["name"] = os.path.basename(runs[-1])
    return p


def make_report(results, label, model, total, prev):
    n = len(results)
    ok = sum(r["passed"] for r in results)
    lines = [f"# 评测结果 {label}".rstrip(), "", f"- 主模型：{model}", f"- 通过：**{ok}/{n}（{ok * 100 // max(n, 1)}%）**",
             f"- 总用时：{total / 60:.1f} 分钟；平均每题 {sum(r['seconds'] for r in results) / max(n, 1):.0f} 秒",
             f"- 工具调用 {sum(r['tool_calls'] for r in results)} 次，其中出错 {sum(r['tool_errors'] for r in results)} 次；超时 {sum(r['timed_out'] for r in results)} 题"]
    prev_map = {}
    if prev:
        prev_map = {r["id"]: r for r in prev["results"]}
        same = [r for r in results if r["id"] in prev_map]
        if same:
            p_ok = sum(prev_map[r["id"]]["passed"] for r in same)
            c_ok = sum(r["passed"] for r in same)
            lines.append(f"- 和上一次（{prev['name']}）比：同样的 {len(same)} 题，{p_ok} → {c_ok}")
    lines += ["", "| 分类 | 通过 |", "|---|---|"]
    for c in dict.fromkeys(r["cat"] for r in results):
        rs = [r for r in results if r["cat"] == c]
        lines.append(f"| {c} | {sum(r['passed'] for r in rs)}/{len(rs)} |")
    lines += ["", "| 题目 | 结果 | 用时 | 工具 | 出错 | 说明 |", "|---|---|---|---|---|---|"]
    for r in results:
        mark = "✅" if r["passed"] else "❌"
        if r["id"] in prev_map and prev_map[r["id"]]["passed"] != r["passed"]:
            mark += " ⬆️" if r["passed"] else " ⬇️"
        note = r["note"].replace("|", "/").replace("\n", " ")[:90]
        lines.append(f"| {r['id']} | {mark} | {r['seconds']}s | {r['tool_calls']} | {r['tool_errors']} | {note} |")
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    main()
