// 协作运行的落盘：一次运行一个目录，状态快照原子替换。
//
// 目录布局（root 通常是 <应用支持目录>/council）：
//   runs/<runId>/run.json      最新快照（写 tmp 再 rename，断电不写坏）
//   runs/<runId>/verdict.md    裁决正文（跑完后写，方便用户导出）
//
// 「先写盘再执行」由编排器负责时序：每次状态转移先 save、成功后才发下一
// 个请求。所以盘上的快照要么是某一步之前的完整状态，要么是之后的完整
// 状态，不会出现半截（rename 在同一文件系统内是原子的）。

import 'dart:convert';
import 'dart:io';

import 'collab_models.dart';

class CollabStore {
  CollabStore(this.root);

  /// 存放所有运行的目录。
  final Directory root;

  Directory _runDir(String id) => Directory('${root.path}/runs/$id');

  File _runFile(String id) => File('${_runDir(id).path}/run.json');

  /// 原子保存：同目录 tmp 文件写完 rename 过去。
  Future<void> save(CollabRun run) async {
    final dir = _runDir(run.id);
    await dir.create(recursive: true);
    final tmp = File('${dir.path}/run.json.tmp');
    await tmp.writeAsString(jsonEncode(run.toJson()), flush: true);
    await tmp.rename(_runFile(run.id).path);
  }

  Future<CollabRun?> load(String id) async {
    final file = _runFile(id);
    if (!await file.exists()) return null;
    try {
      final json = jsonDecode(await file.readAsString());
      if (json is! Map) return null;
      return CollabRun.fromJson(json.cast<String, Object?>());
    } on FormatException {
      // 半截文件（进程正好死在 write 窗口，理论上不会发生，因为 rename
      // 原子；但云同步/手工改动可能弄坏）：当作没有，别让恢复流程崩。
      return null;
    }
  }

  /// 全部运行，最近的在前。
  Future<List<CollabRun>> list() async {
    final runsDir = Directory('${root.path}/runs');
    if (!await runsDir.exists()) return const [];
    final runs = <CollabRun>[];
    await for (final entity in runsDir.list()) {
      if (entity is! Directory) continue;
      final run = await load(entity.path.split(Platform.pathSeparator).last);
      if (run != null) runs.add(run);
    }
    runs.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return runs;
  }

  /// 最近一次尚未走到终态的运行（冷启动恢复用）。
  Future<CollabRun?> latestUnfinished() async {
    for (final run in await list()) {
      if (!run.phase.isTerminal) return run;
    }
    return null;
  }

  /// 裁决正文单独落一份可读的 Markdown。
  Future<void> writeVerdict(CollabRun run) async {
    final verdict = run.verdict;
    if (verdict == null || verdict.isEmpty) return;
    final dir = _runDir(run.id);
    await dir.create(recursive: true);
    await File('${dir.path}/verdict.md').writeAsString(verdict, flush: true);
  }
}
