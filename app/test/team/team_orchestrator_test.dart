// C4 团队内核的单元测试：不经过网络与 Flutter，用 Fake 驱动跑群聊编排。
//
// 覆盖：@ 点名定向、无点名全体、会话复用、增量上下文（别人的话补进来、
// 自己的话不重复喂）、失败重试、取消、并发上限、成员维护、落盘往返。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dsh_app/council/collab_models.dart';
import 'package:dsh_app/council/collab_orchestrator.dart';
import 'package:dsh_app/team/team_models.dart';
import 'package:dsh_app/team/team_orchestrator.dart';
import 'package:dsh_app/team/team_store.dart';
import 'package:flutter_test/flutter_test.dart';

enum FakeKind { ok, fail, hang }

final class Script {
  const Script(this.kind, {this.text = '答案', this.failFirst = 0});
  final FakeKind kind;
  final String text;
  final int failFirst;
}

final class FakeDriver implements CollabSessionDriver {
  FakeDriver([Map<String, Script> scripts = const {}]) : scripts = {...scripts};

  /// 队友 id → 剧本；未列出的默认 ok。
  final Map<String, Script> scripts;

  final opened = <SeatSpec>[];
  final prompts = <String, List<String>>{};
  final cancelled = <String>[];

  final _seatOf = <String, String>{};
  final _calls = <String, int>{};
  final _hangs = <String, Completer<TurnOutcome>>{};
  int _sessions = 0;
  int _running = 0;
  int peak = 0;

  @override
  Future<String> openSession(SeatSpec seat, {String? workspaceId}) async {
    opened.add(seat);
    final id = 's${_sessions++}';
    _seatOf[id] = seat.id;
    return id;
  }

  @override
  Future<TurnOutcome> runTurn(String sessionId, String text, {Duration? timeout}) async {
    _running++;
    peak = math.max(peak, _running);
    try {
      final mateId = _seatOf[sessionId] ?? '';
      final script = scripts[mateId] ?? const Script(FakeKind.ok);
      final count = (_calls[mateId] ?? 0) + 1;
      _calls[mateId] = count;
      prompts.putIfAbsent(mateId, () => []).add(text);
      switch (script.kind) {
        case FakeKind.ok:
          await Future<void>.delayed(const Duration(milliseconds: 3));
          if (count <= script.failFirst) {
            return const TurnOutcome(kind: TurnKind.failed, error: '第一次失败');
          }
          return TurnOutcome(kind: TurnKind.completed, text: script.text);
        case FakeKind.fail:
          return const TurnOutcome(kind: TurnKind.failed, error: '供应商报错');
        case FakeKind.hang:
          final hang = Completer<TurnOutcome>();
          _hangs[sessionId] = hang;
          return await hang.future;
      }
    } finally {
      _running--;
    }
  }

  @override
  Future<void> cancel(String sessionId) async {
    cancelled.add(sessionId);
    final hang = _hangs.remove(sessionId);
    if (hang != null && !hang.isCompleted) {
      hang.complete(const TurnOutcome(kind: TurnKind.aborted));
    }
  }
}

Teammate mate(String id, String name, {String brief = ''}) =>
    Teammate(id: id, name: name, brief: brief, provider: 'prov', model: 'mod-$id');

Directory tempDir() => Directory.systemTemp.createTempSync('team_orch');

