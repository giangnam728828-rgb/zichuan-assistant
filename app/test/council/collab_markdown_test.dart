// 议会导出：Markdown 里要有议题、裁决、每个席位的答案与角色。

import 'package:dsh_app/collab/collab_export.dart';
import 'package:dsh_app/council/collab_models.dart';
import 'package:flutter_test/flutter_test.dart';

CollabRun _run({
  CollabPhase phase = CollabPhase.done,
  String? verdict = '## 结论\n可以上线\n\n## 共识\n- 风险可控',
  String? failure,
  Map<String, SeatState>? seats,
}) => CollabRun(
  id: 'r1',
  spec: const CouncilSpec(
    question: '要不要上线',
    seats: [
      SeatSpec(id: 's0', provider: 'deepseek', model: 'flash', label: 'V41 Flash', role: SeatRole.engineer),
      SeatSpec(id: 's1', provider: 'zhipu', model: 'glm-5', label: 'GLM-5', role: SeatRole.contrarian),
    ],
    mode: CollabMode.deliberative,
  ),
  phase: phase,
  seats:
      seats ??
      const {
        's0': SeatState(status: SeatStatus.revised, answer: '初稿', revised: '建议分批放量'),
        's1': SeatState(status: SeatStatus.answered, answer: '还有回滚预案没定'),
      },
  verdict: verdict,
  failure: failure,
  callsUsed: 5,
  createdAt: DateTime(2026, 11, 25, 9, 20),
  updatedAt: DateTime(2026, 11, 25, 9, 26),
);

void main() {
  test('完整运行：议题、方式、裁决、席位答案都在', () {
    final text = councilMarkdown(_run());
    expect(text, contains('# 议会 · 要不要上线'));
    expect(text, contains('审议 · 两轮'));
    expect(text, contains('2026-11-25 09:20'));
    expect(text, contains('5 次'));
    expect(text, contains('## 主席裁决'));
    expect(text, contains('可以上线'));
    expect(text, contains('### V41 Flash（技术专家）'));
    // 修订后的版本优先于初稿。
    expect(text, contains('建议分批放量'));
    expect(text, isNot(contains('初稿')));
    expect(text, contains('### GLM-5（唱反调者）'));
    expect(text, contains('还有回滚预案没定'));
  });

  test('没有裁决的失败运行：写出失败原因，席位标状态', () {
    final text = councilMarkdown(
      _run(
        phase: CollabPhase.failed,
        verdict: null,
        failure: '预算用尽',
        seats: const {
          's0': SeatState(status: SeatStatus.timedOut, error: '超时'),
          's1': SeatState(status: SeatStatus.cancelled),
        },
      ),
    );
    expect(text, contains('## 未完成的原因'));
    expect(text, contains('预算用尽'));
    expect(text, isNot(contains('## 主席裁决')));
    expect(text, contains('（超时，没有内容）'));
    expect(text, contains('（已取消，没有内容）'));
  });

  test('快速模式的标题与空答案占位', () {
    final run = CollabRun(
      id: 'r2',
      spec: const CouncilSpec(
        question: '选哪个',
        seats: [SeatSpec(id: 's0', provider: 'deepseek', model: 'flash', label: 'V41 Flash')],
        mode: CollabMode.quick,
      ),
      phase: CollabPhase.done,
      seats: const {'s0': SeatState(status: SeatStatus.answered, answer: '选 A')},
      verdict: '选 A',
      createdAt: DateTime(2026, 11, 25, 10, 0),
      updatedAt: DateTime(2026, 11, 25, 10, 1),
    );
    final text = councilMarkdown(run);
    expect(text, contains('快速 · 民主计票'));
    // 无角色不写括号。
    expect(text, contains('### V41 Flash\n'));
    expect(text, contains('选 A'));
  });

  test('时间戳格式固定为两位数', () {
    expect(collabStamp(DateTime(2026, 1, 2, 3, 4)), '2026-01-02 03:04');
  });
}
