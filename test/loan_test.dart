// ローン機能のテスト。
// 分割払いと違い、口座から直接・返済日も個別・返済開始が先のことがある。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  AppState app() =>
      AppState()..cardPaymentDays.addAll(AppState.kSeedCardPaymentDays);

  group('返済額と期間', () {
    test('無利息なら 借入額 ÷ 回数', () {
      final l = Loan(
        id: 'l1',
        name: '奨学金',
        principal: 2400000,
        totalCount: 240,
        startMonth: DateTime(2028, 10),
      );
      expect(l.monthlyAmount, 10000);
      expect(l.finishMonth, DateTime(2048, 9));
    });

    test('毎月の返済額を直接指定できる', () {
      final l = Loan(
        id: 'l2',
        name: '奨学金',
        principal: 2400000,
        totalCount: 240,
        startMonth: DateTime(2028, 10),
        monthlyOverride: 12345,
      );
      expect(l.monthlyAmount, 12345);
    });

    test('返済開始より前の月は対象外', () {
      final l = Loan(
        id: 'l3',
        name: '奨学金',
        principal: 120000,
        totalCount: 12,
        startMonth: DateTime(2028, 4),
      );
      expect(l.isActiveIn(DateTime(2026, 9)), isFalse); // 在学中
      expect(l.countIn(DateTime(2028, 4)), 1);
      expect(l.countIn(DateTime(2028, 5)), 2);
      expect(l.isActiveIn(DateTime(2029, 4)), isFalse); // 完済後
    });

    test('残り回数と残債', () {
      final l = Loan(
        id: 'l4',
        name: 'ローン',
        principal: 120000,
        totalCount: 12,
        startMonth: DateTime(2026, 1),
      );
      expect(l.remainingCountAt(DateTime(2026, 1)), 12);
      expect(l.remainingCountAt(DateTime(2026, 7)), 6);
      expect(l.remainingAmountAt(DateTime(2026, 7)), 60000);
      expect(l.remainingCountAt(DateTime(2030, 1)), 0);
    });
  });

  group('予想残高への反映', () {
    test('口座払いは自分の名前で、自分の返済日に落ちる', () {
      final a = app()
        ..addLoan(
          name: '奨学金',
          principal: 120000,
          totalCount: 12,
          startMonth: DateTime(2026, 8),
          payDay: 27,
        );

      final aug = a.expenseBreakdownOf(DateTime(2026, 8));
      expect(aug.firstWhere((e) => e.label == '奨学金').amount, 10000);

      // 9月の引き落としに、8月ぶんとして出る
      final draw = a.drawBreakdownOf(DateTime(2026, 9));
      expect(draw.firstWhere((e) => e.label == '奨学金').amount, 10000);
    });

    test('返済開始前は何も引かれない', () {
      final a = app()
        ..addLoan(
          name: '奨学金',
          principal: 120000,
          totalCount: 12,
          startMonth: DateTime(2028, 4), // 卒業後から
        );
      expect(a.expenseBreakdownOf(DateTime(2026, 8)).any((e) => e.label == '奨学金'),
          isFalse);
      expect(a.drawnInMonth(DateTime(2026, 9)), 0);
    });

    test('カード払いのローンはそのカードの請求に含まれる', () {
      final a = app()
        ..addLoan(
          name: '車のローン',
          principal: 120000,
          totalCount: 12,
          startMonth: DateTime(2026, 8),
          method: '三井OLIVE',
        );

      final aug = a.expenseBreakdownOf(DateTime(2026, 8));
      expect(aug.any((e) => e.label == '車のローン'), isFalse);
      expect(aug.firstWhere((e) => e.label == '三井OLIVE').amount, 10000);
    });

    test('内訳をタップすると回数が見える', () {
      final a = app()
        ..addLoan(
          name: '奨学金',
          principal: 120000,
          totalCount: 12,
          startMonth: DateTime(2026, 8),
        );
      final rows = a.expenseDetailOf(DateTime(2026, 9), '奨学金');
      expect(rows.single.subtitle, contains('2/12回目'));
    });
  });

  group('頭金', () {
    test('借入額には含めず、総額として表示できる', () {
      final l = Loan(
        id: 'l5',
        name: '車のローン',
        principal: 1000000,
        totalCount: 60,
        startMonth: DateTime(2026, 10),
        downPayment: 300000,
        downPaymentDate: DateTime(2026, 9, 20),
      );
      expect(l.totalPrice, 1300000); // 頭金 30万 ＋ 借入 100万
      expect(l.monthlyAmount, 16667); // 無利息なら 100万 ÷ 60回
      expect(l.totalCost, 300000 + 16667 * 60);
      expect(l.hasDownPayment, isTrue);
    });

    test('口座払いの頭金は、その日付の月にそのまま引かれる', () {
      final a = app()
        ..addLoan(
          name: '車のローン',
          principal: 600000,
          totalCount: 60,
          startMonth: DateTime(2026, 10),
        );
      a.loans.single
        ..downPayment = 300000
        ..downPaymentDate = DateTime(2026, 9, 20);

      // 月ズレしない（9月の出費として9月に引く）
      final sep = a.oneTimeExpensesIn(DateTime(2026, 9));
      expect(sep, hasLength(1));
      expect(sep.single.label, '車のローン 頭金');
      expect(sep.single.amount, 300000);
      expect(a.oneTimeExpensesIn(DateTime(2026, 10)), isEmpty);
    });

    test('カード払いの頭金はそのカードの請求に入る', () {
      final a = app()
        ..addLoan(
          name: '車のローン',
          principal: 600000,
          totalCount: 60,
          startMonth: DateTime(2026, 10),
        );
      a.loans.single
        ..downPayment = 300000
        ..downPaymentDate = DateTime(2026, 9, 20)
        ..downPaymentMethod = '三井OLIVE';

      expect(a.oneTimeExpensesIn(DateTime(2026, 9)), isEmpty); // 口座からは出ない
      final sep = a.expenseBreakdownOf(DateTime(2026, 9));
      expect(sep.firstWhere((e) => e.label == '三井OLIVE').amount, 300000);
    });
  });

  group('予定支出', () {
    test('予定日の月に引かれ、払ったら消える', () {
      final a = app()
        ..addPlannedExpense(
            title: '車検', amount: 80000, date: DateTime(2026, 11, 5));

      expect(a.oneTimeExpensesIn(DateTime(2026, 11)).single.amount, 80000);
      expect(a.oneTimeExpensesIn(DateTime(2026, 10)), isEmpty);

      a.markPlannedExpensePaid(a.plannedExpenses.single.id, DateTime(2026, 11, 5));
      expect(a.oneTimeExpensesIn(DateTime(2026, 11)), isEmpty);
    });

    test('毎月くり返しにできる', () {
      final a = app()
        ..addPlannedExpense(
            title: '仕送り',
            amount: 30000,
            date: DateTime(2026, 9, 10),
            monthly: true);
      expect(a.oneTimeExpensesIn(DateTime(2026, 9)).single.amount, 30000);
      expect(a.oneTimeExpensesIn(DateTime(2026, 12)).single.amount, 30000);
      expect(a.oneTimeExpensesIn(DateTime(2026, 8)), isEmpty); // 登録前
    });

    test('書き出し・取り込みで保たれる', () {
      final a = app()
        ..addPlannedExpense(
            title: '旅行', amount: 50000, date: DateTime(2026, 12, 20));
      final restored = AppState()..importJson(a.exportJson());
      expect(restored.plannedExpenses.single.title, '旅行');
      expect(restored.plannedExpenses.single.amount, 50000);
    });
  });

  group('初回だけ金額が違う契約（ショッピングクレジット）', () {
    // ジャックスのショッピングクレジットの実例:
    // 現金価格 193,800 / 手数料 0 / 24回 / 2026年10月〜2028年9月 / 毎月27日
    // 第1回 9,800円、第2回目以降 8,000円 × 23回
    Loan jaccs() => Loan(
          id: 'jaccs',
          name: 'BTOパソコン（ジャックス）',
          principal: 193800,
          totalCount: 24,
          startMonth: DateTime(2026, 10),
          payDay: 27,
          firstPaymentAmount: 9800,
        );

    test('2回目以降の額が残りから逆算される', () {
      final l = jaccs();
      expect(l.firstAmount, 9800);
      expect(l.monthlyAmount, 8000); // (193800 - 9800) / 23
    });

    test('支払総額が契約書と一致する', () {
      expect(jaccs().totalRepayment, 193800);
    });

    test('初回の月だけ金額が違う', () {
      final l = jaccs();
      expect(l.amountIn(DateTime(2026, 10)), 9800);
      expect(l.amountIn(DateTime(2026, 11)), 8000);
      expect(l.amountIn(DateTime(2028, 9)), 8000); // 最終回
      expect(l.amountIn(DateTime(2028, 10)), 0); // 完済後
      expect(l.finishMonth, DateTime(2028, 9));
    });

    test('残債が正しく減る', () {
      // remainingAmountAt は「その月の時点でこれから払う額」。
      // 10月の返済(27日)はまだなので、10月時点では全額残っている。
      final l = jaccs();
      expect(l.remainingAmountAt(DateTime(2026, 9)), 193800); // 開始前
      expect(l.remainingAmountAt(DateTime(2026, 10)), 193800); // 初回はこれから
      expect(l.remainingAmountAt(DateTime(2026, 11)), 184000); // 初回を払い終えた
      expect(l.remainingAmountAt(DateTime(2026, 12)), 176000);
      expect(l.remainingAmountAt(DateTime(2029, 1)), 0); // 完済後
    });

    test('予想残高にも初回の額で反映される', () {
      final a = app()
        ..addLoan(
          name: 'BTOパソコン（ジャックス）',
          principal: 193800,
          totalCount: 24,
          startMonth: DateTime(2026, 10),
          payDay: 27,
          firstPaymentAmount: 9800,
        );
      final oct = a.expenseBreakdownOf(DateTime(2026, 10));
      expect(oct.firstWhere((e) => e.label.contains('BTO')).amount, 9800);
      final nov = a.expenseBreakdownOf(DateTime(2026, 11));
      expect(nov.firstWhere((e) => e.label.contains('BTO')).amount, 8000);
    });
  });

  group('保存', () {
    test('書き出し・取り込みで保たれる', () {
      final a = app()
        ..addLoan(
          name: '奨学金',
          principal: 2400000,
          totalCount: 240,
          startMonth: DateTime(2028, 10),
          payDay: 27,
          interestRate: 0,
        );
      final restored = AppState()..importJson(a.exportJson());
      expect(restored.loans, hasLength(1));
      final l = restored.loans.single;
      expect(l.name, '奨学金');
      expect(l.totalCount, 240);
      expect(l.startMonth, DateTime(2028, 10));
      expect(l.monthlyAmount, 10000);
    });
  });
}
