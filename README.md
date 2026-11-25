# Toolula AI

本地 AI 助手 (SwiftUI, macOS 14+, Apple 芯片)。

## 编译
```
./build_app.sh            # 正式版
./build_app.sh --selftest # 带自测开关的版本 (见 SelfTest.swift)
```

## 相关目录
- Lightroom 修图插件在相邻的 `../AIPhotoEdit.lrplugin`（单独的 git 仓库）。
  `build_app.sh` 会把其中的 `ai_edit.py`、`*.lua`、`desktop_process.py` 复制进 App。
- 用户数据: `~/Library/Application Support/ToolulaAI/`（不在仓库里）。
- 签名: 钥匙串里的本地证书「Toolula Local Signing」（不在仓库里）。
