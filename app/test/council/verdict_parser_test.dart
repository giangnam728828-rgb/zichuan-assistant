// 裁决解析器测试：标准四段、置信度各种写法、无标题回退。

import 'package:dsh_app/council/verdict_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('标准四段：结论 + 置信度 + 三个列表块', () {
    final parsed = parseVerdict('''
## 结论
建议优先做本地搜索。置信度（中）：跨两家服务商的席位意见一致，但样本只覆盖手机端。
## 共识
- 离线可用是刚需
- 隐私是差异化优势
## 分歧
- 一位成员认为应该先做插件生态
## 建议核实
1. 目标用户的机型分布
2. 模型分发的合规限制
''');
    expect(parsed.isStructured, isTrue);
    expect(parsed.conclusion, contains('优先做本地搜索'));
    expect(parsed.confidence, Confidence.mid);
    expect(parsed.consensus, hasLength(2));
    expect(parsed.consensus.first, '离线可用是刚需');
    expect(parsed.disagreement, hasLength(1));
    expect(parsed.toVerify, hasLength(2));
    expect(parsed.toVerify.last, '模型分发的合规限制');
  });

  test('置信度写法变体：冒号、括号、逗号', () {
    expect(parseVerdict('## 结论\n置信度：高').confidence, Confidence.high);
    expect(parseVerdict('## 结论\n置信度（低）').confidence, Confidence.low);
    expect(parseVerdict('## 结论\n置信度 高，因为证据充分').confidence, Confidence.high);
  });

  test('模型不听话（没有标题）：退化为原文，不结构化', () {
    final parsed = parseVerdict('我觉得应该先做本地搜索，理由有三点……');
    expect(parsed.isStructured, isFalse);
    expect(parsed.conclusion, isNull);
    expect(parsed.consensus, isEmpty);
  });

  test('只有结论段也算结构化', () {
    final parsed = parseVerdict('## 结论\n先做 A，再做 B。');
    expect(parsed.isStructured, isTrue);
    expect(parsed.conclusion, '先做 A，再做 B。');
    expect(parsed.confidence, isNull);
  });

  test('### 三级标题也能认出来', () {
    final parsed = parseVerdict('### 结论\n结论正文\n### 共识\n- 一致同意 X');
    expect(parsed.conclusion, '结论正文');
    expect(parsed.consensus, ['一致同意 X']);
  });
}
