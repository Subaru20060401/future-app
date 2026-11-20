// 💡 定期支払いの開始月（＝最初の利用月）。開始月より前の支出・引き落とし・確認待ちには載せない。
//   口座振替・手動払いは利用した月に、カード払いは翌月（カードの引落日）に口座から落ちる。
//   開始月の無い以前のデータは、従来どおりどの月にも載せる。
//   期待値はすべてコメントの手計算から書いた。今日は 2026-11-19（木）に固定する。
//
//   使う暦: 11/27 金、12/27 日 → 12/28 月、2027-01-26 火、01-27 水、02-26 金、02-27 土 → 03-01 月
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_counter_app/app_state.dart';
import 'package:my_counter_app/widgets/month_picker_field.dart';

import 'support/test_app.dart';

void main() {
  final today = DateTime(2026, 11, 19, 10);

  // 口座 100,000円、残高を書いたのは 11/19 9:00。カードA は 26日払い・月末締め。ほかの動きは無い
  Future<AppState> base() async {
    final app = await fixedApp(today);
    app.currentBalance = 100000;
    app.balanceUpdatedAt = DateTime(2026, 11, 19, 9);
    app.cardPaymentDays['カードA'] = 26;
    return app;
  }

  Subscription account({DateTime? start, int payDay = 27, String method = ''}) => Subscription(
      id: 's1', title: '動画', amount: 1000, payDay: payDay, method: method, startMonth: start);

  group('口座振替・12月開始・毎月27日・1,000円', () {
    test('支出（利用月）: 11月 0、12月 1,000、1月 1,000', () async {
      final app = await base();
      app.subscriptions.add(account(start: DateTime(2026, 12)));
      expect(app.subscriptionTotalOf(DateTime(2026, 11)), 0); // 開始前
      expect(app.subscriptionTotalOf(DateTime(2026, 12)), 1000); // 開始月
      expect(app.subscriptionTotalOf(DateTime(2027, 1)), 1000);
      expect(app.expenseDetailOf(DateTime(2026, 11), '定期支払い'), isEmpty);
      expect(app.expenseDetailOf(DateTime(2026, 12), '定期支払い').single.amount, 1000);
    });

    test('残高の予想: 11月末 100,000 → 12月末 99,000（12/27日→12/28月）→ 1月末 98,000（1/27）', () async {
      final app = await base();
      app.subscriptions.add(account(start: DateTime(2026, 12)));
      expect(app.thisMonthBalance, 100000); // 11/27 は開始前なので引かない
      expect(app.nextMonthBalance, 99000); // 100,000 − 1,000
      expect(app.monthAfterNextBalance, 98000); // 99,000 − 1,000
      final dec = app.forecastMonths(count: 2)[1].lines.single;
      expect(dec.date, DateTime(2026, 12, 28));
      expect(dec.amount, -1000);
    });

    test('年間支出: 2026年は12月の 1,000 だけ、2027年は 12 か月で 12,000（年またぎ）', () async {
      final app = await base();
      app.subscriptions.add(account(start: DateTime(2026, 12)));
      expect(app.expenseSummaryOfYear(2026).total, 1000);
      expect(app.expenseSummaryOfYear(2027).total, 12000);
    });
  });

  group('カード払い（カードA・26日払い）・12月開始・1,000円', () {
    test('支出は12月の利用から。最初に口座から落ちるのは1月（1/26）', () async {
      final app = await base();
      app.subscriptions.add(account(start: DateTime(2026, 12), method: 'カードA'));
      expect(app.subscriptionTotalOf(DateTime(2026, 11)), 0);
      expect(app.subscriptionTotalOf(DateTime(2026, 12)), 1000);
      // 11月末 100,000（11/26 の引落に入らない）、12月末 100,000（12/28 の引落は11月利用＝開始前）、
      // 1月末 99,000（12月利用の 1,000 を 1/26 に引く）
      expect(app.thisMonthBalance, 100000);
      expect(app.nextMonthBalance, 100000);
      expect(app.monthAfterNextBalance, 99000);
      final jan = app.forecastMonths(count: 3)[2].lines.single;
      expect(jan.date, DateTime(2027, 1, 26));
      expect(app.subscriptionFirstDrawMonth('カードA', DateTime(2026, 12)), DateTime(2027, 1));
      expect(app.subscriptionFirstDrawMonth('', DateTime(2026, 12)), DateTime(2026, 12));
    });

    test('すでに届いている銀行の確定明細は残る（その月の請求は確定額を使い、定期を足さない）', () async {
      final app = await base();
      app.subscriptions.add(account(start: DateTime(2026, 12), method: 'カードA'));
      // 1/26 の引落（12月利用ぶん）が銀行で 5,000円と確定済み
      app.payments.add(bank('カードA', 5000, DateTime(2027, 1, 26)));
      // 1月末 = 100,000 − 5,000（確定額。定期 1,000 は確定額に含まれるので足さない）= 95,000
      expect(app.monthAfterNextBalance, 95000);
      expect(app.payments.where((p) => p.source == PaymentSource.bank), hasLength(1));
    });
  });

  group('開始月のない以前のデータ', () {
    test('従来どおり毎月載せる（11月末 99,000＝11/27 に 1,000）', () async {
      final app = await base();
      app.subscriptions.add(account());
      expect(app.subscriptions.single.startMonth, isNull);
      expect(app.subscriptionTotalOf(DateTime(2026, 11)), 1000);
      expect(app.subscriptionTotalOf(DateTime(2020, 1)), 1000);
      expect(app.thisMonthBalance, 99000);
    });

    test('取り込んでも開始月は未設定のまま（勝手に今月にしない）。あとから設定できる', () async {
      final src = await base();
      final data = jsonDecode(src.exportJson()) as Map<String, dynamic>;
      data['subscriptions'] = [
        {'id': 'old', 'title': '古い定期', 'amount': 1000, 'payDay': 27, 'method': ''}
      ];
      final app = await base();
      await app.importJson(jsonEncode(data));
      expect(app.subscriptions.single.startMonth, isNull);
      expect(app.thisMonthBalance, 99000);
      expect(jsonEncode(app.subscriptions.single.toJson()), isNot(contains('startMonth')));
      app.setSubscriptionStartMonth('old', DateTime(2026, 12));
      expect(app.thisMonthBalance, 100000);
      await settle();
      final b = await reloadApp(today);
      expect(b.subscriptions.single.startMonth, DateTime(2026, 12));
      app.setSubscriptionStartMonth('old', null); // 未設定に戻す
      expect(app.thisMonthBalance, 99000);
    });

    test('開始月は書き出し・取り込みで残る', () async {
      final src = await base();
      src.subscriptions.add(account(start: DateTime(2027, 1)));
      final app = await base();
      await app.importJson(src.exportJson());
      expect(app.subscriptions.single.startMonth, DateTime(2027, 1));
      expect(app.subscriptionTotalOf(DateTime(2026, 12)), 0);
      expect(app.subscriptionTotalOf(DateTime(2027, 1)), 1000);
    });
  });

  group('確認待ち（口座振替・毎月5日）', () {
    test('今月開始で支払日を過ぎてから登録 → 11/5 は確認待ちに出る。開始前の10月は出ない', () async {
      final app = await base();
      app.subscriptions.add(account(start: DateTime(2026, 11), payDay: 5));
      final ids = app.pendingDraws.map((d) => d.id).toList();
      expect(ids, contains('sub:s1:2026-11'));
      expect(ids, isNot(contains('sub:s1:2026-10')));
    });

    test('開始月のない以前のデータは、従来どおり 10月・11月とも出る', () async {
      final app = await base();
      app.subscriptions.add(account(payDay: 5));
      final ids = app.pendingDraws.map((d) => d.id).toList();
      expect(ids, containsAll(['sub:s1:2026-10', 'sub:s1:2026-11']));
    });

    test('来月開始なら、まだ何も出ない', () async {
      final app = await base();
      app.subscriptions.add(account(start: DateTime(2026, 12), payDay: 5));
      expect(app.pendingDraws.where((d) => d.id.startsWith('sub:')), isEmpty);
    });
  });

  testWidgets('開始月の欄: ◀ ▶ で月が動き、12月 → 1月で年が変わる。未設定に戻せる', (tester) async {
    DateTime? value = DateTime(2026, 12);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => MonthPickerField(
            label: '開始月',
            value: value,
            allowUnset: true,
            fallback: DateTime(2026, 11),
            onChanged: (m) => setState(() => value = m),
          ),
        ),
      ),
    ));
    expect(find.text('2026年12月'), findsOneWidget);
    await tester.tap(find.byTooltip('1か月後'));
    await tester.pump();
    expect(value, DateTime(2027, 1));
    expect(find.text('2027年1月'), findsOneWidget);
    await tester.tap(find.byTooltip('1か月前'));
    await tester.pump();
    await tester.tap(find.byTooltip('1か月前'));
    await tester.pump();
    expect(value, DateTime(2026, 11));
    await tester.tap(find.text('未設定に戻す'));
    await tester.pump();
    expect(value, isNull);
    expect(find.text('未設定'), findsOneWidget);
    // 年と月を選ぶ
    await tester.tap(find.text('未設定'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('前の年'));
    await tester.pump();
    await tester.tap(find.text('3月'));
    await tester.pumpAndSettle();
    expect(value, DateTime(2025, 3));
  });
}
