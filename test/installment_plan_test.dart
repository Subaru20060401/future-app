// 分割の見込み（金利・月額）と保存後の額が一致するテスト（コード点検 2026-10-22 で見つけたもの）。
// ⚠️ 以前は「分割払いを編集」の見込みが元のカードの金利で出ていて、
//   カードを選び直すと保存後の月額（新しいカードの金利）と食い違っていた。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/app_state.dart';
import 'package:my_counter_app/money_format.dart';
import 'package:my_counter_app/screens/payment_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AppState> app() async {
    final a = AppState();
    await a.ready;
    a.cardPaymentDays
      ..['楽天カード'] = 27
      ..['三井OLIVE'] = 26;
    a.setInterestRate('楽天カード', 15.0);
    a.setInterestRate('三井OLIVE', 0.0);
    a.installments.add(Installment(
      id: 'i1',
      name: 'テスト分割',
      cardName: '楽天カード',
      totalAmount: 120000,
      installmentCount: 6,
      remainingMonths: 6,
      monthlyAmount: 0,
      interestRate: 15,
      startDate: DateTime(2026, 10, 1),
    ));
    return a;
  }

  test('編集でカードを変えたら、新しいカードの金利で計算し直す（見込みと同じ）', () async {
    final a = await app();
    final plan = a.installmentPlanOf('三井OLIVE', 120000, 6);
    a.editInstallment('i1', count: 6, cardName: '三井OLIVE');
    final i = a.installments.single;
    expect(i.interestRate, plan.rate);
    expect(i.monthlyAmount, plan.monthly);
    expect(i.monthlyAmount, 20000, reason: '金利0%なら12万÷6');
  });

  test('Amazonの2・3回は手数料無料', () {
    expect(computeInstallmentMonthly(30000, 3, 0), 10000);
  });

  testWidgets('編集画面の見込みは、選び直したカードの金利で出る', (t) async {
    t.view.physicalSize = const Size(430, 1200);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final a = await app();
    await t.pumpWidget(ChangeNotifierProvider.value(
      value: a,
      child: const MaterialApp(home: PaymentScreen()),
    ));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(Tab, '分割'));
    await t.pumpAndSettle();
    await t.tap(find.text('テスト分割'));
    await t.pumpAndSettle();

    final rakuten = a.installmentPlanOf('楽天カード', 120000, 6);
    expect(find.text('月額 ¥${yenNum(rakuten.monthly)} × 6回'), findsOneWidget);

    await t.tap(find.text('楽天カード').last);
    await t.pumpAndSettle();
    await t.tap(find.text('三井OLIVE').last);
    await t.pumpAndSettle();
    expect(find.text('月額 ¥20,000 × 6回'), findsOneWidget);
    expect(find.text('金利(年率): 0.0%'), findsOneWidget);

    await t.tap(find.widgetWithText(ElevatedButton, '保存'));
    await t.pumpAndSettle();
    expect(a.installments.single.monthlyAmount, 20000);
  });
}
