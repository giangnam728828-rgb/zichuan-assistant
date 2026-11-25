// 厂商 Logo 体系：谁家的模型认成谁、深色下近黑的品牌色要换、窄屏长名不挤掉标记。

import 'package:dsh_app/ui/bots/bot_chat_kit.dart';
import 'package:dsh_app/ui/chat/model_brand_mark.dart';
import 'package:dsh_app/ui/providers/provider_brand_icon.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';

void main() {
  setUpAll(loadTestFonts);

  test('provider ids and model names map to the right brand', () {
    const cases = {
      'anthropic/claude-4.6': ModelBrand.claude,
      'claude': ModelBrand.claude,
      'google/gemini-3-pro': ModelBrand.gemini,
      'gemini': ModelBrand.gemini,
      'openai/gpt-5.2': ModelBrand.openai,
      'openai': ModelBrand.openai,
      'deepseek/deepseek-v4-pro': ModelBrand.deepseek,
      'qwen/qwen3-max': ModelBrand.qwen,
      'moonshot/kimi-k3': ModelBrand.kimi,
      'kimi': ModelBrand.kimi,
      'zhipu/glm-5': ModelBrand.glm,
      '智谱': ModelBrand.glm,
      'x-ai/grok-5': ModelBrand.grok,
      'meta/llama-4': ModelBrand.llama,
      'mistral/mistral-large': ModelBrand.mistral,
    };
    cases.forEach((ref, brand) {
      expect(brandOf(ref), brand, reason: ref);
      // 不区分大小写，也接受从一个完整的模型引用里认。
      expect(brandOf(ref.toUpperCase()), brand, reason: ref);
    });
    // 自建网关、没听说过的名字：不猜，落到通用标记。
    expect(brandOf('my-gateway'), ModelBrand.other);
    expect(brandOf('custom-gateway/llm-1'), ModelBrand.other);
    expect(brandOf(null), ModelBrand.other);
  });

  test('a near-black brand switches to the text colour in the dark', () {
    final light = ThemeData(brightness: Brightness.light).colorScheme;
    final dark = ThemeData(brightness: Brightness.dark).colorScheme;

    // 浅色底上保持品牌原色。
    expect(brandColorOn(ModelBrand.openai, light), brandColor(ModelBrand.openai, light.primary));
    expect(brandColorOn(ModelBrand.claude, light), brandColor(ModelBrand.claude, light.primary));

    // 深色底上近黑的几家改用正文色，否则看不见。
    expect(brandColorOn(ModelBrand.openai, dark), dark.onSurface);
    expect(brandColorOn(ModelBrand.kimi, dark), dark.onSurface);
    expect(brandColorOn(ModelBrand.grok, dark), dark.onSurface);
    // 本身够亮的品牌不动。
    expect(brandColorOn(ModelBrand.deepseek, dark), brandColor(ModelBrand.deepseek, dark.primary));
  });

  test('a Bot takes its brand from the model it actually runs', () {
    final bot = DsBot.fromJson(const {
      'id': 'b1',
      'name': 'Writer',
      'model': 'deepseek/deepseek-v4-flash',
      'appliedModel': 'anthropic/claude-4.6',
    });
    expect(botModelLabel(bot), 'claude-4.6');
    expect(botModelBrand(bot), ModelBrand.claude);
  });

  testWidgets('a long model name never squeezes the brand mark', (t) async {
    usePhoneView(t);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 120,
              child: Row(
                children: [
                  ProviderBrandIcon(brand: brandOf('openai/gpt-5.2'), size: 20),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'gpt-5.2-super-long-experimental-preview',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    expect(t.getSize(find.byType(ProviderBrandIcon)), const Size(20, 20));
    final text = t.widget<Text>(find.textContaining('gpt-5.2'));
    expect(text.overflow, TextOverflow.ellipsis);
  });

  testWidgets('the filled mark carries a tinted plate, the plain one does not', (t) async {
    usePhoneView(t);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              ProviderBrandIcon(brand: ModelBrand.claude, size: 20, filled: true),
              ProviderBrandIcon(brand: ModelBrand.claude, size: 20),
            ],
          ),
        ),
      ),
    );

    final plates = t.widgetList<Container>(find.byType(Container));
    expect(plates.length, 1);
    final decoration = plates.single.decoration! as BoxDecoration;
    expect(decoration.shape, BoxShape.circle);
    expect(
      decoration.color!.a,
      closeTo(0.12, 0.01),
      reason: '淡底只该是很薄的一层品牌色',
    );
  });

  testWidgets('the mark is decorative unless a label is given', (t) async {
    usePhoneView(t);
    await t.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              ProviderBrandIcon(brand: ModelBrand.deepseek, semanticLabel: 'DeepSeek'),
              ProviderBrandIcon(brand: ModelBrand.deepseek),
            ],
          ),
        ),
      ),
    );

    expect(find.bySemanticsLabel('DeepSeek'), findsOneWidget);
  });
}
