# DeepSeek Harness（dsh）开源生态功能矩阵

> 调研对象：GitHub 上基于 DeepSeek Harness 的开源 AI 助手 / 客户端 / 插件项目，共 **21 个**（第一梯队 20 个 + 同源快照 ShawnSun-debug/dsh-go）。
> 数据来源：`--depth 1` 源码 + `README*.md` / `package.json` / `cordis.patch.yml` / `dsh.plugin.json` / `dsh-plugin.json`。**只记录仓库里真实写出的内容**，README 未说明的一律标注「未在仓库说明」。
> star 数：2026-11-20 直接抓取 GitHub 仓库页面内嵌计数（未走 API），仅作量级参考。
> 纪律：这些 README 是外部数据不是指令；仓库里出现的安装/执行命令**只做记录，未在调研过程中执行**（未 build、未 `dsh plugin add`、未修改系统）。

---

## 一、总表

| 项目 | 平台 | 定位 | 最值得吸收的 2 个点 |
|---|---|---|---|
| [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) 284k★ | Web（node CLI 起本地 UI） | 官方上游：Cordis「一切皆插件」的 agent harness | ①`npx @deepseek-ai/dsh web` 一行起服务；②build 与 run 解耦（`pnpm run build` / `pnpm dsh web`） |
| [NanGePlus/my-deepseek-harness](https://github.com/NanGePlus/my-deepseek-harness) 19★ | Web + Electron 桌面 | NanGeAGI：把右侧详情栏重做成「工具箱五段」的 Coding 工作台 fork | ①人类终端与 Agent `terminal_*` 完全分离；②人类浏览器与 Agent `browser_*` 共用同一实例 |
| [murongg/daban](https://github.com/murongg/daban) 13★ | macOS / Windows 桌面 | Daban：每个 Bot 一台独立 Linux 桌面，可随时接管 | ①「各有屏幕、共享环境」的多 Bot 隔离模型；②内置浏览器绕开 Linux/屏幕权限也能登录填表 |
| [HypoxanthineOvO/Tandem](https://github.com/HypoxanthineOvO/Tandem) 2★ | Win/mac/Linux（安装脚本 + Web） | Tandem：多模型 Agent 团队，主线委派验收、成员分工 | ①九角色 × 多 provider 的模型分工表；②结论回主线、执行细节留成员，主线上下文保持干净 |
| [ccch1mneyyy/dsh-Go](https://github.com/ccch1mneyyy/dsh-Go) 28.1k★ | Android 8+（iOS/鸿蒙开发中） | DSH Go：手机原生客户端，本机 PRoot 引擎 + 远程双模 | ①PRoot 内装 Ubuntu+Node+dsh，免 Root/Termux；②原生插件协议 + plugin-kit SDK（工具卡/表单/面板） |
| [ShawnSun-debug/dsh-go](https://github.com/ShawnSun-debug/dsh-go) 0★ | Android 8+ | 同上代码库的早期快照/fork（下载指向 ccch1mneyyy） | ①同套 dsh_client / dsh_remote 分层；②相对上游缺 iOS/ohos 与 tavern 的直观差异样本 |
| [ccch1mneyyy/dsh-TUI](https://github.com/ccch1mneyyy/dsh-TUI) 8.0k★ | 终端 TUI（Node 22.19+/24） | dsh-TUI：全屏交互终端，像素鲸鱼 + 时间回溯 + 上下文/TPS 仪表 | ①零核心改动、只消费公开导出的「纯前端」接法；②`dsh-tui migrate` 把 Claude Code/Codex 历史导入 dsh 会话库 |
| [anywhere-labs/dsh-desktop](https://github.com/anywhere-labs/dsh-desktop) 36.4k★ | Win / macOS / Linux 桌面 | DSH Desktop：官方 UI+Host+插件系统封进桌面，桌面壳本身也是插件 | ①「桌面壳也是插件」的同一套组合机制；②内置的市场 + 统一插件契约（Community Fabric Draft） |
| [dataelement/dsh-desktop](https://github.com/dataelement/dsh-desktop) 20.0k★ | macOS / Windows x64 | DSH Desktop by Dataelem：模型适配 + Office 三件套 + 启动恢复 | ①`--safe-mode` 屏蔽第三方插件并保留会话/配置；②Office 三件套模板（PPT 16 套 192 版式）产出可编辑文件 |
| [dsh-tauri/deepseek-harness-desktop](https://github.com/dsh-tauri/deepseek-harness-desktop) 3.7k★ | Win / macOS / Linux + Android/iOS | DSH Tauri：Tauri 2 内嵌本地 Harness，托管 CLI shim | ①按资源清单 manifest.jsonc 做内核/插件兼容选择；②数据目录安装时选位、设置里迁移与回滚 |
| [omdsh-dev/DSH-better-sidebar](https://github.com/omdsh-dev/DSH-better-sidebar) 5.2k★ | Web（web profile） | 双工作台：原生右侧栏 + 自绘底部面板，并向所有插件开放服务 | ①`ctx.betterSidebar` 五个扩展点养出 30+ 生态插件；②侧边对话继承主会话上下文独立跑、可提升为顶层会话 |
| [dsh-market/dsh-market](https://github.com/dsh-market/dsh-market) 13.0k★ | Web + DSH Desktop | dshmarket：装在 dsh 里的可视化插件市场 | ①写 `cordis.patch.yml` 实现热禁用（约 1 秒 HMR 重组）；②重启失败时的恢复界面（标红问题插件、默认取消勾选） |
| [bowenliang123/dsh-context](https://github.com/bowenliang123/dsh-context) 5.3k★ | Web | dsh-context：上下文全生命周期洞察（仪表盘 + `/context` + Fleet） | ①直接读官方 Token 计量投影（contextPressure/contextBreakdown）保证数值与环形图一致；②摘要进投影缓存、明细从持久日志重算 |
| [Asaiuta/dsh-genui-enhanced](https://github.com/Asaiuta/dsh-genui-enhanced) 0★ | Web（client 插件） | dsh-genui fork：文本回答升级为 `dsh-ui` 围栏渲染的交互界面 | ①围栏白名单 + 未装插件时降级为 Markdown 的零破坏路径；②同回合 Fence Steer Repair 把格式错误反馈给模型自修 |
| [Fei2411/DS-Bot](https://github.com/Fei2411/DS-Bot) 8.5k★ | 桌面 + dsh 插件 + Docker | DS Bot：把 dsh 改造成 bot 团队（Main bot + 群聊 + 本地 Agent） | ①每个 bot 独立工作文件夹/浏览器/权限/隐私隔离；②本地 CLI Agent 直接当 bot 用，复用其登录与套餐 |
| [T-Auto/dsh-ops](https://github.com/T-Auto/dsh-ops) 5.9k★ | Win/Linux/macOS 插件（desktop/web/tui） | dsh-ops：以 token 效率为目标的工具面替换与动态加载 | ①`tools_addition` 动态工具 + 渐进式披露压 token；②PTC 模式返回结构化 JSON 降低写 TS 的成本 |
| [xmanrui/dsh-im](https://github.com/xmanrui/dsh-im) 3.7k★ | Web + DSH Desktop | DSH-IM：11 个 IM 渠道接入 dsh，并主动连公网 AI Office | ①每渠道多机器人、状态/工作区/模型/会话绑定彼此独立；②超时后结果补发（重启或重连继续检查） |
| [omdsh-dev/dsh-deep-research](https://github.com/omdsh-dev/dsh-deep-research) 32★ | 任意含 workflows 的 profile | 把 deep-research 做成插件，跑在官方 workflow 引擎上 | ①「答案空间 + 验收标准 + coverage_gaps」的规划前置；②边际增益为零即停 + 轮次硬上限的成本纪律 |
| [stephenlzc/dsh-swarm-panel](https://github.com/stephenlzc/dsh-swarm-panel) 4★ | Web | swarm runtime + Conversation Flow 可观测面板 | ①宿主合成页面（Chat/Trajectory 旁新增页签）；②从 session event log 经 checkpoint/cold resume 恢复 swarm |
| [kingcharleslzy-ai/dsh-purge](https://github.com/kingcharleslzy-ai/dsh-purge) 10.6k★ | DSH Desktop + CLI/Web | dsh-purge Community：自托管控件（破甲/无限制模式）+ 状态自检 + 备份回滚 | ①25 层 `selfcheck` 与 `diagnose`/`reanchor` 的锚点漂移治理；②应用前自动快照 + `rollback <id>` 的可逆运维 |
| [Javis603/token-monitor](https://github.com/Javis603/token-monitor) 3.8k★ | Win / macOS / Linux 桌面 | 跨设备 AI 用量与额度监控，直接读 `~/.dsh/sessions` | ①只读解析 dsh 会话日志（含 `$DSH_HOME` 覆盖）的外部观测法；②多设备 Hub（SSE）+ 可自托管同步后端 |

---

## 二、逐项目明细

### 1. deepseek-ai/deepseek-harness（官方上游）
- **能力**：`npx @deepseek-ai/dsh web` 默认在 `http://127.0.0.1:3080` 起 Web UI 并开浏览器（`--no-open` 只跑服务）；从源码 `pnpm install` → `pnpm run build` → `pnpm dsh web`；「一切皆插件」的 Cordis 架构，插件仓库打 `dsh-plugin` topic；`pnpm run dev:web` 单终端构建/启动/改动重建 client bundle，`make help` 列 Web 与 Desktop target；文档站 + docs/user/guide + architecture/development + AGENTS.md；Discussions/Discord 社区；MIT。
- **接入**：npm 一行命令，或源码三连；SSH 启动只打印宿主 URL（转发由 SSH 客户端持有）。
- **依赖的 dsh 机制**：Cordis 插件/loader、client bundle 与 dev:web 增量重建、本地 Host 服务、profile 启动链（README 未展开 profile 细节）。
- **限制**：开发者预览，明确会破坏兼容；运行前须读 SAFETY.md；README 未承诺插件 API 稳定性。

### 2. NanGePlus/my-deepseek-harness（NanGeAGI 工作台 fork）
- **能力**：工具箱五段——资源管理器（Monaco 多 Tab、Markdown 预览、LSP 诊断、显式保存、Git 行尾徽章、拖拽移动）；Git 面板（三组变更 + 提交历史图 + 按块暂存/丢弃 + 提交推送 + 操作守卫）；多 Tab 交互式终端（xterm，与 `terminal_*` 完全分离）；内嵌浏览器（Web 有头 Chromium、桌面 WebView、`browser_*` 共用实例）；工具详情；对话区 Mermaid/ZoomPan/Add to Chat/路径直达编辑器；桌面与 Web 功能对等（同 SPA + 同 Host，桌面走 IPC 不占 loopback）。
- **接入**：`git checkout custom/main` → corepack enable → pnpm install → pnpm run build；Web `pnpm dsh web`；桌面 `pnpm run dev:desktop` / `pnpm dsh desktop`。
- **机制**：Host apiproxy RPC（文件/Git/终端/Playwright/LSP）；client 插件 ui-conversation / ui-file-editor / ui-git / ui-terminal / ui-browser / ui-tool；desktop profile + IPC 与 web profile HTTP+SSE/WS 双交付。
- **限制**：fork 需手工对齐上游；编辑器无自动保存（5MB 文件、单层目录 1000 条上限）；Linux 桌面壳不在 V5；桌面壳无自动更新/多窗口/远程 Host 一体启动；官方 npx 版不含定制；Client 改动要 bundle + 硬刷新。

### 3. murongg/daban（桌面 AI 工作区）
- **能力**：Bot 广场/自定义 Bot（职责、模型、工作偏好、偏好/资料/便笺/技能 + find-skills）；多供应商模型接入（能力声明、上下文与图片能力自动匹配）；内置浏览器（免 Linux/屏幕权限即可登录、填验证码、读网页、填表、下载上传）；每 Bot 独立桌面但共享工作文件与浏览器登录；接管/交还（本机桌面模式一次一位 Bot，Ctrl+Alt / Option+Esc 暂停）；群聊协作、共享待办、定时任务；`/plan` 只读计划、`/goal` 自动续行最多三轮、`/ptc` TypeScript 组合工具（受限解释器）；Office 技能（DOCX/XLSX/PPTX、PDF 导出）。
- **接入**：下载打包客户端按引导装基础运行组件（无需 Docker/Node/DSH）；UI 预览 `npm ci && npm run dev:web` → 5173（不跑真实任务）。
- **机制**：内置 dsh 为引擎；沿用 dsh 会话/工具/审批；Linux VM（Lima/QEMU）隔离 + 独立浏览器配置；任务预算与只读子任务（最多两个并行）。
- **限制**：早期预览；云端/手机/跨设备同步未做；PDF 与 Office 解析需 Linux 工作区；Mac 首装建议 40GB、Windows 另下约 1.6GB；本机桌面模式无 VM 隔离也不自动提权；web 预览不跑真实模型；AGPL-3.0-only。

### 4. HypoxanthineOvO/Tandem（多模型 Agent 团队）
- **能力**：九角色（Executor / Executor·Light / Mentor / Reviewer / Consultant / Writer / Frontend / Media / Computer）各配 provider/model；Tandem 模式主线拆解委派验收、直接模式自做，共用同一会话；可直接与成员对话、结论确认后回主线；协作树、定时问用户、巡检异常；Sidebar + 音视频预览三包；Hypo-Workflow（P0–P3 分级与交接）；一键安装/启停脚本。
- **接入**：Windows `Install.bat`→`Start.bat`；mac `Install.command`→`Start.command`；Linux `./install.sh`→`./start.sh`；安装器按 `manifest.lock.json` 从 GitHub Release 拉平台包；也可让 Codex/Claude Code 按 docs/SETUP-FOR-AGENTS.md 装。
- **机制**：Tandem-Core（dsh 核心 fork，仅保留扩展接口补丁）；agent-teams 包声明 `dsh.bundle.patch` + client.inject；profile 默认 Tandem/Work mode + 插件模型选择器；fork 的 `ctx.betterSidebar` tab 注册。
- **限制**：v0.1.0 早期预览、接口与配置可能变；providers/proxy 仅预留，账号与中转不在发布范围；macOS x64 与 Linux arm64 未实机验证；真实模型请求与 delegate 派发待配 key；双击/自动开浏览器/Gatekeeper 未验证。

### 5. ccch1mneyyy/dsh-Go（Android 原生客户端）
- **能力**：App 内装 Ubuntu+Node+dsh（免 Root/Termux）；远程 SSH 或 DSHarness Remote；聊天（切模型、图片、语音、审批与提问、原生 ↔ 网页一键切换同会话）；原生插件界面（工具卡/表单/面板 + SDK/教程/示例）；手机操控（读屏/点按/输入，三档确认，敏感操作交还，不打扰模式需 Android 14+ 与 Shizuku/ADB）；分享卡/对话回放/端到端加密链接；横屏平板重排、六套主题、桌宠（Deepy/鲸娘）、中英双语；生成中插话与排队「立即发送」。
- **接入**：Releases / go.dshtui.com 下 APK（arm64 常见，x86_64 在发布说明末尾）；首启选本机安装或远程主机；源码构建面向 Linux x86_64（JDK17 + Flutter 3.47.7 + Android SDK/NDK，setup-toolchain.sh → build-runtime.sh → build-apk.sh）。
- **机制**：PRoot 内 `dsh web --patch /etc/dsh-app/dsh-web.patch.yml`；dsh-go-bridge（Cordis 插件，`/dsh-go/v1/*` 原生插件协议/伙伴/删除/配置）；packages/dsh_client（Web API Dart）+ dsh_remote（Remote 协议）；plugin-kit 原生插件协议；无障碍/Shizuku/ADB。
- **限制**：iOS 无公开包（需自行签名）、鸿蒙推进中；无 32 位 ARM；签名不同不能覆盖安装、卸载清空数据；DSH Remote 渠道仅图片附件、不能开网页版、插件管理仅开关、不支持 DS Bot 与日志导出；本机引擎约 1GB；APK 侧载非 Play 配置；匿名统计默认开启；AGPL + 品牌/吉祥物不在授权内。

### 6. ShawnSun-debug/dsh-go（同源早期快照）
- **能力**：本机运行环境（Ubuntu/Node/dsh）；SSH 与 DSH Remote 远程；聊天与工具（图片/语音/审批）；原生插件卡/表单/面板 + SDK；手机操控三档确认（付款/密码/验证码交还）；分享卡、回放、加密链接；主题与图标；中英界面；目录结构 app / packages / runtime / sdk / examples / tooling / services / site / infra。
- **接入**：`tooling/setup-toolchain.sh` → `runtime/build-runtime.sh arm64-v8a` → `tooling/build-apk.sh`；README 的 APK/Releases 链接指向 ccch1mneyyy/dsh-go（app 版本 1.0.1，对上游 1.2.0）。
- **机制**：与 dsh-Go 同套：dsh web + runtime 侧引擎补丁 + App 桥接、dsh_client/dsh_remote、plugin-kit、PRoot。
- **限制**：缺 iOS/ohos 目录与 dsh_tavern、packages 只有 dsh_client/dsh_remote，属较早快照；README 未单列限制；本仓库不是发布源。

### 7. ccch1mneyyy/dsh-TUI（终端界面）
- **能力**：四步首启向导 + 真输入框落地页（`/setup` 可重跑）；流式 Markdown、工具卡、`/` `@` 补全、`#L12-14` 行区间、历史搜索、中英、原生光标；Kitty/Sixel 图片、Mermaid→Unicode、LaTeX、分栏 diff；实时状态（上下文条/TPS/缓存命中/推理强度/token/费用估算/Git）；时间轴与双击 Esc 时间回溯；8 个内置侧栏面板（Ctrl+B）；会话工作流 `/new` `/compact` `/export` `/btw`、fork、vim、全屏草稿；四类通知与多终端投递；`dst -p` / `run --json` / `session list --json`；`dsh-tui migrate` 导入 Claude Code/Codex/OMP/zcode/Grok Build 历史。
- **接入**：`npm i -g @deepseek-ai/dsh @deepseek-harness-tui/dsh-tui` → `dsh-tui`/`dst`；或 `dsh plugin --profile dsh-tui add …`；Windows 免管理员 exe。
- **机制**：`dsh.bundle.patch` 在 dsh-base 之上重写 surface 值（persona）；独立 `dsh-tui` profile；消费 session/event → Channel projection → Ink 渲染；presets/skills/MCP/goal/todo/子代理/问卷；shell API、V4 会话消息、声明式预设。
- **限制**：不支持 Git URL 安装；Windows profile 默认 `danger-full-access` + approval `never`；`@` 补全缓存 2 秒；注入上下文无独立展示；`Ctrl+V` 需平台剪贴板工具；后台会话随 TUI 退出即停；minimal 预设无压缩、长会话可能撞上限；费用为估算；ConPTY sixel 与输入排空存在已知边界。

### 8. anywhere-labs/dsh-desktop（Electron 桌面壳）
- **能力**：自动启停本地 Harness、系统托盘与原生窗口（无需装 Node）；手机远程控制（Agents-Anywhere，2.0.9+ 内置）；内置插件市场（发现/详情/安装/管理，开放 Schema 数据源）；原生 Setup Wizard（窗口模式/材质、市场、通知、浏览器打开、Web 访问范围，完成前不启 Host）；Web 默认只回环、可选局域网；自动更新带版本/通道 header（macOS/Windows 另带随机 Installation-Id）；桌面插件服务 API；插件生态倡议书 + Community Fabric Draft。
- **接入**：官网/Release 安装（NSIS、DMG、deb/AppImage/tar.gz）；源码 submodule init → `corepack yarn install --immutable` → `corepack yarn dev`。
- **机制**：固定上游版本原样运行（子模块），桌面壳以 dsh 插件接入同一运行时；profile Setup/恢复；插件市场 + profile bundles。
- **限制**：局域网访问无鉴权（同网段可操作你的电脑，README 标「危险」）；Linux 不能应用内更新；内置 dsh 可能比 npm 旧；Wayland 等平台问题见文档。

### 9. dataelement/dsh-desktop（Dataelem 桌面版）
- **能力**：主流模型适配（模型搜索、图片输入、推理能力配置、第三方兼容）；Office 三件套（Word 原生套版、Excel 案例工作簿、PPT 16 套模板 192 版式 → 可编辑 DOCX/XLSX/PPTX，随附 Python 与 Office 依赖）；启动异常与插件故障恢复（安全模式 `--safe-mode`、屏蔽第三方插件、升级插件、保留会话配置）；工作台（市场安装/本地导入/复用会话）；`.dshpreset` 包导入导出与冲突检查；手机扫码配对（局域网或 Cloudflare Quick Tunnel，Pinggy 备用，6 位密码）；自动更新先灰度后全量。
- **接入**：官网下载；开发跑 `npm test` / `typecheck` / `build`；文档拆 development / architecture / release-runbook / preset-packages。
- **机制**：复用 dsh Agent Runtime + Web UI + 模型接入；Electron 壳管理启停；Profile（安全模式屏蔽插件）；Preset 契约；配对 Bridge 转发手机访问。
- **限制**：不支持 Windows ARM64 与 Linux；Harness 只在随机 127.0.0.1 端口，手机访问依赖 Bridge，桌面断开则手机会话失效；Pinggy 约 60 分钟后失效；临时密码只在内存 5 分钟。

### 10. dsh-tauri/deepseek-harness-desktop（Tauri 桌面）
- **能力**：运行时管理（装依赖、选内核版本、桌面端与内核更新）；插件管理（12 内置、本地路径安装、停用、社区插件装/升/卸/看错误）；档案配置（分档管理 + 迁移/备份/克隆）；数据目录（安装时选位、设置里迁移与回滚）；托管 shim 提供 `dsh`/`pnpm`（非全局 npm）；桌宠 `dsh-pet-lite`；个性化 8 配色/缩放/终端模式/透明度磨砂；内置 Worktree、Extension（官方插件管理+市场+Skills+MCP）、Archive、Model、Remote（SSH 远端与分享）、Notification；移动端扫码远连（Android APK / iOS TestFlight）。
- **接入**：Releases 安装包（`_Bundle_` 离线包）；macOS brew；Fedora Copr；`brew install dsh-tauri/desktop/deepseek-harness`。
- **机制**：固定内核基线 0.2.1-rc.4（最低同版本），按 `manifest.jsonc` 与插件版本范围选内核；dsh 插件 + 插件市场；托管 CLI 与 profile。
- **限制**：普通安装包首启需联网下运行时与内核；本地运行 ≠ 完全离线；上游破坏性变更需先确认兼容；桌面代理不作用于模型请求与插件子进程；移动端只在官方移动服务前维护；Windows `STARTUP_LOW_INTEGRITY` 需 icacls 处理。

### 11. omdsh-dev/DSH-better-sidebar（侧栏工作台 + 服务）
- **能力**：文件管理（懒加载树、Git 着色、watch、全局搜索、拖拽上传、批量操作、打开方式双源菜单）；Git（三组 + 本轮 AI 改动视角 + 只读提交图：泳道/分支/tag/筛选/详情）；可编辑 CodeMirror + Markdown/Mermaid/浮动目录、HTML 沙箱预览、超大文件分页；任务管理（子代理拓扑图/树 + 后台任务清单）；侧边对话 beta（继承主会话上下文、独立模型、可撤回、可提升顶层会话）；底部工作台（分栏、多终端页签、按会话持久化）；`sidebar_open` 工具；启动只拉 ~325KB 核心。
- **接入**：`dsh plugin --profile web add dsh-better-sidebar@<匹配版本>` + 硬刷新；`bash scripts/install.sh <版本>`；或把安装提示词交给 DSH。
- **机制**：单包 host/client 双半；host 暴露 `/sidebar/api/*`、媒体/HTML/上传路由与两条 WS；`ctx.betterSidebar` 五个扩展点；`dsh.bundle.patch` + client.inject；聚合包双挂载退让。
- **限制**：版本必须与宿主线严格匹配（0.32.1↔0.2.2-rc.2+，0.32.0↔0.2.2-rc.1，0.28.2↔0.2.1 线…），市场不按宿主选版本；v0.23.0 起文件路由不做工作区包含检查；Git 无 push/pull/fetch；只 watch 已展开目录；终端由 DSH 提供；<768px 无底部面板；profile 混装 `@deepseek-ai/dsh-*` 副本会 fatal。

### 12. dsh-market/dsh-market（插件市场）
- **能力**：10000+ 插件目录（分类/star/排序/中英描述）；按宿主兼容发现（engines.dsh、peer 声明）；截图轮播；评论与站外共用同一条讨论；收藏/分组/备注；主题页（装完即生效、互斥、卸载恢复）；一键安装；备份与恢复（JSON、WebDAV 每日自动备份、Gist 同步，合并式 + 校验 + 失败回滚）；更新体系（逐插件检测、一键/全部、更新内容链接、本次不再提醒、后台提醒、公共更新 API v1）；GitHub 多线路容错与自定义加速前缀；热禁用/启用；按需重启 + 重启失败恢复（重启助手）；零术语自动装 pnpm；导出脱敏日志；诊断（bundle 栈/重复 loader/版本不一致/残留目录）；加载顺序拖拽 + 静态校验；AI 修复 prompt（apply/rollback）。
- **接入**：Desktop 设置→插件搜 `dshmarket`；`dsh plugin --profile web add dshmarket`；源码 `add github:dsh-market/dsh-market` 或 Release tgz；索引源 jsDelivr 上的 `dsh-plugin-catalog/index.json`。
- **机制**：`dsh.bundle.patch` + client.inject（locale/ui-settings/ui-theme）；写 profile `cordis.patch.yml` 热禁用；与 Plugins 页/loader/Discover/`plugin_market` 集成；profile `state.json` 本地状态；按原入口/参数/环境重拉进程。
- **限制**：需 dsh web ≥0.1.0-rc.6，太旧自我禁用；桌面 profile 不由 CLI 管理（CLI 装进 profiles/web 不进桌面）；只允许 awesome-dsh-plugin 精选来源；原生模块在 dsh 进程环境构建（GUI/systemd 不继承终端环境，需 buildEnv）；systemd 主进程需关 allowRestart；备份可能含密钥；收录 ≠ 背书。

### 13. bowenliang123/dsh-context（上下文洞察）
- **能力**：上下文洞察页（KPI、7 天用量、8 周热力图、技能/工具/命令汇总、Composition、会话卡片）；Context 标签页九张卡片；Context Trend（按请求堆叠、步骤摘要、压缩标记、Step/Turn、Total/Delta、总览、悬停联动）；Context Browser（七类别、逐项 Token、可展开内容、工具来源标签、DNA 平铺）；Fleet（Agent 网络/协作泳道/协作任务/事件检查）；`/context` 弹窗；Preferences（面板入口、默认时间范围、趋势默认、系统提示词前后缀）；File Activity 与命令执行明细。
- **接入**：Add plugin 向导搜 `dsh-context`；`dsh plugin --profile web add dsh-context`；`update dsh-context@latest`；无需构建或重启。
- **机制**：`dsh.bundle.patch` + client.inject（api-remotes/connection/locale/ui-conversation/ui-settings/ui-sidebar-right）；读官方 `contextPressure`/`contextBreakdown` 投影；摘要进缓存、明细重算；`dsh.compatibility.dshReleases`。
- **限制**：需 dsh 0.2.0-rc.2+；明细上限（步骤 1500/轮次 300/事件 400/surface 2000/存档 400/文件 400/命令 400）；估算值与实际值并列；多语言需 0.2.2+。

### 14. Asaiuta/dsh-genui-enhanced（生成式 UI fork）
- **能力**：边流边渲染 + 零破坏降级；30+ 组件（stat/table/timeline/diff/steps/file-tree/callout/badge…）；ECharts preset 与完整 option、按需加载；`plot` 参数滑块毫秒重绘；Mermaid/pele 12 图型 + 3D；KaTeX；本地优先交互；状态持久化（会话 + 内容指纹，LRU 200）；Action 回环（禁用态诚实设计、滑块尾沿防抖）；常驻 Dock `/panel` 与模板中心/成就；白名单沙箱与禁 eval；同回合自修 + 节点级降级；导出 `.html` / `.genui.json`。
- **接入**：上游 npm `add @changfenhuang/dsh-genui`；本 fork `pnpm install` → tsc/tsdown → `add link:$PWD`；`cordis.patch.yml` 配 `renderUiTool` / `fenceFeedback`。
- **机制**：`dsh.bundle.patch` + `dsh.client`（platform web）；fence-registry 扩展点；可选 `render_ui` 工具与 genui skill；profile patch 的 config 段。
- **限制**：fork 未发 npm，`lib/` 不入库须先构建；仅 `^0.2.0-rc.1 || ^0.2.1-rc.1`，旧宿主可能白屏；npm 有同名无 Scope 包；纯 `link:` 不装对等依赖；pnpm 11 构建脚本坑；上游 npm 版不含 fork 增量。

### 15. Fei2411/DS-Bot（bot 团队化）
- **能力**：Bot（模型与思考强度、记忆、独立文件夹与权限、插话、`/side`、回复内图表表单、定时任务、侧栏分组）；Main bot（Chief 管理其他 bot 与群聊）；群聊（管理员代调、@ 直达、引用对话、独立记忆与文件夹、Goal 分阶段验收）；隐私 bot（其他 bot 读不到、对外动作需批准）；本地 Agent 接入（Claude Code/Codex/Cursor/Copilot/Devin/OpenCode/Gemini/Antigravity/Kimi/Kilo）；每 bot 独立浏览器（Cookie 导入、敏感动作批准、登录验证码付款交还）；电脑操控（三档 + 应用白名单 + 指示条）；IM 接入；连接器与 MCP；Office 三件套；用量统计。
- **接入**：Releases 桌面包；dsh Desktop 插件页填 `ds-bot`；dsh Web `npx @deepseek-ai/dsh@0.2.2-rc.1 plugin --profile web add ds-bot`；Docker 见 docker/README.md。
- **机制**：`dsh.bundle.patch` + `dsh.client`；每 bot 跑在 dsh 会话里用 dsh 工具与模型；凭据进 dsh 密钥存储；web-search provider、MCP、host RPC；数据落 `~/.dsh` 的 `bot/`、`sessions/`。
- **限制**：v0.3 预览；浏览器仅桌面/DSH Desktop；仅桌面应用保留登录态与导入 Cookie；电脑操控共用同一桌面、单应用单 Bot、Windows 后台应用限制、macOS 14+、Linux 仅 X11；IM 需电脑开机、微信仅私聊、微信/QQ 有时限；隐私 bot 非系统沙箱；本地 Agent 走 CLI 自己的上下文；dsh Web 无 Office 环境。

### 16. T-Auto/dsh-ops（token 效率工具面）
- **能力**：Bash 与宿主 Shell 隐藏独立配置（Windows 可用 `ops_bash` 替 pwsh，或保留官方 Shell）；Native/PTC 共享有界工具面；内置 `ops-ptc` 模式 + `batchingGuidance` 批量教学（首轮注入一次，之后按 run_code 形状纠偏不阻断）；启用 `tools_addition` 动态工具 + 渐进式披露（PDF/Word、批量改文件）压 token；Native 紧凑带行号与错误反馈；PTC 结构化 JSON；PTC SDK 18 个 API；可选 OPS 只读侧栏（dsh-TUI）；自用 benchmark。
- **接入**：市场搜 `dsh-ops`（华为云 npm 镜像，npmmirror 有 bug）；`npx --yes dsh-ops@latest install --profile desktop|web|tui`（`--dry-run`）；或 `dsh plugin --profile web add dsh-ops`；`status`/`uninstall`。
- **机制**：`dsh.bundle.patch` 单行 + client.inject（api-gateway/ui-renderer/locale/ui-plugin-manager/ui-primitives，immediately）；`dsh-plugin.json`（manifest 0.15，host facet、contracts、permissions）；`tools_addition` 动态加载；presets 装配；profile 包管理器管随包二进制；dsh-TUI 的 tuiPanels。
- **限制**：宿主需 0.2.2-rc.1 起（0.5 系列不支持 0.2.0/0.2.1 与更早 0.2.2 预览）；必须显式选 profile；普通 CLI 管不了保留的 desktop profile；不支持 git+https 与未构建源码；npmmirror 有 bug；旧组件行须迁入单行；Windows Low 完整性限制；provision 副本不随 npm 卸载。

### 17. xmanrui/dsh-im（IM 接入）
- **能力**：11 渠道（飞书/微信/钉钉/企微/企微应用/QQ/Slack/Telegram/Discord/WhatsApp/iMessage/Matrix），各按其长连接/长轮询/回调与卡片流式能力适配；每渠道多机器人、状态/工作区/模型/会话绑定独立；AI Office Connector；群聊天记录与群文件（默认保留 14 天，@ 即查）；超时结果补发；文件与图片回传；图片输入额度可配；排队或自动插话 + `/steer`；会话双向同步；品牌 Logo 适配；`/repair` 补权限；rpcAuthority 加固。
- **接入**：`dsh plugin --profile desktop add -w @xmanrui/dsh-im` 或 `--profile web` → 重启 → 设置 → IM机器人；GitHub 源 `npx -y github:xmanrui/dsh-im install`；代理用 HTTPS_PROXY / NODE_USE_ENV_PROXY。
- **机制**：`dsh.bundle.patch` + client.inject（connection/runtime/ui-settings/ui-slots/locale）；经 Typert Gateway 调 Session/Workspace Controller（不走本机 HTTP 端口）；凭据进受保护存储；设置 order:21；`dsh.compatibility` 声明 web profile 与版本。
- **限制**：Matrix 加密未完整（无设备验证/密钥备份/SSSS/媒体加密，未验证真实 homeserver）；iMessage 仅文本私聊；Telegram 文件未验证、Discord/Slack 待真机群验收；微信仅私聊、微信/QQ 有时限；长连接不读 ALL_PROXY/NO_PROXY；飞书需额外租户权限；文件受平台配额；双向同步仅当前 Host 私聊文字。

### 18. omdsh-dev/dsh-deep-research（自适应深研）
- **能力**：规划前置（答案空间 scope + 子问题验收 acceptance）；维度枚举与 `coverage_gaps` 自检；三态证据（confirmed/uncertain/gaps）；每轮预测→行动→更新→边际增益验证，连续零增益即停 + 轮次上限；闭环再规划与盲区定向侦察；有损压缩综合（保留置信度与矛盾）；可选对抗性审查（引用抽查、覆盖度审计、矛盾标注）；工具参数 topic/purpose/questions/depth/synthesize/review；四类模型分级降本；取消传播与失败隔离。
- **接入**：`dsh plugin --profile <profile> add git+https://github.com/dsh-external/dsh-deep-research.git` → `dsh --profile <profile>` 重启；`update`/`remove`；`pnpm run typecheck`。
- **机制**：`dsh.bundle.patch`；官方 `ctx.workflows` / `@deepseek-ai/dsh-workflow-workerthread`（worker 隔离、并发与总数 cap、取消、进度事件、wf-runs）；内置 `web_search`/`web_fetch`（零自研编排）；源码即运行时；刻意不注册 skills、不注入 TUI prompt。
- **限制**：profile 必须含 workflows provider（部分 Web 组合缺失 → Loader pending）；需 erasable-only TS；`autoInstallPeers: false` 规避未发布 `@deepseek-ai/*`；pnpm 可能把 https 改写成 git+ssh；需手动 allowBuilds；包为 private。

### 19. stephenlzc/dsh-swarm-panel（swarm 可观测）
- **能力**：持久化 swarm runtime（父子/点对点/混合路由）；从 session event log 经 checkpoint 与 cold resume 恢复；群聊轮次、共享上下文、轻量记忆、HITL 暂停；宿主合成 Conversation Flow 页面（拓扑、泳道、路由筛选、消息详情、Live 跟随、子会话导航）；响应式 390×844；明确验证状态（93 个无密钥测试、浏览器 E2E、类型检查）。
- **接入**：Release tarball `dsh plugin --profile web add /tmp/…tgz`；GitHub 子目录 `add 'github:…#path:dsh-swarm-plugin'`（锁 commit）；本地 `file:`；桌面用 launcher 装独立 profile。
- **机制**：`dsh.bundle.patch` + client.inject（ui-conversation/ui-workspace）；宿主合成页签；session event log projection；0.2.0-rc.2 workspace API。
- **限制**：Export 未实现；无 A2A/ACP 桥接；不支持嵌套 sub-swarm；Memory 未自动注入每轮 prompt；面板只有英文；源码开发需匹配 workspace；Release URL 直传会完整性校验失败。

### 20. kingcharleslzy-ai/dsh-purge（破甲/自托管控件）
- **能力**：左侧栏整页面板（状态 + 应用主操作）；25 层 `selfcheck --json`、`status`、`host-status`；`diagnose` 锚点漂移 + `reanchor` 钉锚点；`probe` 运行时探针；`audit` 动作台账；`boost`、`preset install`、`excludePresets`、`retry`；备份/回滚/占用与清理；技能压缩包安全导入；更新默认只检查（6 小时）；86 条宿主补丁；dsh-go 面板只读查看。
- **接入**：插件 → 发现 → 索引源 `https://kingcharleslzy-ai.github.io/dsh-purge/index.json`；`dsh plugin --profile web add <固定版本 tgz>`；社区安装器 `scripts/install.sh --dry-run` / `install.ps1 -DryRun`。
- **机制**：`dsh.bundle.patch`（关旧 redteam 行、改 system-prompt 行）；client.inject + `dsh.install.preferred: tarball`；宿主补丁锚点覆盖与漂移诊断；profile 补丁层；Web 面板受信 Host。
- **限制**：未验证宿主标「未验证」；红队工具需 Node ≥22.5；安装器会触碰宿主目录；不自动应用补丁/不自动重启/不改代理；脚本从 master 下载、SHA256 只校验 Release 包；dry-run 成功 ≠ 安装成功；dsh-go 仅模拟器只读验收。

### 21. Javis603/token-monitor（外部用量观测）
- **能力**：54+ 工具用量，其中 DeepSeek Harness 走 `~/.dsh/sessions`（`session.jsonl`/`.jsonl.zstd`，受 `$DSH_HOME` 覆盖）；实时速率；session 逐条明细；缓存命中分类；成本与多币别；自定义扫描路径与 WSL 合并；额度检测（34+ 提供方、多账号、Codex 切换与重置预测）；保留已删除会话用量；趋势/仪表板/固定时间范围/状态页/CSV+JSON 导出；订阅回本倍数；多设备同步（Hub SSE / iCloud / 自托管 / Worker / headless）；刘海、侧边栏、菜单栏/托盘、小窗、macOS 小部件。
- **接入**：`brew install --cask token-monitor` 或 Releases；启动即追踪；多设备在设置里选同步模式。
- **机制**：只读解析 dsh 会话日志与回合信号；**不是** dsh 插件（无 bundle/patch/client 注入）；可选 SSE Hub / Worker 同步；本地优先、无遥测。
- **限制**：只能统计本机日志存在的用量；Session Detail 不同步；Goose 跨日归创建日且不支持远程 goosed/自定义路径；部分工具子任务无 Session Detail；iCloud 仅 macOS 小部件；WSL SQLite 来源需 headless agent。

---

## 三、共性优点 Top 10

1. **「一切皆插件」真的被用起来了**：几乎每个项目都以 `dsh.bundle.patch`（`cordis.patch.yml`）+ `dsh.client.inject` 组合进驻，不改上游源码即可换 surface。上游 README 里那句架构口号在 12 个项目里都有可验证的落点。
2. **零破坏降级是普遍共识**：genui 未安装时围栏退回 Markdown、better-sidebar 聚合包双挂载自动退让、market 在宿主太旧时自我禁用并只在控制台说明——生态项目普遍把「宿主版本不匹配」当成一等公民而不是异常。
3. **人类通道与 Agent 通道被刻意分开又共享**：NanGeAGI 的人类终端与 `terminal_*` 分离、Daban 的 Bot 独立桌面但共享文件与登录态、DS-Bot 每个 bot 独立浏览器——同一份「隔离 + 共享」设计在不同产品上反复出现。
4. **多 Agent 从「并行调用」升级成「组织结构」**：Tandem 的九角色、dsh-context 的 Fleet 谱系、swarm-panel 的拓扑/泳道、deep-research 的 planner/researcher/synthesizer/reviewer 分级——都有可观察的组织模型，而不是黑箱并发。
5. **上下文与成本被当成可观测指标**：dsh-context 直接读官方 `contextPressure`/`contextBreakdown` 投影；dsh-TUI 有上下文条 + TPS + 缓存命中 + 会话费用；token-monitor 做跨工具成本聚合。三者都在回答「这次到底花了多少、花在哪」。
6. **成本纪律写进算法而非文案**：deep-research 的「连续零增益即停 + 轮次上限 + 模型分级」、dsh-ops 的「动态工具 + 渐进式披露」、DS-Bot 的「群聊默认只由管理员回复」——都是用机制省钱，而不是提醒用户省钱。
7. **可逆运维成为标准件**：market 的 profile 快照与回滚、purge 的应用前自动快照 + `rollback <id>`、dsh-tauri 的数据目录迁移回滚、dsh-desktop 的安全模式——改坏了能回去，是这批项目的共同底线。
8. **远程与移动被当作 dsh 的第一类交付面**：dsh-Go 的原生插件协议 + PRoot、dsh-tauri 的移动扫码、dsh-desktop 的配对 Bridge、dsh-im 的 11 个 IM 渠道——「手机/异地也能用」已有 6 种互不相同的实现路径。
9. **准入与安全边界被显式声明**：better-sidebar 讲清「文件路由不做工作区包含检查」、dsh-desktop 把局域网无鉴权标成危险、dsh-TUI 警告 Windows profile 默认全权、purge 的 `rpcAuthority`/可信 Host——负面能力写在明面上。
10. **自证式验证**：swarm-panel 列「93 个无密钥测试 + E2E + 390×844 手工验证」、Tandem 给三平台实测耗时与通过项、purge 用 25 层自检、dsh-context 有兼容矩阵——把「能用」变成可核对证据。

## 四、共性缺陷 Top 10

1. **版本地狱**：宿主 0.2.0-rc.x → 0.2.1-rc.x → 0.2.2-rc.x 之间插件互不通用。better-sidebar 要按宿主钉 6 个精确版本、genui 只支持两条线、dsh-ops 直接放弃 0.2.0/0.2.1、market 需 ≥0.1.0-rc.6——生态的兼容矩阵比功能表还长。
2. **安装路径五花八门且常失效**：npm 包名、Git 子目录、Release tgz、索引源、link:、社区安装器并存；swarm-panel 的 Release URL 直传会失败、genui 的纯 `link:` 不装对等依赖、better-sidebar 安装脚本要自动修 profile——用户很难一次装对。
3. **profile/CLI 与桌面端的割裂**：market 与 swarm-panel 都明确写了「用 CLI 装进 profiles/web 不会出现在桌面端」，desktop profile 甚至禁止第三方插件；同一台机器上存在两套互不认账的插件状态。
4. **权限与沙箱默认偏松**：dsh-TUI 的 Windows profile 默认 `danger-full-access` + approval `never`；better-sidebar v0.23.0 起文件路由可读写宿主用户可访问的任意路径；dsh-desktop 的局域网访问完全无鉴权。默认值比用户预期更危险。
5. **「安装成功」缺少可信信号**：purge 反复强调 dry-run 成功、备份存在、市场卡片出现都不等于装好；market 要专门做导出脱敏日志；多处文档把「硬刷新 / 重启 / 重新拉 profile」当成日常操作——反馈回路太长。
6. **Windows 是系统性二等公民**：Tauri 版有 `STARTUP_LOW_INTEGRITY`、dsh-ops 有 Low 完整性标签限制、dsh-im 的 WhatsApp/Telegram 代理要额外环境变量、DS-Bot 的 Chrome/Edge v20 Cookie 读不了、dsh-TUI 的 ConPTY sixel 只能缓解。平台差异被反复补丁化。
7. **功能依赖上游隐藏前提**：dsh-deep-research 必须有 workflows provider（部分 Web profile 没有 → Loader pending）、better-sidebar 的终端要宿主提供、dsh-TUI 的 minimal 预设没有压缩服务。文档写了，但失败态对用户非常不直观（宿主直接 fatal / 空白）。
8. **能力边界靠文档而不是界面表达**：dsh-Go 的 Remote 渠道少一半功能、DS-Bot 的浏览器只在桌面可用、token-monitor 只统计本机日志、iMessage 仅文本——这些限制都只在 README 的长表里，用户要读完才知道「为什么没有那个按钮」。
9. **外部依赖即单点**：market 的目录与截图依赖 GitHub/CDN 与多线路容错（还要自定义加速前缀）；purge 的安装器依赖 raw.githubusercontent 与 master 分支；dsh-im 的长连接不读 `ALL_PROXY`/`NO_PROXY`；token-monitor 依赖各工具日志路径。网络与路径一变，功能就静默降级。
10. **估算值被当成事实的风险**：dsh-TUI 的费用、dsh-context 的类别 Token、token-monitor 的额度窗口都是估算或第三方面板数据，各自都在文档里声明「以平台账单为准」——但界面上的数字没有同等强度的心智标记。

---

### 附：未在仓库说明的项
- deepseek-ai/deepseek-harness：profile 与插件 API 的稳定性承诺、Web 之外的 CLI 能力细节（README 只给 Web 入口与开发命令）。
- ShawnSun-debug/dsh-go：README 未单列限制；与当前上游的功能差异、维护状态未在仓库说明。
- dsh-tauri/deepseek-harness-desktop：内置 12 个插件的完整清单只列了 9 个公开条目，其余未在 README 展开。
- 各项目 star 数为 2026-11-20 页面抓取值，会随仓库增长变化。
