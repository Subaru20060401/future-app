// 入出金の履歴に並べるもの（保存した履歴＋デビットの利用）のテスト。
// 💡 デビットは口座から即時に出ていくのに残高を書き換えないので、
//   履歴に出てこなかった。明細から作って混ぜる。
// ⚠️ 保存はしない（Gmailの作り直しで明細が変わると履歴だけ残ってズレるため）。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Payment usage(String card, int amount, DateTime d, {bool infoOnly = false, String note = ''}) =>
      Payment(
        id: '${card}_${d.toIso8601String()}_$amount',
        cardName: card,
        amount: amount,
        paymentDate: d,
        source: PaymentSource.usage,
        infoOnly: infoOnly,
        note: note,
      );

  group('デビットを履歴に出す', () {
    test('デビットの利用が引き落としとして並ぶ', () {
      final app = AppState()
        ..payments.add(usage('三井OLIVE（デビット）', 1200, DateTime(2026, 9, 20)));
      final rows = app.balanceLedger();
      expect(rows, hasLength(1));
      expect(rows.single.isDeposit, isFalse);
      expect(rows.single.amount, 1200);
      expect(rows.single.isDebit, isTrue);
      // 残高は動かしていないので「反映後の残高」は持たない
      expect(rows.single.balanceAfter, isNull);
    });

    test('利用先のメモがあれば名前に添える', () {
      final app = AppState()
        ..payments.add(usage('三井OLIVE（デビット）', 800, DateTime(2026, 9, 20), note: 'ローソン'));
      expect(app.balanceLedger().single.label, '三井OLIVE（デビット）（ローソン）');
    });

    test('デビット以外のカード利用は出ない（引き落としは月まとめで出るため）', () {
      final app = AppState()
        ..payments.add(usage('三井OLIVE', 5000, DateTime(2026, 9, 20)));
      expect(app.balanceLedger(), isEmpty);
    });

    test('記録だけの明細（infoOnly）は出ない（二重に見えてしまうため）', () {
      final app = AppState()
        ..payments.add(usage('三井OLIVE（デビット）', 900, DateTime(2026, 9, 20), infoOnly: true));
      expect(app.balanceLedger(), isEmpty);
    });

    test('保存した履歴と混ざって新しい順に並ぶ', () {
      final app = AppState();
      app.currentBalance = 50000;
      app.payments.add(usage('三井OLIVE（デビット）', 1000, DateTime(2026, 9, 15)));
      app.addPastBalanceEntry(
        kind: BalanceEntryKind.deposit,
        label: 'バイト代',
        amount: 80000,
        at: DateTime(2026, 9, 25),
      );
      app.addPastBalanceEntry(
        kind: BalanceEntryKind.draw,
        label: '家賃',
        amount: 30000,
        at: DateTime(2026, 9, 10),
      );
      final rows = app.balanceLedger();
      expect(rows.map((e) => e.label).toList(), ['バイト代', '三井OLIVE（デビット）', '家賃']);
    });

    test('デビットの行は取り消せない（明細が正本）', () {
      final app = AppState()
        ..payments.add(usage('三井OLIVE（デビット）', 1000, DateTime(2026, 9, 15)));
      expect(app.balanceLedger().single.entry, isNull);
    });
  });
}
