// 协作会话登记表：落盘往返、去重、恢复，以及历史列表用的过滤函数。

import 'dart:io';

import 'package:dsh_app/collab/collab_session_book.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

CollabSessionOwner _owner(
  String id, {
  CollabSessionKind kind = CollabSessionKind.council,
  String ownerId = 'run1',
  String label = 'V41 Flash',
  String? parentLabel = '要不要上线',
}) => CollabSessionOwner(
  sessionId: id,
  kind: kind,
  ownerId: ownerId,
  label: label,
  parentLabel: parentLabel,
);

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('collab-book-');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  group('落盘', () {
    test('保存后读回来，字段一个不少', () async {
      final book = CollabSessionBook(dir);
      await book.save({
        's1': _owner('s1'),
        's2': _owner('s2', kind: CollabSessionKind.team, ownerId: 'team1', label: '阿蓝', parentLabel: null),
      });

      final loaded = await CollabSessionBook(dir).load();
      expect(loaded.keys.toSet(), {'s1', 's2'});
      expect(loaded['s1']!.kind, CollabSessionKind.council);
      expect(loaded['s1']!.label, 'V41 Flash');
      expect(loaded['s1']!.parentLabel, '要不要上线');
      expect(loaded['s2']!.kind, CollabSessionKind.team);
      expect(loaded['s2']!.ownerId, 'team1');
      expect(loaded['s2']!.parentLabel, isNull);
    });

    test('没有文件时是空表', () async {
      expect(await CollabSessionBook(dir).load(), isEmpty);
    });

    test('坏文件当作空表，不抛错', () async {
      await File('${dir.path}/sessions.json').writeAsString('{不是 json');
      expect(await CollabSessionBook(dir).load(), isEmpty);
    });

    test('写入是原子替换：旧内容不会残留半截', () async {
      final book = CollabSessionBook(dir);
      await book.save({'s1': _owner('s1')});
      await book.save({'s2': _owner('s2')});
      final loaded = await book.load();
      expect(loaded.keys.toList(), ['s2']);
    });
  });

  group('Notifier', () {
    ProviderContainer container() => ProviderContainer(
      overrides: [collabSessionRootProvider.overrideWithValue(() async => dir)],
    );

    test('登记后历史列表把他们折叠掉', () async {
      final c = container();
      addTearDown(c.dispose);
      final notifier = c.read(collabSessionBookProvider.notifier);
      // provider 会随登记表失效重建，每次都要重新读。
      bool filtered(String id) => c.read(collabSessionFilterProvider)(id);

      expect(filtered('s1'), isFalse);
      await notifier.register(_owner('s1'));
      expect(filtered('s1'), isTrue);
      expect(filtered('other'), isFalse);
    });

    test('内容没变不重复写盘', () async {
      final c = container();
      addTearDown(c.dispose);
      final notifier = c.read(collabSessionBookProvider.notifier);
      await notifier.register(_owner('s1'));
      final first = await File('${dir.path}/sessions.json').lastModified();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await notifier.register(_owner('s1'));
      expect(await File('${dir.path}/sessions.json').lastModified(), first);
    });

    test('新实例从盘上恢复（进程重启）', () async {
      final first = container();
      await first.read(collabSessionBookProvider.notifier).register(_owner('s1'));
      first.dispose();

      final second = container();
      addTearDown(second.dispose);
      // 先碰一下让它 build（build 里发起异步读盘），等它读完再断言。
      second.read(collabSessionBookProvider);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(second.read(collabSessionFilterProvider)('s1'), isTrue);
      expect(second.read(collabSessionBookProvider)['s1']!.label, 'V41 Flash');
    });

    test('移除后不再过滤', () async {
      final c = container();
      addTearDown(c.dispose);
      final notifier = c.read(collabSessionBookProvider.notifier);
      await notifier.register(_owner('s1'));
      await notifier.forget('s1');
      expect(c.read(collabSessionFilterProvider)('s1'), isFalse);
      expect((await CollabSessionBook(dir).load()).containsKey('s1'), isFalse);
    });

    test('批量登记空 id 直接跳过', () async {
      final c = container();
      addTearDown(c.dispose);
      final notifier = c.read(collabSessionBookProvider.notifier);
      await notifier.registerAll([_owner(''), _owner('s1')]);
      expect(c.read(collabSessionBookProvider).keys.toList(), ['s1']);
    });
  });
}
