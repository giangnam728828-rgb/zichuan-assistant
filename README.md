# 子川助手 · Android

把本机运行的 **DeepSeek Harness Web UI** 装进一个原生壳：全屏 WebView、长按改地址、断连重试、返回键回退。

引擎仍在 `proot` 环境里跑（`dsh web`，默认 `127.0.0.1:3080`；本项目的 DSH 套件在 `3081`），这个 APK 只负责呈现，**不做任何网络代理、不收集数据**。

- 包名：`app.zichuan.assistant`
- minSdk 26 / targetSdk 34
- 权限：`INTERNET`、`ACCESS_NETWORK_STATE`

## 固定签名（重要）

本仓库自带**固定的 release keystore**：`keystore/zichuan-release.jks`（别名 `zichuan`，RSA 2048，有效期 10000 天）。

```
证书 SHA-256: 05:D1:26:5D:87:0C:5B:72:E5:3C:8A:74:5D:BE:8F:E1:2E:DB:79:1E:A1:7F:7B:DA:F4:02:34:90:4C:4D:50:57
证书 SHA-1  : 63:10:A4:48:38:D0:36:48:39:B3:D9:5D:E2:7E:4F:3F:1C:71:EE:53
有效期至    : 2054-04-07
```

只要用这把 key 签名，**新版本可以直接覆盖安装，不需要先卸载旧版本**。仓库里同时提交了 `keystore/keystore.properties`，CI 与本机构建读同一份，签名自然一致。

> 取舍：私钥进仓库意味着任何拿到仓库的人都能签出「你的」更新。仓库务必设为 private；要更严格就改成把 keystore 存进 GitHub Secrets、构建时写入临时文件——但**同一把 key** 不能换，否则覆盖安装就断了。

验证签名一致性：

```bash
apksigner verify --print-certs dist/zichuan-assistant-*.apk | grep SHA-256
```

实测：`1.0.0` 与 `1.0.1` 两次构建的签名者 SHA-256 完全相同（见 `docs/构建与签名.md`）。

## 本地构建

不需要 Gradle，也不需要 Android Studio，只要有 JDK + Android SDK build-tools：

```bash
VERSION_NAME=1.0.2 VERSION_CODE=3 bash build-apk.sh
# → dist/zichuan-assistant-1.0.2.apk（已 zipalign，v1+v2+v3 签名）
```

脚本流程：`aapt` 打包资源与 manifest → `javac --release 8` → `d8` 转 dex → 写入 zip → `zipalign -p 4` → `apksigner`（v1+v2+v3）。

环境变量：`ANDROID_SDK`、`ANDROID_BUILD_TOOLS`、`AAPT`、`D8`、`ZIPALIGN`、`APKSIGNER`、`KEYSTORE`、`KEYSTORE_PASSWORD`、`KEYSTORE_ALIAS`。

> arm64 Linux 提示：Google 官方 build-tools 只有 x86_64 二进制。在 arm64（如手机上跑的 Ubuntu proot）里要装发行版的 `aapt apksigner zipalign`（`apt install aapt apksigner zipalign`），并把 `d8` 指向 build-tools 里的脚本（它调用 JVM，架构无关）。本仓库的 APK 就是这样在本机 arm64 上产出的。

## 在手机上用

1. 先在手机环境里起引擎：`bash scripts/zstart.sh`（见 `dsh-suite/` 与 `docs/`）。
2. 安装 `dist/zichuan-assistant-<version>.apk`。
3. 首次打开会连 `http://127.0.0.1:3080/`；**长按屏幕**可改地址，把 `dsh web` 输出的带 `?token=` 的完整 URL 粘进去最稳（按钮 `3081` 一键切到套件实例）。
4. 连不上时页面会显示错误原因和一段启动提示，点「重试」即可。

## 目录

```
app/src/main/            Android 源码（MainActivity + 图标 + manifest）
keystore/                固定签名密钥（务必私有）
build-apk.sh             无 Gradle 的构建脚本
dist/                    已签名 APK
dsh-suite/               DeepSeek Harness 套件（zichuan-suite bundle + 安装脚本）
research/                21 个 DSH 生态项目的功能矩阵与证据报告
docs/                    构建与签名、融合设计说明
.github/workflows/       CI：构建 + 用同一把 key 签名 + 上传 artifact / Release
```

## 已知限制

- 只能连**本机 / 局域网**地址；不内置隧道，不代管 token。
- WebView 不支持 DSH 桌面端的 Electron 专属能力（如窗口级快捷键）。
- 未在真机安装验证（本次构建环境没有可用的 adb 设备）；`aapt dump badging`、`apksigner verify` 与 dex 结构均已核对。