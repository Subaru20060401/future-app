// 💡 金額の意味の区別（docs/architecture-plan.md §11）:
//   ① 利用月の支出（履歴・推移・年間支出）… 残高のゲートを使わない
//   ③ 残高の予想 … 残高を書いた日より後のものだけ
//   暦: 2026-12-26 土 → 12-28 月 / 2027-01-26 火
import 'package:flutter_test/flutter_test.dart';
import 'package:my_counter_app/app_state.dart';

import 'support/test_app.dart';

void main() {
  Future<AppState> build() async {
    final app = await fixedApp(DateTime(2027, 1, 20, 10));
    app.currentBalance = 100000;
    app.cardPaymentDays['A'] = 26;
    app.payments.addAll([
      usage('A', 5000, DateTime(2026, 11, 10, 12)), // 11月利用 → 12/28 引落
      usage('A', 8000, DateTime(2026, 12, 20, 12)), // 12月利用 → 1/26 引落（年をまたぐ）
    ]);
    app.subscriptions.add(Subscription(id: 's', title: '動画', amount: 1000, payDay: 10));
    return app;
  }

  test('残高を書き直しても、過去の支出履歴は変わらない', () async {
    final app = await build();
    Map<String, int> hist(DateTime m) =>
        {for (final e in app.expenseBreakdownOf(m)) e.label: e.amount};
    final before = [for (final m in [11, 12]) hist(DateTime(2026, m))];
    final trend = app.monthlyTrend(4).map((e) => e.expense).toList();
    final year = app.expenseSummaryOfYear(2026);

    app.updateBalance(50000); // 残高を書いた日＝今日（予想のゲートが進む）

    expect([for (final m in [11, 12]) hist(DateTime(2026, m))], before);
    expect(app.monthlyTrend(4).map((e) => e.expense).toList(), trend);
    expect(app.expenseSummaryOfYear(2026), year);
  });

  test('12月の利用は翌年1月に引き落とされても、12月（2026年）の支出に入る', () async {
    final app = await build();
    expect(app.expenseBreakdownOf(DateTime(2026, 12)).singleWhere((e) => e.label == 'A').amount,
        8000);
    // 年間支出: 11月 5,000 + 定期1,000 / 12月 8,000 + 定期1,000（定期は毎月）
    //   2026年の 1〜10 月にも定期 1,000 が今の設定から計算されて入る（12か月 × 1,000）
    final y = app.expenseSummaryOfYear(2026);
    expect(y.total, 5000 + 8000 + 12 * 1000);
    expect(y.fromSettings, 12 * 1000); // 定期は今の設定からの推定
    // 2027年には 12月利用ぶんは入らない（1月の利用は無いので定期だけ）
    expect(app.expenseSummaryOfYear(2027).total, 12 * 1000);
    // 一方、残高の予想では 1/26 の引き落としとして 1 月に入る（支払日の月）
    final jan = app.forecastMonths(count: 1).first.lines.singleWhere((l) => l.label == 'A');
    expect(jan.date, DateTime(2027, 1, 26));
    expect(jan.amount, -8000);
  });

  test('銀行確定のカードは記録（実績）、分割は設定からの計算として分ける', () async {
    final app = await build();
    app.installments.add(Installment(
        id: 'i',
        name: 'PC',
        cardName: 'A',
        totalAmount: 9000,
        installmentCount: 3,
        remainingMonths: 3,
        monthlyAmount: 3000,
        startDate: DateTime(2026, 11, 1)));
    final nov = app.expenseSummaryOf(DateTime(2026, 11));
    expect(nov.total, 5000 + 3000 + 1000);
    expect(nov.fromSettings, 3000 + 1000);
    // 11月利用ぶんが銀行で確定したら、確定額に分割も含まれるので設定からの計算は定期だけ
    app.payments.add(bank('A', 8000, DateTime(2026, 12, 28)));
    final novConfirmed = app.expenseSummaryOf(DateTime(2026, 11));
    expect(novConfirmed.total, 8000 + 1000);
    expect(novConfirmed.fromSettings, 1000);
  });
}
