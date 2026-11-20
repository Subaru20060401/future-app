// 💡 財布の現金は口座の残高の予想に入れない（2026-11 仕様変更）。
//   財布は記録・表示するだけ。ATM で引き出すと口座が減り、財布が増える。
//   期待値はすべてコメントの手計算から書いた。今日は 2026-11-19（木）に固定する。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_counter_app/app_state.dart';

import 'support/test_app.dart';

void main() {
  final today = DateTime(2026, 11, 19, 10);

  // 口座 50,000円・財布 5,000円・ほかに入出金なし
  Future<AppState> simple() async {
    final app = await fixedApp(today);
    app.currentBalance = 50000;
    app.balanceUpdatedAt = DateTime(2026, 11, 19, 9);
    app.walletCash = 5000;
    return app;
  }

  group('財布は口座の予想に入れない', () {
    test('口座 50,000・財布 5,000・入出金なし → 3 か月とも月末は 50,000（表示の ON/OFF で変わらない）', () async {
      final app = await simple();
      for (final show in [true, false]) {
        app.showWalletCash = show;
        expect(app.thisMonthBalance, 50000, reason: '表示 $show');
        expect(app.nextMonthBalance, 50000, reason: '表示 $show');
        expect(app.monthAfterNextBalance, 50000, reason: '表示 $show');
        expect(app.forecastMonths(count: 1).single.start, 50000);
      }
    });

    test('根拠の内訳に「財布の現金」は出ない（今月の起点は口座の残高だけ）', () async {
      final app = await simple();
      expect(app.thisMonthBreakdown.containsKey('財布の現金'), isFalse);
      expect(app.thisMonthBreakdown['現在の残高'], 50000);
    });

    test('最低残高・足りない日・不足の通知も財布を数えない', () async {
      final app = await fixedApp(today);
      // 口座 3,000・財布 10,000。カードA（26日払い）で 10/10 に 5,000円 → 11/26 に引落し
      //   口座だけ: 3,000 − 5,000 = −2,000（足りない）。財布を足すと 8,000 で足りてしまう（以前の誤り）
      app.currentBalance = 3000;
      app.balanceUpdatedAt = DateTime(2026, 11, 19, 9);
      app.walletCash = 10000;
      app.cardPaymentDays['カードA'] = 26;
      app.payments.add(usage('カードA', 5000, DateTime(2026, 10, 10, 12)));
      for (final show in [true, false]) {
        app.showWalletCash = show;
        final low = app.lowestBalanceAhead()!;
        expect(low.balance, -2000, reason: '表示 $show');
        expect(low.date, DateTime(2026, 11, 26));
        final short = app.shortfallDaysAhead();
        expect(short.map((d) => d.date), [DateTime(2026, 11, 26)], reason: '表示 $show');
        expect(short.single.balance, -2000);
      }
    });

    test('財布の金額は消えない（保存・書き出し・取り込みで残る）', () async {
      final app = await simple();
      await app.saveData();
      final b = await reloadApp(today);
      expect(b.walletCash, 5000);
      final c = await fixedApp(today);
      await c.importJson(app.exportJson());
      expect(c.walletCash, 5000);
    });
  });

  group('ATM で引き出す: 口座が減り、財布が増える', () {
    test('口座 50,000・財布 5,000 で 10,000 引き出す → 口座 40,000・財布 15,000、月末の見込み 40,000', () async {
      final app = await simple();
      app.addWithdrawal(date: DateTime(2026, 11, 19), amount: 10000);
      expect(app.currentBalance, 40000);
      expect(app.walletCash, 15000);
      expect(app.thisMonthBalance, 40000);
      // 支出の内訳の「ATM」には、これまでどおり出す
      expect(app.withdrawalsOf(DateTime(2026, 11)), 10000);
      expect(app.balanceHistory.first.label, 'ATM引き出し');
      expect(app.balanceHistory.first.amount, 10000);
    });

    test('引き出しを消すと口座と財布が元に戻る', () async {
      final app = await simple();
      app.addWithdrawal(date: DateTime(2026, 11, 19), amount: 10000);
      app.removeWithdrawal(app.withdrawals.single.id);
      expect(app.currentBalance, 50000);
      expect(app.walletCash, 5000);
      expect(app.balanceHistory.where((e) => e.label == 'ATM引き出し'), isEmpty);
    });

    test('入出金の履歴から取り消しても、口座・財布・引き出しの記録がそろって戻る', () async {
      final app = await simple();
      app.addWithdrawal(date: DateTime(2026, 11, 19), amount: 10000);
      app.undoBalanceEntry(app.balanceHistory.first.id);
      expect(app.currentBalance, 50000);
      expect(app.walletCash, 5000);
      expect(app.withdrawals, isEmpty);
    });

    test('以前の版で登録した引き出し（口座・財布を動かしていない）を消しても、お金は動かさない', () async {
      final app = await simple();
      final data = jsonDecode(app.exportJson()) as Map<String, dynamic>;
      data['withdrawals'] = [
        {'id': 'old1', 'date': '2026-11-10T00:00:00.000', 'amount': 3000, 'memo': ''}
      ];
      await app.importJson(jsonEncode(data));
      expect(app.withdrawals.single.movedToWallet, isFalse);
      app.removeWithdrawal('old1');
      expect(app.currentBalance, 50000);
      expect(app.walletCash, 5000);
    });

    test('引き出しの印は保存・取り込みで残る（あとで消しても正しく戻る）', () async {
      final app = await simple();
      app.addWithdrawal(date: DateTime(2026, 11, 19), amount: 10000);
      final c = await fixedApp(today);
      await c.importJson(app.exportJson());
      expect(c.withdrawals.single.movedToWallet, isTrue);
      c.removeWithdrawal(c.withdrawals.single.id);
      expect(c.currentBalance, 50000);
      expect(c.walletCash, 5000);
    });
  });
}
