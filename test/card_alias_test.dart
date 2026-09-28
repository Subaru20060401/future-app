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

  // 💡 表記違いで2枚とも「登録済み」になってしまった場合（例: 三菱UFJ と MUFGカード）。
  //   ⚠️ カード名は明細以外にもいろいろな場所に文字列で入っている。
  //     1か所でも残ると、金額が予想から消えたり削除した明細が復活する。
  group('登録済みカードどうしをまとめる', () {
    AppState twoCards() => AppState()
      ..setCardPaymentDay('三菱UFJ', 10)
      ..setCardClosingDay('三菱UFJ', 15)
      ..setCardPaymentDay('MUFGカード', 10);

    test('設定は1枚になり、まとめ先の締め日・引き落とし日が残る', () {
      final app = twoCards();
      app.renameOrMergeCard('MUFGカード', '三菱UFJ');
      expect(app.cardPaymentDays.containsKey('MUFGカード'), isFalse);
      expect(app.cardPaymentDays['三菱UFJ'], 10);
      expect(app.closingDayOf('三菱UFJ'), 15);
    });

    test('明細・分割・定期・ローン・頭金・Amazon付け替えが全部移る', () {
      final app = twoCards();
      app.payments.add(Payment(
          id: 'p1',
          cardName: 'MUFGカード',
          amount: 3000,
          paymentDate: d,
          source: PaymentSource.usage));
      app.installments.add(Installment(
        id: 'i1',
        name: 'PC',
        cardName: 'MUFGカード',
        totalAmount: 120000,
        installmentCount: 12,
        remainingMonths: 12,
        monthlyAmount: 10000,
        interestRate: 15.0,
      ));
      app.addSubscription(title: 'Netflix', amount: 1500, payDay: 10, method: 'MUFGカード');
      app.loans.add(Loan(
        id: 'l1',
        name: '車',
        principal: 600000,
        interestRate: 3.0,
        totalCount: 12,
        startMonth: DateTime(2026, 9),
        payDay: 10,
        method: 'MUFGカード', // カード払いのローン
        downPayment: 50000,
        downPaymentDate: DateTime(2026, 9, 20),
        downPaymentMethod: 'MUFGカード', // 頭金もカード払い
      ));
      app.amazonCardOverrides['amazon#1'] = 'MUFGカード';
      app.setBudget('MUFGカード', 20000);
      app.setInterestRate('MUFGカード', 12.0);

      app.renameOrMergeCard('MUFGカード', '三菱UFJ');

      expect(app.payments.single.cardName, '三菱UFJ');
      expect(app.installments.single.cardName, '三菱UFJ');
      expect(app.subscriptions.single.method, '三菱UFJ');
      expect(app.loans.single.method, '三菱UFJ');
      expect(app.loans.single.downPaymentMethod, '三菱UFJ');
      expect(app.amazonCardOverrides['amazon#1'], '三菱UFJ');
      expect(app.budgets['MUFGカード'], isNull);
      expect(app.budgets['三菱UFJ'], 20000);
      expect(app.interestRateOf('三菱UFJ'), 12.0);
    });

    test('予算が両方にあれば足す（どちらも消えない）', () {
      final app = twoCards()
        ..setBudget('三菱UFJ', 30000)
        ..setBudget('MUFGカード', 20000);
      app.renameOrMergeCard('MUFGカード', '三菱UFJ');
      expect(app.budgets['三菱UFJ'], 50000);
    });

    test('削除した明細は、まとめた後の取り込みでも復活しない', () {
      final app = twoCards();
      app.reconcilePayments([item('MUFGカード', 8000, d, 'b1#0')]);
      final id = app.payments.single.id;
      app.removePayment(id); // ゴミ箱へ（墓石を記録）
      expect(app.payments, isEmpty);

      app.renameOrMergeCard('MUFGカード', '三菱UFJ');
      // 銀行は相変わらず古い表記で送ってくる
      app.reconcilePayments([item('MUFGカード', 8000, d, 'b1#0')]);
      expect(app.payments, isEmpty); // 復活しない
    });

    test('前にまとめた名前の行き先も付け替わる（迷子にしない）', () {
      final app = twoCards();
      app.mergeCardName('ミツビシUFJニコス', 'MUFGカード'); // 銀行表記 → MUFGカード
      app.renameOrMergeCard('MUFGカード', '三菱UFJ'); // さらに1枚にまとめる
      expect(app.resolveCardName('ミツビシUFJニコス'), '三菱UFJ');
      expect(app.resolveCardName('MUFGカード'), '三菱UFJ');
    });
  });

  group('カード名を変える（まとめ先が無い場合）', () {
    test('締め日・引き落とし日を引き継いで、名前だけ変わる', () {
      final app = AppState()
        ..setCardPaymentDay('三菱UFJ', 10)
        ..setCardClosingDay('三菱UFJ', 15);
      app.renameOrMergeCard('三菱UFJ', '三菱UFJカード');
      expect(app.cardPaymentDays.containsKey('三菱UFJ'), isFalse);
      expect(app.cardPaymentDays['三菱UFJカード'], 10);
      expect(app.closingDayOf('三菱UFJカード'), 15);
      // 締め期間も引き継いだ設定で計算される（9/16〜10/15 → 11月の引き落とし）
      final r = app.cardClosingPeriodOf('三菱UFJカード', DateTime(2026, 11));
      expect(r.start, DateTime(2026, 9, 16));
      expect(r.end, DateTime(2026, 10, 15));
    });

    test('空の名前や同じ名前では何も壊さない', () {
      final app = AppState()..setCardPaymentDay('三菱UFJ', 10);
      app.renameOrMergeCard('三菱UFJ', '   ');
      app.renameOrMergeCard('三菱UFJ', '三菱UFJ');
      expect(app.cardPaymentDays['三菱UFJ'], 10);
      expect(app.cardAliases, isEmpty);
    });
  });
}
