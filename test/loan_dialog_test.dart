// ローンの追加画面に出す額と、保存後に予想で使う額が一致するテスト（コード点検 2026-10-22 の指摘）。
// ⚠️ 以前は画面が同じ計算を自前で持っていて、端数の丸め方が違った。
//   元金100円・年利3%・3回・初回2円で、画面は「49円×2」、保存後は「50円×2」だった。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/app_state.dart';
import 'package:my_counter_app/screens/payment_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AppState> openDialog(WidgetTester t) async {
    t.view.physicalSize = const Size(430, 1400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final app = AppState();
    await app.ready;
    await t.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: const MaterialApp(home: PaymentScreen()),
    ));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(Tab, 'ローン'));
    await t.pumpAndSettle();
    await t.tap(find.byType(FloatingActionButton));
    await t.pumpAndSettle();
    return app;
  }

  Future<void> fill(WidgetTester t, String label, String v) async {
    await t.enterText(find.widgetWithText(TextField, label), v);
    await t.pump();
  }

  testWidgets('初回だけ違う契約：画面の額と保存後の額が同じ', (t) async {
    final app = await openDialog(t);
    await fill(t, '名前', 'テストローン');
    await fill(t, '借入総額(円)', '100');
    await fill(t, '返済回数（月）', '3');
    await fill(t, '年利(%)', '3');
    await fill(t, '初回だけ違う金額（任意）', '2');

    final l = Loan(
        id: '', name: '', principal: 100, totalCount: 3,
        startMonth: DateTime(2026, 1), interestRate: 3, firstPaymentAmount: 2);
    expect(find.text('初回 ¥2 ＋ 2回目以降 ¥${l.monthlyAmount} × 2回'), findsOneWidget);
    expect(find.text('支払総額 ¥${l.totalRepayment}'), findsOneWidget);

    await t.tap(find.widgetWithText(ElevatedButton, '保存'));
    await t.pumpAndSettle();
    final saved = app.loans.single;
    expect(saved.monthlyAmount, l.monthlyAmount);
    expect(saved.totalRepayment, l.totalRepayment);
  });

  testWidgets('ふつうの契約・月額指定でも一致する', (t) async {
    final app = await openDialog(t);
    await fill(t, '名前', 'テストローン');
    await fill(t, '借入総額(円)', '1000000');
    await fill(t, '返済回数（月）', '36');
    await fill(t, '年利(%)', '2.9');
    final l = Loan(
        id: '', name: '', principal: 1000000, totalCount: 36,
        startMonth: DateTime(2026, 1), interestRate: 2.9);
    expect(find.text('毎月 ¥${l.monthlyAmount} × 36回'), findsOneWidget);
    expect(find.text('支払総額 ¥${l.totalRepayment}'), findsOneWidget);

    await fill(t, '2回目以降の返済額を指定（任意）', '30000');
    expect(find.text('毎月 ¥30000 × 36回'), findsOneWidget);
    expect(find.text('支払総額 ¥1080000'), findsOneWidget);
    await t.tap(find.widgetWithText(ElevatedButton, '保存'));
    await t.pumpAndSettle();
    expect(app.loans.single.totalRepayment, 1080000);
  });
}
