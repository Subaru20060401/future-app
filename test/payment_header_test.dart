// 支払い管理の上の部分（絞り込み・合計・分割の内数）と、メール更新の結果表示のテスト
// （UI改善計画 2026-10-14 の段階2）。データは架空。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/app_state.dart';
import 'package:my_counter_app/gmail_sync.dart';
import 'package:my_counter_app/screens/payment_screen.dart';
import 'package:my_counter_app/widgets/sync_status.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const longCredit = 'とても長い名前のテスト用クレジットカード';
  const longDebit = 'とても長い名前のテスト用クレジットカード（デビット）';

  Future<AppState> pumpScreen(WidgetTester t, {double width = 320}) async {
    t.view.physicalSize = Size(width, 900);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final app = AppState();
    await app.ready;
    final now = DateTime.now();
    app.payments.addAll([
      Payment(id: 'a', cardName: longCredit, amount: 1234567,
          paymentDate: DateTime(now.year, now.month, 3), source: PaymentSource.usage),
      Payment(id: 'b', cardName: longDebit, amount: 800,
          paymentDate: DateTime(now.year, now.month, 4), source: PaymentSource.usage),
    ]);
    // 分割払い（クレジットに乗る）＝合計の内数
    app.installments.add(Installment(
      id: 'i', name: 'PC', cardName: longCredit, totalAmount: 36000,
      installmentCount: 12, remainingMonths: 12, monthlyAmount: 3000, interestRate: 0,
      startDate: DateTime(now.year, now.month),
    ));
    await t.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: const MaterialApp(home: PaymentScreen()),
    ));
    await t.pumpAndSettle();
    return app;
  }

  testWidgets('幅320pxでも上の部分がはみ出さない', (t) async {
    await pumpScreen(t);
    expect(t.takeException(), isNull);
  });

  testWidgets('合計は桁区切りで、分割は「合計に含む」内数として別の行に出る', (t) async {
    await pumpScreen(t);
    // 1,234,567 + 800 + 分割 3,000
    expect(find.text('合計 ¥1,238,367'), findsOneWidget);
    expect(find.text('うち分割 ¥3,000（合計に含む）'), findsOneWidget);
    expect(find.text('2件'), findsOneWidget);
  });

  testWidgets('カードの絞り込みは全名称とクレジット／デビットの区別が読める一覧から選ぶ', (t) async {
    await pumpScreen(t);
    expect(find.text('カード：すべて ▾'), findsOneWidget);
    await t.tap(find.text('カード：すべて ▾'));
    await t.pumpAndSettle();
    // 一覧には切らずに全名称が出る（明細の行にも同じ名前があるので、シートの中で探す）
    final sheet = find.byType(BottomSheet);
    expect(find.descendant(of: sheet, matching: find.text(longCredit)), findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.text(longDebit)), findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.textContaining('デビット（')), findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.textContaining('クレジット（')), findsOneWidget);

    await t.tap(find.descendant(of: sheet, matching: find.text(longDebit)));
    await t.pumpAndSettle();
    expect(find.text('カード：$longDebit ▾'), findsOneWidget);
    expect(find.text('1件'), findsOneWidget);
    expect(find.text('合計 ¥800'), findsOneWidget, reason: 'デビットには分割が乗っていない');
  });

  testWidgets('並びと「引落確定も表示」は、選んでいる状態が文字で読める', (t) async {
    await pumpScreen(t);
    expect(find.text('並び：日付が古い順 ▾'), findsOneWidget);
    expect(find.widgetWithText(FilterChip, '引落確定も表示'), findsOneWidget);
  });

  group('メール更新の結果', () {
    test('成功は短い一言、詳細では「取り込み直しで外れた」を自分の削除と分けて書く', () {
      final r = GmailSyncResult(added: 3, removed: 1, fetched: 40);
      expect(r.ok, isTrue);
      expect(r.shortMessage, 'メールを確認しました');
      expect(r.detailLines.join('\n'), contains('取り込み直しで外れた明細: 1件（自分で削除したものは含みません）'));
    });

    test('取りこぼしで見送ったときは、成功と言わない', () {
      final r = GmailSyncResult(fetched: 40, missed: 2);
      expect(r.ok, isFalse);
      expect(r.shortMessage, '一部のメールが取れず、反映を見送りました');
    });

    testWidgets('失敗のときはホームの一行に再試行が出る（消える通知だけにしない）', (t) async {
      final app = AppState();
      await app.ready;
      lastGmailSync.value = (at: DateTime(2026, 10, 14, 22, 0), result: GmailSyncResult(missed: 2));
      addTearDown(() => lastGmailSync.value = null);
      await t.pumpWidget(ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: SyncStatusBar())),
      ));
      expect(find.textContaining('反映を見送りました'), findsOneWidget);
      expect(find.text('再試行'), findsOneWidget);
      expect(find.text('詳細'), findsOneWidget);
    });

    testWidgets('一度も連携していない人には「期限切れ」も「未連携」も出さない', (t) async {
      final app = AppState();
      await app.ready;
      addTearDown(() => lastGmailSync.value = null);
      for (final r in [
        GmailSyncResult(needsPermission: true),
      ]) {
        lastGmailSync.value = (at: DateTime(2026, 10, 14, 22, 0), result: r);
        await t.pumpWidget(ChangeNotifierProvider.value(
          value: app,
          child: const MaterialApp(home: Scaffold(body: SyncStatusBar())),
        ));
        expect(find.text('再試行'), findsNothing);
        expect(find.textContaining('期限'), findsNothing);
      }
    });

    testWidgets('成功のときは再試行を出さない', (t) async {
      final app = AppState();
      await app.ready;
      lastGmailSync.value = (at: DateTime(2026, 10, 14, 22, 0), result: GmailSyncResult(fetched: 3));
      addTearDown(() => lastGmailSync.value = null);
      await t.pumpWidget(ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: SyncStatusBar())),
      ));
      expect(find.textContaining('メールを確認しました'), findsOneWidget);
      expect(find.text('再試行'), findsNothing);
    });
  });
}
