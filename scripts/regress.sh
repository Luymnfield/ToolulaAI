#!/bin/zsh
# 自动回归测试: 用自测构建 (./build_app.sh --selftest) 跑一遍主要功能, 截图并和上一次对比。
#
#   scripts/regress.sh            完整 (含需要大模型的: 对话+工具、压缩、预热、修图识别)
#   scripts/regress.sh --quick    跳过需要大模型的测试
#   选项: --no-build  不重新编译    --model <id>  对话测试用的模型 (默认 mlx:qwen3.8-27b)
#         --threshold <百分比>  截图变化超过多少算明显 (默认 1.0)
#
# 结果在 regress-results/<时间>/: 每个测试的截图 (.png) 和日志 (.txt)、差异图 (*.diff.png)、summary.md
# 退出码: 0 = 全部通过 (截图变化只提示, 不算失败)
set -u
setopt null_glob
cd "$(dirname "$0")/.."
ROOT=$PWD
QUICK=0; BUILD=1; MODEL="mlx:qwen3.8-27b"; THRESH=1.0
while (( $# )); do
  case $1 in
    --quick) QUICK=1 ;;
    --no-build) BUILD=0 ;;
    --model) MODEL=$2; shift ;;
    --threshold) THRESH=$2; shift ;;
    *) echo "未知参数 $1"; exit 2 ;;
  esac
  shift
done

APP="$ROOT/build/selftest/Toolula AI.app"
DOMAIN=com.toolula.ai-photo-edit
DATA="$HOME/Toolula"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$ROOT/regress-results/$STAMP"
PREVS=("$ROOT"/regress-results/2*(/N))
PREV=${PREVS[-1]:-}
mkdir -p "$OUT"
SUMMARY="$OUT/summary.md"
FAIL=0
typeset -a ROWS

if (( BUILD )); then
  echo "▸ 编译自测版…"
  ./build_app.sh --selftest > "$OUT/build.log" 2>&1 || { echo "编译失败，见 $OUT/build.log"; exit 1; }
fi
[[ -d "$APP" ]] || { echo "找不到 $APP，先运行 ./build_app.sh --selftest"; exit 1; }
mkdir -p .build/tools
if [[ ! -x .build/tools/imgdiff || scripts/imgdiff.swift -nt .build/tools/imgdiff ]]; then
  xcrun swiftc -O scripts/imgdiff.swift -o .build/tools/imgdiff 2>>"$OUT/build.log" || echo "（imgdiff 编译失败，跳过截图对比）"
fi

