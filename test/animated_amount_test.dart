// 金額が変わったときの動き（AnimatedAmount）のテスト。
// ⚠️ 表示だけのもの。最初に0円から数え上げない・同じ金額では動かない・
//   動きを減らす設定では止まる、を固定する。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_counter_app/widgets/animated_amount.dart';

void main() {
  // 値を差し替えられる入れ物
  Widget host(int value, {bool reduceMotion = false}) => MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduceMotion),
          child: Scaffold(
            body: AnimatedAmount(value: value, style: const TextStyle(fontSize: 20)),
          ),
        ),
      );

  testWidgets('最初に表示したときは動かさず、差額も出さない', (t) async {
    await t.pumpWidget(host(50000));
    expect(find.text('¥ 50000'), findsOneWidget);
    expect(find.textContaining('今回の更新'), findsNothing);
  });

  testWidgets('金額が変わると途中を通って最終値になり、差額を添える', (t) async {
    await t.pumpWidget(host(50000));
    await t.pumpWidget(host(47000));
    await t.pump(const Duration(milliseconds: 100)); // 途中
    expect(find.text('¥ 50000'), findsNothing);
    expect(find.text('¥ 47000'), findsNothing, reason: 'まだ動いている途中');
    await t.pump(const Duration(milliseconds: 300)); // 250ms を過ぎた
    expect(find.text('¥ 47000'), findsOneWidget);
    expect(find.text('今回の更新 −¥3000'), findsOneWidget);
  });

  testWidgets('差額は数秒で消える', (t) async {
    await t.pumpWidget(host(50000));
    await t.pumpWidget(host(53000));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('今回の更新 +¥3000'), findsOneWidget);
    await t.pump(const Duration(seconds: 5));
    expect(find.textContaining('今回の更新'), findsNothing);
    expect(find.text('¥ 53000'), findsOneWidget);
  });

  testWidgets('同じ金額で作り直されても動かない', (t) async {
    await t.pumpWidget(host(50000));
    await t.pumpWidget(host(50000));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('¥ 50000'), findsOneWidget);
    expect(find.textContaining('今回の更新'), findsNothing);
  });

  testWidgets('続けて変わったら、差額は最初の値からまとめて出す', (t) async {
    await t.pumpWidget(host(50000));
    await t.pumpWidget(host(47000));
    await t.pump(const Duration(milliseconds: 300));
    await t.pumpWidget(host(45000));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('¥ 45000'), findsOneWidget);
    expect(find.text('今回の更新 −¥5000'), findsOneWidget);
  });

  testWidgets('動きを減らす設定なら、すぐ最終値にする', (t) async {
    await t.pumpWidget(host(50000, reduceMotion: true));
    await t.pumpWidget(host(47000, reduceMotion: true));
    await t.pump(); // 1フレームだけ
    expect(find.text('¥ 47000'), findsOneWidget);
    expect(find.text('今回の更新 −¥3000'), findsOneWidget);
  });
}
