# 子川助手 · Android

[![Android CI](https://github.com/giangnam728828-rgb/zichuan-assistant/actions/workflows/android.yml/badge.svg)](https://github.com/giangnam728828-rgb/zichuan-assistant/actions/workflows/android.yml)

仓库：<https://github.com/giangnam728828-rgb/zichuan-assistant>（private）
下载：<https://github.com/giangnam728828-rgb/zichuan-assistant/releases>

> 私有仓库的 Release 资产需要登录后才能下载；本机 `dist/` 里也有同样的 APK。

这是一个 **DeepSeek Harness Web UI 的 Android WebView 壳**，不是独立模型或完整原生助手：实际对话界面由本机 DSH Web 提供。之前的构建默认打开了不带认证的地址，因此会显示 DSH 的认证提示页；1.0.4 起改为首次启动连接页，并能识别认证提示、引导粘贴完整链接。

引擎仍由 DSH App / `proot` 环境运行。APK 负责呈现 Web UI、保存连接地址、提供连接配置和断连说明；不会启动或代管模型，也不会记录 URL/token 到日志。

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

1. 先让 DSH App / `dsh web` 在本机运行。
2. 安装 `dist/zichuan-assistant-<version>.apk`；首次打开会显示连接设置页，不再把裸 `127.0.0.1:3080/` 当作已连接。
3. 在 DSH-Go「设置 → 本机引擎 → 日志」里找到 `dsh web:`，复制后面的**完整 URL**（通常含 `?token=…`）；也可从运行 DSH 的终端复制。回到连接设置页点「从剪贴板粘贴」→「保存并连接」。只填 `http://127.0.0.1:3080/` 会触发 DSH 认证提示。
4. 若已存地址失效，App 会识别认证页并重新显示连接设置。连接成功后可用右上角「连接设置」更新地址；链接只保存在本机应用私有设置中。

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

## 发布流水线

`main` 上改动 `app/**` 或 `build-apk.sh` 会触发 **Android CI**：装 build-tools 34 → `build-apk.sh` 构建 → **校验签名指纹必须等于上面那个 SHA-256**（不等就 fail）→ 上传 artifact → 发 Release（tag `v<版本>`，只带本次构建的 APK）。

CI 每次成功发布时生成递增 `versionCode`，签名者 SHA-256 固定为上面的证书指纹；可直接覆盖安装。1.0.4 修复连接配置与认证提示页处理。

## 已知限制

- 只能连**本机 / 局域网**地址；不内置隧道，不代管 token。
- WebView 不支持 DSH 桌面端的 Electron 专属能力（如窗口级快捷键）。
- 未在真机安装验证（本次构建环境没有可用的 adb 设备）；`aapt dump badging`、`apksigner verify` 与 dex 结构均已核对。