# 测试前记下用户的设置和数据, 测完恢复 / 核对
OLD_CHAT=$(defaults read $DOMAIN chatModel 2>/dev/null || echo "")
OLD_PHOTO=$(defaults read $DOMAIN photoModel 2>/dev/null || echo "")
OLD_SECTION=$(defaults read $DOMAIN section 2>/dev/null || echo "")
CONV_BEFORE=$(ls "$DATA/Chats" 2>/dev/null | grep -c '\.json$' || true)
LMS=~/.lmstudio/bin/lms
lms_loaded() { [[ -x $LMS ]] && $LMS ps --json 2>/dev/null | /usr/bin/python3 -c 'import json,sys
try: print("\n".join(sorted(m.get("identifier") or m.get("modelKey") or "" for m in json.load(sys.stdin))))
except Exception: pass'; }
LOADED_BEFORE=$(lms_loaded)
restore() {
  [[ -n "$OLD_CHAT" ]] && defaults write $DOMAIN chatModel "$OLD_CHAT"
  [[ -n "$OLD_PHOTO" ]] && defaults write $DOMAIN photoModel "$OLD_PHOTO"
  [[ -n "$OLD_SECTION" ]] && defaults write $DOMAIN section "$OLD_SECTION"
  defaults write $DOMAIN settingsTab -int 0
  # 测试中新加载到 LM Studio 的模型卸载掉
  if [[ -x $LMS ]]; then
    for m in $(lms_loaded); do
      [[ -n "$m" ]] || continue
      echo "$LOADED_BEFORE" | grep -qxF "$m" || { echo "卸载测试中加载的模型: $m"; $LMS unload "$m" >/dev/null 2>&1; }
    done
  fi
}
trap restore EXIT

# run <名字> <超时秒> <检查: 日志里必须出现的正则, 可空> [自测参数...]
run() {
  local name=$1 timeout=$2 expect=$3; shift 3
  local png="$OUT/$name.png" txt="$OUT/$name.txt" t0=$SECONDS st="" note=""
  printf "▸ %-22s" "$name"
  timeout $timeout open -n -W -a "$APP" --args --snapshot "$png" "$@" -AppleLanguages '(zh-Hans)' -ApplePersistenceIgnoreState YES
  local rc=$?
  pkill -f "selftest/Toolula AI.app/Contents/MacOS/ToolulaAI --snapshot $png" 2>/dev/null
  if (( rc == 124 )); then st="❌"; note="超时 (${timeout}s)"
  elif [[ ! -s "$txt" ]]; then st="❌"; note="没有日志"
  elif [[ -n "$expect" ]] && ! grep -Eq -- "$expect" "$txt"; then st="❌"; note="日志里没有: $expect"
  else st="✅"; fi
  [[ $st == "❌" ]] && FAIL=$((FAIL+1))
  # 和上一次的截图对比
  local diffs=""
  for f in "$OUT"/$name.png "$OUT"/$name.*.png; do
    [[ -f $f && $f != *.diff.png ]] || continue
    local base=${f:t}
    if [[ -n "$PREV" && -f "$PREV/$base" && -x .build/tools/imgdiff ]]; then
      local r=$(.build/tools/imgdiff "$PREV/$base" "$f" "$OUT/${base%.png}.diff.png")
      local pct=${r%% *}
      if (( $(echo "$pct > $THRESH" | bc -l) )); then diffs+="⚠️ ${base} 变化 ${pct}% "; else rm -f "$OUT/${base%.png}.diff.png"; fi
    fi
  done
  local secs=$((SECONDS - t0))
  echo " $st ${secs}s $note $diffs"
  ROWS+=("| $name | $st | ${secs}s | $note | $diffs |")
}

echo "结果目录: $OUT"
[[ -n "$PREV" ]] && echo "对比上一次: $PREV"

# 1. 各页面截图
for s in home chat photo image video automation skills memory models; do
  run "page-$s" 60 "machine:" --section $s
done
# 2. 不需要大模型的功能
run markdown 60 "markdown blocks: .*table" --section chat --markdown-demo
run settings 90 "Settings_window" --section chat --settings-shots
run palette 60 "keys: section=video" --section home --palette-query "前往 视频" --keys "cmd+k|return"
run a11y 60 "ax: buttons=[0-9]+ unnamed=0" --section chat --ax-dump
run hotkey 60 "hotkey check" --section chat --hotkey-check
DIAG=$(mktemp -d)
run diagnostics 90 "diagnostics: .*zip" --section home --diagnostics "$DIAG"
rm -rf "$DIAG"
run route-test 60 "route 你好" --section chat --route-test
run lut-test 60 "lut identity entries=35937" --section photo --lut-test

# 德语界面: 截图后用 Vision 识别, 列出还显示中文的地方 (对话标题等用户数据本来就是中文, 需要人工看一眼)
if [[ -x .build/tools/ocr_cjk || -f scripts/ocr_cjk.swift ]]; then
  [[ -x .build/tools/ocr_cjk && ! scripts/ocr_cjk.swift -nt .build/tools/ocr_cjk ]] || xcrun swiftc -O scripts/ocr_cjk.swift -o .build/tools/ocr_cjk 2>>"$OUT/build.log"
  mkdir -p "$OUT/de"
  printf "▸ %-22s" "german-ui"
  for s in home photo models; do
    timeout 60 open -n -W -a "$APP" --args --snapshot "$OUT/de/$s.png" --section $s -AppleLanguages '(de)' -ApplePersistenceIgnoreState YES
  done
  timeout 90 open -n -W -a "$APP" --args --snapshot "$OUT/de/settings.png" --section home --settings-shots -AppleLanguages '(de)' -ApplePersistenceIgnoreState YES
  .build/tools/ocr_cjk "$OUT"/de/*.png > "$OUT/de/cjk.txt" 2>/dev/null
  n=$(grep -c . "$OUT/de/cjk.txt")
  echo " ℹ️  德语截图里识别到 $n 处中文 (见 de/cjk.txt; 图标偶尔会被误认成汉字)"
  ROWS+=("| german-ui | ℹ️ | | 德语截图里识别到 $n 处中文，见 de/cjk.txt | |")
fi

# 3. 需要大模型的
if (( ! QUICK )); then
  run chat-tools 400 "\[tool\]|\[assistant\] .+" --section chat --chat-model "$MODEL" --chat "用 list_directory 工具看一下 /Applications 文件夹里有几个项目，只回答数字。" --auto-approve
  run compress 600 "compress ok=true" --section chat --chat-model "$MODEL" --compress-test
  run warm 400 "warm-test: Optional" --section chat --chat-model "$MODEL" --warm-test
  IMG=$(ls /System/Library/Desktop\ Pictures/*.heic 2>/dev/null | head -1)
  [[ -z "$IMG" ]] && IMG="$ROOT/Resources/toolula_ai_icon.png"
  run recognize 600 "recognize: .*s" --section photo --recognize "$IMG"
  run quick-ask 400 "quick: .*answer=.+" --section chat --chat-model "$MODEL" --quick "用一句话解释什么是推测解码。" --quick-continue
fi

# 用户数据核对: 测试前后对话数量一致
CONV_AFTER=$(ls "$DATA/Chats" 2>/dev/null | grep -c '\.json$' || true)
if [[ "$CONV_BEFORE" != "$CONV_AFTER" ]]; then
  FAIL=$((FAIL+1)); ROWS+=("| 用户数据 | ❌ | | 对话文件数 $CONV_BEFORE -> $CONV_AFTER | |")
else
  ROWS+=("| 用户数据 | ✅ | | 对话文件数不变 ($CONV_AFTER) | |")
fi

{
  echo "# Toolula 回归测试 $STAMP"
  echo
  echo "- 模式: $([[ $QUICK == 1 ]] && echo quick || echo 完整)  对比: $([[ -n "$PREV" ]] && echo ${PREV:t} || echo 无)  截图变化阈值: ${THRESH}%"
  echo "- 失败: $FAIL"
  echo
  echo "| 测试 | 结果 | 用时 | 说明 | 截图变化 |"
  echo "|---|---|---|---|---|"
  for r in "${ROWS[@]}"; do echo "$r"; done
} > "$SUMMARY"
echo
echo "汇总: $SUMMARY  (失败 $FAIL)"
exit $(( FAIL > 0 ))
