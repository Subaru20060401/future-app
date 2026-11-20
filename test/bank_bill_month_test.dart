// 💡 引き落としの「請求の月」と実際の引落日を分ける（公開前の確認 2）。
//   暦: 2026-10-31 土 → 11-02 月 / 11-30 月 / 11-26 木 / 11-27 金
import 'package:flutter_test/flutter_test.dart';
import 'package:my_counter_app/app_state.dart';

import 'support/test_app.dart';

void main() {
  // 31日払いのカード B。9/10 の利用 6,000（10月請求 → 10/31土 → 11/2）、10/10 の利用 7,000（11月請求 → 11/30）
  Future<AppState> slipped() async {
    final a = await fixedApp(DateTime(2026, 11, 3, 10));
    a.currentBalance = 100000;
    a.balanceUpdatedAt = DateTime(2026, 10, 29, 9);
    a.cardPaymentDays['B'] = 31;
    a.payments.addAll([
      usage('B', 6000, DateTime(2026, 9, 10, 12)),
      usage('B', 7000, DateTime(2026, 10, 10, 12)),
    ]);
    return a;
  }

  group('再現: 休みで翌月にずれた引落の銀行確定', () {
    test('確定前: 11月は 11/2 に 6,000・11/30 に 7,000、11月末 87,000', () async {
      final a = await slipped();
      final nov = a.forecastMonths(count: 1).first;
      expect(nov.lines.map((l) => (l.date, l.amount)).toSet(),
          {(DateTime(2026, 11, 2), -6000), (DateTime(2026, 11, 30), -7000)});
      expect(nov.end, 87000);
    });

    test('11/2 付けの確定 6,000 は10月の請求。二重にならず、11/30 の 7,000 も残る', () async {
      final a = await slipped();
      final b = bank('B', 6000, DateTime(2026, 11, 2));
      a.payments.add(b);
      expect(a.billMonthOf(b).month, DateTime(2026, 10));
      expect(a.billMonthOf(b).status, BillMonthStatus.matched);
      final nov = a.forecastMonths(count: 1).first;
      // 100,000 − 6,000（11/2 確定）− 7,000（11/30 見込み）
      expect(nov.end, 87000);
      expect(nov.lines.map((l) => (l.date, l.amount, l.certainty)).toSet(), {
        (DateTime(2026, 11, 2), -6000, Certainty.confirmed),
        (DateTime(2026, 11, 30), -7000, Certainty.estimated),
      });
      // 利用月の支出: 9月は確定 6,000、10月は利用 7,000（以前は 10月が 6,000 に置き換わっていた）
      int card(DateTime m) =>
          a.expenseBreakdownOf(m).where((e) => e.label == 'B').fold(0, (s, e) => s + e.amount);
      expect(card(DateTime(2026, 9)), 6000);
      expect(card(DateTime(2026, 10)), 7000);
      expect(a.drawDateOf('B', DateTime(2026, 10)), DateTime(2026, 11, 2)); // 確定の日付をそのまま使う
      expect(a.homeNotices.where((n) => n.kind == HomeNoticeKind.bankBillMonthUnknown), isEmpty);
    });

    test('同じカード・同じ金額の別の請求（11/2 と 11/30 の両方が 6,000）を1つにまとめない', () async {
      final a = await slipped();
      a.payments.removeWhere((p) => p.amount == 7000);
      a.payments.add(usage('B', 6000, DateTime(2026, 10, 10, 12)));
      a.payments.addAll([
        bank('B', 6000, DateTime(2026, 11, 2)),
        bank('B', 6000, DateTime(2026, 11, 30)),
      ]);
      expect(a.billMonthOf(a.payments.firstWhere((p) => p.paymentDate.day == 2 && p.source == PaymentSource.bank)).month,
          DateTime(2026, 10));
      expect(a.billMonthOf(a.payments.firstWhere((p) => p.paymentDate.day == 30)).month,
          DateTime(2026, 11));
      final nov = a.forecastMonths(count: 1).first;
      expect(nov.lines.where((l) => l.amount == -6000), hasLength(2));
      expect(nov.end, 88000);
    });

    test('確認待ち: 10月請求の確定で 11月請求の見込みを隠さない', () async {
      final a = await slipped();
      a.payments.add(bank('B', 6000, DateTime(2026, 11, 2)));
      final later = await fixedApp(DateTime(2026, 12, 1, 9));
      later.cardPaymentDays['B'] = 31;
      later.payments.addAll(a.payments);
      final ids = later.pendingDraws.map((d) => d.id).toList();
      expect(ids, contains('card:B:2026-11')); // 11/30 の 11月請求
      expect(ids.where((i) => i.startsWith('bank:')), hasLength(1));
      expect(ids, isNot(contains('card:B:2026-10'))); // 10月請求は確定に置き換わる
    });

    test('Gmail の取り込み: 10月請求の確定が、11月請求の「請求予定」を消さない', () async {
      final a = await slipped();
      a.reconcilePayments([
        (cardName: 'B', amount: 6000, date: DateTime(2026, 11, 2), source: PaymentSource.bank, sourceId: 'bank-1', note: ''),
        (cardName: 'B', amount: 7000, date: DateTime(2026, 11, 30), source: PaymentSource.billing, sourceId: 'bill-1', note: ''),
      ]);
      expect(a.payments.where((p) => p.source == PaymentSource.billing).map((p) => p.amount), [7000]);
    });
  });

  group('判定できない場合', () {
    test('設定の引落日を変えた後の古い確定: 自動では決めず、要確認として利用者に選んでもらう', () async {
      final a = await slipped();
      final b = bank('B', 6000, DateTime(2026, 11, 2));
      a.payments.add(b);
      a.cardPaymentDays['B'] = 27; // 設定を変えた（10/27・11/27 のどちらとも合わない）
      expect(a.billMonthOf(b).status, BillMonthStatus.unresolved);
      // 集計は日付の月（11月請求）として扱う＝以前と同じ。関係する予想の行に要確認を付ける
      final lines = a.forecastMonths(count: 1).first.lines.where((l) => l.label == 'B');
      expect(lines, isNotEmpty);
      expect(lines.every((l) => l.needsReview), isTrue);
      final notice = a.homeNotices.singleWhere((n) => n.kind == HomeNoticeKind.bankBillMonthUnknown);
      expect(notice.bankRecord, same(b));
      // 候補は日付の前月と日付の月
      expect(a.billMonthCandidatesOf(b).map((c) => (c.month, c.expectedDate)), [
        (DateTime(2026, 10), DateTime(2026, 10, 27)),
        (DateTime(2026, 11), DateTime(2026, 11, 27)),
      ]);
      // 利用者が10月の請求と選ぶ → 要確認が消え、10月の請求として数える
      a.setBankBillMonth(b, DateTime(2026, 10));
      expect(a.billMonthOf(b), (month: DateTime(2026, 10), status: BillMonthStatus.userChosen));
      expect(a.homeNotices.where((n) => n.kind == HomeNoticeKind.bankBillMonthUnknown), isEmpty);
      expect(a.forecastMonths(count: 1).first.lines.any((l) => l.needsReview), isFalse);
    });

    test('いつもと違う日の振替（設定は26日、確定は 11/5）も判定できない', () async {
      final a = await fixedApp(DateTime(2026, 11, 6, 10));
      a.cardPaymentDays['C'] = 26;
      final b = bank('C', 4000, DateTime(2026, 11, 5));
      a.payments.add(b);
      expect(a.billMonthOf(b).status, BillMonthStatus.unresolved);
    });

    test('判定できない確定が複数あっても、それぞれ確認待ちに出る（1件だけと仮定しない）', () async {
      final a = await fixedApp(DateTime(2026, 11, 20, 10));
      a.cardPaymentDays['C'] = 26;
      a.payments.addAll([
        bank('C', 4000, DateTime(2026, 11, 5)),
        bank('C', 5000, DateTime(2026, 11, 12)),
      ]);
      expect(a.homeNotices.where((n) => n.kind == HomeNoticeKind.bankBillMonthUnknown), hasLength(2));
    });

    test('選んだ請求の月は保存・書き出し・取り込みで残る', () async {
      final a = await slipped();
      final b = bank('B', 6000, DateTime(2026, 11, 2));
      a.payments.add(b);
      a.cardPaymentDays['B'] = 27;
      a.setBankBillMonth(b, DateTime(2026, 10));
      await a.saveData();
      final r = await reloadApp(DateTime(2026, 11, 3, 10));
      expect(r.bankBillMonths, {'bank-B-2026-11-02T00:00:00.000': '2026-10'});
      final c = await fixedApp(DateTime(2026, 11, 3, 10));
      await c.importJson(a.exportJson());
      expect(c.bankBillMonths, a.bankBillMonths);
    });

    test('引落日の設定が無いカードは日付の月で扱い、確認待ちには出さない', () async {
      final a = await fixedApp(DateTime(2026, 11, 20, 10));
      final b = bank('未設定カード', 3000, DateTime(2026, 11, 2));
      a.payments.add(b);
      expect(a.billMonthOf(b), (month: DateTime(2026, 11), status: BillMonthStatus.noSetting));
      expect(a.homeNotices.where((n) => n.kind == HomeNoticeKind.bankBillMonthUnknown), isEmpty);
    });
  });
}
