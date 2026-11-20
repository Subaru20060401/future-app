// 💡 予想残高を「手で計算できる小さいケース」で確かめる。
//   期待値はすべてコメントの手計算から書いた（実装の出力を写したものではない）。
//   今日は 2026-11-19（木）に固定する。
//
//   使う暦（銀行の休業日は土日祝）:
//     11/16 月  11/23 月・勤労感謝の日  11/25 水  11/26 木  11/27 金
//     12/26 土  12/27 日  12/28 月
//     2027-01-26 火  01-27 水
import 'package:flutter_test/flutter_test.dart';
import 'package:my_counter_app/app_state.dart';

import 'support/test_app.dart';

void main() {
  final today = DateTime(2026, 11, 19, 10);

  // 共通の材料（手計算の前提）
  //   口座 100,000円、残高を書いたのは 11/16（この日以前の動きは残高に入っている）
  //   カードA: 引落日 26日・月末締め
  //     10/10 に 10,000円 → 11/26（木）に引落し
  //     11/05 に  3,000円 → 12/26（土）→ 翌営業日 12/28（月）に引落し
  //   勤務先「カフェ」: 月末締め・翌月25日払い（休みなら前営業日）
  //     10/06 10:00〜15:00 時給1,000円 → 5,000円 を 11/25（水）に受け取る
  //   定期「スマホ」1,000円・毎月27日・口座振替
  //     11/27（金）、12/27（日）→12/28（月）、1/27（水）
  //   予定支出「旅行」20,000円・12/05
  Future<AppState> build() async {
    final app = await fixedApp(today);
    app.currentBalance = 100000;
    app.balanceUpdatedAt = DateTime(2026, 11, 16, 9);
    app.cardPaymentDays['カードA'] = 26;
    app.payments.addAll([
      usage('カードA', 10000, DateTime(2026, 10, 10, 12)),
      usage('カードA', 3000, DateTime(2026, 11, 5, 12)),
    ]);
    final w = Workplace(id: 'wp-cafe', name: 'カフェ', paydayDay: 25, paydayMonthOffset: 1);
    app.workplaces.add(w);
    addShift(app, shiftAt(w, DateTime(2026, 10, 6, 10), DateTime(2026, 10, 6, 15)));
    app.subscriptions.add(Subscription(id: 's1', title: 'スマホ', amount: 1000, payDay: 27));
    app.plannedExpenses.add(PlannedExpense(
        id: 'pe1', title: '旅行', amount: 20000, date: DateTime(2026, 12, 5)));
    return app;
  }

  test('月末の予想（今月・来月・翌々月）', () async {
    final app = await build();
    // 11月末 = 100,000 + 5,000(給料11/25) − 10,000(カードA 11/26) − 1,000(スマホ11/27) = 94,000
    expect(app.thisMonthBalance, 94000);
    // 12月末 = 94,000 − 20,000(旅行12/5) − 3,000(カードA 12/28) − 1,000(スマホ12/28) = 70,000
    expect(app.nextMonthBalance, 70000);
    // 1月末 = 70,000 − 1,000(スマホ1/27) = 69,000（12月の利用は無いのでカードAは0）
    expect(app.monthAfterNextBalance, 69000);
  });

  test('引落日は休みなら翌営業日（12/26土 → 12/28月）', () async {
    final app = await build();
    expect(app.drawDateOf('カードA', DateTime(2026, 12)), DateTime(2026, 12, 28));
    expect(app.drawDateOf('カードA', DateTime(2026, 11)), DateTime(2026, 11, 26));
  });

  test('いちばん少なくなる日', () async {
    final app = await build();
    // 今 100,000 → 11/25 +5,000=105,000 → 11/26 −10,000=95,000 → 11/27 −1,000=94,000
    //   → 12/5 −20,000=74,000 → 12/28 −4,000=70,000 → 1/27 −1,000=69,000
    final low = app.lowestBalanceAhead()!;
    expect(low.balance, 69000);
    expect(low.date, DateTime(2027, 1, 27));
  });

  test('残高を書いた日より前の動きは予想に入れない（二重計上ゲート）', () async {
    final app = await build();
    // 11/26 の 12:00 に残高を書いた＝11/25 の給料と 11/26 のカードAは残高に入っている。
    //   11月末 = 100,000 − 1,000(スマホ11/27) = 99,000
    app.balanceUpdatedAt = DateTime(2026, 11, 26, 12);
    expect(app.thisMonthBalance, 99000);
  });

  test('財布の現金は起点に足す。表示をOFFにすると足さない', () async {
    final app = await build();
    app.walletCash = 3000;
    expect(app.thisMonthBalance, 97000); // 94,000 + 3,000
    app.showWalletCash = false;
    expect(app.thisMonthBalance, 94000);
  });

  test('銀行の引落確定があれば、その日付と金額を使う', () async {
    final app = await build();
    // 11月の請求は銀行のお知らせで 11/27 に 9,500円と確定（利用通知の合計 10,000円より正）
    app.payments.add(bank('カードA', 9500, DateTime(2026, 11, 27)));
    expect(app.drawDateOf('カードA', DateTime(2026, 11)), DateTime(2026, 11, 27));
    // 11月末 = 100,000 + 5,000 − 9,500 − 1,000 = 94,500
    expect(app.thisMonthBalance, 94500);
  });

  test('カード払いの分割は、そのカードの請求に合算して引落日に落ちる', () async {
    final app = await build();
    // 10/20 にカードAで 3回払い（月 2,000円）。10月・11月・12月の利用ぶんとして積まれ、
    //   11/26・12/28・1/26 に落ちる（n月の引落 = n-1月の利用）
    app.installments.add(Installment(
      id: 'i1',
      name: '家電',
      cardName: 'カードA',
      totalAmount: 6000,
      installmentCount: 3,
      remainingMonths: 3,
      monthlyAmount: 2000,
      startDate: DateTime(2026, 10, 20),
    ));
    expect(app.thisMonthBalance, 92000); // 94,000 − 2,000
    expect(app.nextMonthBalance, 66000); // 70,000 − 2,000 − 2,000
    expect(app.monthAfterNextBalance, 63000); // 69,000 − 2,000 − 2,000 + ... ↓
    // 1月: 66,000 − 1,000(スマホ) − 2,000(分割3回目、12月利用ぶん) = 63,000
  });

  test('一度きりの出費は月をずらさず、その日付の月に引く', () async {
    final app = await build();
    final dec = app.oneTimeExpensesIn(DateTime(2026, 12));
    expect(dec.map((e) => (e.label, e.amount, e.date)),
        [('旅行', 20000, DateTime(2026, 12, 5))]);
    expect(app.oneTimeExpensesIn(DateTime(2027, 1)), isEmpty);
  });

  test('次の引き落とし（30日以内・今日以降・日付順）', () async {
    final app = await build();
    // 今日 11/19 から 12/19 まで: 11/26 カードA −10,000、11/27 スマホ −1,000、12/5 旅行 −20,000
    final out = app.upcomingOutflows();
    expect(out.map((l) => (l.date, l.label, l.amount)), [
      (DateTime(2026, 11, 26), 'カードA', -10000),
      (DateTime(2026, 11, 27), '定期: スマホ', -1000),
      (DateTime(2026, 12, 5), '旅行', -20000),
    ]);
  });

  test('残高を書いてからの日数（11/16 → 11/19 で 3 日）', () async {
    final app = await build();
    expect(app.daysSinceBalanceUpdate, 3);
    app.balanceUpdatedAt = null;
    expect(app.daysSinceBalanceUpdate, isNull);
  });
}
