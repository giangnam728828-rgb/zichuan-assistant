// v4.3 · 15.4 / P0-H：协作历史的长按详情面板。
//
// 要求：长按不是「直接问删不删」，而是先给一份能看清这条会话是什么的面板——
// 标题、类型、成员数、创建/更新时间、当前状态、最近一条提问与最近回答；操作
// 至少要有打开、重命名、导出 Markdown、删除（二次确认），未跑完的还要能继续。

import 'package:dsh_app/collab/collab_conversations.dart';
import 'package:dsh_app/ui/collab/collab_history.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart' show testApp;

CollabHistoryEntry _entry({CollabRunStatus status = CollabRunStatus.running, String? failure}) => CollabHistoryEntry(
  id: 'c1',
  kind: CollabKind.council,
  title: '要不要上线',
  subtitle: '议会',
  memberCount: 3,
  createdAt: DateTime(2026, 11, 20, 9, 30),
  updatedAt: DateTime(2026, 11, 28, 10, 15),
  status: status,
  failure: failure,
  lastQuestion: '这一版能不能直接上线',
  lastAnswer: '建议先灰度，观察一天错误率再全量。',
);

Widget _host(CollabHistoryEntry entry) => testApp(
  Scaffold(
    body: Consumer(
      builder: (context, ref, _) => TextButton(
        onPressed: () => showCollabEntrySheet(context, ref, entry),
        child: const Text('open sheet'),
      ),
    ),
  ),
);

void main() {
  testWidgets('长按面板：类型、成员、时间、状态、最近一问一答都在', (tester) async {
    await tester.pumpWidget(_host(_entry()));
    await tester.tap(find.text('open sheet'));
    await tester.pumpAndSettle();

    expect(find.text('要不要上线'), findsOneWidget);
    expect(find.text('议会'), findsAtLeastNWidgets(1));
    expect(find.text('3 位参会模型'), findsOneWidget);
    expect(find.text('进行中'), findsOneWidget);
    expect(find.text('最近的提问'), findsOneWidget);
    expect(find.byKey(const ValueKey('collab-sheet-question')), findsOneWidget);
    expect(find.text('这一版能不能直接上线'), findsOneWidget);
    expect(find.text('最近的回答'), findsOneWidget);
    expect(find.textContaining('建议先灰度'), findsOneWidget);
  });

  testWidgets('操作项：打开 / 重命名 / 导出 / 继续 / 删除', (tester) async {
    await tester.pumpWidget(_host(_entry()));
    await tester.tap(find.text('open sheet'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('collab-sheet-open')), findsOneWidget);
    expect(find.byKey(const ValueKey('collab-sheet-rename')), findsOneWidget);
    expect(find.byKey(const ValueKey('collab-sheet-export')), findsOneWidget);
    expect(find.byKey(const ValueKey('collab-sheet-delete')), findsOneWidget);
    expect(find.byKey(const ValueKey('collab-sheet-resume')), findsOneWidget, reason: '运行中要能接着跑');
  });

  testWidgets('已完成的会话不摆「继续运行」', (tester) async {
    await tester.pumpWidget(_host(_entry(status: CollabRunStatus.done)));
    await tester.tap(find.text('open sheet'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('collab-sheet-resume')), findsNothing);
    expect(find.text('已完成'), findsOneWidget);
  });

  testWidgets('失败原因写在面板里，不是只剩一句「失败」', (tester) async {
    await tester.pumpWidget(_host(_entry(status: CollabRunStatus.failed, failure: '第 2 位成员的模型额度用尽')));
    await tester.tap(find.text('open sheet'));
    await tester.pumpAndSettle();

    expect(find.text('已失败'), findsOneWidget);
    expect(find.textContaining('额度用尽'), findsOneWidget);
  });
}
