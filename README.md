# 知川助手（Zhichuan Assistant）

[![Android CI](https://github.com/giangnam728828-rgb/zichuan-assistant/actions/workflows/android.yml/badge.svg)](https://github.com/giangnam728828-rgb/zichuan-assistant/actions/workflows/android.yml)

仓库：<https://github.com/giangnam728828-rgb/zichuan-assistant>（private）  
下载：<https://github.com/giangnam728828-rgb/zichuan-assistant/releases>

> **这是一个真正的独立原生 Android 应用**，不是 WebView 套壳。  
> 原生 Flutter UI + Kotlin Android 桥，内置 Ubuntu 24.04 PRoot 运行时，支持写代码、跑构建、交付到手机、操作手机四件事。

## 技术栈

- **界面**：Flutter 原生 UI（`app/`）+ Kotlin Android 桥
- **运行时**：Ubuntu 24.04 PRoot（arm64-v8a），包含 Node.js 24、pnpm 11、Go、Rust、Python、GCC/C++ 等工具链
- **包名**：`app.zichuan.assistant`
- **minSdk**：26 | **targetSdk**：28
- **协议**：AGPL-3.0（见 `LICENSE`）

## 固定签名（重要）

本仓库使用固定的 release keystore：`keystore/zichuan-release.jks`（别名 `zichuan`，RSA 2048，有效期 10000 天）。

```
证书 SHA-256: 05:D1:26:5D:87:0C:5B:72:E5:3C:8A:74:5D:BE:8F:E1:2E:DB:79:1E:A1:7F:7B:DA:F4:02:34:90:4C:4D:50:57
证书 SHA-1  : 63:10:A4:48:38:D0:36:48:39:B3:D9:5D:E2:7E:4F:3F:1C:71:EE:53
有效期至    : 2054-04-07
```

只要用这把 key 签名，**新版本可以直接覆盖安装，不需要先卸载旧版本**。

验证签名一致性：
```bash
apksigner verify --print-certs dist/zichuan-assistant-*.apk | grep SHA-256
```

## 本地构建

### 前置条件

- Android SDK（含 build-tools 35.0.0）
- JDK 21
- `curl`、`zstd`（运行时组装需要）

### 构建步骤

```bash
# 1. 组装运行时（首次或更新 toolchain 时）
cd /root/dsh-go-upstream
bash runtime/build-runtime.sh arm64-v8a

# 2. 构建 APK（在私有仓库根目录）
cd /root/zichuan-android/repo
bash build-apk.sh

# 产物：dist/zichuan-assistant-<VERSION_NAME>.apk
```

环境变量签名（密码不落盘）：
```bash
KEYSTORE_PASSWORD=xxx KEY_PASSWORD=xxx bash build-apk.sh
```

## 真机安装

```bash
adb install dist/zichuan-assistant-*.apk
```

> ⚠️ 某些设备可能被策略拦截（`[POLICY_BLOCKED]`），需手动完成安装。

## 功能特性

- **聊天界面**：原生 Flutter 聊天窗口，支持多会话、多宿主
- **代码工作区**：内置终端、文件编辑、子代理并行
- **构建工作区**：一键运行 `pnpm run build`、`pnpm test`
- **手机操控**：读屏、点按、输入、导航、分享等原生能力
- **插件生态**：支持 dsh-go 插件系统
- **运行时环境**：完整的 Ubuntu 24.04 PRoot，预装主流开发工具

## 文档

- [`docs/architecture.md`](docs/architecture.md) - 架构说明
- [`docs/release.md`](docs/release.md) - 发布流程
- [`docs/plugins/`](docs/plugins/) - 插件开发指南
- [`ASSETS.md`](ASSETS.md) - 素材与许可说明
- [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) - 第三方许可声明

## 协议声明

本应用基于 [DSH Go](https://github.com/deepseek-ai/dsh-go) 衍生，整体采用 **AGPL-3.0** 协议。

品牌美术「知川 river mark」为操作者自有，程序化生成于 `app/tool/make_river_sprites.py`，不附带上游 DSH Go 的鲸鱼/桌宠素材。

---

> 最后更新：2026-11-20
> 版本：2.0.0+1
