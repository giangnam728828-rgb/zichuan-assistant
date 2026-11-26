// 厂商标记：模型选择器、聊天消息、议会成员、团队成员、历史会话共用一套。
//
// 规则（方案第四部分）：
// 1. 图标必须是真实品牌资源，统一放本地 assets/brands/，不请求远程图片。
// 2. Provider 与 Model 分两层判断：模型名优先认品牌（OpenRouter 上的
//    deepseek-chat 仍是 DeepSeek），模型名认不出再看 Provider。
// 3. 认不出的用中性标记，绝不伪造品牌 Logo。
// 4. 所有页面走同一个 [brandOf] + [ProviderBrandIcon]，不各写一套。

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

enum ModelBrand {
  claude,
  gemini,
  openai,
  deepseek,
  qwen,
  spark,
  kimi,
  glm,
  grok,
  llama,
  mistral,
  doubao,
  hunyuan,
  minimax,
  other,
}

/// 从 provider id / 模型 id / 展示名里认品牌。
///
/// 先看模型名：同一个模型挂在自定义中转、聚合网关（OpenRouter、SiliconFlow、
/// Together…）下时，Provider 变了，品牌不该变。模型名里没有任何已知品牌词
/// 时才退回 Provider（官方账户的模型名常是 V4、GLM-5 这类不带厂商的短名）。
ModelBrand brandOf(String? provider, [String? name]) {
  final model = (name ?? '').toLowerCase();
  final vendor = (provider ?? '').toLowerCase();
  const aliases = <ModelBrand, List<String>>{
    ModelBrand.claude: ['claude', 'anthropic'],
    ModelBrand.gemini: ['gemini', 'gemma'],
    ModelBrand.openai: ['gpt', 'openai', 'chatgpt', 'davinci'],
    ModelBrand.deepseek: ['deepseek'],
    ModelBrand.qwen: ['qwen', 'qwq', '通义', '千问'],
    // 讯飞星火：中英文都认；spark 单独留给星火（不是 Apache Spark）。
    ModelBrand.spark: ['spark', '星火', '讯飞', 'iflytek', 'xfyun'],
    ModelBrand.kimi: ['kimi', 'moonshot'],
    ModelBrand.glm: ['glm', 'zhipu', '智谱', 'chatglm'],
    ModelBrand.grok: ['grok'],
    ModelBrand.llama: ['llama', 'meta-llama'],
    ModelBrand.mistral: ['mistral', 'mixtral', 'codestral'],
    ModelBrand.doubao: ['doubao', '豆包'],
    ModelBrand.hunyuan: ['hunyuan', '混元'],
    ModelBrand.minimax: ['minimax', 'abab'],
  };
  for (final entry in aliases.entries) {
    if (entry.value.any((token) => _mentions(model, token))) return entry.key;
  }
  // 模型名认不出：官方 Provider 本身就说明品牌。
  for (final entry in aliases.entries) {
    if (entry.value.any((token) => _mentions(vendor, token))) return entry.key;
  }
  return ModelBrand.other;
}

/// 英文品牌词按「词」匹配：`spark` 命中 `spark-4.0`，但不命中 `sparkling`；
/// `gpt` 命中 `gpt-4o`，但不命中 `gptx`。中文品牌词直接包含即可。
bool _mentions(String haystack, String token) {
  if (token.isEmpty) return false;
  final ascii = RegExp(r'^[\x00-\x7F]+$').hasMatch(token);
  if (!ascii) return haystack.contains(token);
  var from = 0;
  while (true) {
    final at = haystack.indexOf(token, from);
    if (at < 0) return false;
    final before = at == 0 ? '' : haystack[at - 1];
    final end = at + token.length;
    final after = end >= haystack.length ? '' : haystack[end];
    final leftOk = !RegExp(r'[a-z0-9]').hasMatch(before);
    final rightOk = !RegExp(r'[a-z0-9]').hasMatch(after);
    if (leftOk && rightOk) return true;
    from = at + 1;
  }
}

/// 品牌色。近黑的几家（OpenAI、Kimi、Grok）在深色主题里由 [brandColorOn]
/// 换成正文色。
Color brandColor(ModelBrand brand, Color fallback) => switch (brand) {
  ModelBrand.claude => const Color(0xFFC96442),
  ModelBrand.gemini => const Color(0xFF4285F4),
  ModelBrand.openai => const Color(0xFF0F0F0F),
  ModelBrand.deepseek => const Color(0xFF4D6BFE),
  ModelBrand.qwen => const Color(0xFF615CED),
  ModelBrand.spark => const Color(0xFF0A4C9B),
  ModelBrand.kimi => const Color(0xFF1F1F1F),
  ModelBrand.glm => const Color(0xFF2E5BFF),
  ModelBrand.grok => const Color(0xFF111111),
  ModelBrand.llama => const Color(0xFF0866FF),
  ModelBrand.mistral => const Color(0xFFFF7000),
  ModelBrand.doubao => const Color(0xFF1C64F2),
  ModelBrand.hunyuan => const Color(0xFF0052D9),
  ModelBrand.minimax => const Color(0xFFE8332A),
  ModelBrand.other => fallback,
};

