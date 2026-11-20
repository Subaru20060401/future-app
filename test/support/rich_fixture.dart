// 💡 回帰テスト用の、要素を一通り含む架空の家計データ（実データではない）。
//   ⚠️ このデータで記録した値は「その時点の実装の出力」であって、正しさの根拠ではない。
//     正しさは forecast_hand_calc_test.dart などの手計算テストで確かめる。
import 'package:my_counter_app/app_state.dart';

import 'test_app.dart';

Future<AppState> richApp(DateTime now) async {
  final app = await fixedApp(now);
  app.currentBalance = 150000;
  app.walletCash = 2000;
  app.balanceUpdatedAt = DateTime(2026, 10, 28, 20);

  // カード（引落日・締め日）
  app.cardPaymentDays.addAll({
    '三井OLIVE': 26,
    '楽天カード': 27,
    '三菱カード': 10,
    '月末払いカード': 31, // 月末が休みだと翌月にずれる（10/31土→11/2、1/31日→2/1）
    'Amazonマスター': 26,
  });
  app.cardClosingDays['三菱カード'] = 15;

  final p = app.payments;
  // 三井OLIVE: 9月・10月・11月・12月の利用
  p.addAll([
    usage('三井OLIVE', 4800, DateTime(2026, 9, 12, 12)),
    usage('三井OLIVE', 12000, DateTime(2026, 10, 3, 18)),
    usage('三井OLIVE', 2300, DateTime(2026, 10, 21, 8)),
    usage('三井OLIVE', 6600, DateTime(2026, 11, 2, 13)),
    usage('三井OLIVE', 1500, DateTime(2026, 12, 4, 9)),
    // 10月利用ぶんの銀行の引落確定（11/26）
    bank('三井OLIVE', 15000, DateTime(2026, 11, 26)),
  ]);
  // 楽天カード
  p.addAll([
    usage('楽天カード', 8900, DateTime(2026, 10, 11, 12)),
    usage('楽天カード', 25000, DateTime(2026, 11, 20, 12)),
    usage('楽天カード', 3200, DateTime(2026, 12, 1, 12)),
    Payment(
      id: 'rk-bill',
      cardName: '楽天カード',
      amount: 9100,
      paymentDate: DateTime(2026, 11, 27),
      source: PaymentSource.billing,
      sourceId: 'bill-rk-11',
    ),
  ]);
  // 三菱カード（15日締め・10日払い）
  p.addAll([
    usage('三菱カード', 7000, DateTime(2026, 10, 14, 12)),
    usage('三菱カード', 5000, DateTime(2026, 10, 16, 12)),
    usage('三菱カード', 4000, DateTime(2026, 11, 15, 12)),
    usage('三菱カード', 9000, DateTime(2026, 11, 30, 12)),
    usage('三菱カード', 2500, DateTime(2026, 12, 20, 12)),
  ]);
  // 月末払いカード
  p.addAll([
    usage('月末払いカード', 6000, DateTime(2026, 9, 20, 12)),
    usage('月末払いカード', 7000, DateTime(2026, 10, 20, 12)),
    usage('月末払いカード', 8000, DateTime(2026, 12, 20, 12)),
  ]);
  // デビット（即時引落）と、記録だけの Amazon 明細、手入力
  p.addAll([
    usage('三井デビット', 1200, DateTime(2026, 10, 27, 12)),
    usage('三井デビット', 800, DateTime(2026, 10, 29, 12)),
    usage('三井デビット', 950, DateTime(2026, 11, 18, 12)),
    Payment(
      id: 'amz1',
      cardName: 'Amazonマスター',
      amount: 3980,
      paymentDate: DateTime(2026, 11, 8),
      source: PaymentSource.usage,
      sourceId: 'amazon#order-1',
      infoOnly: true,
    ),
    Payment(
      id: 'man1',
      cardName: '楽天カード',
      amount: 1100,
      paymentDate: DateTime(2026, 11, 12),
      source: PaymentSource.manual,
      note: '手入力',
    ),
  ]);

  // 分割払い
  app.installments.addAll([
    Installment(
      id: 'inst-rk',
      name: 'パソコン',
      cardName: '楽天カード',
      totalAmount: 120000,
      installmentCount: 6,
      remainingMonths: 6,
      monthlyAmount: 20500,
      startDate: DateTime(2026, 9, 25),
    ),
    Installment(
      id: 'inst-mb',
      name: 'イヤホン',
      cardName: '三菱カード',
      totalAmount: 30000,
      installmentCount: 3,
      remainingMonths: 3,
      monthlyAmount: 10000,
      startDate: DateTime(2026, 11, 3),
    ),
    Installment(
      id: 'inst-none',
      name: 'カード未設定の分割',
      totalAmount: 9000,
      installmentCount: 3,
      remainingMonths: 3,
      monthlyAmount: 3000,
      startDate: DateTime(2026, 11, 1),
    ),
  ]);

  // ローン（口座払い＝個別の返済日、カード払い＝カードの請求に合算、頭金は口座から）
  app.loans.addAll([
    Loan(
      id: 'loan-sch',
      name: '奨学金',
      principal: 100000,
      totalCount: 10,
      startMonth: DateTime(2026, 12),
      payDay: 27,
    ),
    Loan(
      id: 'loan-car',
      name: '原付',
      principal: 60000,
      totalCount: 6,
      startMonth: DateTime(2026, 11),
      method: '三井OLIVE',
      downPayment: 15000,
      downPaymentDate: DateTime(2026, 12, 10),
    ),
  ]);

  // 定期支払い（口座振替・カード払い・手動払い）
  app.subscriptions.addAll([
    Subscription(id: 'sub-phone', title: 'スマホ', amount: 2980, payDay: 27),
    Subscription(id: 'sub-video', title: '動画配信', amount: 990, payDay: 15, method: '楽天カード'),
    Subscription(id: 'sub-gym', title: 'ジム', amount: 3000, payDay: 5, method: kManualPayMethod),
  ]);

  // 予定の入出金
  app.plannedIncomes.add(PlannedIncome(
      id: 'pi-home', title: '仕送り', amount: 30000, date: DateTime(2026, 10, 5), monthly: true));
  app.plannedExpenses.addAll([
    PlannedExpense(id: 'pe-trip', title: '旅行', amount: 40000, date: DateTime(2026, 12, 18)),
    PlannedExpense(
        id: 'pe-club', title: '部費', amount: 2000, date: DateTime(2026, 11, 30), monthly: true),
  ]);
  app.paypayTransfers.add(PayPayTransfer(
    id: 'pp1',
    amount: 10000,
    acceptedAt: DateTime(2026, 11, 30, 21),
    scheduledDate: DateTime(2026, 12, 3),
    bank: '三井住友銀行',
  ));
  app.withdrawals.add(Withdrawal(id: 'atm1', date: DateTime(2026, 11, 10), amount: 5000));

  // 勤務先とシフト
  final cafe = Workplace(id: 'wp-cafe', name: 'カフェ', paydayDay: 25, paydayMonthOffset: 1);
  final juku = Workplace(
      id: 'wp-juku',
      name: '塾',
      closingDay: 15,
      paydayDay: 10,
      paydayMonthOffset: 1,
      paydayAdjust: PaydayAdjust.after);
  app.workplaces.addAll([cafe, juku]);
  for (final m in [9, 10, 11, 12, 13]) {
    final y = m > 12 ? 2027 : 2026;
    final mm = m > 12 ? m - 12 : m;
    for (final d in [3, 9, 17, 24]) {
      addShift(app, shiftAt(cafe, DateTime(y, mm, d, 10), DateTime(y, mm, d, 16), wage: 1100));
    }
    addShift(app, shiftAt(juku, DateTime(y, mm, 12, 17), DateTime(y, mm, 12, 21), wage: 1500));
  }
  // 10月のカフェは実給料を入力済み
  app.actualSalariesByWp['2026-10|wp-cafe'] = 27000;
  return app;
}
