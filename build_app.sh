#!/bin/zsh
# 编译并打包成 "Toolula AI.app"
#   ./build_app.sh             正式版 -> build/Toolula AI.app
#   ./build_app.sh --selftest  自测版 (带 --snapshot 等自测开关) -> build/selftest/Toolula AI.app
set -e
cd "$(dirname "$0")"
SELFTEST=0
[[ "$1" == "--selftest" ]] && SELFTEST=1
if (( SELFTEST )); then
  swift build -c release --scratch-path .build-selftest -Xswiftc -DTOOLULA_SELFTEST
  BIN=.build-selftest/release/ToolulaAI
  APP="build/selftest/Toolula AI.app"
else
  swift build -c release
  BIN=.build/release/ToolulaAI
  APP="build/Toolula AI.app"
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ToolulaAI"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp ../AIPhotoEdit.lrplugin/ai_edit.py "$APP/Contents/Resources/ai_edit.py"
mkdir -p "$APP/Contents/Resources/AIPhotoEdit.lrplugin" && cp ../AIPhotoEdit.lrplugin/*.lua ../AIPhotoEdit.lrplugin/ai_edit.py ../AIPhotoEdit.lrplugin/desktop_process.py "$APP/Contents/Resources/AIPhotoEdit.lrplugin/"
/usr/bin/python3 Localization/make_strings.py "$APP/Contents/Resources"
for f in "$APP"/Contents/Resources/*.lproj/Localizable.strings; do plutil -lint "$f" >/dev/null || { echo "bad strings: $f"; exit 1; }; done
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Toolula AI</string>
  <key>CFBundleDisplayName</key><string>Toolula AI</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>en</string><string>de</string></array>
  <key>CFBundleIdentifier</key><string>com.toolula.ai-photo-edit</string>
  <key>CFBundleExecutable</key><string>ToolulaAI</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>com.toolula.ai</string>
    <key>CFBundleURLSchemes</key><array><string>toolula</string></array>
  </dict></array>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>照片</string>
    <key>CFBundleTypeRole</key><string>Editor</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key><array>
      <string>public.image</string><string>public.camera-raw-image</string><string>public.folder</string>
    </array>
  </dict></array>
</dict></plist>
PLIST
SIGN_ID="-"
if security find-certificate -c "Toolula Local Signing" >/dev/null 2>&1; then SIGN_ID="Toolula Local Signing"; fi
if (( SELFTEST )); then
  # 自测版不带小组件 (避免和正式版的小组件重复注册)
  codesign --force -s "$SIGN_ID" "$APP"
  echo "signed with: $SIGN_ID"
  echo "built (selftest): $APP"
  exit 0
fi
# 桌面小组件 (WidgetKit 扩展): 单独编译, 放进 PlugIns, 必须开沙盒
WX="$APP/Contents/PlugIns/ToolulaWidget.appex"
mkdir -p "$WX/Contents/MacOS" "$WX/Contents/Resources" .build/widget
xcrun swiftc -sdk "$(xcrun --show-sdk-path)" -target arm64-apple-macos14.0 -O -application-extension -parse-as-library \
  -module-name ToolulaWidget Widget/ToolulaWidget.swift -Xlinker -e -Xlinker _NSExtensionMain -o .build/widget/ToolulaWidget
cp .build/widget/ToolulaWidget "$WX/Contents/MacOS/ToolulaWidget"
sips -Z 128 Resources/toolula_ai_icon.png --out "$WX/Contents/Resources/logo.png" >/dev/null
/usr/bin/python3 Localization/make_strings.py "$WX/Contents/Resources" >/dev/null
cat > "$WX/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Toolula AI</string>
  <key>CFBundleDisplayName</key><string>Toolula AI</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>en</string><string>de</string></array>
  <key>CFBundleIdentifier</key><string>com.toolula.ai-photo-edit.widget</string>
  <key>CFBundleExecutable</key><string>ToolulaWidget</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSExtension</key><dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string>
  </dict>
</dict></plist>
PLIST
cat > .build/widget/widget.entitlements <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>
ENT
# 有本地签名证书就用它：签名要求固定不变，更新后不用重新授权「辅助功能」等权限 (SIGN_ID 在上面检测)
codesign --force -s "$SIGN_ID" --entitlements .build/widget/widget.entitlements "$WX"
codesign --force -s "$SIGN_ID" "$APP"
echo "signed with: $SIGN_ID"
echo "built: $APP"
