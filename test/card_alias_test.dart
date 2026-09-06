// カード名の統合（銀行表記と自分が付けた名前の食い違い）のテスト。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  ({String cardName, int amount, DateTime date, PaymentSource source, String sourceId, String note})
      item(String card, int amount, DateTime d, String id) => (
            cardName: card,
            amount: amount,
            date: d,
            source: PaymentSource.bank,
            sourceId: id,
            note: '',
          );

  final d = DateTime(2026, 9, 10);

  AppState withCard() =>
      AppState()..setCardPaymentDay('三菱UFJカード', 10);

  group('割れているカード名', () {
    test('登録していない名前の明細を見つけられる', () {
      final app = withCard()
        ..reconcilePayments([item('ミツビシUFJニコス', 8000, d, 'b1#0')]);
      final un = app.unregisteredCardNames;
      expect(un, hasLength(1));
      expect(un.single.name, 'ミツビシUFJニコス');
      expect(un.single.count, 1);
    });

    test('登録済みのカードは候補に出ない', () {
      final app = withCard()
        ..reconcilePayments([item('三菱UFJカード', 8000, d, 'b1#0')]);
      expect(app.unregisteredCardNames, isEmpty);
    });
  });

  group('まとめる', () {
    test('既存の明細がまとめ先に付け替わる', () {
      final app = withCard()
        ..reconcilePayments([item('ミツビシUFJニコス', 8000, d, 'b1#0')]);

      app.mergeCardName('ミツビシUFJニコス', '三菱UFJカード');
      expect(app.payments.single.cardName, '三菱UFJカード');
      expect(app.unregisteredCardNames, isEmpty);
      expect(app.cardChoices.where((c) => c == 'ミツビシUFJニコス'), isEmpty);
    });

    test('次の取り込みでも同じ扱いになる', () {
      final app = withCard()
        ..reconcilePayments([item('ミツビシUFJニコス', 8000, d, 'b1#0')]);
      app.mergeCardName('ミツビシUFJニコス', '三菱UFJカード');

      // 銀行は相変わらず自分の表記で送ってくる
      app.reconcilePayments([item('ミツビシUFJニコス', 8000, d, 'b1#0')]);
      expect(app.payments.single.cardName, '三菱UFJカード');
      expect(app.unregisteredCardNames, isEmpty);
    });

    test('まとめると合計も1枚ぶんになる', () {
      final app = withCard()
        ..reconcilePayments([
          item('ミツビシUFJニコス', 8000, d, 'b1#0'),
        ]);
      app.mergeCardName('ミツビシUFJニコス', '三菱UFJカード');
      // 銀行確定は翌月引き落とし＝前月の利用として集計される
      final totals = app.paymentTotalsByCardOf(DateTime(2026, 8));
      expect(totals['三菱UFJカード'], 8000);
      expect(totals['ミツビシUFJニコス'], isNull);
    });

    test('分割払い・定期支払いの紐付けも付け替わる', () {
      final app = withCard();
      app.installments.add(Installment(
        id: 'i1',
        name: 'PC',
        cardName: 'ミツビシUFJニコス',
        totalAmount: 120000,
        installmentCount: 12,
        remainingMonths: 12,
        monthlyAmount: 10000,
        interestRate: 15.0,
      ));
      app.mergeCardName('ミツビシUFJニコス', '三菱UFJカード');
      expect(app.installments.single.cardName, '三菱UFJカード');
    });

    test('まとめた設定は書き出し・取り込みで保たれる', () {
      final app = withCard()
        ..reconcilePayments([item('ミツビシUFJニコス', 8000, d, 'b1#0')]);
      app.mergeCardName('ミツビシUFJニコス', '三菱UFJカード');

      final restored = AppState()..importJson(app.exportJson());
      expect(restored.cardAliases['ミツビシUFJニコス'], '三菱UFJカード');
      expect(restored.resolveCardName('ミツビシUFJニコス'), '三菱UFJカード');
    });

    test('まとめを解除できる', () {
      final app = withCard();
      app.mergeCardName('ミツビシUFJニコス', '三菱UFJカード');
      app.unmergeCardName('ミツビシUFJニコス');
      expect(app.resolveCardName('ミツビシUFJニコス'), 'ミツビシUFJニコス');
    });
  });
}
