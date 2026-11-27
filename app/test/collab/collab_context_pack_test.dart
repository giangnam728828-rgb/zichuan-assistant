// 任务上下文检索（方案第一部分 · 场景 A/B/C 的核心）。
//
// 用户先贴一大段方案、仓库地址、执行要求，切到议会/团队后只说「按前面
// 那一大段方案执行」。这里验证：检索能定位到那几条长消息、把它们排进
// 提示词块、留下消息编号，并在预算不够时裁剪而不是把资料整段丢掉。

import 'package:dsh_app/collab/collab_context_pack.dart';
import 'package:flutter_test/flutter_test.dart';

CollabContextMessage _msg(String id, String text, {CollabContextRole role = CollabContextRole.user}) =>
    CollabContextMessage(id: id, text: text, role: role);

String _long(String seed, int chars) {
  final buffer = StringBuffer(seed);
  while (buffer.length < chars) {
    buffer.write('。${seed}要求第 ${buffer.length} 字');
  }
  return buffer.toString();
}

void main() {
  group('CollabContextPack.build', () {
    test('空历史给空包', () {
      final pack = CollabContextPack.build(history: const []);
      expect(pack.isEmpty, isTrue);
      expect(pack.promptBlock, isEmpty);
      expect(pack.sourceMessageIds, isEmpty);
    });

    test('只有短消息时全部进最近几轮，不当资料锚点', () {
      final pack = CollabContextPack.build(
        history: [
          _msg('m1', '你好'),
          _msg('m2', '帮我看看这个项目'),
          _msg('m3', '嗯'),
        ],
      );
      expect(pack.anchors, isEmpty);
      expect(pack.recent.map((m) => m.id), ['m1', 'm2', 'm3']);
      expect(pack.promptBlock, contains('最近几轮'));
      expect(pack.promptBlock, isNot(contains('任务资料')));
    });

    test('早期的长方案成为锚点，当前这句话不重复带上', () {
      final plan = _long('【完整修改方案】', 900);
      final pack = CollabContextPack.build(
        history: [
          _msg('m1', plan),
          _msg('m2', 'https://github.com/giangnam728828-rgb/zichuan-assistant'),
          _msg('m3', '按前面那一大段方案执行'),
        ],
        currentText: '按前面那一大段方案执行',
      );
      expect(pack.anchors.map((m) => m.id), ['m1']);
      expect(pack.recent.map((m) => m.id), ['m2']);
      expect(pack.sourceMessageIds, ['m1', 'm2']);
      final block = pack.promptBlock;
      expect(block, contains('【此前的对话资料】'));
      expect(block, contains('[#m1]'));
      expect(block, contains('【完整修改方案】'));
      expect(block, contains('上面 / 前面 / 刚才'));
      // 当前这句话已经单独作为议题发出，不该在资料里重复一遍。
      expect(block, isNot(contains('按前面那一大段方案执行')));
    });

    test('长消息里挑最长的几条当锚点，最多 maxAnchors 条', () {
      final pack = CollabContextPack.build(
        history: [
          _msg('short', _long('短方案', 300)),
          _msg('longest', _long('最长方案', 2000)),
          _msg('mid', _long('中等方案', 1200)),
          _msg('note', '最近的补充'),
        ],
        maxAnchors: 2,
        maxRecent: 2,
      );
      expect(pack.anchors.map((m) => m.id), ['longest', 'mid']);
    });

    test('预算不够时裁剪单条而不是整段丢弃，并标记 truncated', () {
      final pack = CollabContextPack.build(
        history: [_msg('m1', _long('超长方案', 6000))],
        budget: 1200,
      );
      expect(pack.anchors, hasLength(1));
      expect(pack.anchors.first.text.length, lessThanOrEqualTo(1200));
      expect(pack.truncated, isTrue);
      expect(pack.promptBlock, contains('字已省略'));
    });

    test('助手的长回答不进锚点（资料只取用户给的）', () {
      final pack = CollabContextPack.build(
        history: [
          _msg('a1', _long('助手的分析', 1500), role: CollabContextRole.assistant),
          _msg('u1', '好的，就按这个办'),
        ],
      );
      expect(pack.anchors, isEmpty);
      expect(pack.recent.map((m) => m.id), ['a1', 'u1']);
    });

    test('落盘往返保留锚点、裁剪标记与编号', () {
      final pack = CollabContextPack.build(
        history: [_msg('m1', _long('方案', 800)), _msg('m2', '继续')],
      );
      final restored = CollabContextPack.fromJson(pack.toJson());
      expect(restored.anchors.map((m) => m.id), pack.anchors.map((m) => m.id));
      expect(restored.recent.map((m) => m.id), pack.recent.map((m) => m.id));
      expect(restored.truncated, pack.truncated);
      expect(restored.promptBlock, pack.promptBlock);
    });
  });

  group('collabContextSummary', () {
    test('空包给一句实话', () {
      expect(collabContextSummary(const CollabContextPack()), '没有带上此前的资料');
    });

    test('有锚点和近期消息时分开数', () {
      final pack = CollabContextPack.build(
        history: [_msg('m1', _long('方案', 400)), _msg('m2', '继续')],
      );
      expect(collabContextSummary(pack), contains('1 段资料'));
      expect(collabContextSummary(pack), contains('最近'));
    });
  });
}
