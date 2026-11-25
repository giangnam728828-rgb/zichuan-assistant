import 'package:dsh_app/ui/chat/model_brand_mark.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// 临时目检：把 11 种品牌标记排成一张图，跑 --update-goldens 生成后人工查看。
void main() {
  testWidgets('all brands render', (tester) async {
    final brands = ModelBrand.values;
    await tester.binding.setSurfaceSize(const Size(11 * 64 + 24, 120));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: 'Roboto'),
        home: ColoredBox(
          color: Colors.white,
          child: Center(
            child: SizedBox(
              width: 11 * 64 + 24,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final b in brands)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ModelBrandMark(brand: b, onTap: () {}),
                          const SizedBox(height: 6),
                          Text(b.name, style: const TextStyle(fontSize: 9)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Row).first,
      matchesGoldenFile('goldens/brand_marks_all.png'),
    );
  });
}
