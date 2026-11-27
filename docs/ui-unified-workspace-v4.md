# 统一聊天工作区重构 v4 · 实施记录

对应方案：《总方案·知川助手·聊天 / 议会 / 团队统一工作区重构 v4》。
基线：`ui-chuan-shui` 分支 `aa6154af`（签名材料移出仓库：keystore 与口令改走 Secrets）。

## 架构变化

- `ChatScreen` 成为唯一聊天工作区根页面。议会/团队不再是独立路由：
  `CouncilPage` / `TeamPage` 改造为 `CouncilModeView` / `TeamModeView`
  （文件仍在 `ui/council/council_page.dart`、`ui/team/team_page.dart`），
  只提供消息内容、发送/停止、成员管理与运行恢复，不再自带 Scaffold、
  顶栏或返回键。
- 新增 `ui/chat/shared/conversation_mode_host.dart`：按「模式 + 主机 +
  请求序号」把模式视图放进工作区，视图通过 `CollabHeaderInfo` 把标题、
  状态、菜单动作发布给统一的 `ChatHeader`。
- `conversation_workspace.dart` 从透明 Scaffold 改为纯内容列
  （顶栏留白 + 消息区 + 错误行 + 输入栏）。背景（壁纸 + 潮汐光斑）由
  外壳画一次，三种模式共用，黑底问题的结构根源（opaque 路由 + 透明
  Scaffold）随之消失。
- `conversation_mode_switcher.dart`：三段式删除，改为单枚「当前模式」
  按钮（44dp，窄屏只留图标 + 小箭头）+ 纵向三项悬浮面板
  （`showGeneralDialog`，约 200ms 淡入 + 缩放 + 6dp 位移，点外面 /
  返回键关闭）。按钮位于顶栏右侧操作区、新对话键之前。
- `switchConversationMode` 不再 push/pushReplacement：切到议会/团队 =
  `startNew`（新建会话请求），切回聊天 = 保留原聊天会话。
  `conversationModeRoute` 已删除。
- 历史（`collab_history.dart`）与深链（`collab_entry.dart`）改为
  `openExisting` / `openRun` + 切到聊天标签，在同一工作区恢复原会话。
- `home_shell.dart` 删除启动时的协作页 push：冷启动第一帧由
  `ChatScreen` 按存档模式直接渲染（`conversationModeInitialProvider`
  机制不变）。

## 会话与状态

- `ConversationModeState` 增加瞬时请求字段（不落盘）：
  `requestNonce` / `openId` / `openRunId` / `createNew`。
  主动切换 bump 序号得到全新视图实例；冷启动序号为 0，恢复上次会话，
  不自动新建。持久化格式（`dsh.conversation_mode.v3`）不变。
- 议会新增 `CouncilConversationsNotifier.createLocal`（同步进内存表）
  与 `flush`（落盘一次、失败抛给界面显示错误行）。
- 团队第一阶段直接读本地 `TeamStore` 创建/恢复 `TeamState`
  （复制上一个团队的队友配置，不复制消息与运行任务）。

## 启动性能（方案八 / 九）

- 议会：`initState` 同步确定/创建会话，第一帧即聊天界面；
  Store ready、落盘、编排器连接、历史席位登记、运行快照恢复全部
  移到后台 `_bootBackground`，各阶段带超时与耗时日志
  （`[council boot]`），失败只出错误行 + 重试。
- 团队：`_bootLocal` 只读本地文件；`_bootEngine` 后台连编排器、
  订阅、登记、擦除运行残影、接定时唤醒（`[team boot]` 日志）。
- 成员不足时输入栏照常可用，仅发送键不亮
  （`ConversationComposer` 现在把 `sendable` 真正传给 `Composer`）。

## 动效

- 复用 `AppMotion`：面板 200ms easeOutCubic；内容切换
  `AnimatedSwitcher` 240ms 淡入 + 8dp 位移；消息进场沿用 `EnterOnce`
  （历史消息不重播）；减少动画时全部归零。

## 测试

- 更新：`conversation_mode_switcher_test`（单按钮 + 面板 + 工作区内
  切换 + 请求语义）、`council_page_test` / `council_page_history_test` /
  `team_page_test`（模式视图 + 顶栏脚手架 `test/collab/mode_view_harness.dart`）、
  `collab_history_test` / `collab_tap_test`（断言模式状态而非路由）。
- 静态检查与上述套件的执行结果见提交说明；真机视觉/耗时/录屏验证
  （方案十六）需要在真实设备上安装预览包后补做。

## 遗留问题

- 真机验证（背景一致性、切换动画、议会启动耗时、强退恢复）待安装
  CI 预览包后执行。
- 议会/团队消息区目前不滚到顶栏「后面」（内容列从顶栏下沿开始），
  用消息区上沿 24dp 渐隐近似聊天的 EdgeFade 手感；如需完全一致的
  全屏滚动 + 渐隐，可后续把模式视图拆进 ChatScreen 的 body/composer
  两个布局槽。