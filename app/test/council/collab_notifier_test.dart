// C1b：终态通知的单元测试。用记录器代替系统通知，验证文案与时机。

import 'dart:io';

import 'package:dsh_app/council/collab_notifier.dart';
import 'package:dsh_app/council/collab_orchestrator.dart';
import 'package:dsh_app/council/collab_store.dart';
import 'package:dsh_app/notify/notify_channel.dart';
import 'package:flutter_test/flutter_test.dart';

import 'collab_orchestrator_test.dart' show FakeDriver, FakeScript, FakeKind, spec;

void main() {
  late Directory tmp;
  late CollabStore store;
  late List<NotifyPost> posted;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('collab_notifier');
    store = CollabStore(tmp);
    posted = [];
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  CollabOrchestrator make(FakeDriver driver, {String id = 'run1'}) => CollabOrchestrator(
    driver: driver,
    store: store,
    newId: () => id,
    retryDelay: (_, _) => Duration.zero,
  );

  Future<void> settle(CollabOrchestrator o) async {
    await for (final run in o.events) {
      if (run.phase.isTerminal) return;
    }
  }

  test('完成时发一条通知：席位数与裁决首句', () async {
    final driver = FakeDriver({});
    final o = make(driver);
    final notifier = CollabNotifier(show: (post) async => posted.add(post));
    notifier.bind(o.events);
    await o.submit(spec());
    await settle(o);

    expect(posted, hasLength(1));
    final post = posted.single;
    expect(post.kind, 'council');
    expect(post.title, contains('3/3 席'));
    expect(post.text, isNotEmpty);
    expect(post.attention, isFalse);
    expect(post.group, 'council|run1');
    await o.dispose();
  });

  test('失败时发通知，带原因', () async {
    final driver = FakeDriver({
      'seat0': const FakeScript(FakeKind.fail),
      'seat1': const FakeScript(FakeKind.fail),
      'seat2': const FakeScript(FakeKind.fail),
    });
    final o = make(driver);
    final notifier = CollabNotifier(show: (post) async => posted.add(post));
    notifier.bind(o.events);
    await o.submit(spec());
    await settle(o);

    expect(posted, hasLength(1));
    expect(posted.single.title, contains('没能完成'));
    expect(posted.single.text, contains('所有席位'));
    await o.dispose();
  });

  test('取消不发通知', () async {
    final driver = FakeDriver({
      'seat0': const FakeScript(FakeKind.hang),
      'seat1': const FakeScript(FakeKind.hang),
      'seat2': const FakeScript(FakeKind.hang),
    });
    final o = make(driver);
    final notifier = CollabNotifier(show: (post) async => posted.add(post));
    notifier.bind(o.events);
    await o.submit(spec(maxConcurrency: 1, timeout: const Duration(seconds: 5)));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await o.cancel('run1');
    await settle(o);

    expect(posted, isEmpty);
    await o.dispose();
  });

  test('裁决首句会去掉 Markdown 记号并截断', () {
    final lead = CollabNotifier.verdictLead('## 结论\n**建议先做本地搜索**，因为……');
    expect(lead, '建议先做本地搜索，因为……');
    final long = CollabNotifier.verdictLead('## 结论\n${'很长' * 40}');
    expect(long.length, lessThanOrEqualTo(61));
    expect(long.endsWith('…'), isTrue);
  });
}
