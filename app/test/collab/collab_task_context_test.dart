// 任务上下文包（方案第一部分 · 3.3）：提取、序列化、落盘、阶段推进。
//
// 这一层的意义是「接得上」：用户隔一天说「继续完成剩下的」，系统要知道
// 目标是什么、仓库/分支在哪、谁负责、哪几步做完了。

import 'dart:io';

import 'package:dsh_app/collab/collab_context_pack.dart';
import 'package:dsh_app/collab/collab_task_context.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CollabTaskFacts：从资料里提取事实', () {
    test('完整 URL 取 owner/repo，去掉 .git', () {
      expect(
        CollabTaskFacts.repo('仓库：https://github.com/giangnam728828-rgb/zichuan-assistant.git'),
        'giangnam728828-rgb/zichuan-assistant',
      );
    });

    test('owner/repo 形式也认，但不把路径/版本号当仓库', () {
      expect(CollabTaskFacts.repo('目标仓库 giangnam728828-rgb/zichuan-assistant 分支 ui-chuan-shui'),
          'giangnam728828-rgb/zichuan-assistant');
      expect(CollabTaskFacts.repo('见 docs/guide 里的说明'), isNull);
      expect(CollabTaskFacts.repo('版本 1.2.3'), isNull);
    });

    test('分支：中文、英文、命令行三种写法', () {
      expect(CollabTaskFacts.branch('分支：ui-chuan-shui'), 'ui-chuan-shui');
      expect(CollabTaskFacts.branch('branch = release/2.1'), 'release/2.1');
      expect(CollabTaskFacts.branch('git push --branch feature-x'), 'feature-x');
      expect(CollabTaskFacts.branch('分支是什么？'), isNull);
    });

    test('凭据只留引用，绝不带明文', () {
      expect(CollabTaskFacts.credentialRef('用这个 ghp_abcdefghijklmnop 提交'), 'github.token');
      expect(CollabTaskFacts.credentialRef('GitHub token 已经配好了'), 'github.token');
      expect(CollabTaskFacts.credentialRef('没有凭据'), isNull);
    });

    test('scan 一次取三项', () {
      final facts = CollabTaskFacts.scan(
        '按方案改 https://github.com/a/b 分支 dev，token 用 ghp_1234567890123456',
      );
      expect(facts.repo, 'a/b');
      expect(facts.branch, 'dev');
      expect(facts.credentialRef, 'github.token');
    });
  });

  group('collabTaskFromPack', () {
    test('目标、资料编号、仓库、分支、成员都落到上下文里', () {
      final pack = CollabContextPack.build(
        history: [
          CollabContextMessage(
            id: 'm1',
            text: '【方案】把输入栏挡住的内容修掉。仓库 https://github.com/giangnam728828-rgb/zichuan-assistant 分支 ui-chuan-shui，'
                '${'细节' * 120}',
            role: CollabContextRole.user,
          ),
          CollabContextMessage(id: 'm2', text: '按上面执行', role: CollabContextRole.user),
        ],
        currentText: '按上面执行',
      );
      final task = collabTaskFromPack(
        id: 'r1',
        conversationId: 'c1',
        kind: 'council',
        goal: '按上面执行',
        pack: pack,
        memberIds: const ['seat0', 'seat1'],
      );
      expect(task.goal, '按上面执行');
      expect(task.sourceMessageIds, ['m1']);
      expect(task.repo, 'giangnam728828-rgb/zichuan-assistant');
      expect(task.branch, 'ui-chuan-shui');
      expect(task.memberIds, ['seat0', 'seat1']);
      expect(task.stage, CollabTaskStage.planning);
    });

    test('没有资料时字段留空，不猜', () {
      final task = collabTaskFromPack(
        id: 'r2',
        conversationId: 'c2',
        kind: 'team',
        goal: '把首页调一下',
        pack: const CollabContextPack(),
      );
      expect(task.repo, isNull);
      expect(task.branch, isNull);
      expect(task.credentialRef, isNull);
      expect(task.sourceMessageIds, isEmpty);
    });
  });

  group('序列化与落盘', () {
    test('JSON 往返保留每一项', () {
      final task = CollabTaskContext(
        id: 'r1',
        conversationId: 'c1',
        kind: 'team',
        goal: '修输入栏',
        sourceMessageIds: const ['m1', 'm2'],
        repo: 'a/b',
        branch: 'dev',
        credentialRef: 'github.token',
        memberIds: const ['m1', 'm2'],
        items: const [
          CollabTaskItem(id: 't1', title: '改布局', owner: '队友甲', deps: [], status: CollabTaskStage.done, result: '已改'),
          CollabTaskItem(id: 't2', title: '补测试', owner: '队友乙', deps: ['t1']),
        ],
        stage: CollabTaskStage.running,
        currentStep: '任务图 1/2',
        done: const ['改布局'],
        pending: const ['补测试'],
        testStatus: '未跑',
        buildStatus: '未构建',
        result: '输入栏不再遮挡',
        createdAt: DateTime(2026, 11, 27, 10),
        updatedAt: DateTime(2026, 11, 27, 11),
        rev: 3,
      );
      final back = CollabTaskContext.fromJson(task.toJson());
      expect(back.id, 'r1');
      expect(back.goal, '修输入栏');
      expect(back.sourceMessageIds, ['m1', 'm2']);
      expect(back.repo, 'a/b');
      expect(back.branch, 'dev');
      expect(back.credentialRef, 'github.token');
      expect(back.items.map((i) => i.id), ['t1', 't2']);
      expect(back.items.first.status, CollabTaskStage.done);
      expect(back.items.last.deps, ['t1']);
      expect(back.stage, CollabTaskStage.running);
      expect(back.testStatus, '未跑');
      expect(back.rev, 3);
      expect(back.progressLabel, '进行中 · 1/2');
    });

    test('坏 JSON 不炸：认不出的阶段退回 planning', () {
      final back = CollabTaskContext.fromJson({'id': 'x', 'stage': 'nonsense', 'items': 'oops'});
      expect(back.stage, CollabTaskStage.planning);
      expect(back.items, isEmpty);
    });

    test('落盘往返：save → list → load → delete', () async {
      final dir = Directory.systemTemp.createTempSync('collab-task');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final store = CollabTaskStore(dir);
      final at = DateTime(2026, 11, 27, 12);
      final task = CollabTaskContext(
        id: 'r1',
        conversationId: 'c1',
        kind: 'council',
        goal: '按方案执行',
        repo: 'a/b',
        createdAt: at,
        updatedAt: at,
      );
      await store.save(task);
      final listed = await store.list();
      expect(listed, hasLength(1));
      expect(listed.single.goal, '按方案执行');
      final loaded = await store.load('r1');
      expect(loaded, isNotNull);
      expect(loaded!.repo, 'a/b');
      await store.delete('r1');
      expect(await store.load('r1'), isNull);
      expect(await store.list(), isEmpty);
    });
  });

  group('发送前自检（错误分类）', () {
    test('指代「上面」但这次对话没有资料：拦下并说清楚', () {
      final pre = collabTaskPreflight(goal: '按前面那一大段方案执行', pack: const CollabContextPack());
      expect(pre.blocking, isNotNull);
      expect(pre.blocking, contains('另一条聊天'));
    });

    test('指代且有资料：放行', () {
      final pack = CollabContextPack.build(
        history: [CollabContextMessage(id: 'm1', text: '${'方案' * 200}', role: CollabContextRole.user)],
      );
      final pre = collabTaskPreflight(goal: '按前面那个方案做', pack: pack);
      expect(pre.blocking, isNull);
    });

    test('要提交但没有仓库：不拦，但提醒', () {
      final pre = collabTaskPreflight(goal: '改完提交到 GitHub 并构建', pack: const CollabContextPack());
      expect(pre.blocking, isNull);
      expect(pre.notes.join(), contains('没找到目标仓库'));
    });

    test('有仓库但没有凭据：提醒权限风险', () {
      final pre = collabTaskPreflight(
        goal: '提交并构建 APK',
        pack: const CollabContextPack(),
        repo: 'owner/repo',
      );
      expect(pre.notes.join(), contains('凭据'));
    });

    test('只是句子里带了「之前」：不拦（这条曾把普通提问挡掉）', () {
      final pre = collabTaskPreflight(goal: '切走之前的那一问', pack: const CollabContextPack());
      expect(pre.blocking, isNull);
    });

    test('指代 + 要动作 + 短句才拦；长句自带上下文不拦', () {
      final long = '按前面那一大段方案执行，同时注意 ${'细节' * 40}';
      expect(collabTaskPreflight(goal: long, pack: const CollabContextPack()).blocking, isNull);
      expect(
        collabTaskPreflight(goal: '照上面的方案改', pack: const CollabContextPack()).blocking,
        isNotNull,
      );
    });

    test('普通提问：既无拦阻也无提醒', () {
      final pre = collabTaskPreflight(goal: '解释一下这段代码', pack: const CollabContextPack());
      expect(pre.isEmpty, isTrue);
    });
  });

  group('资料摘录（通过编号找回原文）', () {
    test('最多 3 条、每条 200 字，令牌被抹掉', () {
      final long = '第一步改布局。' * 100;
      final pack = CollabContextPack.build(
        history: [
          CollabContextMessage(id: 'm1', text: long, role: CollabContextRole.user),
          CollabContextMessage(id: 'm2', text: '用 ghp_abcdefghijklmnopqrst 提交', role: CollabContextRole.user),
          CollabContextMessage(id: 'm3', text: '分支 dev', role: CollabContextRole.user),
          CollabContextMessage(id: 'm4', text: '第四条不该进', role: CollabContextRole.user),
        ],
      );
      final excerpts = collabTaskExcerpts(pack);
      expect(excerpts.length, lessThanOrEqualTo(3));
      expect(excerpts['m1']!.length, lessThanOrEqualTo(201));
      expect(excerpts.values.join(), isNot(contains('ghp_')));
      expect(excerpts.values.join(), contains('<已隐去>'));
    });

    test('落盘往返保留摘录', () {
      final task = CollabTaskContext(
        id: 'r1',
        conversationId: 'c1',
        kind: 'council',
        goal: 'g',
        excerpts: const {'m1': '原文摘录'},
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      );
      expect(CollabTaskContext.fromJson(task.toJson()).excerpts, {'m1': '原文摘录'});
    });
  });

  group('阶段语义', () {
    test('终态只有 done / failed / cancelled', () {
      expect(CollabTaskStage.done.isTerminal, isTrue);
      expect(CollabTaskStage.failed.isTerminal, isTrue);
      expect(CollabTaskStage.cancelled.isTerminal, isTrue);
      expect(CollabTaskStage.running.isTerminal, isFalse);
      expect(CollabTaskStage.testing.isTerminal, isFalse);
      expect(CollabTaskStage.building.isTerminal, isFalse);
      expect(CollabTaskStage.waiting.isTerminal, isFalse);
    });

    test('任务项 isOpen 跟随状态', () {
      const open = CollabTaskItem(id: 'a', title: 'x');
      const closed = CollabTaskItem(id: 'b', title: 'y', status: CollabTaskStage.done);
      expect(open.isOpen, isTrue);
      expect(closed.isOpen, isFalse);
      final context = CollabTaskContext(
        id: 'x',
        conversationId: 'c',
        kind: 'team',
        goal: '',
        items: const [open, closed],
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      );
      expect(context.openCount, 1);
    });
  });
}
