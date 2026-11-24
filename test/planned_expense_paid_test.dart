// 予定支出を「払い済み」にするテスト（2026-10-23、テストからしか呼べなかった機能を画面に出した）。
// 💡 予定日より前に払って残高を書き直すと、残高と予想の両方で引かれて二重になる。
//   払い済みにした回だけ予想から外す。予定日を過ぎた回は確認待ちに出る（test/due_items_test.dart）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/app_state.dart';
import 'package:my_counter_app/gemini_client.dart';
import 'package:my_counter_app/widgets/planned_expense_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);

  Future<AppState> app() async {
    final a = AppState();
    await a.ready;
    return a;
  }

  test('一度きり：払い済みにすると予想から外れ、取り消すと戻る', () async {
    final a = await app();
    final d = today.add(const Duration(days: 40));
    final month = DateTime(d.year, d.month);
    a.addPlannedExpense(title: '車検', amount: 80000, date: d);
    final e = a.plannedExpenses.single;
    expect(a.nextUnpaidPlannedExpenseDate(e), d);
    expect(a.plannedExpensesIn(month), hasLength(1));

    a.markPlannedExpensePaid(e.id, d);
    expect(a.isPlannedExpensePaid(e.id, d), isTrue);
    expect(a.plannedExpensesIn(month), isEmpty);
    expect(a.nextUnpaidPlannedExpenseDate(e), isNull);

    a.unmarkPlannedExpensePaid(e.id, d);
    expect(a.plannedExpensesIn(month), hasLength(1));
  });

  test('毎月：今回を払い済みにすると、次回は翌月になる', () async {
    final a = await app();
    final first = today.add(const Duration(days: 1)); // 明日から毎月
    a.addPlannedExpense(title: '習い事', amount: 5000, date: first, monthly: true);
    final e = a.plannedExpenses.single;
    expect(a.nextUnpaidPlannedExpenseDate(e), first);
    a.markPlannedExpensePaid(e.id, first);
    final next = a.nextUnpaidPlannedExpenseDate(e)!;
    expect(next.isAfter(first), isTrue);
    expect(DateTime(next.year, next.month), DateTime(first.year, first.month + 1));
    // 翌月分は予想に残る
    expect(a.plannedExpensesIn(DateTime(next.year, next.month)), hasLength(1));
  });

  test('予定日を過ぎた一度きりの出費は「払い済みにする」の対象にしない', () async {
    final a = await app();
    a.addPlannedExpense(title: '過去', amount: 1000, date: today.subtract(const Duration(days: 3)));
    expect(a.nextUnpaidPlannedExpenseDate(a.plannedExpenses.single), isNull);
  });

  // 💡 2026-11 変更: 「払った」は残高から引くか、もう残高に入っているかを選ぶ（以前は予想から外すだけ）
  testWidgets('シートの ✓ で「残高から引く」を選ぶと、残高から引いて払い済みにし、取り消すと残高も戻る', (t) async {
    await initializeDateFormatting('ja_JP', null);
    final a = await app();
    a.currentBalance = 100000;
    final d = today.add(const Duration(days: 40));
    a.addPlannedExpense(title: '車検', amount: 80000, date: d);
    await t.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            onPressed: () => showPlannedExpenseSheet(context, a),
            child: const Text('開く'),
          ),
        ),
      ),
    ));
    await t.tap(find.text('開く'));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('払い済みにする'));
    await t.pumpAndSettle();
    expect(find.textContaining('いまの口座残高から引きますか'), findsOneWidget);
    await t.tap(find.widgetWithText(FilledButton, '残高から引く'));
    await t.pumpAndSettle();
    expect(a.isPlannedExpensePaid(a.plannedExpenses.single.id, d), isTrue);
    expect(a.currentBalance, 20000); // 100,000 − 80,000
    expect(find.text('払い済み（予想から外しています）'), findsOneWidget);

    await t.tap(find.byTooltip('払い済みを取り消す'));
    await t.pumpAndSettle();
    expect(a.isPlannedExpensePaid(a.plannedExpenses.single.id, d), isFalse);
    expect(a.currentBalance, 100000);
  });

  testWidgets('「もう残高に入っている」を選ぶと、残高は変えずに払い済みにする', (t) async {
    await initializeDateFormatting('ja_JP', null);
    final a = await app();
    a.currentBalance = 100000;
    final d = today.add(const Duration(days: 40));
    a.addPlannedExpense(title: '車検', amount: 80000, date: d);
    await t.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            onPressed: () => showPlannedExpenseSheet(context, a),
            child: const Text('開く'),
          ),
        ),
      ),
    ));
    await t.tap(find.text('開く'));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('払い済みにする'));
    await t.pumpAndSettle();
    await t.tap(find.text('もう残高に入っている'));
    await t.pumpAndSettle();
    expect(a.isPlannedExpensePaid(a.plannedExpenses.single.id, d), isTrue);
    expect(a.currentBalance, 100000);
  });

  test('Gemini の 402 は、前払い残高0円と次にすることが分かる文にする', () {
    final m = describeGeminiError(402, '{"error":{"code":402}}');
    expect(m, contains('前払い残高が0円'));
    expect(m, contains('無料枠'));
    expect(m, isNot(contains('Geminiでエラーが起きました')));
  });
}
