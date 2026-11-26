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
cp Resources/toolula_comfy_launch.py "$APP/Contents/Resources/toolula_comfy_launch.py"
mkdir -p "$APP/Contents/Resources/AIPhotoEdit.lrplugin" && cp ../AIPhotoEdit.lrplugin/*.lua ../AIPhotoEdit.lrplugin/ai_edit.py ../AIPhotoEdit.lrplugin/desktop_process.py "$APP/Contents/Resources/AIPhotoEdit.lrplugin/"
# 翻译检查: 有没翻译的界面文字时给警告 (不中断编译)
MISSING=$(/usr/bin/python3 scripts/check_translations.py 2>&1 >/dev/null | grep -o '缺少翻译 [0-9]*' | grep -o '[0-9]*')
if [[ -n "$MISSING" && "$MISSING" != "0" ]]; then
  echo "⚠️  有 $MISSING 条界面文字缺少英文/德文翻译，运行 scripts/check_translations.py 查看"
fi
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
  <key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>zh-Hant</string><string>en</string><string>ja</string><string>ko</string><string>de</string><string>fr</string><string>es</string><string>pt-BR</string><string>pt</string><string>ru</string></array>
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
  </dict>
  <dict>
    <key>CFBundleTypeName</key><string>Toolula 对话</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Owner</string>
    <key>LSItemContentTypes</key><array><string>com.toolula.chat</string></array>
  </dict></array>
  <key>UTExportedTypeDeclarations</key><array><dict>
    <key>UTTypeIdentifier</key><string>com.toolula.chat</string>
    <key>UTTypeDescription</key><string>Toolula 对话</string>
    <key>UTTypeConformsTo</key><array><string>public.plain-text</string><string>public.utf8-plain-text</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>toolulachat</string></array></dict>
  </dict></array>
  <key>NSServices</key><array>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>用 Toolula 总结</string></dict>
      <key>NSMessage</key><string>summarizeFiles</string>
      <key>NSPortName</key><string>Toolula AI</string>
      <key>NSSendFileTypes</key><array><string>public.item</string></array>
      <key>NSRequiredContext</key><dict/>
      <key>NSIconName</key><string>NSActionTemplate</string>
    </dict>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>用 Toolula 修图</string></dict>
      <key>NSMessage</key><string>editPhotos</string>
      <key>NSPortName</key><string>Toolula AI</string>
      <key>NSSendFileTypes</key><array><string>public.image</string></array>
      <key>NSRequiredContext</key><dict/>
    </dict>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>用 Toolula 做成视频</string></dict>
      <key>NSMessage</key><string>videoFromImage</string>
      <key>NSPortName</key><string>Toolula AI</string>
      <key>NSSendFileTypes</key><array><string>public.image</string></array>
      <key>NSRequiredContext</key><dict/>
    </dict>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>问 Toolula</string></dict>
      <key>NSMessage</key><string>askAboutText</string>
      <key>NSPortName</key><string>Toolula AI</string>
      <key>NSSendTypes</key><array><string>public.utf8-plain-text</string><string>NSStringPboardType</string></array>
      <key>NSRequiredContext</key><dict/>
    </dict>
  </array>
</dict></plist>
PLIST
# 服务菜单 (访达右键) 在各语言里的名字
while IFS='|' read -r L S1 S2 S3 S4; do
  [[ -z "$L" ]] && continue
  mkdir -p "$APP/Contents/Resources/$L.lproj"
  printf '"用 Toolula 总结" = "%s";\n"用 Toolula 修图" = "%s";\n"用 Toolula 做成视频" = "%s";\n"问 Toolula" = "%s";\n' "$S1" "$S2" "$S3" "$S4" > "$APP/Contents/Resources/$L.lproj/ServicesMenu.strings"
done <<'SERVICES'
en|Summarize with Toolula|Edit with Toolula|Make a Video with Toolula|Ask Toolula
de|Mit Toolula zusammenfassen|Mit Toolula bearbeiten|Mit Toolula als Video|Toolula fragen
zh-Hant|用 Toolula 摘要|用 Toolula 修圖|用 Toolula 製作影片|問 Toolula
ja|Toolulaで要約|Toolulaで編集|Toolulaでビデオを作成|Toolulaに質問
ko|Toolula로 요약|Toolula로 편집|Toolula로 비디오 만들기|Toolula에게 묻기
fr|Résumer avec Toolula|Modifier avec Toolula|Créer une vidéo avec Toolula|Demander à Toolula
es|Resumir con Toolula|Editar con Toolula|Crear un video con Toolula|Preguntar a Toolula
pt-BR|Resumir com o Toolula|Editar com o Toolula|Criar vídeo com o Toolula|Perguntar ao Toolula
pt|Resumir com o Toolula|Editar com o Toolula|Criar vídeo com o Toolula|Perguntar ao Toolula
ru|Кратко с Toolula|Изменить в Toolula|Создать видео в Toolula|Спросить Toolula
SERVICES
# 快捷指令动作的元数据 (AppIntents): swift build 已经导出了编译器的常量信息 (.swiftconstvalues), 用它生成 Metadata.appintents
INT=.build/intents; mkdir -p $INT
SCRATCH=.build; (( SELFTEST )) && SCRATCH=.build-selftest
CV=$(find $SCRATCH -name 'ToolulaAI*.swiftconstvalues' -newer Sources/ToolulaAI/Intents.swift 2>/dev/null | head -1)
[[ -z "$CV" ]] && CV=$(find $SCRATCH -name 'ToolulaAI*.swiftconstvalues' 2>/dev/null | head -1)
if [[ -n "$CV" ]]; then
  ls "$PWD"/Sources/ToolulaAI/*.swift > $INT/src.txt
  echo "$PWD/$CV" > $INT/cv.txt
  xcrun appintentsmetadataprocessor --output "$APP/Contents/Resources" --toolchain-dir "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain" \
    --module-name ToolulaAI --sdk-root "$(xcrun --show-sdk-path)" --xcode-version "$(xcodebuild -version | tail -1 | awk '{print $3}')" --platform-family macOS \
    --deployment-target 14.0 --target-triple arm64-apple-macos14.0 --source-file-list $INT/src.txt --swift-const-vals-list $INT/cv.txt \
    --binary-file "$APP/Contents/MacOS/ToolulaAI" --no-app-shortcuts-localization --force > $INT/processor.log 2>&1 \
    && echo "快捷指令动作: $(ls "$APP/Contents/Resources/Metadata.appintents" | tr '\n' ' ')" \
    || { echo "⚠️  快捷指令元数据生成失败，见 $INT/processor.log"; tail -3 $INT/processor.log; }
else
  echo "⚠️  没找到编译器导出的常量信息，快捷指令动作不可用"
fi
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
  <key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>zh-Hant</string><string>en</string><string>ja</string><string>ko</string><string>de</string><string>fr</string><string>es</string><string>pt-BR</string><string>pt</string><string>ru</string></array>
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
