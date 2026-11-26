# Toolula AI

本地 AI 助手 (SwiftUI, macOS 14+, Apple 芯片)。

## 编译和安装
```
./build_app.sh             # 正式版 -> build/Toolula AI.app (会检查翻译，缺了给警告)
./build_app.sh --selftest  # 自测版 -> build/selftest/Toolula AI.app (带 --snapshot 等开关，见 Sources/ToolulaAI/SelfTest.swift)
scripts/install.sh         # 把正式版装到 /Applications 并重新注册
```
签名用钥匙串里的本地证书「Toolula Local Signing」（不在仓库里），重新编译后权限不会丢。

## 测试
```
swift test                   # 单元测试 (Tests/ToolulaAITests)
scripts/regress.sh --quick   # 回归测试：各页面截图 + 不需要大模型的功能，和上一次截图做像素对比
scripts/regress.sh           # 完整回归 (另含对话+工具、压缩、预热、修图识别、快速提问)
scripts/check_translations.py   # 找没翻译的界面文字 (白名单: Localization/untranslated_whitelist.txt)
scripts/check_a11y.py           # 找只有图标、没有 accessibilityLabel 的按钮
```
回归结果在 `regress-results/<时间>/summary.md`（不提交）。

## 相关目录
- Lightroom 修图插件在相邻的 `../AIPhotoEdit.lrplugin`（单独的 git 仓库）。
  `build_app.sh` 会把其中的 `ai_edit.py`、`*.lua`、`desktop_process.py` 复制进 App。
- 用户数据: `~/Library/Application Support/ToolulaAI/`（不在仓库里）。
  对话在 `conversations/<uuid>.json`，备份在 `backups/`，Toolula 启动的后台进程记录在 `pids/`。
- 翻译: `Localization/translations.json`（key 是中文原文，值是 [英文, 德文]），由 `Localization/make_strings.py` 生成 lproj。
