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
