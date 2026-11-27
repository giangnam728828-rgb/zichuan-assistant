// 团队会话的落盘：一个团队一个 JSON 快照（原子替换）+ 导出 Markdown。
//
// 与议会的 CollabStore 同一套约定：目录 <root>/<teamId>.json，写 tmp 再
// rename。群聊记录随每条消息更新，MVP 阶段一整份快照足够小（C6 再按天
// 拆或者改成追加日志）。

import 'dart:convert';
import 'dart:io';

import 'team_models.dart';

class TeamStore {
  TeamStore(this.root);

  final Directory root;

  File _file(String id) => File('${root.path}/$id.json');

  /// 并发写同一个团队时，临时文件必须各自独立：固定 `.tmp` 名会出现
  /// 「A 刚 rename 走，B 再去 rename 就找不到文件」的竞态。
  static int _tmpSeq = 0;

  Future<void> save(TeamState state) async {
    await root.create(recursive: true);
    final seq = _tmpSeq++;
    final tmp = File('${root.path}/${state.id}.json.$pid.$seq.tmp');
    try {
      await tmp.writeAsString(jsonEncode(state.toJson()), flush: true);
      await tmp.rename(_file(state.id).path);
    } on Object {
      // 临时文件写失败或已被替换：不影响盘上已有的完整快照。
      if (await tmp.exists()) {
        try {
          await tmp.delete();
        } on Object {
          // 删除失败也不必让上层失败。
        }
      }
      rethrow;
    }
  }

  static final pid = DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  Future<TeamState?> load(String id) async {
    final file = _file(id);
    if (!await file.exists()) return null;
    try {
      final json = jsonDecode(await file.readAsString());
      if (json is! Map) return null;
      return TeamState.fromJson(json.cast<String, Object?>());
    } on FormatException {
      return null;
    }
  }

  /// 全部团队会话，最近更新的在前。
  Future<List<TeamState>> list() async {
    if (!await root.exists()) return const [];
    final states = <TeamState>[];
    await for (final entity in root.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final name = entity.path.split(Platform.pathSeparator).last;
      final state = await load(name.substring(0, name.length - 5));
      if (state != null) states.add(state);
    }
    states.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return states;
  }

  Future<TeamState?> latest() async {
    final all = await list();
    return all.isEmpty ? null : all.first;
  }

  /// 删掉一个团队：会话、Markdown 导出都删，别的团队不动。
  Future<void> delete(String id) async {
    for (final name in ['$id.json', '$id.md']) {
      final file = File('${root.path}/$name');
      if (await file.exists()) await file.delete();
    }
    if (!await root.exists()) return;
    // 写盘中途留下的临时文件按名字前缀清：`<id>.json.<pid>.<seq>.tmp`。
    await for (final entity in root.list()) {
      if (entity is! File) continue;
      final name = entity.path.split(Platform.pathSeparator).last;
      if (name.startsWith('$id.json.') && name.endsWith('.tmp')) await entity.delete();
    }
  }

  Future<void> writeMarkdown(TeamState state) async {
    await root.create(recursive: true);
    await File('${root.path}/${state.id}.md').writeAsString(state.toMarkdown(), flush: true);
  }
}
