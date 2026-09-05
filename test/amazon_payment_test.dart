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

  group('既定は Amazonマスター として計上', () {
    test('Amazon明細はそのまま支出になる', () {
      final app = AppState()..reconcilePayments([amazon]);
      final p = app.payments.single;
      expect(p.cardName, 'Amazonマスター');
      expect(p.infoOnly, isFalse);
      expect(app.paymentTotalsByCardOf(DateTime(2026, 9))['Amazonマスター'], 3000);
    });

    test('Amazonマスターで払った分は1件に統合される（二重にならない）', () {
      // 発送メールとvpassの利用通知が同じ買い物を指す。
      // カード・日付・金額が同じなので、取り込みの重複判定で1件にまとまる。
      final app = AppState()
        ..reconcilePayments([amazon, item('Amazonマスター', 3000, d, 'mail-v1')]);
      expect(app.payments, hasLength(1));
      expect(app.paymentTotalsByCardOf(DateTime(2026, 9))['Amazonマスター'], 3000);
    });

    test('別カードの通知は自動では重複と見なさない（移すまでは両方出る）', () {
      // 楽天で払った場合、金額が同じでもカードが違うので機械的には判断できない。
      // ユーザーが「使ったカードに移す」を押した時点で重複が解消される。
      final app = AppState()
        ..reconcilePayments([amazon, item('楽天カード', 3000, d, 'mail-r1')]);
      final totals = app.paymentTotalsByCardOf(DateTime(2026, 9));
      expect(totals['Amazonマスター'], 3000);
      expect(totals['楽天カード'], 3000);

      // 移すと重複が検出され、Amazon側が記録のみになる
      final az = app.payments.firstWhere((p) => app.isAmazonPayment(p));
      expect(app.moveAmazonPaymentTo(az.id, '楽天カード'), isFalse);
      final after = app.paymentTotalsByCardOf(DateTime(2026, 9));
      expect(after['楽天カード'], 3000);
      expect(after['Amazonマスター'], isNull);
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
      expect(app.payments.single.cardName, '楽天カード');

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

    test('Amazonマスターへ選び直せば元に戻る', () {
      final app = AppState()..reconcilePayments([amazon]);
      final id = app.payments.single.id;
      app.moveAmazonPaymentTo(id, '楽天カード');
      expect(app.payments.single.cardName, '楽天カード');

      app.moveAmazonPaymentTo(id, 'Amazonマスター');
      final p = app.payments.single;
      expect(p.cardName, 'Amazonマスター');
      expect(p.infoOnly, isFalse);
      expect(app.paymentTotalsByCardOf(DateTime(2026, 9))['Amazonマスター'], 3000);
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
