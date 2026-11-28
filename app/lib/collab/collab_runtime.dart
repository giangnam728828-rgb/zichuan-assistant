// 进程级共享的协作编排器登记处。
//
// 团队页/议会页在连上引擎时创建共享实例（页面切走不打断正在跑的成员），
// 历史抽屉与任务工作台需要同一个实例来做「继续运行」「重命名」——不能各自
// 再建一个，否则内存快照会互相覆盖，标题也会被旧快照改回去。
//
// 这里只放指针，不放逻辑：谁创建谁登记，谁需要谁读取。

import '../council/collab_orchestrator.dart';
import '../team/team_orchestrator.dart';

/// 当前连接的团队编排器（团队页创建）。
TeamOrchestrator? sharedTeamOrchestrator;

/// 当前连接的议会编排器（议会页创建）。
CollabOrchestrator? sharedCouncilOrchestrator;

/// 断开/换连接时清掉，避免拿着旧客户端的实例去发请求。
void forgetSharedCollabOrchestrators() {
  sharedTeamOrchestrator = null;
  sharedCouncilOrchestrator = null;
}
