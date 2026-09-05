// カード請求の「利用先」メモのテスト。
// メール取り込みで作り直されても、手で書いたメモが消えないことを担保する。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('利用先メモ', () {
    test('追加時に利用先を書ける', () {
      final app = AppState()
        ..addPayment(
          cardName: '三井OLIVE',
          amount: 3000,
          date: DateTime(2026, 9, 5),
          note: 'Amazonで購入',
        );
      expect(app.payments.single.note, 'Amazonで購入');
    });

    test('前後の空白は落とす', () {
      final app = AppState()
        ..addPayment(
          cardName: '三井OLIVE',
          amount: 100,
          date: DateTime(2026, 9, 5),
          note: '  コンビニ  ',
        );
      expect(app.payments.single.note, 'コンビニ');
    });

    test('あとから書ける・消せる', () {
      final app = AppState()
        ..addPayment(cardName: '楽天カード', amount: 500, date: DateTime(2026, 9, 5));
      final id = app.payments.single.id;

      app.setPaymentNote(id, '書店');
      expect(app.payments.single.note, '書店');

      app.setPaymentNote(id, '');
      expect(app.payments.single.note, '');
    });

    test('メール由来の明細に書いたメモは再取り込みで消えない', () {
      final app = AppState();
      // 1回目の取り込み
      app.reconcilePayments([
        (
          cardName: '三井OLIVE',
          amount: 1200,
          date: DateTime(2026, 9, 3),
          source: PaymentSource.usage,
          sourceId: 'mail-1',
          note: 'SEVEN-ELEVEN',
        )
      ]);
      final id = app.payments.single.id;
      app.setPaymentNote(id, '会社の備品代（立替）');

      // 同じメールをもう一度取り込む（自動データは作り直される）
      app.reconcilePayments([
        (
          cardName: '三井OLIVE',
          amount: 1200,
          date: DateTime(2026, 9, 3),
          source: PaymentSource.usage,
          sourceId: 'mail-1',
          note: 'SEVEN-ELEVEN',
        )
      ]);
      expect(app.payments.single.note, '会社の備品代（立替）');
    });

    test('メモを消すと次の取り込みでメール側の利用先に戻る', () {
      final app = AppState();
      item() => (
            cardName: '三井OLIVE',
            amount: 800,
            date: DateTime(2026, 9, 4),
            source: PaymentSource.usage,
            sourceId: 'mail-2',
            note: 'LAWSON',
          );
      app.reconcilePayments([item()]);
      app.setPaymentNote(app.payments.single.id, '自分メモ');
      app.setPaymentNote(app.payments.single.id, '');
      app.reconcilePayments([item()]);
      expect(app.payments.single.note, 'LAWSON');
    });

    test('メモは書き出し・取り込みで保たれる', () {
      final app = AppState();
      app.reconcilePayments([
        (
          cardName: '楽天カード',
          amount: 2000,
          date: DateTime(2026, 9, 2),
          source: PaymentSource.usage,
          sourceId: 'mail-3',
          note: '',
        )
      ]);
      app.setPaymentNote(app.payments.single.id, '旅行の予約');

      final restored = AppState()..importJson(app.exportJson());
      expect(restored.paymentNotes['mail-3'], '旅行の予約');
      expect(restored.payments.single.note, '旅行の予約');
    });
  });
}
