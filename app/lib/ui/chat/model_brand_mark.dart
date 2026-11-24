import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 输入栏里的模型键：当前模型所属厂商的标记，点开模型选择。
///
/// 顶栏不再放模型名（B5）：模型选择跟着输入栏走，跟手边的事待在一起。
/// 没有厂商 logo 素材，用「品牌色 + 自绘标记」表达是哪一家：各家显示
/// 自己的品牌形——Claude 的放射星芒、Gemini 的四角星、OpenAI 的花结、
/// DeepSeek 的鲸、Llama 的无穷环，字谱的品牌本身就是字母 Z；其余用
/// 品牌字母。24dp 的圆里认得出来，也不依赖版权素材。
enum ModelBrand { claude, gemini, openai, deepseek, qwen, kimi, glm, grok, llama, mistral, other }

/// 从 provider id / 展示名里认品牌。认不出就是 [ModelBrand.other]。
ModelBrand brandOf(String? provider, [String? name]) {
  final text = '${provider ?? ''} ${name ?? ''}'.toLowerCase();
  if (text.contains('claude') || text.contains('anthropic')) return ModelBrand.claude;
  if (text.contains('gemini') || text.contains('google')) return ModelBrand.gemini;
  if (text.contains('openai') || text.contains('gpt')) return ModelBrand.openai;
  if (text.contains('deepseek')) return ModelBrand.deepseek;
  if (text.contains('qwen') || text.contains('通义')) return ModelBrand.qwen;
  if (text.contains('kimi') || text.contains('moonshot')) return ModelBrand.kimi;
  // 字谱（zhipu 的中文名）的品牌标是字母 Z。
  if (text.contains('glm') || text.contains('zhipu') || text.contains('字谱') || text.contains('智谱')) {
    return ModelBrand.glm;
  }
  if (text.contains('grok') || text.contains('xai')) return ModelBrand.grok;
  if (text.contains('llama') || text.contains('meta')) return ModelBrand.llama;
  if (text.contains('mistral')) return ModelBrand.mistral;
  return ModelBrand.other;
}

Color brandColor(ModelBrand brand, Color fallback) => switch (brand) {
  ModelBrand.claude => const Color(0xFFC96442),
  ModelBrand.gemini => const Color(0xFF4285F4),
  ModelBrand.openai => const Color(0xFF0F0F0F),
  ModelBrand.deepseek => const Color(0xFF4D6BFE),
  ModelBrand.qwen => const Color(0xFF615CED),
  ModelBrand.kimi => const Color(0xFF1F1F1F),
  ModelBrand.glm => const Color(0xFF2E5BFF),
  ModelBrand.grok => const Color(0xFF111111),
  ModelBrand.llama => const Color(0xFF0866FF),
  ModelBrand.mistral => const Color(0xFFFF7000),
  ModelBrand.other => fallback,
};

String _letter(ModelBrand brand) => switch (brand) {
  ModelBrand.deepseek => 'D',
  ModelBrand.qwen => 'Q',
  ModelBrand.kimi => 'K',
  // 字谱的品牌标本身就是字母 Z。
  ModelBrand.glm => 'Z',
  ModelBrand.grok => 'X',
  ModelBrand.mistral => 'M',
  // 品牌形走 CustomPainter，不会落到这里。
  _ => '',
};

/// 36dp 的圆钮，与输入栏其他键同高。底色是品牌色的一层淡雾，里面是标记。
class ModelBrandMark extends StatelessWidget {
  const ModelBrandMark({
    super.key,
    required this.brand,
    required this.onTap,
    this.size = 36,
    this.semanticLabel,
  });

  final ModelBrand brand;
  final VoidCallback onTap;
  final double size;

