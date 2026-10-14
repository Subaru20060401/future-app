// 支払い管理の5つのタブのテスト（UI改善計画 2026-10-14 の段階1）。
// ⚠️ 以前は TabController の数(4)とタブ・中身の数(5)が食い違っていて、
//   ATM のタブに正しく届かなかった。5つとも中身と追加画面が開けることを固定する。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/app_state.dart';
import 'package:my_counter_app/screens/payment_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpScreen(WidgetTester t) async {
    t.view.physicalSize = const Size(430, 900);
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
  }

  // タブ名 → そのタブの中身（空のとき）と、＋で開く追加画面の見出し
  const cases = [
    ('カード', 'この月の請求はありません', 'カード請求を追加'),
    ('分割', '分割払いはありません', '分割払いを追加'),
    ('定期', '定期支払いはありません', '定期支払いを追加'),
    ('ローン', 'ローンはありません', 'ローンを追加'),
    ('ATM', '引き出し履歴はありません', 'ATM引き出しを追加'),
  ];

  for (final (tab, empty, addTitle) in cases) {
    testWidgets('「$tab」タブの中身と追加画面が開ける', (t) async {
      await pumpScreen(t);
      await t.tap(find.widgetWithText(Tab, tab));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.textContaining(empty), findsOneWidget);

      await t.tap(find.byType(FloatingActionButton));
      await t.pumpAndSettle();
      expect(find.text(addTitle), findsOneWidget);
    });
  }
}
