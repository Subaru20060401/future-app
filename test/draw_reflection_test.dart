// 💡 確認待ちの引き落としの二重引き落とし対策（公開前の確認 1）。
//   ・「入力した残高に含まれているか」は前後関係からの推定で、断定しない
//   ・同じ引き落とし（同じ ID）は一度だけ反映する。判定は AppState 側（画面に頼らない）
//   ・別の正当な請求を処理済みにしない
//   暦: 2026-11-26 木（A の引落）/ 11-27 金
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:my_counter_app/app_state.dart';
import 'package:my_counter_app/widgets/deposit_dialog.dart';

import 'support/test_app.dart';

void main() {
  late DateTime now;
  Future<AppState> app() async {
    now = DateTime(2026, 11, 27, 10);
    final a = await clockApp(() => now);
    a.currentBalance = 100000;
    a.cardPaymentDays['A'] = 26;
    a.payments.add(usage('A', 10000, DateTime(2026, 10, 5, 12))); // 11/26 に 10,000 落ちる
    return a;
  }

  const id = 'card:A:2026-11';

  group('入力した残高に含まれているか（推定）', () {
    test('引落の翌日に残高を入力 → 含まれている可能性', () async {
      final a = await app();
      a.updateBalance(90000);
      expect(a.drawReflectionOf(DateTime(2026, 11, 26)), DrawReflection.maybeIncluded);
    });

    test('引落と同じ日に入力 → 判断できない（入力が引落の前か後か分からない）', () async {
      final a = await app();
      now = DateTime(2026, 11, 26, 8);
      a.updateBalance(100000);
      expect(a.drawReflectionOf(DateTime(2026, 11, 26)), DrawReflection.unknown);
    });

    test('引落の前日に入力 → まだ含まれていない見込み', () async {
      final a = await app();
      now = DateTime(2026, 11, 25, 20);
      a.updateBalance(100000);
      now = DateTime(2026, 11, 27, 10);
      expect(a.drawReflectionOf(DateTime(2026, 11, 26)), DrawReflection.likelyNotIncluded);
    });

    test('残高を入力した記録が無い（旧データ）→ 判断できない', () async {
      final a = await app();
      a.balanceUpdatedAt = DateTime(2026, 11, 27); // 旧データにはゲートの日付しか無い
      expect(a.drawReflectionOf(DateTime(2026, 11, 26)), DrawReflection.unknown);
    });

    test('入金・引き落としの反映では「入力した残高」は進まない（1件引いても他が「含まれている」にならない）',
        () async {
      final a = await app();
      now = DateTime(2026, 11, 25, 20);
      a.updateBalance(100000);
      a.cardPaymentDays['C'] = 27;
      a.payments.add(usage('C', 3000, DateTime(2026, 10, 7, 12))); // 11/27 に落ちる
      now = DateTime(2026, 11, 28, 10);
      expect(a.applyDraw(id, 10000, label: 'A（予定）'), isTrue);
      expect(a.balanceEnteredAt, DateTime(2026, 11, 25, 20));
      expect(a.drawReflectionOf(DateTime(2026, 11, 27)), DrawReflection.likelyNotIncluded);
    });
  });

  group('一度だけ反映する（AppState 側の判定）', () {
    test('引落後に残高を入力 → 基本の「残高はそのまま確認」なら残高は変わらない', () async {
      final a = await app();
      a.updateBalance(90000);
      expect(a.pendingDraws.map((d) => d.id), contains(id)); // 確認待ちからは消さない
      expect(a.skipDraw(id), isTrue);
      expect(a.currentBalance, 90000);
      expect(a.pendingDraws.map((d) => d.id), isNot(contains(id)));
    });

    test('連打: 2回目は何もしない', () async {
      final a = await app();
      expect(a.applyDraw(id, 10000), isTrue);
      expect(a.applyDraw(id, 10000), isFalse);
      expect(a.currentBalance, 90000);
      expect(a.balanceHistory.where((e) => e.sourceKey == id), hasLength(1));
    });

    test('確認したあとに「引く」が来ても何もしない（逆も同じ）', () async {
      final a = await app();
      expect(a.skipDraw(id), isTrue);
      expect(a.applyDraw(id, 10000), isFalse);
      expect(a.currentBalance, 100000);
      final b = await app();
      expect(b.applyDraw(id, 10000), isTrue);
      expect(b.skipDraw(id), isFalse);
      expect(b.currentBalance, 90000);
    });

    test('再起動後に同じ ID がもう一度来ても何もしない（保存した状態から読み直す）', () async {
      final a = await app();
      expect(a.applyDraw(id, 10000), isTrue);
      await a.saveData();
      final b = await reloadApp(now);
      expect(b.currentBalance, 90000);
      expect(b.pendingDraws.map((d) => d.id), isNot(contains(id)));
      expect(b.applyDraw(id, 10000), isFalse);
      expect(b.currentBalance, 90000);
    });

    test('まとめて引くのは「まだ含まれていない見込み」だけ', () async {
      final a = await app();
      now = DateTime(2026, 11, 26, 20);
      a.updateBalance(90000); // 11/26 に入力（A は同じ日＝判断できない）
      a.cardPaymentDays['C'] = 27;
      a.payments.add(usage('C', 3000, DateTime(2026, 10, 7, 12))); // 11/27
      now = DateTime(2026, 11, 28, 10);
      final r = a.applyLikelyNotIncludedDraws();
      expect(r, (count: 1, amount: 3000));
      expect(a.currentBalance, 87000);
      expect(a.pendingDraws.map((d) => d.id), contains(id)); // 判断できない A は残す
    });
  });

  group('別の正当な請求を処理済みにしない', () {
    test('31日払い: ずれた10月請求（11/2）と11月請求（11/30）は別々。片方の処理でもう片方は消えない', () async {
      now = DateTime(2026, 12, 1, 9);
      final a = await clockApp(() => now);
      a.cardPaymentDays['B'] = 31;
      a.payments.addAll([
        usage('B', 1000, DateTime(2026, 9, 10, 12)),
        usage('B', 2000, DateTime(2026, 10, 10, 12)),
      ]);
      a.skipDraw('card:B:2026-11'); // 11月請求（11/30）だけ処理
      expect(a.pendingDraws.map((d) => d.id), ['card:B:2026-10']); // 10月請求（11/2）は残る
      a.applyDraw('card:B:2026-10', 1000);
      expect(a.pendingDraws, isEmpty);
    });

    test('同じ日・同じ金額の別のカードは別の引き落とし', () async {
      final a = await app();
      a.cardPaymentDays['D'] = 26;
      a.payments.add(usage('D', 10000, DateTime(2026, 10, 5, 12)));
      a.applyDraw(id, 10000);
      expect(a.pendingDraws.map((d) => d.id), ['card:D:2026-11']);
    });
  });

  group('画面: 引き落としの確認', () {
    Future<void> open(WidgetTester tester, AppState a, ({String id, String label, int amount, DateTime date}) d) async {
      await initializeDateFormatting('ja_JP');
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('ja'),
        supportedLocales: const [Locale('ja')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(
          body: Builder(
            builder: (c) => TextButton(
              onPressed: () => showDrawDialog(c, a, d),
              child: const Text('開く'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('開く'));
      await tester.pumpAndSettle();
    }

    testWidgets('含まれている可能性があるとき: 基本は「残高はそのまま」、引く前に対象・金額・変更後の残高', (tester) async {
      late AppState a;
      await tester.runAsync(() async {
        a = await app();
        a.updateBalance(90000);
      });
      final d = a.pendingDraws.single;
      await open(tester, a, d);
      expect(find.textContaining('含まれている可能性があります'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, '残高はそのまま（確認した）'), findsOneWidget);
      await tester.tap(find.text('残高から引く…'));
      await tester.pumpAndSettle();
      expect(find.text('残高から引きますか？'), findsOneWidget);
      expect(find.textContaining('A（予定）'), findsWidgets);
      expect(find.text('引いた後の残高'), findsOneWidget);
      expect(find.text('¥80,000'), findsOneWidget);
      expect(find.text('入力した残高に含まれていると、二重に引くことになります'), findsOneWidget);
      await tester.tap(find.text('やめる'));
      await tester.pumpAndSettle();
      expect(a.currentBalance, 90000);
      expect(a.pendingDraws, isNotEmpty);
    });
  });
}