void main() {
  late Directory dir;
  late TeamStore store;
  late FakeDriver driver;
  late TeamOrchestrator orch;
  var tick = 0;
  var seq = 0;

  void boot({
    Map<String, Script> scripts = const {},
    int maxConcurrency = 3,
    Duration turnTimeout = const Duration(milliseconds: 300),
    Duration Function(int minutes)? wakeInterval,
  }) {
    driver = FakeDriver(scripts);
    orch = TeamOrchestrator(
      driver: driver,
      store: store,
      maxConcurrency: maxConcurrency,
      turnTimeout: turnTimeout,
      newId: () => 'team${seq++}',
      clock: () => DateTime(2026, 3, 1).add(Duration(milliseconds: tick++)),
      pause: (duration) async {},
      wakeInterval: wakeInterval,
    );
  }

  setUp(() {
    dir = tempDir();
    store = TeamStore(dir);
    tick = 0;
    seq = 0;
    boot();
  });

  tearDown(() async {
    await orch.dispose();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('建队', () {
    test('队友名字去重、空名补「队友 N」', () async {
      final team = await orch.create(
        teammates: [
          mate('m1', '阿蓝'),
          mate('m2', ' 阿蓝 '),
          const Teammate(id: 'm3', name: '  ', provider: 'p', model: 'm'),
        ],
      );
      expect(team.teammates.map((m) => m.name).toList(), ['阿蓝', '阿蓝 2', '队友 3']);
      expect(team.rev, 1);
    });

    test('队友数量必须在 2 到 6 之间', () async {
      await expectLater(orch.create(teammates: [mate('m1', '阿蓝')]), throwsArgumentError);
      await expectLater(
        orch.create(teammates: [for (var i = 0; i < 7; i++) mate('m$i', '队友$i')]),
        throwsArgumentError,
      );
    });
  });

  group('发言', () {
    test('没点名：全体都答，每个队友一个独立会话', () async {
      final team = await orch.create(teammates: [mate('m1', '阿蓝'), mate('m2', '阿橙')]);
      final after = await orch.send(team.id, '今天先对一下接口');

      final answers = [
        for (final msg in after.messages)
          if (msg.role == TeamMsgRole.teammate) msg,
      ];
      expect(answers.length, 2);
      expect(answers.map((m) => m.teammateId).toSet(), {'m1', 'm2'});
      expect(driver.opened.length, 2);
      expect(after.sessions.length, 2);
      expect(after.sessions.values.toSet().length, 2, reason: '两个队友不能共用一个会话');
    });

    test('@ 点名：只有被点名的人收到', () async {
      final team = await orch.create(teammates: [mate('m1', '阿蓝'), mate('m2', '阿橙')]);
      final after = await orch.send(team.id, '@阿蓝 你来说说接口怎么定');

      final answers = [
        for (final msg in after.messages)
          if (msg.role == TeamMsgRole.teammate) msg,
      ];
      expect(answers.length, 1);
      expect(answers.single.teammateId, 'm1');
      expect(driver.opened.map((s) => s.id).toList(), ['m1']);
      expect(driver.prompts.containsKey('m2'), isFalse);
      expect(after.sessions.containsKey('m2'), isFalse);
    });

    test('连续点名两个人：两个都收到', () async {
      final team = await orch.create(teammates: [mate('m1', '阿蓝'), mate('m2', '阿橙'), mate('m3', '小绿')]);
      final after = await orch.send(team.id, '@阿蓝 @阿橙 一起看下这个方案');

      expect(after.sessions.keys.toSet(), {'m1', 'm2'});
      expect(driver.prompts.containsKey('m3'), isFalse);
    });

    test('会话复用：第二次发言不再新开会话', () async {
      final team = await orch.create(teammates: [mate('m1', '阿蓝'), mate('m2', '阿橙')]);
      await orch.send(team.id, '第一句');
      final openedAfterFirst = driver.opened.length;
      final sessionsAfterFirst = {...(await orch.load(team.id))!.sessions};

      await orch.send(team.id, '第二句');
      expect(driver.opened.length, openedAfterFirst);
      expect((await orch.load(team.id))!.sessions, sessionsAfterFirst);
      expect(driver.prompts['m1']!.length, 2);
    });

    test('增量上下文：别人的话补进来，自己的话不重复喂', () async {
      boot(
        scripts: {
          'm1': const Script(FakeKind.ok, text: '接口这么定：GET /x'),
          'm2': const Script(FakeKind.ok, text: '好，我按这个写'),
        },
      );
      final team = await orch.create(teammates: [mate('m1', '阿蓝'), mate('m2', '阿橙')]);

      await orch.send(team.id, '@阿蓝 你先定接口');
      // 第一次发言时群里还没有别人的话，提示词里不该有背景段。
      expect(driver.prompts['m1']!.first, isNot(contains('群里刚发生的事')));
      expect(driver.prompts['m1']!.first, contains('【现在需要你回应】'));
      expect(driver.prompts['m1']!.first, contains('你先定接口'));

      await orch.send(team.id, '@阿橙 你照着接口写');
      await orch.send(team.id, '@阿蓝 阿橙写完了吗');

      final last = driver.prompts['m1']!.last;
      expect(last, contains('群里刚发生的事'));
      expect(last, contains('阿橙：好，我按这个写'), reason: '别的队友的发言要补进来');
      expect(last, isNot(contains('接口这么定')), reason: '自己说过的话在会话里，不重复喂');
      expect(last, contains('阿橙写完了吗'));
    });

    test('自己的角色与别人的角色都写进提示词', () async {
      final team = await orch.create(
        teammates: [mate('m1', '阿蓝', brief: '负责前端'), mate('m2', '阿橙', brief: '负责后端')],
      );
      await orch.send(team.id, '@阿蓝 开始吧');
      final prompt = driver.prompts['m1']!.single;
      expect(prompt, contains('你是团队里的「阿蓝」'));
      expect(prompt, contains('你的角色：负责前端'));
      expect(prompt, contains('阿橙（负责后端）'));
    });
  });

  group('失败与并发', () {
    test('失败重试一次后成功：只留一条正常答复', () async {
      boot(scripts: {'m1': const Script(FakeKind.ok, text: '终于答上了', failFirst: 1)});
      final team = await orch.create(teammates: [mate('m1', '阿蓝'), mate('m2', '阿橙')]);
      final after = await orch.send(team.id, '@阿蓝 在吗');

      final answers = [
        for (final msg in after.messages)
          if (msg.role == TeamMsgRole.teammate) msg,
      ];
      expect(answers.length, 1);
      expect(answers.single.text, '终于答上了');
      expect(answers.single.failed, isFalse);
      expect(driver.prompts['m1']!.length, 2);
    });

    test('两次都失败：留一条失败标记的消息', () async {
      boot(scripts: {'m1': const Script(FakeKind.fail)});
      final team = await orch.create(teammates: [mate('m1', '阿蓝'), mate('m2', '阿橙')]);
      final after = await orch.send(team.id, '@阿蓝 在吗');

      final answers = [
        for (final msg in after.messages)
          if (msg.role == TeamMsgRole.teammate) msg,
      ];
      expect(answers.length, 1);
      expect(answers.single.failed, isTrue);
      expect(answers.single.text, contains('供应商报错'));
      expect(driver.prompts['m1']!.length, 2);
    });

    test('一个队友失败不影响其他人', () async {
      boot(scripts: {'m1': const Script(FakeKind.fail)});
      final team = await orch.create(teammates: [mate('m1', '阿蓝'), mate('m2', '阿橙')]);
      final after = await orch.send(team.id, '都说说');

      final answers = [
        for (final msg in after.messages)
          if (msg.role == TeamMsgRole.teammate) msg,
      ];
      expect(answers.length, 2);
      expect(answers.firstWhere((m) => m.teammateId == 'm1').failed, isTrue);
      expect(answers.firstWhere((m) => m.teammateId == 'm2').failed, isFalse);
    });

    test('并发上限：5 个队友最多 2 个同时在飞', () async {
      boot(maxConcurrency: 2);
      final team = await orch.create(teammates: [for (var i = 1; i <= 5; i++) mate('m$i', '队友$i')]);
      final after = await orch.send(team.id, '各自报一下进度');

      expect(after.sessions.length, 5);
      expect(driver.peak, lessThanOrEqualTo(2));
    });

    test('取消：停下在飞的会话，群里留提示，不落半截答复', () async {
      boot(scripts: {'m1': const Script(FakeKind.hang), 'm2': const Script(FakeKind.hang)});
      final team = await orch.create(teammates: [mate('m1', '阿蓝'), mate('m2', '阿橙')]);

      final sending = orch.send(team.id, '一起想个名字');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await orch.cancel(team.id);
      await sending;

      final after = (await orch.load(team.id))!;
      expect(driver.cancelled, isNotEmpty);
      expect(
        [for (final msg in after.messages) if (msg.role == TeamMsgRole.system) msg.text],
        contains('已停止这一轮。'),
      );
      expect(after.messages.where((m) => m.role == TeamMsgRole.teammate), isEmpty);
    });

    test('取消之后还能继续发言', () async {
      boot(scripts: {'m1': const Script(FakeKind.hang)});
      final team = await orch.create(teammates: [mate('m1', '阿蓝'), mate('m2', '阿橙')]);
      final sending = orch.send(team.id, '@阿蓝 先想');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await orch.cancel(team.id);
      await sending;

      driver.scripts['m1'] = const Script(FakeKind.ok, text: '想好了');
      final after = await orch.send(team.id, '@阿蓝 继续');
      expect(after.messages.last.text, '想好了');
      expect(after.messages.last.failed, isFalse);
    });
  });

  group('成员维护', () {
    test('加队友到 6 个就封顶', () async {
      final team = await orch.create(teammates: [mate('m1', 'A'), mate('m2', 'B')]);
      for (var i = 3; i <= 6; i++) {
        await orch.addMate(team.id, mate('m$i', '队友$i'));
      }
      await expectLater(orch.addMate(team.id, mate('m7', '多余')), throwsStateError);
    });

    test('移除队友：清掉会话与游标，群里留一句', () async {
      final team = await orch.create(teammates: [mate('m1', '阿蓝'), mate('m2', '阿橙')]);
      await orch.send(team.id, '都在吗');
      expect((await orch.load(team.id))!.sessions.length, 2);

      final after = await orch.removeMate(team.id, 'm1');
      expect(after.teammates.map((m) => m.id).toList(), ['m2']);
      expect(after.sessions.containsKey('m1'), isFalse);
      expect(after.cursors.containsKey('m1'), isFalse);
      expect(after.messages.last.text, contains('离开了团队'));
    });

    test('改队友信息：重名直接报错', () async {
      final team = await orch.create(teammates: [mate('m1', '阿蓝'), mate('m2', '阿橙')]);
      await expectLater(
        orch.updateMate(team.id, mate('m2', '阿蓝')),
        throwsArgumentError,
      );
      final after = await orch.updateMate(team.id, mate('m2', '阿橙', brief: '负责后端'));
      expect(after.mate('m2')!.brief, '负责后端');
    });
  });

  group('持久化', () {
    test('落盘往返：会话、游标、消息都在', () async {
      final team = await orch.create(teammates: [mate('m1', '阿蓝'), mate('m2', '阿橙')]);
      await orch.send(team.id, '@阿蓝 在吗');

      final reloaded = await store.load(team.id);
      expect(reloaded, isNotNull);
      expect(reloaded!.sessions['m1'], isNotNull);
      expect(reloaded.mateBySession(reloaded.sessions['m1']!)?.name, '阿蓝');
      expect(reloaded.cursors['m1'], greaterThan(0));
      expect(reloaded.messages.length, 2);
      expect(reloaded.toJson().keys, containsAll(['id', 'teammates', 'sessions', 'cursors', 'messages']));
    });

    test('未知字段不炸（向后兼容）', () {
      final json = {
        'id': 't1',
        'teammates': [
          {'id': 'm1', 'name': '阿蓝', 'provider': 'p', 'model': 'm', 'futureField': true},
        ],
        'sessions': {'m1': 's1'},
        'cursors': {'m1': 3},
        'messages': <Object?>[],
        'createdAt': '2026-03-01T00:00:00.000',
        'updatedAt': '2026-03-01T00:00:00.000',
        'rev': 2,
        'unknown': 'x',
      };
      final state = TeamState.fromJson(json);
      expect(state.rev, 2);
      expect(state.cursors['m1'], 3);
      expect(state.mateBySession('s1')?.name, '阿蓝');
      expect(jsonEncode(state.toJson()), isNot(contains('unknown')));
      // 队友预设（决定工具，如联网）跟着队友一起落盘。
      final withPreset = TeamState.fromJson({
        ...json,
        'teammates': [
          {'id': 'm1', 'name': '阿蓝', 'provider': 'p', 'model': 'm', 'agentPreset': 'research'},
        ],
      });
      expect(withPreset.mate('m1')!.agentPreset, 'research');
    });

    test('导出 Markdown：按发言人分节', () async {
      final team = await orch.create(teammates: [mate('m1', '阿蓝'), mate('m2', '阿橙')]);
      final after = await orch.send(team.id, '@阿蓝 在吗');
      final markdown = after.toMarkdown();
      expect(markdown, contains('**我**：'));
      expect(markdown, contains('**阿蓝**：'));

      await store.writeMarkdown(after);
      final file = File('${dir.path}/${team.id}.md');
      expect(file.existsSync(), isTrue);
      expect(await file.readAsString(), contains('阿蓝'));
    });

    test('最近更新的团队排在前面', () async {
      final older = await orch.create(teammates: [mate('m1', 'A'), mate('m2', 'B')]);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final newer = await orch.create(teammates: [mate('m1', 'C'), mate('m2', 'D')]);
      await orch.send(newer.id, '说句话');

      final all = await orch.list();
      expect(all.first.id, newer.id);
      expect(all.last.id, older.id);
      expect((await orch.latest())!.id, newer.id);
    });
  });

  group('@ 解析', () {
    test('多个点名、无点名、前缀不完整', () {
      final mates = [mate('m1', '阿蓝'), mate('m2', '阿橙')];

      final both = parseMentions(mates, '@阿蓝 @阿橙 一起看下');
      expect(both.targets.map((m) => m.name).toList(), ['阿蓝', '阿橙']);
      expect(both.text, '一起看下');

      final none = parseMentions(mates, '你们都在吗');
      expect(none.targets, isEmpty);
      expect(none.text, '你们都在吗');

      // 「@阿蓝蓝」不该命中「阿蓝」。
      final wrong = parseMentions(mates, '@阿蓝蓝 你好');
      expect(wrong.targets, isEmpty);
      expect(wrong.text, '@阿蓝蓝 你好');
    });

    test('点名后接中文逗号也能剥开', () {
      final mates = [mate('m1', '阿蓝')];
      final parsed = parseMentions(mates, '@阿蓝，你说');
      expect(parsed.targets.single.name, '阿蓝');
      expect(parsed.text, '你说');
    });
  });

  group('主管', () {
    test('设了主管：不点名时只有主管接活', () async {
      final team = await orch.create(
        teammates: [mate('m1', '阿蓝'), mate('m2', '阿橙')],
        leadId: 'm1',
      );
      expect(team.lead?.name, '阿蓝');

      final after = await orch.send(team.id, '这周做什么');
      final replies = after.messages.where((m) => m.role == TeamMsgRole.teammate).toList();
      expect(replies.length, 1);
      expect(replies.single.teammateId, 'm1');
      expect(driver.prompts.containsKey('m2'), isFalse);
    });

    test('主管在答复里 @ 人：被点名的人接着答一轮', () async {
      boot(scripts: {
        'm1': const Script(FakeKind.ok, text: '我先分一下：@阿橙 你去看接口'),
        'm2': const Script(FakeKind.ok, text: '接口看过了，没问题'),
      });
      final team = await orch.create(
        teammates: [mate('m1', '阿蓝'), mate('m2', '阿橙')],
        leadId: 'm1',
      );
      final after = await orch.send(team.id, '这周做什么');

      final replies = after.messages.where((m) => m.role == TeamMsgRole.teammate).toList();
      expect(replies.map((m) => m.teammateId).toList(), ['m1', 'm2']);
      // 被分派的人能在提示词里看到主管的原话。
      expect(driver.prompts['m2']!.single, contains('@阿橙 你去看接口'));
    });

    test('主管自己 @ 自己不会把自己再跑一遍', () async {
      boot(scripts: {
        'm1': const Script(FakeKind.ok, text: '我来做。@阿蓝 记一下'),
      });
      final team = await orch.create(
        teammates: [mate('m1', '阿蓝'), mate('m2', '阿橙')],
        leadId: 'm1',
      );
      final after = await orch.send(team.id, '这周做什么');
      expect(after.messages.where((m) => m.role == TeamMsgRole.teammate).length, 1);
    });

    test('移除主管：主管位空出来，下一条回到全员作答', () async {
      final team = await orch.create(
        teammates: [mate('m1', '阿蓝'), mate('m2', '阿橙')],
        leadId: 'm1',
      );
      final left = await orch.removeMate(team.id, 'm1');
      expect(left.lead, isNull);
      expect(left.messages.last.text, contains('主管一职空了出来'));

      final after = await orch.send(team.id, '还在吗');
      expect(after.messages.where((m) => m.role == TeamMsgRole.teammate).length, 1);
    });

    test('setLead 可设可撤；指定不在队里的人报错', () async {
      final team = await orch.create(teammates: [mate('m1', '阿蓝'), mate('m2', '阿橙')]);
      expect(team.lead, isNull);

      final set = await orch.setLead(team.id, 'm2');
      expect(set.lead?.id, 'm2');

      final cleared = await orch.setLead(team.id, null);
      expect(cleared.lead, isNull);

      await expectLater(orch.setLead(team.id, 'nope'), throwsArgumentError);
    });

    test('建队时指定了不存在的主管：报错', () async {
      await expectLater(
        orch.create(teammates: [mate('m1', '阿蓝'), mate('m2', '阿橙')], leadId: 'ghost'),
        throwsArgumentError,
      );
    });
  });

  group('移交', () {
    test('答复末尾「移交 @名字」：落一张移交卡，下一位接着答', () async {
      boot(scripts: {
        'm1': const Script(FakeKind.ok, text: '前端我改完了。\n移交 @阿橙'),
        'm2': const Script(FakeKind.ok, text: '收到，我来跑测试'),
      });
      final team = await orch.create(teammates: [mate('m1', '阿蓝'), mate('m2', '阿橙')]);
      final after = await orch.send(team.id, '@阿蓝 改一下登录页');

      final fromBlue = after.messages.firstWhere((m) => m.teammateId == 'm1');
      expect(fromBlue.handoffTo, 'm2');
      // 移交那一行从正文里去掉，界面上靠卡片表达。
      expect(fromBlue.text, '前端我改完了。');

      final fromOrange = after.messages.firstWhere((m) => m.teammateId == 'm2');
      expect(fromOrange.text, '收到，我来跑测试');
      // 接手的人在提示词里能看到「这件事交给你了」。
      expect(driver.prompts['m2']!.single, contains('【这件事交给你了】'));
    });

    test('正文中间提到「交给阿橙」不算移交', () async {
      boot(scripts: {
        'm1': const Script(FakeKind.ok, text: '这块以前交给阿橙做过，你可以问他。\n还有别的问题吗'),
      });
      final team = await orch.create(teammates: [mate('m1', '阿蓝'), mate('m2', '阿橙')]);
      final after = await orch.send(team.id, '@阿蓝 登录页谁熟');

      final fromBlue = after.messages.firstWhere((m) => m.teammateId == 'm1');
      expect(fromBlue.handoffTo, isNull);
      expect(driver.prompts.containsKey('m2'), isFalse);
    });

    test('移交给不认识的名字：当作普通答复', () async {
      boot(scripts: {'m1': const Script(FakeKind.ok, text: '做完了。\n移交 @查无此人')});
      final team = await orch.create(teammates: [mate('m1', '阿蓝'), mate('m2', '阿橙')]);
      final after = await orch.send(team.id, '@阿蓝 干点活');
      expect(after.messages.firstWhere((m) => m.teammateId == 'm1').handoffTo, isNull);
    });

    test('互相推诿：同一个人一轮只跑一次，不会无限循环', () async {
      boot(scripts: {
        'm1': const Script(FakeKind.ok, text: '我不太会。\n移交 @阿橙'),
        'm2': const Script(FakeKind.ok, text: '我也不会。\n移交 @阿蓝'),
      });
      final team = await orch.create(teammates: [mate('m1', '阿蓝'), mate('m2', '阿橙')]);
      final after = await orch.send(team.id, '@阿蓝 你来');

      // m1 答 → 移交 m2 → m2 答 → 想交回 m1，但 m1 这一轮已答过，不再重复。
      final replies = after.messages.where((m) => m.role == TeamMsgRole.teammate).toList();
      expect(replies.map((m) => m.teammateId).toList(), ['m1', 'm2']);
      expect(driver.prompts['m1']!.length, 1);
    });

    test('移交卡能落盘并读回来', () async {
      boot(scripts: {'m1': const Script(FakeKind.ok, text: '做完了。\n移交 @阿橙')});
      final team = await orch.create(teammates: [mate('m1', '阿蓝'), mate('m2', '阿橙')]);
      final after = await orch.send(team.id, '@阿蓝 干活');
      final saved = await TeamStore(dir).load(after.id);
      expect(saved!.messages.firstWhere((m) => m.teammateId == 'm1').handoffTo, 'm2');
      expect(saved.leadId, isNull);
    });
  });

  group('移交解析', () {
    test('三种写法都认：移交 / 交给 / 转交，带不带 @ 都行', () {
      final mates = [mate('m1', '阿蓝'), mate('m2', '阿橙')];
      for (final line in ['移交 @阿橙', '交给：阿橙', '转交阿橙', '移交: @阿橙。']) {
        final parsed = parseHandoff(mates, '前面的话\n$line');
        expect(parsed.toId, 'm2', reason: line);
        expect(parsed.text, '前面的话', reason: line);
      }
    });

    test('只在最后两行找：更早的行不算', () {
      final mates = [mate('m1', '阿蓝'), mate('m2', '阿橙')];
      final parsed = parseHandoff(mates, '移交 @阿橙\n第一行正文\n第二行正文');
      expect(parsed.toId, isNull);
    });

    test('parseAssignments 扫全文并排除自己；名字要有边界', () {
      final mates = [mate('m1', '阿蓝'), mate('m2', '阿橙')];
      final got = parseAssignments(mates, '@阿橙 看接口，@阿蓝 别忙了', exceptId: 'm1');
      expect(got.map((m) => m.name).toList(), ['阿橙']);
      expect(parseAssignments(mates, '@阿橙橙 你好'), isEmpty);
    });
  });

  group('写权限', () {
    test('只读顾问：提示词里明确不许动手，且不占写锁', () async {
      final team = await orch.create(
        teammates: [
          mate('m1', '阿蓝'),
          Teammate(
            id: 'm2',
            name: '阿橙',
            provider: 'p',
            model: 'm',
            readOnly: true,
          ),
        ],
      );
      await orch.send(team.id, '一起看看这个方案');

      expect(driver.prompts['m2']!.single, contains('只读顾问'));
      expect(driver.prompts['m2']!.single, contains('不要修改文件'));
      expect(driver.prompts['m1']!.single, isNot(contains('只读顾问')));
    });

    test('两位可写队友排队：同一时刻只有一个在飞', () async {
      boot(scripts: {
        'm1': const Script(FakeKind.ok),
        'm2': const Script(FakeKind.ok),
      });
      final team = await orch.create(teammates: [mate('m1', '阿蓝'), mate('m2', '阿橙')]);
      await orch.send(team.id, '各改一个文件');

      expect(driver.peak, 1);
    });

    test('关掉互斥：可写队友回到并发跑', () async {
      boot(maxConcurrency: 3, scripts: {
        'm1': const Script(FakeKind.ok),
        'm2': const Script(FakeKind.ok),
      });
      final team = await orch.create(teammates: [mate('m1', '阿蓝'), mate('m2', '阿橙')]);
      await orch.setExclusiveWrite(team.id, false);
      await orch.send(team.id, '各改一个文件');

      expect(driver.peak, greaterThan(1));
    });

    test('只读 + 可写可以并行：只读的不抢写锁', () async {
      boot(scripts: {
        'm1': const Script(FakeKind.ok),
        'm2': const Script(FakeKind.ok),
        'm3': const Script(FakeKind.ok),
      });
      final team = await orch.create(
        teammates: [
          mate('m1', '阿蓝'),
          Teammate(id: 'm2', name: '阿橙', provider: 'p', model: 'm', readOnly: true),
          Teammate(id: 'm3', name: '阿绿', provider: 'p', model: 'm', readOnly: true),
        ],
      );
      await orch.send(team.id, '先说思路');

      // 两位只读顾问同时跑，可写那位不论排在哪边都不该把并发压到 1。
      expect(driver.peak, greaterThan(1));
    });

    test('只读标记能落盘读回来', () async {
      final team = await orch.create(
        teammates: [
          mate('m1', '阿蓝'),
          Teammate(id: 'm2', name: '阿橙', provider: 'p', model: 'm', readOnly: true),
        ],
      );
      final saved = await TeamStore(dir).load(team.id);
      expect(saved!.mate('m2')!.readOnly, isTrue);
      expect(saved.mate('m1')!.readOnly, isFalse);
    });
  });

  group('定时唤醒', () {
    test('到点自动在群里发一句，队友接着答', () async {
      boot(wakeInterval: (_) => const Duration(milliseconds: 25));
      final team = await orch.create(teammates: [mate('m1', '阿蓝'), mate('m2', '阿橙')]);
      final woke = await orch.setWake(team.id, 1);
      expect(woke.wakeMinutes, 1);

      // 等两拍，至少催过一次。
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final after = (await orch.load(team.id))!;
      final wakes = after.messages.where((m) => m.role == TeamMsgRole.user).toList();
      expect(wakes, isNotEmpty);
      expect(wakes.first.text, TeamState.defaultWakePrompt);
    });

    test('关掉唤醒之后不再发', () async {
      boot(wakeInterval: (_) => const Duration(milliseconds: 25));
      final team = await orch.create(teammates: [mate('m1', '阿蓝'), mate('m2', '阿橙')]);
      await orch.setWake(team.id, 1);
      await orch.setWake(team.id, null);
      await Future<void>.delayed(const Duration(milliseconds: 120));

      final after = (await orch.load(team.id))!;
      expect(after.messages.where((m) => m.role == TeamMsgRole.user), isEmpty);
      expect(after.wakeMinutes, isNull);
    });

    test('间隔越界直接拒绝', () async {
      final team = await orch.create(teammates: [mate('m1', '阿蓝'), mate('m2', '阿橙')]);
      await expectLater(orch.setWake(team.id, 0), throwsArgumentError);
      await expectLater(orch.setWake(team.id, 24 * 60 + 1), throwsArgumentError);
    });

    test('唤醒配置落盘，重开编排器后接着催', () async {
      boot(wakeInterval: (_) => const Duration(milliseconds: 25));
      final team = await orch.create(teammates: [mate('m1', '阿蓝'), mate('m2', '阿橙')]);
      await orch.setWake(team.id, 1, wakePrompt: '进度如何');
      await orch.dispose();

      // 新的编排器（模拟进程重启）从盘上读，定时器要自己接上。
      boot(wakeInterval: (_) => const Duration(milliseconds: 25));
      final restored = await orch.load(team.id);
      expect(restored!.wakeMinutes, 1);
      expect(restored.wakePrompt, '进度如何');

      await Future<void>.delayed(const Duration(milliseconds: 120));
      final after = (await orch.load(team.id))!;
      expect(
        after.messages.where((m) => m.role == TeamMsgRole.user).map((m) => m.text),
        contains('进度如何'),
      );
    });
  });

  group('进度', () {
    test('跑的时候记着谁在跑，跑完擦掉', () async {
      boot(scripts: {'m1': const Script(FakeKind.hang)});
      final team = await orch.create(teammates: [mate('m1', '阿蓝'), mate('m2', '阿橙')]);

      final sending = orch.send(team.id, '@阿蓝 先想');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final during = (await orch.load(team.id))!;
      expect(during.running, ['m1']);

      await orch.cancel(team.id);
      await sending;
      final after = (await orch.load(team.id))!;
      expect(after.running, isEmpty);
    });

    test('盘上的「正在跑」是上次进程的残影：load 时擦掉', () async {
      final team = await orch.create(teammates: [mate('m1', '阿蓝'), mate('m2', '阿橙')]);
      // 模拟上次进程在跑时被杀：直接往盘上写 running。
      await store.save(team.copyWith(running: ['m1']));

      await orch.dispose();
      boot(); // 新编排器：内存里没有一轮在跑
      final restored = await orch.load(team.id);
      expect(restored!.running, isEmpty);
      // 擦除也要落盘，下次读盘不会又冒出来。
      expect((await store.load(team.id))!.running, isEmpty);
    });

    test('running 随状态 JSON 往返', () {
      final state = TeamState(
        id: 't1',
        teammates: [mate('m1', '阿蓝'), mate('m2', '阿橙')],
        running: const ['m2', 'm1'],
        createdAt: DateTime(2026, 3, 1),
        updatedAt: DateTime(2026, 3, 1),
      );
      expect(TeamState.fromJson(state.toJson()).running, ['m2', 'm1']);
    });
  });
}
