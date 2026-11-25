// 历史页的分类：全部 / 普通 / 议会 / 团队（方案第三部分）。
//
// 分类只影响历史页看什么，不动会话本身。默认「全部」：普通会话照旧按天排，
// 议会与团队在列表最上面各自成段，和普通聊天互不混淆。

import 'package:flutter_riverpod/flutter_riverpod.dart';

enum HistoryKind {
  all('全部'),
  normal('普通'),
  council('议会'),
  team('团队');

  const HistoryKind(this.label);

  final String label;
}

class HistoryKindController extends Notifier<HistoryKind> {
  @override
  HistoryKind build() => HistoryKind.all;

  void select(HistoryKind kind) => state = kind;
}

final historyKindProvider = NotifierProvider<HistoryKindController, HistoryKind>(
  HistoryKindController.new,
);
