// 默认顺序回答（方案第四部分 · P1）。
//
// 议会默认按席位顺序作答：上一位说完，下一位才开口；同一时刻只有一个
// 席位在飞（主聊天区因此只有一条活动流）。要抢时间时仍可显式调高
// maxConcurrency，这里也验证那条路没被拆掉。

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:dsh_app/council/collab_models.dart';
import 'package:dsh_app/council/collab_orchestrator.dart';
import 'package:dsh_app/council/collab_store.dart';
import 'package:flutter_test/flutter_test.dart';

final class _OrderedDriver implements CollabSessionDriver {
  _OrderedDriver();

  final started = <String>[];
  final finished = <String>[];
  int _running = 0;
  int peak = 0;
  final _seatOf = <String, String>{};
  int _counter = 0;

  /// 每次调用之间给一点时间，让并发真的重叠得起来（否则峰值永远是 1）。
  static const hold = Duration(milliseconds: 12);

  @override
  Future<String> openSession(SeatSpec seat, {String? workspaceId}) async {
    final id = 's${_counter++}';
    _seatOf[id] = seat.id;
    return id;
  }

  @override
  Future<TurnOutcome> runTurn(
    String sessionId,
    String text, {
    Duration? timeout,
    List<CollabAttachment> attachments = const [],
  }) async {
    final seat = _seatOf[sessionId] ?? '';
    _running++;
    peak = math.max(peak, _running);
    started.add(seat);
    await Future<void>.delayed(hold);
    finished.add(seat);
    _running--;
    return TurnOutcome(kind: TurnKind.completed, text: '答案来自$seat');
  }

  @override
  Future<void> cancel(String sessionId) async {}
}

CouncilSpec _spec({int seats = 3, int? maxConcurrency}) => CouncilSpec(
  question: '按前面那一大段方案执行',
  seats: [
    for (var i = 0; i < seats; i++) SeatSpec(id: 'seat$i', provider: 'p$i', model: 'm$i', label: '成员$i'),
  ],
  chairId: 'seat0',
  maxConcurrency: maxConcurrency ?? 1,
  budgetCalls: 16,
  seatTimeout: const Duration(seconds: 5),
);

void main() {
  late Directory tmp;
  late CollabStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('collab_seq');
    store = CollabStore(tmp);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  CollabOrchestrator make(CollabSessionDriver driver) => CollabOrchestrator(
    driver: driver,
    store: store,
    newId: () => 'run-seq',
    retryDelay: (_, _) => Duration.zero,
  );

  Future<CollabRun> waitTerminal(CollabOrchestrator o) async {
    await for (final run in o.events) {
      if (run.phase.isTerminal) return run;
    }
    return (await o.snapshot('run-seq'))!;
  }

  test('默认席位顺序作答：同一时刻只有一位在飞', () async {
    final driver = _OrderedDriver();
    final o = make(driver);
    await o.submit(_spec());
    final done = await waitTerminal(o);
    expect(done.phase, CollabPhase.done);
    expect(driver.peak, 1, reason: '默认顺序作答，不能有两位同时开口');
    expect(done.answeredCount, 3);
    await o.dispose();
  });

  test('席位的开始顺序就是席位顺序（不是随机完成顺序）', () async {
    final driver = _OrderedDriver();
    final o = make(driver);
    await o.submit(_spec(seats: 4));
    await waitTerminal(o);
    // 主席综合也在同一驱动里，最后一位是主席；前四位按座位次序。
    expect(driver.started.take(4).toList(), ['seat0', 'seat1', 'seat2', 'seat3']);
    await o.dispose();
  });

  test('上一位写完才轮到下一位（完成顺序 = 开始顺序）', () async {
    final driver = _OrderedDriver();
    final o = make(driver);
    await o.submit(_spec());
    await waitTerminal(o);
    expect(driver.finished.take(3).toList(), ['seat0', 'seat1', 'seat2']);
    await o.dispose();
  });

  test('显式并行配置在 v3 里也被规范成严格一位', () async {
    // 单独一份 store + 驱动：提交一条 4 席、旧写法 maxConcurrency: 4 的 spec。
    final tmp2 = Directory.systemTemp.createTempSync('collab_par');
    addTearDown(() {
      if (tmp2.existsSync()) tmp2.deleteSync(recursive: true);
    });
    final driver = _OrderedDriver();
    final parallel = CollabOrchestrator(
      driver: driver,
      store: CollabStore(tmp2),
      newId: () => 'run-par',
      retryDelay: (_, _) => Duration.zero,
    );
    // v3 · 2.5：即使显式传 4，逐席位执行、峰值仍为 1。
    final oldStyle = _spec(seats: 4, maxConcurrency: 4);
    final normalized = CouncilSpec.fromJson(oldStyle.toJson());
    expect(normalized.maxConcurrency, 1);
    await parallel.submit(oldStyle);
    await for (final run in parallel.events) {
      if (run.phase.isTerminal) break;
    }
    expect(driver.peak, 1, reason: 'v3 要求实际模型请求并发始终为 1');
    await parallel.dispose();
  });

  test('顺序作答时提示词带上资料（指代能对上）', () async {
    final driver = _OrderedDriver();
    final o = make(driver);
    await o.submit(
      _spec(seats: 2).copyWithFirstContext(),
    );
    final done = await waitTerminal(o);
    expect(done.phase, CollabPhase.done);
    expect(done.spec.context, contains('此前的对话资料'));
    await o.dispose();
  });
}

extension on CouncilSpec {
  /// 在测试里给 spec 补一段资料（不改生产代码）。
  CouncilSpec copyWithFirstContext() => CouncilSpec(
    question: question,
    seats: seats,
    mode: mode,
    chairId: chairId,
    maxConcurrency: maxConcurrency,
    seatTimeout: seatTimeout,
    budgetCalls: budgetCalls,
    workspaceId: workspaceId,
    context: '【此前的对话资料】\n[#m1] 用户：完整方案…',
    sourceMessageIds: const ['m1'],
  );
}
