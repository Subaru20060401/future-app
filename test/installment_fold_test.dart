// 分割払いを「独立した引き落とし」ではなく、組んだカードの請求に含めて扱うテスト。
// 実際の引き落としがカードごとの日付で起きるため、ここがズレると
// 「三井は落ちたが楽天はまだ」の時点で口座残高と予想が食い違う。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  AppState app() => AppState()
    ..cardPaymentDays.addAll(AppState.kSeedCardPaymentDays);

  void addInst(AppState a, String card, int monthly, DateTime start) {
    a.installments.add(Installment(
      id: 'i_${card}_$monthly',
      name: '$card の分割',
      cardName: card,
      totalAmount: monthly * 6,
      installmentCount: 6,
      remainingMonths: 6,
      monthlyAmount: monthly,
      interestRate: 0,
      startDate: start,
    ));
  }

  Payment usage(String card, int amount, DateTime d) => Payment(
        id: '$card$amount',
        cardName: card,
        amount: amount,
        paymentDate: d,
        source: PaymentSource.usage,
      );

  final aug = DateTime(2026, 8);
  final augDay = DateTime(2026, 8, 10);

  group('カードごとに割り振る', () {
    test('分割の月額がカード別に分かれる', () {
      final a = app();
      addInst(a, '三井OLIVE', 5000, augDay);
      addInst(a, '楽天カード', 3000, augDay);

      final byCard = a.installmentTotalByCardOf(aug);
      expect(byCard['三井OLIVE'], 5000);
      expect(byCard['楽天カード'], 3000);
    });

    test('支出内訳に「分割払い」の独立スライスは出ない', () {
      final a = app()..payments.add(usage('三井OLIVE', 10000, augDay));
      addInst(a, '三井OLIVE', 5000, augDay);

      final labels = a.expenseBreakdownOf(aug).map((e) => e.label);
      expect(labels, isNot(contains('分割払い')));
    });

    test('カードの金額に分割ぶんが足されている', () {
      final a = app()..payments.add(usage('三井OLIVE', 10000, augDay));
      addInst(a, '三井OLIVE', 5000, augDay);

      final mitsui = a.expenseBreakdownOf(aug).firstWhere((e) => e.label == '三井OLIVE');
      expect(mitsui.amount, 15000);
    });

    test('カードの明細に分割の行が出る', () {
      final a = app()..payments.add(usage('三井OLIVE', 10000, augDay));
      addInst(a, '三井OLIVE', 5000, augDay);

      final rows = a.expenseDetailOf(aug, '三井OLIVE');
      expect(rows.any((r) => r.title.startsWith('分割:')), isTrue);
      expect(rows.fold(0, (s, r) => s + r.amount), 15000);
    });
  });

  group('引き落としのタイミング', () {
    test('分割ぶんはカードの引き落とし日に乗る', () {
      // 三井は26日、楽天は29日。分割はそれぞれの日に含まれて落ちる。
      final a = app();
      addInst(a, '三井OLIVE', 5000, augDay);
      addInst(a, '楽天カード', 3000, augDay);

      final draw = a.drawBreakdownOf(DateTime(2026, 9));
      expect(draw.any((e) => e.label == '分割払い'), isFalse);
      expect(draw.firstWhere((e) => e.label == '三井OLIVE').amount, 5000);
      expect(draw.firstWhere((e) => e.label == '楽天カード').amount, 3000);
    });

    test('参考表示の「うち分割払い」は合計と別に取れる', () {
      final a = app();
      addInst(a, '三井OLIVE', 5000, augDay);
      addInst(a, '楽天カード', 3000, augDay);

      expect(a.installmentPartOfDraw(DateTime(2026, 9)), 8000);
      // 合計にはカード側で1回だけ入っている（二重に足されていない）
      expect(a.drawnInMonth(DateTime(2026, 9)), 8000);
    });
  });

  group('カード未設定の古いデータ', () {
    test('消さずに別枠で残す（予想から抜け落ちない）', () {
      final a = app();
      a.installments.add(Installment(
        id: 'old',
        name: '昔の分割',
        cardName: '', // 旧UIではカードを選べなかった
        totalAmount: 30000,
        installmentCount: 6,
        remainingMonths: 6,
        monthlyAmount: 5000,
        interestRate: 0,
        startDate: augDay,
      ));

      expect(a.unassignedInstallmentTotalOf(aug), 5000);
      final labels = a.expenseBreakdownOf(aug).map((e) => e.label);
      expect(labels, contains('分割払い（カード未設定）'));
      expect(a.installmentsWithoutCard, hasLength(1));
    });

    test('カードを設定すればそのカードに合算される', () {
      final a = app();
      a.installments.add(Installment(
        id: 'old',
        name: '昔の分割',
        cardName: '',
        totalAmount: 30000,
        installmentCount: 6,
        remainingMonths: 6,
        monthlyAmount: 5000,
        interestRate: 0,
        startDate: augDay,
      ));

      a.editInstallment('old', count: 6, cardName: '三井OLIVE');
      expect(a.unassignedInstallmentTotalOf(aug), 0);
      expect(a.installmentTotalByCardOf(aug)['三井OLIVE'], greaterThan(0));
      final labels = a.expenseBreakdownOf(aug).map((e) => e.label);
      expect(labels, isNot(contains('分割払い（カード未設定）')));
    });
  });

  group('銀行確定済みの月', () {
    test('確定額に含まれるので分割を足さない', () {
      final a = app()
        ..payments.add(Payment(
          id: 'b1',
          cardName: '三井OLIVE',
          amount: 12000,
          paymentDate: DateTime(2026, 9, 26), // 8月利用ぶんの確定
          source: PaymentSource.bank,
        ));
      addInst(a, '三井OLIVE', 5000, augDay);

      final mitsui = a.expenseBreakdownOf(aug).firstWhere((e) => e.label == '三井OLIVE');
      expect(mitsui.amount, 12000, reason: '確定額に既に分割が含まれている');
      expect(a.installmentFoldedInto(aug), 0);
    });
  });
}