Color brandColorOn(ModelBrand brand, ColorScheme scheme) {
  final color = brandColor(brand, scheme.primary);
  if (scheme.brightness == Brightness.dark && color.computeLuminance() < 0.12) return scheme.onSurface;
  return color;
}

/// 品牌名：模型卡第二行、成员列表里用。
String brandLabel(ModelBrand brand) => switch (brand) {
  ModelBrand.claude => 'Anthropic',
  ModelBrand.gemini => 'Google',
  ModelBrand.openai => 'OpenAI',
  ModelBrand.deepseek => 'DeepSeek',
  ModelBrand.qwen => '通义千问',
  ModelBrand.spark => '讯飞星火',
  ModelBrand.kimi => 'Moonshot',
  ModelBrand.glm => '智谱',
  ModelBrand.grok => 'xAI',
  ModelBrand.llama => 'Meta',
  ModelBrand.mistral => 'Mistral',
  ModelBrand.doubao => '字节跳动',
  ModelBrand.hunyuan => '腾讯',
  ModelBrand.minimax => 'MiniMax',
  ModelBrand.other => '其他',
};

/// 本地品牌图（`assets/brands/<name>.svg`）。未知品牌没有图，用中性标记。
String? brandAsset(ModelBrand brand) => switch (brand) {
  ModelBrand.claude => 'assets/brands/claude.svg',
  ModelBrand.gemini => 'assets/brands/gemini.svg',
  ModelBrand.openai => 'assets/brands/openai.svg',
  ModelBrand.deepseek => 'assets/brands/deepseek.svg',
  ModelBrand.qwen => 'assets/brands/qwen.svg',
  ModelBrand.spark => 'assets/brands/spark.svg',
  ModelBrand.kimi => 'assets/brands/kimi.svg',
  ModelBrand.glm => 'assets/brands/zhipu.svg',
  ModelBrand.grok => 'assets/brands/grok.svg',
  ModelBrand.llama => 'assets/brands/llama.svg',
  ModelBrand.mistral => 'assets/brands/mistral.svg',
  ModelBrand.doubao => 'assets/brands/doubao.svg',
  ModelBrand.hunyuan => 'assets/brands/hunyuan.svg',
  ModelBrand.minimax => 'assets/brands/minimax.svg',
  ModelBrand.other => null,
};

/// 列表里的小图标兜底：真实品牌图走 [BrandGlyph]，这里只给没有素材的场合。
IconData brandIconData(ModelBrand brand) => switch (brand) {
  ModelBrand.other => Icons.smart_toy_outlined,
  _ => Icons.circle,
};

/// 36dp 的圆钮（输入栏的模型键）：品牌色淡底 + 真实品牌图。
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
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final color = brandColorOn(brand, Theme.of(context).colorScheme);
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
                child: BrandGlyph(brand: brand, size: size * 0.5, color: color),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 一家的品牌图，无底色、无点击：消息身份、成员行、模型卡都用它。
///
/// 品牌图是单色 SVG（`currentColor`），用 [color] 染色；未知品牌画一枚中性
/// 星形，不冒充任何 Logo。
class BrandGlyph extends StatelessWidget {
  const BrandGlyph({super.key, required this.brand, required this.size, required this.color});

  final ModelBrand brand;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final asset = brandAsset(brand);
    if (asset == null) {
      // 未知品牌：一枚空心圆点，明确表示「没有 Logo」，不拿星星或机器人冒充。
      return SizedBox.square(
        dimension: size,
        child: Center(
          child: Container(
            width: size * 0.72,
            height: size * 0.72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: color.withValues(alpha: 0.55), width: 1.2),
            ),
            child: Center(
              child: Container(
                width: size * 0.16,
                height: size * 0.16,
                decoration: BoxDecoration(shape: BoxShape.circle, color: color.withValues(alpha: 0.55)),
              ),
            ),
          ),
        ),
      );
    }
    return SvgPicture.asset(
      asset,
      width: size,
      height: size,
      fit: BoxFit.contain,
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
      excludeFromSemantics: true,
    );
  }
}
