import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Loan loan({String id = 'pc', String name = 'PC JACCSショッピングローン'}) => Loan(
    id: id,
    name: name,
    principal: 193800,
    totalCount: 24,
    startMonth: DateTime(2026, 9),
    firstPaymentAmount: 9800,
    monthlyOverride: 8000,
  );

  Payment bank({String name = 'ジヤツクス', int amount = 9800, DateTime? date}) =>
      Payment(
        id: 'bank',
        cardName: name,
        amount: amount,
        paymentDate: date ?? DateTime(2026, 10, 27),
        source: PaymentSource.bank,
        sourceId: 'mail#0',
      );

  test('既存の初回請求を表記ゆれで照合し、9800円を1回だけ引く', () {
    final a = AppState()
      ..loans.add(loan())
      ..payments.add(bank());
    expect(a.repairLoanBillingLinks(), isTrue);
    expect(a.drawnInMonth(DateTime(2026, 10)), 9800);
    expect(a.drawBreakdownOf(DateTime(2026, 10)), hasLength(1));
    expect(a.payments, hasLength(1));
    expect(a.unregisteredCardNames, isEmpty);
    expect(a.repairLoanBillingLinks(), isFalse);
    // 💡 確定メールが来ていない次の月は、通常額の予測を続ける。
    expect(a.drawnInMonth(DateTime(2026, 11)), 8000);
    expect(a.expenseDetailOf(DateTime(2026, 9), 'ジヤツクス').single.amount, 9800);
  });

  test('通常額と違っても、手動で対応を確定したら銀行額が正本', () {
    final l = loan()..firstPaymentAmount = 0;
    final a = AppState()
      ..loans.add(l)
      ..payments.add(bank());
    expect(a.repairLoanBillingLinks(), isFalse);
    a.linkBankBillingToLoan('ジヤツクス', l.id);
    expect(a.drawnInMonth(DateTime(2026, 10)), 9800);
    expect(l.monthlyOverride, 8000);
  });

  test('銀行確定後は手動の頭金も重ねない。別日の頭金は残す', () {
    final l = loan()
      ..downPayment = 9800
      ..downPaymentDate = DateTime(2026, 10, 27);
    final a = AppState()
      ..loans.add(l)
      ..payments.add(bank());
    a.linkBankBillingToLoan('ジヤツクス', l.id);
    expect(a.oneTimeExpensesIn(DateTime(2026, 10)), isEmpty);
    expect(
      a.drawnInMonth(DateTime(2026, 10)) +
          a.oneTimeExpenseForecastIn(DateTime(2026, 10)),
      9800,
    );
    l.downPaymentDate = DateTime(2026, 10, 20);
    expect(a.oneTimeExpenseForecastIn(DateTime(2026, 10)), 9800);
  });

  test('頭金は翌月の確定請求では消さない', () {
    final l = loan()
      ..downPayment = 9800
      ..downPaymentDate = DateTime(2026, 9, 27);
    final a = AppState()
      ..loans.add(l)
      ..payments.add(bank());
    a.linkBankBillingToLoan('ジヤツクス', l.id);
    expect(a.oneTimeExpenseForecastIn(DateTime(2026, 9)), 9800);
  });

  test('銀行の実際の日付で残高更新日の二重計上ゲートを通す', () {
    final a = AppState()
      ..loans.add(loan())
      ..payments.add(bank());
    a.linkBankBillingToLoan('ジヤツクス', 'pc');
    a.balanceUpdatedAt = DateTime(2026, 10, 26);
    expect(a.drawnInMonth(DateTime(2026, 10)), 9800);
    a.balanceUpdatedAt = DateTime(2026, 10, 27);
    expect(a.drawnInMonth(DateTime(2026, 10)), 0);
  });

  test('同じ会社に複数ローンがあれば、同額でも自動では選ばない', () {
    final a = AppState()
      ..loans.addAll([loan(), loan(id: 'other', name: '家電（ジャックス）')])
      ..payments.add(bank());
    expect(a.repairLoanBillingLinks(), isFalse);
    a.linkBankBillingToLoan('ジヤツクス', 'pc');
    expect(a.drawnInMonth(DateTime(2026, 10)), 19600);
    expect(
      a
          .expenseBreakdownOf(DateTime(2026, 9))
          .any((e) => e.label == '家電（ジャックス）'),
      isTrue,
    );
  });

  test('日付・額が違う、無関係な名前、登録済みカードは自動統合しない', () {
    for (final p in [
      bank(amount: 10000),
      bank(date: DateTime(2026, 10, 26)),
      bank(name: '別会社'),
    ]) {
      final a = AppState()
        ..loans.add(loan())
        ..payments.add(p);
      expect(a.repairLoanBillingLinks(), isFalse);
    }
    final a = AppState()
      ..loans.add(loan())
      ..payments.add(bank())
      ..cardPaymentDays['ジヤツクス'] = 27;
    expect(a.repairLoanBillingLinks(), isFalse);
  });

  test('カード払いのローンと、関係ない銀行請求は従来どおり', () {
    final a = AppState()
      ..loans.add(loan()..method = 'テストカード')
      ..payments.add(bank(name: '別カード'));
    expect(a.repairLoanBillingLinks(), isFalse);
    expect(a.drawnInMonth(DateTime(2026, 10)), 19600);
  });

  test('銀行の記録のみ行は予定額を打ち消さない', () {
    final a = AppState()
      ..loans.add(loan())
      ..payments.add(bank()..infoOnly = true);
    a.linkBankBillingToLoan('ジヤツクス', 'pc');
    expect(
      a
          .expenseBreakdownOf(DateTime(2026, 9))
          .firstWhere((e) => e.label.contains('PC'))
          .amount,
      9800,
    );
  });

  test('紐づけを解除しても取り込みで勝手に戻らない', () {
    final a = AppState()
      ..loans.add(loan())
      ..payments.add(bank());
    a.repairLoanBillingLinks();
    a.unlinkBankBillingFromLoan('pc', 'ジヤツクス');
    expect(a.repairLoanBillingLinks(), isFalse);
    expect(a.unregisteredCardNames, hasLength(1));
  });

  test('名前変更・保存・置換インポートでも紐づけを維持する', () {
    final a = AppState()
      ..loans.add(loan())
      ..payments.add(bank());
    a.linkBankBillingToLoan('ジヤツクス', 'pc');
    a.loans.single.name = '新しい名前';
    final restored = AppState()..importJson(a.exportJson());
    expect(restored.loanForBankBillingName('ジャックス')?.name, '新しい名前');
    expect(restored.drawnInMonth(DateTime(2026, 10)), 9800);
    final withoutLinks = jsonDecode(a.exportJson()) as Map<String, dynamic>;
    withoutLinks['loans'][0]['bankBillingNames'] = [];
    withoutLinks['loans'][0]['autoLinkBankBills'] = false;
    restored.importJson(jsonEncode(withoutLinks));
    expect(restored.loanForBankBillingName('ジヤツクス'), isNull);
  });

  test('旧バックアップの既存行もインポート時に自己修復する', () {
    final a = AppState()
      ..loans.add(loan())
      ..payments.add(bank());
    final restored = AppState()..importJson(a.exportJson());
    expect(restored.loans.single.bankBillingNames, ['ジヤツクス']);
    expect(restored.drawnInMonth(DateTime(2026, 10)), 9800);
  });

  test('メールの作り直しでも対応を保ち、通常額に戻る', () {
    final a = AppState()..loans.add(loan());
    a.reconcilePayments([
      (
        cardName: 'ジヤツクス',
        amount: 9800,
        date: DateTime(2026, 10, 27),
        source: PaymentSource.bank,
        sourceId: 'mail#0',
        note: '',
      ),
    ]);
    expect(a.loanForBankBillingName('ジヤツクス')?.id, 'pc');
    a.reconcilePayments([
      (
        cardName: 'ジヤツクス',
        amount: 8000,
        date: DateTime(2026, 11, 27),
        source: PaymentSource.bank,
        sourceId: 'mail2#0',
        note: '',
      ),
    ]);
    expect(a.drawnInMonth(DateTime(2026, 11)), 8000);
  });
}
