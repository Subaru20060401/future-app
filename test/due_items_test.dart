// 💡 日付が過ぎた支払い・入金を確認待ちに出す（2026-11-25 ユーザーの画面で見つかった不具合）。
//   ・予定支出（I Phone ¥83,000・11/24）が日付を過ぎても「いまの残高」から引かれず、確認待ちにも出なかった
//   ・その状態で予定入金を「受け取った」にすると、基準日が進んで予定支出が予想からも黙って消えた
//   ・口座払いのローン（月々・頭金）も同じ。給料も、入金のお知らせメールが無いと確認が出なかった
//   期待値はすべてコメントの手計算から書いた。今日は 2026-11-25（水）2:45 に固定する。
//
//   暦: 11/20 金、11/23 月・勤労感謝の日、11/24 火、11/25 水、11/27 金
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:my_counter_app/app_state.dart';
import 'package:my_counter_app/widgets/deposit_dialog.dart';

import 'support/test_app.dart';

void main() {
  final today = DateTime(2026, 11, 25, 2, 45);

  // 口座 200,000円。残高を入力したのは 11/20 9:00。
  //   予定支出 I Phone 83,000円（11/24）
  //   予定入金 チケット 11,000円（11/25）
  //   口座払いのローン PC 120,000円・12回（月 10,000円）・返済日 23日・10月から
  //     → 11月の返済は 11/23（祝日）→ 11/24（火）
  //   勤務先 カフェ（翌月25日払い）: 10/6 に 10:00〜15:00 時給 1,000円 → 5,000円 を 11/25 に受け取る
  Future<AppState> build() async {
    final a = await fixedApp(today);
    a.currentBalance = 200000;
    a.balanceUpdatedAt = DateTime(2026, 11, 20, 9);
    a.balanceEnteredAt = DateTime(2026, 11, 20, 9);
    a.plannedExpenses.add(PlannedExpense(id: 'pe', title: 'I Phone', amount: 83000, date: DateTime(2026, 11, 24)));
    a.plannedIncomes.add(PlannedIncome(id: 'pi', title: 'チケット', amount: 11000, date: DateTime(2026, 11, 25)));
    a.loans.add(Loan(id: 'pc', name: 'PCローン', principal: 120000, totalCount: 12, startMonth: DateTime(2026, 10), payDay: 23));
    final w = Workplace(id: 'cafe', name: 'カフェ', paydayDay: 25, paydayMonthOffset: 1);
    a.workplaces.add(w);
    addShift(a, shiftAt(w, DateTime(2026, 10, 6, 10), DateTime(2026, 10, 6, 15)));
    return a;
  }

  ({String id, String label, int amount, DateTime date}) draw(AppState a, String label) =>
      a.pendingDraws.singleWhere((d) => d.label == label);

  test('日付が過ぎた予定支出・ローンの返済・給料が確認待ちに出る', () async {
    final a = await build();
    final i = draw(a, 'I Phone（予定支出）');
    expect((i.amount, i.date), (83000, DateTime(2026, 11, 24)));
    final l = draw(a, 'PCローン（返済）');
    expect((l.amount, l.date), (10000, DateTime(2026, 11, 24)));
    final s = a.dueSalaries.single;
    expect((s.workplace.id, s.payDate, s.amount), ('cafe', DateTime(2026, 11, 25), 5000));
    final titles = a.homeNotices.map((n) => n.title).toList();
    expect(titles, containsAll([
      '引き落としの確認：I Phone（予定支出）',
      '引き落としの確認：PCローン（返済）',
      '給料の入金確認：カフェ',
      '予定入金の確認：チケット',
    ]));
    // 11月末 = 200,000 − 83,000(I Phone) − 10,000(ローン) + 5,000(給料) + 11,000(チケット) = 123,000
    expect(a.thisMonthBalance, 123000);
  });

  test('予定入金を受け取る前に、未処理の予定支出・ローンを先に確かめる（基準日が進むと予想から外れるため）', () async {
    final a = await build();
    expect(a.drawsAtRiskOnSnapshotAdvance.map((d) => d.label),
        containsAll(['I Phone（予定支出）', 'PCローン（返済）']));
  });

  test('確認待ちを順に処理すると、いまの残高と予想がそろう', () async {
    final a = await build();
    // I Phone を引く: 200,000 − 83,000 = 117,000
    expect(a.applyDraw(draw(a, 'I Phone（予定支出）').id, 83000, label: 'I Phone（予定支出）'), isTrue);
    expect(a.currentBalance, 117000);
    expect(a.isPlannedExpensePaid('pe', DateTime(2026, 11, 24)), isTrue, reason: '予定支出の一覧でも払い済み');
    // ローンを引く: 117,000 − 10,000 = 107,000
    a.applyDraw(draw(a, 'PCローン（返済）').id, 10000);
    expect(a.currentBalance, 107000);
    // 給料を受け取る: 107,000 + 5,000 = 112,000
    a.receiveSalary('cafe', DateTime(2026, 11, 25), 5000);
    expect(a.currentBalance, 112000);
    // チケットを受け取る: 112,000 + 11,000 = 123,000
    a.receivePlannedIncome('pi', 11000, DateTime(2026, 11, 25));
    expect(a.currentBalance, 123000);
    // 全部処理した → 確認待ちは空、11月末は最初の予想と同じ 123,000
    expect(a.pendingDraws, isEmpty);
    expect(a.dueSalaries, isEmpty);
    expect(a.thisMonthBalance, 123000);
  });

  test('「もう残高に入っている」（スキップ）を選んだ予定支出・ローンは、予想でも二重に引かない', () async {
    final a = await build();
    a.skipDraw(draw(a, 'I Phone（予定支出）').id);
    a.skipDraw(draw(a, 'PCローン（返済）').id);
    expect(a.currentBalance, 200000);
    // 11月末 = 200,000 + 5,000(給料) + 11,000(チケット) = 216,000（I Phone・ローンは入っている）
    expect(a.thisMonthBalance, 216000);
  });

  test('給料が「もう残高に入っている」なら、残高は変えず予想でも足さない', () async {
    final a = await build();
    a.markSalaryIncluded('cafe', DateTime(2026, 11, 25));
    expect(a.currentBalance, 200000);
    expect(a.dueSalaries, isEmpty);
    // 11月末 = 200,000 − 83,000 − 10,000 + 11,000 = 118,000（給料 5,000 は足さない）
    expect(a.thisMonthBalance, 118000);
  });

  test('給料日の近くに入金のお知らせメールが来ていたら、給料の確認は出さない（お知らせのほうで反映する）', () async {
    final a = await build();
    a.pendingDeposits.add(DepositNotice(sourceId: 'mail1', date: DateTime(2026, 11, 25, 9)));
    expect(a.dueSalaries, isEmpty);
  });

  test('入出金の履歴から取り消すと、予定支出は未払い・確認待ちに戻る', () async {
    final a = await build();
    a.applyDraw(draw(a, 'I Phone（予定支出）').id, 83000, label: 'I Phone（予定支出）');
    a.undoBalanceEntry(a.balanceHistory.first.id);
    expect(a.currentBalance, 200000);
    expect(a.isPlannedExpensePaid('pe', DateTime(2026, 11, 24)), isFalse);
    expect(a.pendingDraws.map((d) => d.label), contains('I Phone（予定支出）'));
  });

  test('口座払いの頭金も確認待ちに出て、処理すると予想から外れる', () async {
    final a = await fixedApp(today);
    a.currentBalance = 100000;
    a.balanceUpdatedAt = DateTime(2026, 11, 20, 9);
    // 頭金 20,000円を 11/24 に口座から（ローン本体はカード払い＝口座の返済は無い）
    a.loans.add(Loan(
        id: 'bike', name: '原付', principal: 60000, totalCount: 6, startMonth: DateTime(2026, 12),
        method: 'カードA', downPayment: 20000, downPaymentDate: DateTime(2026, 11, 24)));
    final d = draw(a, '原付 頭金');
    expect((d.amount, d.date), (20000, DateTime(2026, 11, 24)));
    expect(a.thisMonthBalance, 80000); // 100,000 − 20,000
    a.skipDraw(d.id); // もう残高に入っている
    expect(a.thisMonthBalance, 100000);
    expect(a.pendingDraws, isEmpty);
  });

  test('口座振替の定期をスキップしたら、予想でも引かない（以前は日付が残高入力より後だと二重だった）', () async {
    final a = await fixedApp(today);
    a.currentBalance = 100000;
    a.balanceUpdatedAt = DateTime(2026, 11, 20, 9);
    a.subscriptions.add(Subscription(id: 's', title: '動画', amount: 1000, payDay: 24));
    expect(a.thisMonthBalance, 99000); // 11/24 の 1,000 を引く
    a.skipDraw('sub:s:2026-11'); // 11月分（開始月が無いので10月分も出ているが、予想に効くのは11月分）
    expect(a.thisMonthBalance, 100000); // 入っていると確かめた → 引かない
  });

  test('毎月の予定支出は、月ごとに確認待ちに出る', () async {
    final a = await fixedApp(today);
    a.currentBalance = 100000;
    a.balanceUpdatedAt = DateTime(2026, 10, 1);
    a.plannedExpenses.add(PlannedExpense(
        id: 'club', title: '部費', amount: 2000, date: DateTime(2026, 10, 10), monthly: true));
    expect(a.pendingDraws.map((d) => d.id), ['plan:club:2026-10', 'plan:club:2026-11']);
  });

  test('銀行の引落確定が来ているローンの月は、確定のほうだけ出す（二重に出さない）', () async {
    final a = await build();
    a.loans.single.bankBillingNames.add('ジャックス');
    a.payments.add(Payment(
        id: 'b1', cardName: 'ジャックス', amount: 10000, paymentDate: DateTime(2026, 11, 24),
        source: PaymentSource.bank, sourceId: 'bank-1'));
    final labels = a.pendingDraws.map((d) => d.label).toList();
    expect(labels, isNot(contains('PCローン（返済）')));
    expect(labels, contains('ジャックス'));
  });

  Future<AppState> pumpSalary(WidgetTester t) async {
    await initializeDateFormatting('ja_JP', null);
    late AppState a;
    await t.runAsync(() async {
      a = await build();
      // 引き落としは先に処理しておく（受け取りの前の確認を出さないため）
      a.applyDraw(draw(a, 'I Phone（予定支出）').id, 83000);
      a.applyDraw(draw(a, 'PCローン（返済）').id, 10000);
    });
    await t.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            onPressed: () => showSalaryDialog(context, a, a.dueSalaries.single),
            child: const Text('開く'),
          ),
        ),
      ),
    ));
    await t.tap(find.text('開く'));
    await t.pumpAndSettle();
    return a;
  }

  testWidgets('給料の確認: 金額を直して「受け取った」で残高に足す', (t) async {
    final a = await pumpSalary(t);
    expect(find.text('給料の入金：カフェ'), findsOneWidget);
    await t.enterText(find.byKey(const Key('salary-amount')), '4800');
    await t.tap(find.text('受け取った（残高に足す）'));
    await t.pumpAndSettle();
    expect(a.currentBalance, 107000 + 4800);
    expect(a.dueSalaries, isEmpty);
  });

  testWidgets('給料の確認: 「もう残高に入っている」なら残高は変えない', (t) async {
    final a = await pumpSalary(t);
    await t.tap(find.text('もう残高に入っている'));
    await t.pumpAndSettle();
    expect(a.currentBalance, 107000);
    expect(a.dueSalaries, isEmpty);
  });
}
