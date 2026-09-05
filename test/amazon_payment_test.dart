// Amazon明細の扱い（二重計上の防止と、使ったカードへの付け替え）のテスト。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  ({String cardName, int amount, DateTime date, PaymentSource source, String sourceId, String note})
      item(String card, int amount, DateTime d, String sourceId) =>
          (
            cardName: card,
            amount: amount,
            date: d,
            source: PaymentSource.usage,
            sourceId: sourceId,
            note: '',
          );

  final d = DateTime(2026, 9, 3);
  final amazon = item('Amazonマスター', 3000, d, 'amazon#249-1');

  group('既定は「記録のみ」', () {
    test('Amazon明細は合計に入らない', () {
      final app = AppState()..reconcilePayments([amazon]);
      final p = app.payments.single;
      expect(p.infoOnly, isTrue);
      expect(app.paymentTotalsByCardOf(DateTime(2026, 9))['Amazonマスター'], isNull);
    });

    test('カード会社の通知と並んでも二重にならない', () {
      // 楽天で払った → Amazonの発送メールと楽天の利用通知が両方来る
      final app = AppState()
        ..reconcilePayments([amazon, item('楽天カード', 3000, d, 'mail-r1')]);
      final totals = app.paymentTotalsByCardOf(DateTime(2026, 9));
      expect(totals['楽天カード'], 3000);
      expect(totals['Amazonマスター'], isNull);
      expect(totals.values.fold(0, (s, v) => s + v), 3000); // 合計は1件ぶん
    });

    test('カード会社の通知（vpass由来）は普通に計上される', () {
      // _resolveCardName で Amazonマスター に振られた本物の請求は sourceId が違う
      final app = AppState()
        ..reconcilePayments([item('Amazonマスター', 1500, d, 'mail-v1')]);
      expect(app.payments.single.infoOnly, isFalse);
      expect(app.paymentTotalsByCardOf(DateTime(2026, 9))['Amazonマスター'], 1500);
    });
  });

  group('使ったカードへの付け替え', () {
    test('付け替えるとそのカードの支出になる', () {
      final app = AppState()..reconcilePayments([amazon]);
      final id = app.payments.single.id;

      expect(app.moveAmazonPaymentTo(id, '楽天カード'), isTrue);
      final p = app.payments.single;
      expect(p.cardName, '楽天カード');
      expect(p.infoOnly, isFalse);
      expect(app.paymentTotalsByCardOf(DateTime(2026, 9))['楽天カード'], 3000);
    });

    test('同じ日・同じ金額が既にあるなら付け替えず記録のみに戻す', () {
      final app = AppState()
        ..reconcilePayments([amazon, item('楽天カード', 3000, d, 'mail-r1')]);
      final az = app.payments.firstWhere((p) => app.isAmazonPayment(p));

      expect(app.moveAmazonPaymentTo(az.id, '楽天カード'), isFalse);
      expect(app.payments.firstWhere((p) => app.isAmazonPayment(p)).infoOnly, isTrue);
      expect(app.paymentTotalsByCardOf(DateTime(2026, 9))['楽天カード'], 3000);
    });

    test('付け替えた後にカード会社の通知が来たら、自動で記録のみに戻る', () {
      final app = AppState()..reconcilePayments([amazon]);
      app.moveAmazonPaymentTo(app.payments.single.id, '楽天カード');
      expect(app.payments.single.infoOnly, isFalse);

      // 後日、楽天の利用通知が届いて再取り込み
      app.reconcilePayments([amazon, item('楽天カード', 3000, d, 'mail-r1')]);
      final az = app.payments.firstWhere((p) => app.isAmazonPayment(p));
      expect(az.infoOnly, isTrue, reason: '二重計上になるので付け替えは取り消される');
      expect(app.paymentTotalsByCardOf(DateTime(2026, 9))['楽天カード'], 3000);
    });

    test('付け替えは再取り込みで消えない', () {
      final app = AppState()..reconcilePayments([amazon]);
      app.moveAmazonPaymentTo(app.payments.single.id, 'PayPayカード');

      app.reconcilePayments([amazon]); // 同じメールをもう一度
      expect(app.payments.single.cardName, 'PayPayカード');
      expect(app.payments.single.infoOnly, isFalse);
    });

    test('手で情報のみに戻せる', () {
      final app = AppState()..reconcilePayments([amazon]);
      final id = app.payments.single.id;
      app.moveAmazonPaymentTo(id, '楽天カード');
      app.resetAmazonPayment(id);

      final p = app.payments.single;
      expect(p.cardName, 'Amazonマスター');
      expect(p.infoOnly, isTrue);
      expect(app.paymentTotalsByCardOf(DateTime(2026, 9))['楽天カード'], isNull);
    });

    test('付け替えは書き出し・取り込みで保たれる', () {
      final app = AppState()..reconcilePayments([amazon]);
      app.moveAmazonPaymentTo(app.payments.single.id, 'メルカード');

      final restored = AppState()..importJson(app.exportJson());
      expect(restored.amazonCardOverrides['amazon#249-1'], 'メルカード');
      expect(restored.payments.single.cardName, 'メルカード');
      expect(restored.payments.single.infoOnly, isFalse);
    });
  });
}
