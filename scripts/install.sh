#!/bin/zsh
# 把 build/Toolula AI.app 安装到 /Applications 并重新注册
set -e
cd "$(dirname "$0")/.."
osascript -e 'quit app "Toolula AI"' 2>/dev/null || true
for i in {1..20}; do pgrep -f "/Applications/Toolula AI.app/Contents/MacOS/ToolulaAI" >/dev/null || break; sleep 0.5; done
rm -rf "/Applications/Toolula AI.app"
ditto "build/Toolula AI.app" "/Applications/Toolula AI.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/Toolula AI.app"
echo "installed /Applications/Toolula AI.app"
