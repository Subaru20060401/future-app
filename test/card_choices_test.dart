// カード選択肢（設定で追加したカードが選べるか）のテスト。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('cardChoices', () {
    test('既定のカードが並び、「その他」が最後に来る', () {
      final app = AppState();
      expect(app.cardChoices.first, '三井OLIVE');
      expect(app.cardChoices.last, AppState.kOtherCard);
      expect(app.cardChoices, contains('楽天カード'));
    });

    test('設定で追加したカードが選択肢に入る', () {
      final app = AppState()..setCardPaymentDay('セゾンカード', 4);
      expect(app.cardChoices, contains('セゾンカード'));
      expect(app.cardChoices.last, AppState.kOtherCard); // 「その他」は末尾のまま
    });

    test('明細にしかないカードも選択肢に残る（過去データを選べる）', () {
      final app = AppState();
      app.payments.add(Payment(
        id: 'p1',
        cardName: '廃止したカード',
        amount: 100,
        paymentDate: DateTime(2026, 8, 1),
        source: PaymentSource.usage,
      ));
      expect(app.cardChoices, contains('廃止したカード'));
    });

    test('分割払いのカードも選択肢に入る', () {
      final app = AppState();
      app.installments.add(Installment(
        id: 'i1',
        name: 'PC',
        cardName: 'オリコカード',
        totalAmount: 120000,
        installmentCount: 12,
        remainingMonths: 12,
        monthlyAmount: 10000,
        interestRate: 15.0,
      ));
      expect(app.cardChoices, contains('オリコカード'));
    });

    test('重複せず、空文字も入らない', () {
      final app = AppState()..setCardPaymentDay('楽天カード', 27);
      app.payments.addAll([
        Payment(
            id: 'p1',
            cardName: '楽天カード',
            amount: 1,
            paymentDate: DateTime(2026, 8, 1),
            source: PaymentSource.usage),
        Payment(
            id: 'p2',
            cardName: '',
            amount: 1,
            paymentDate: DateTime(2026, 8, 1),
            source: PaymentSource.usage),
      ]);
      final choices = app.cardChoices;
      expect(choices.where((c) => c == '楽天カード'), hasLength(1));
      expect(choices.where((c) => c.isEmpty), isEmpty);
      expect(choices.where((c) => c == AppState.kOtherCard), hasLength(1));
    });
  });
}
