// 协作产出的 Markdown（议会裁决 / 团队群聊）与交给系统分享面板。
//
// 生成是纯函数（好测），分享只做「写临时文件 + 拉起面板」。

import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../council/collab_models.dart';

/// 议会一次运行的完整 Markdown：议题、裁决、每个席位的答案。
String councilMarkdown(CollabRun run) {
  final buffer = StringBuffer()
    ..writeln('# 议会 · ${run.spec.question}')
    ..writeln()
    ..writeln('- 方式：${_modeLabel(run.spec.mode)}')
    ..writeln('- 时间：${collabStamp(run.createdAt)}')
    ..writeln('- 调用：${run.callsUsed} 次')
    ..writeln();

  if (run.verdict != null && run.verdict!.trim().isNotEmpty) {
    buffer
      ..writeln('## 主席裁决')
      ..writeln()
      ..writeln(run.verdict!.trim())
      ..writeln();
  }
  if (run.failure != null && run.failure!.trim().isNotEmpty) {
    buffer
      ..writeln('## 未完成的原因')
      ..writeln()
      ..writeln(run.failure!.trim())
      ..writeln();
  }

  buffer.writeln('## 各席位');
  for (final seat in run.spec.seats) {
    final state = run.seatOf(seat.id);
    final role = seat.role == SeatRole.none ? '' : '（${seat.role.label}）';
    final body = state.best?.trim() ?? '';
    buffer
      ..writeln()
      ..writeln('### ${seat.displayName}$role')
      ..writeln()
      ..writeln(body.isEmpty ? '（${_seatStatus(state)}，没有内容）' : body);
  }
  return buffer.toString();
}

/// `2026-11-25 09:20`：落款用的本地时间。
String collabStamp(DateTime at) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${at.year}-${two(at.month)}-${two(at.day)} ${two(at.hour)}:${two(at.minute)}';
}

String _modeLabel(CollabMode mode) => switch (mode) {
  CollabMode.quick => '快速 · 民主计票',
  CollabMode.deliberative => '审议 · 两轮',
  CollabMode.evidence => '循证 · 先答后校验',
};

String _seatStatus(SeatState state) => switch (state.status) {
  SeatStatus.pending => '等待中',
  SeatStatus.running => '作答中',
  SeatStatus.answered => '已作答',
  SeatStatus.revised => '已修订',
  SeatStatus.failed => '失败',
  SeatStatus.timedOut => '超时',
  SeatStatus.cancelled => '已取消',
};

/// 把一段 Markdown 写成临时文件，交给系统分享面板（导出 / 发给自己）。
Future<void> shareMarkdownFile({required String fileName, required String content}) async {
  final dir = Directory('${(await getTemporaryDirectory()).path}/collab');
  await dir.create(recursive: true);
  final file = File('${dir.path}/$fileName');
  await file.writeAsString(content, flush: true);
  await SharePlus.instance.share(
    ShareParams(
      files: [XFile(file.path, mimeType: 'text/markdown', name: fileName)],
      fileNameOverrides: [fileName],
      subject: fileName,
    ),
  );
}
