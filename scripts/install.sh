#!/bin/zsh
# 把 build/Leonix.app 安装到 /Applications 并重新注册
set -e
cd "$(dirname "$0")/.."
osascript -e 'quit app "Leonix"' 2>/dev/null || true
osascript -e 'quit app "Toolula AI"' 2>/dev/null || true   # 改名前的旧版
for i in {1..20}; do pgrep -f "/Applications/(Leonix|Toolula AI).app/Contents/MacOS/ToolulaAI" >/dev/null || break; sleep 0.5; done
rm -rf "/Applications/Leonix.app"
# 改名前的旧版 (Toolula AI.app) 放进废纸篓; 数据都在 ~/Toolula, 不受影响
[[ -d "/Applications/Toolula AI.app" ]] && /usr/bin/trash "/Applications/Toolula AI.app"
ditto "build/Leonix.app" "/Applications/Leonix.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/Leonix.app"
echo "installed /Applications/Leonix.app"
