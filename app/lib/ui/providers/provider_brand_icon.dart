// 厂商标记：模型选择器、Grok 顶栏、QUORUM 成员与每条消息共用一枚。
//
// 没有厂商 logo 素材，统一用「品牌色 + 自绘品牌形」（见 model_brand_mark.dart）：
// Claude 的星芒、Gemini 的四角星、OpenAI 的花结、DeepSeek 的鲸、Llama 的
// 无穷环，字谱是字母 Z，其余用品牌字母。不请求远程图片，不依赖版权素材包。

import 'package:flutter/material.dart';

import '../chat/model_brand_mark.dart';

export '../chat/model_brand_mark.dart' show ModelBrand, brandOf, brandColor, brandIconData;

/// 一枚厂商标记。尺寸从 12（消息身份）到 24（模型卡片）都按同一套形画。
class ProviderBrandIcon extends StatelessWidget {
  const ProviderBrandIcon({
    super.key,
    required this.brand,
    this.size = 16,
    this.filled = false,
    this.semanticLabel,
  });

  final ModelBrand brand;
  final double size;

  /// 加一层品牌色淡底，用在模型卡片和成员行；消息身份区用无底色。
  final bool filled;

  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = brandColorOn(brand, scheme);
    final glyph = BrandGlyph(brand: brand, size: filled ? size * 0.58 : size, color: color);
    final mark = filled
        ? Container(
            width: size,
            height: size,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color.withValues(alpha: 0.12)),
            alignment: Alignment.center,
            child: glyph,
          )
        : SizedBox.square(dimension: size, child: Center(child: glyph));
    if (semanticLabel == null) return ExcludeSemantics(child: mark);
    return Semantics(label: semanticLabel, image: true, child: ExcludeSemantics(child: mark));
  }
}

/// 从 Bot 的模型引用（`provider/model`）里取厂商标记；认不出就用中性图标。
ProviderBrandIcon providerBrandIconOf(String? modelRef, {double size = 16, bool filled = false, String? semanticLabel}) {
  final slash = modelRef?.indexOf('/') ?? -1;
  final provider = slash > 0 ? modelRef!.substring(0, slash) : modelRef;
  return ProviderBrandIcon(
    brand: brandOf(provider),
    size: size,
    filled: filled,
    semanticLabel: semanticLabel,
  );
}
