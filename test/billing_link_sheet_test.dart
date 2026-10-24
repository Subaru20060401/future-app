import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/app_state.dart';
import 'package:my_counter_app/widgets/billing_link_sheet.dart';

void main() {
  testWidgets('狭い画面で表記の違う銀行請求を選び、ローンへの対応を記憶できる', (t) async {
    SharedPreferences.setMockInitialValues({});
    t.view.physicalSize = const Size(390, 700);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final app = AppState();
    await app.loadData();
    app.loans.add(
      Loan(
        id: 'pc',
        name: 'PCのローン',
        principal: 192000,
        totalCount: 24,
        startMonth: DateTime(2026, 9),
        monthlyOverride: 8000,
      ),
    );
    app.payments.add(
      Payment(
        id: 'bank',
        cardName: '請求会社',
        amount: 9800,
        paymentDate: DateTime(2026, 10, 27),
        source: PaymentSource.bank,
      ),
    );
    await t.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showBillingLinkSheet(context),
                child: const Text('確認'),
              ),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('確認'));
    await t.pumpAndSettle();
    await t.tap(find.text('対応を選ぶ'));
    await t.pumpAndSettle();
    await t.tap(find.text('PCのローン'));
    await t.pumpAndSettle();
    expect(app.loanForBankBillingName('請求会社')?.id, 'pc');
    expect(app.drawnInMonth(DateTime(2026, 10)), 9800);
    expect(find.text('ローン：PCのローン'), findsOneWidget);
    await t.tap(find.text('解除'));
    await t.pumpAndSettle();
    expect(app.loanForBankBillingName('請求会社'), isNull);
    expect(find.text('対応を選ぶ'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