  /// 读屏念的名字（「切换模型，当前 Spark X2.6」）。
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final color = brandColor(brand, Theme.of(context).colorScheme.primary);
    return Semantics(
      button: true,
      label: semanticLabel,
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: size,
            height: size,
            child: Center(
              child: Container(
                width: size - 4,
                height: size - 4,
                decoration: BoxDecoration(shape: BoxShape.circle, color: color.withValues(alpha: 0.12)),
                alignment: Alignment.center,
                child: _glyph(color),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _glyph(Color color) {
    final side = size * 0.5;
    return switch (brand) {
      ModelBrand.claude => CustomPaint(size: Size.square(side), painter: _ClaudeStar(color)),
      ModelBrand.gemini => CustomPaint(size: Size.square(side), painter: _GeminiStar(color)),
      ModelBrand.openai => CustomPaint(size: Size.square(side), painter: _OpenAIKnot(color)),
      ModelBrand.deepseek => CustomPaint(size: Size.square(side), painter: _DeepseekWhale(color)),
      ModelBrand.llama => CustomPaint(size: Size.square(side), painter: _LlamaLoop(color)),
      ModelBrand.other => Icon(Icons.auto_awesome, size: side * 0.82, color: color),
      _ => Text(
        _letter(brand),
        style: TextStyle(
          fontSize: side * 0.72,
          fontWeight: FontWeight.w700,
          height: 1,
          color: color,
          letterSpacing: 0,
        ),
      ),
    };
  }
}

/// Claude 的放射星芒：从圆心散出的短线，端点圆头。
class _ClaudeStar extends CustomPainter {
  const _ClaudeStar(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final inner = size.shortestSide * 0.10;
    final outer = size.shortestSide * 0.48;
    final paint = Paint()
      ..color = color
      ..strokeWidth = math.max(1.4, size.shortestSide * 0.09)
      ..strokeCap = StrokeCap.round;
    const spokes = 8;
    for (var i = 0; i < spokes; i++) {
      final angle = i * math.pi * 2 / spokes + math.pi / 8;
      final dir = Offset(math.cos(angle), math.sin(angle));
      canvas.drawLine(center + dir * inner, center + dir * outer, paint);
    }
  }

  @override
  bool shouldRepaint(_ClaudeStar old) => old.color != color;
}

/// Gemini 的四角星：四个尖角，腰身内收。
class _GeminiStar extends CustomPainter {
  const _GeminiStar(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide * 0.48;
    final waist = r * 0.28;
    final path = Path()
      ..moveTo(c.dx, c.dy - r)
      ..quadraticBezierTo(c.dx + waist * 0.4, c.dy - waist, c.dx + r, c.dy)
      ..quadraticBezierTo(c.dx + waist * 0.4, c.dy + waist, c.dx, c.dy + r)
      ..quadraticBezierTo(c.dx - waist * 0.4, c.dy + waist, c.dx - r, c.dy)
      ..quadraticBezierTo(c.dx - waist * 0.4, c.dy - waist, c.dx, c.dy - r)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_GeminiStar old) => old.color != color;
}

/// OpenAI 的花结：六瓣细长花瓣绕心放射，六重对称咬合的结。
class _OpenAIKnot extends CustomPainter {
  const _OpenAIKnot(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide * 0.5;
    final paint = Paint()..color = color;
    final petal = Size(r * 0.30, r * 0.78);
    for (var i = 0; i < 6; i++) {
      canvas.save();
      canvas.translate(c.dx, c.dy);
      canvas.rotate(i * math.pi / 3);
      // 花瓣中心离圆心一段距离：瓣与瓣在中点咬合，露出六重对称。
      canvas.drawOval(
        Rect.fromCenter(center: Offset(0, -r * 0.34), width: petal.width, height: petal.height),
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_OpenAIKnot old) => old.color != color;
}

/// DeepSeek 的鲸：流线鱼身 + 叉尾 + 小背鳍，一笔填充的侧影。
class _DeepseekWhale extends CustomPainter {
  const _DeepseekWhale(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final path = Path()
      // 尾根 → 尾上叶回勾
      ..moveTo(w * 0.08, h * 0.50)
      ..cubicTo(w * 0.02, h * 0.34, w * 0.10, h * 0.32, w * 0.16, h * 0.42)
      // 背脊 → 头
      ..cubicTo(w * 0.32, h * 0.22, w * 0.62, h * 0.20, w * 0.80, h * 0.34)
      // 头 → 腹
      ..cubicTo(w * 0.96, h * 0.44, w * 0.94, h * 0.64, w * 0.76, h * 0.70)
      // 腹 → 尾下
      ..cubicTo(w * 0.54, h * 0.78, w * 0.28, h * 0.74, w * 0.14, h * 0.60)
      ..close()
      // 尾下叶
      ..moveTo(w * 0.08, h * 0.50)
      ..cubicTo(w * 0.06, h * 0.66, w * 0.10, h * 0.76, w * 0.18, h * 0.74)
      ..close()
      // 背鳍
      ..moveTo(w * 0.52, h * 0.24)
      ..quadraticBezierTo(w * 0.62, h * 0.06, w * 0.76, h * 0.30)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_DeepseekWhale old) => old.color != color;
}

/// Llama 的无穷环：两个相扣的圆环。
class _LlamaLoop extends CustomPainter {
  const _LlamaLoop(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide * 0.5;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = r * 0.24;
    final ring = r * 0.44;
    canvas.drawCircle(c.translate(-ring * 0.62, 0), ring, paint);
    canvas.drawCircle(c.translate(ring * 0.62, 0), ring, paint);
  }

  @override
  bool shouldRepaint(_LlamaLoop old) => old.color != color;
}
