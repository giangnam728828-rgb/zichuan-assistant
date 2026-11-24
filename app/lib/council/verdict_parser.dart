// 把主席裁决（Markdown）解析成结构化卡片：结论 + 置信度 + 共识/分歧/待核实。
//
// 主席的提示词固定要求四段（## 结论 / ## 共识 / ## 分歧 / ## 建议核实），
// 但模型不一定听话：解析不出一段就退化成全文，界面按 [ParsedVerdict.isStructured]
// 决定是分块渲染还是原文渲染。

/// 主席在结论段里自报的置信度。
enum Confidence { high, mid, low }

final class ParsedVerdict {
  const ParsedVerdict({
    this.conclusion,
    this.confidence,
    this.consensus = const [],
    this.disagreement = const [],
    this.toVerify = const [],
    this.structured = false,
  });

  final String? conclusion;
  final Confidence? confidence;
  final List<String> consensus;
  final List<String> disagreement;
  final List<String> toVerify;

  /// 至少解析出结论段或一个列表块才算是结构化输出。
  final bool structured;

  bool get isStructured => structured;
}

final _heading = RegExp(r'^\s{0,3}#{1,6}\s*(.+?)\s*$');
final _confidence = RegExp(r'置信度[^高初中低]{0,6}(高|中|低)');
final _bullet = RegExp(r'^\s*(?:[-*+]\s+|\d+[.)、]\s*)');

ParsedVerdict parseVerdict(String markdown) {
  final lines = markdown.split('\n');
  String? section; // 当前段的规范名：结论/共识/分歧/待核实
  final conclusion = <String>[];
  final consensus = <String>[];
  final disagreement = <String>[];
  final toVerify = <String>[];
  var sawHeading = false;

  List<String> bucket(String name) => switch (name) {
    '结论' => conclusion,
    '共识' => consensus,
    '分歧' => disagreement,
    _ => toVerify,
  };

  String sectionOf(String title) {
    final t = title.replaceAll(RegExp(r'[*_`：:]'), '').trim();
    if (t.contains('结论') || t.contains('裁决')) return '结论';
    if (t.contains('共识')) return '共识';
    if (t.contains('分歧')) return '分歧';
    if (t.contains('核实') || t.contains('验证') || t.contains('待查')) return '待核实';
    return t;
  }

  for (final raw in lines) {
    final heading = _heading.firstMatch(raw);
    if (heading != null) {
      sawHeading = true;
      section = sectionOf(heading.group(1)!);
      continue;
    }
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (section == '结论') {
      final text = line.replaceFirst(_bullet, '');
      if (text.isNotEmpty) conclusion.add(text);
    } else if (section == '共识' || section == '分歧' || section == '待核实') {
      final text = line.replaceFirst(_bullet, '');
      if (text.isNotEmpty) bucket(section!).add(text);
    }
  }

  final conclusionText = conclusion.isEmpty ? null : conclusion.join('\n');
  Confidence? confidence;
  final source = conclusionText ?? markdown;
  if (_confidence.firstMatch(source) case final match?) {
    confidence = switch (match.group(1)) {
      '高' => Confidence.high,
      '中' => Confidence.mid,
      _ => Confidence.low,
    };
  }

  return ParsedVerdict(
    conclusion: conclusionText,
    confidence: confidence,
    consensus: consensus,
    disagreement: disagreement,
    toVerify: toVerify,
    structured: sawHeading && (conclusionText != null || consensus.isNotEmpty || disagreement.isNotEmpty),
  );
}
