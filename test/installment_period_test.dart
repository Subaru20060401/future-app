// 分割払いの「その月が何回目か」のテスト（コード点検 2026-10-22 の指摘）。
// ⚠️ 以前は同じ式が AppState に5か所あった。1か所（Installment.countIn）に寄せたので、
//   境目（開始前・初月・最終月・終了後・年越し・開始日の無い旧データ）をここで固める。
// ⚠️ 合計と内訳が同じ判定を使うこと（以前は開始日の無い旧データを合計にだけ入れていた）。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/app_state.dart';

Installment inst({DateTime? start, int count = 3, int remaining = 3, String card = '三井OLIVE'}) =>
    Installment(
      id: 'i1',
      name: 'テスト分割',
      cardName: card,
      totalAmount: 3000 * count,
      installmentCount: count,
      remainingMonths: remaining,
      monthlyAmount: 3000,
      interestRate: 0,
      startDate: start,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('何回目か', () {
    final i = inst(start: DateTime(2026, 11, 20)); // 11月・12月・1月の3回

    test('開始前は0、初月は1、最終月は3、終了後は0', () {
      expect(i.countIn(DateTime(2026, 10)), 0);
      expect(i.countIn(DateTime(2026, 11)), 1);
      expect(i.countIn(DateTime(2026, 12)), 2);
      expect(i.countIn(DateTime(2027, 1)), 3, reason: '年越し');
      expect(i.countIn(DateTime(2027, 2)), 0);
    });

    test('計上額は期間内だけ', () {
      final now = DateTime(2026, 10, 22);
      expect(i.amountIn(DateTime(2026, 10), now: now), 0);
      expect(i.amountIn(DateTime(2027, 1), now: now), 3000);
      expect(i.amountIn(DateTime(2027, 2), now: now), 0);
      expect(i.countLabelIn(DateTime(2026, 12)), '2/3回目');
    });

    test('開始日の無い旧データは、残りがあれば今月だけ', () {
      final now = DateTime(2026, 10, 22);
      final old = inst(start: null, remaining: 2);
      expect(old.countIn(DateTime(2026, 10)), 0);
      expect(old.amountIn(DateTime(2026, 10), now: now), 3000);
      expect(old.amountIn(DateTime(2026, 11), now: now), 0);
      expect(inst(start: null, remaining: 0).amountIn(DateTime(2026, 10), now: now), 0);
    });
  });

  group('合計と内訳が一致する', () {
    final now = DateTime.now();
    final thisMonth = DateTime(now.year, now.month);

    AppState app() => AppState()..cardPaymentDays.addAll(AppState.kSeedCardPaymentDays);

    test('開始日の無い旧データも、カードの内訳に出る（合計と同じ）', () {
      final a = app()..installments.add(inst(start: null, remaining: 2));
      expect(a.installmentTotalByCardOf(thisMonth)['三井OLIVE'], 3000);
      final rows = a.expenseDetailOf(thisMonth, '三井OLIVE').where((r) => r.title.startsWith('分割:'));
      expect(rows.map((r) => r.amount), [3000]);
      expect(rows.single.subtitle, contains('開始日なし'));
    });

    test('「分割払い」の内訳と合計が一致する', () {
      final a = app()
        ..installments.addAll([
          inst(start: null, remaining: 2, card: ''),
          inst(start: DateTime(now.year, now.month), card: ''),
        ]);
      final rows = a.expenseDetailOf(thisMonth, '分割払い');
      expect(rows.fold(0, (s, r) => s + r.amount), a.installmentTotalOf(thisMonth));
      expect(a.unassignedInstallmentTotalOf(thisMonth), 6000);
    });
  });
}
