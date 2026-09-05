// カードの締め日（設定→カードの締め日・引き落とし日）のテスト。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Payment usage(String card, int amount, DateTime d) => Payment(
        id: '${card}_${d.toIso8601String()}_$amount',
        cardName: card,
        amount: amount,
        paymentDate: d,
        source: PaymentSource.usage,
      );

  group('締め日の既定値', () {
    test('未設定は月末締め（従来どおり）', () {
      final app = AppState();
      expect(app.closingDayOf('楽天カード'), 31);
      expect(app.isMonthEndClosing('楽天カード'), isTrue);
      expect(app.closingLabelOf('楽天カード'), '月末締め');
    });

    test('月末締めの対象期間は前月まるごと', () {
      final app = AppState();
      final r = app.cardClosingPeriodOf('楽天カード', DateTime(2026, 9));
      expect(r.start, DateTime(2026, 8, 1));
      expect(r.end, DateTime(2026, 8, 31));
    });
  });

  group('締め日を設定したとき', () {
    test('15日締めは「前々月16日〜前月15日」が対象', () {
      final app = AppState()..setCardClosingDay('楽天カード', 15);
      expect(app.closingLabelOf('楽天カード'), '15日締め');
      final r = app.cardClosingPeriodOf('楽天カード', DateTime(2026, 9));
      expect(r.start, DateTime(2026, 7, 16));
      expect(r.end, DateTime(2026, 8, 15));
    });

    test('締め日が月の日数を超える月は月末に丸める', () {
      final app = AppState()..setCardClosingDay('楽天カード', 30);
      // 2026年3月引き落とし → 対象は 1/31〜2/28（2月は28日まで）
      final r = app.cardClosingPeriodOf('楽天カード', DateTime(2026, 3));
      expect(r.end, DateTime(2026, 2, 28));
      expect(r.start, DateTime(2026, 1, 31));
    });

    test('締め期間の利用だけを合計する', () {
      final app = AppState()..setCardClosingDay('楽天カード', 15);
      app.payments.addAll([
        usage('楽天カード', 1000, DateTime(2026, 7, 15)), // 期間外（前の締め）
        usage('楽天カード', 2000, DateTime(2026, 7, 16)), // 期間内（初日）
        usage('楽天カード', 3000, DateTime(2026, 8, 15)), // 期間内（締め日当日）
        usage('楽天カード', 4000, DateTime(2026, 8, 16)), // 期間外（次の締め）
      ]);
      expect(app.cardUsageInClosingPeriod('楽天カード', DateTime(2026, 9)), 5000);
    });

    test('銀行の引落確定がある月はその金額が正本', () {
      final app = AppState()..setCardClosingDay('楽天カード', 15);
      app.payments.addAll([
        usage('楽天カード', 2000, DateTime(2026, 8, 1)),
        Payment(
          id: 'bank1',
          cardName: '楽天カード',
          amount: 9800,
          paymentDate: DateTime(2026, 9, 27),
          source: PaymentSource.bank,
        ),
      ]);
      expect(app.cardUsageInClosingPeriod('楽天カード', DateTime(2026, 9)), 9800);
    });

    test('内訳ラベルに対象期間が付く', () {
      final app = AppState()
        ..cardPaymentDays.addAll(AppState.kSeedCardPaymentDays)
        ..setCardClosingDay('楽天カード', 15);
      expect(app.drawLabelOf('楽天カード', DateTime(2026, 9)), '楽天カード（7/16〜8/15利用）');
      // 月末締めのカードは従来どおり素のラベル
      expect(app.drawLabelOf('三井OLIVE', DateTime(2026, 9)), '三井OLIVE');
    });
  });

  group('引き落とし内訳への反映', () {
    test('締め日を変えると引き落とし額が変わる', () {
      final app = AppState()..cardPaymentDays.addAll(AppState.kSeedCardPaymentDays);
      app.payments.addAll([
        usage('楽天カード', 1000, DateTime(2026, 7, 20)),
        usage('楽天カード', 5000, DateTime(2026, 8, 20)),
      ]);
      final payMonth = DateTime(2026, 9);

      // 月末締め: 8月ぶん(5000)が9月に引き落とし
      var rakuten = app
          .drawBreakdownOf(payMonth)
          .where((e) => e.label == '楽天カード')
          .fold(0, (s, e) => s + e.amount);
      expect(rakuten, 5000);

      // 15日締め: 対象は 7/16〜8/15 → 7/20の1000だけ
      app.setCardClosingDay('楽天カード', 15);
      rakuten = app
          .drawBreakdownOf(payMonth)
          .where((e) => e.label == '楽天カード')
          .fold(0, (s, e) => s + e.amount);
      expect(rakuten, 1000);
    });

    test('締め日は保存・復元される', () {
      final app = AppState()..setCardClosingDay('楽天カード', 15);
      final restored = AppState()..importJson(app.exportJson());
      expect(restored.closingDayOf('楽天カード'), 15);
    });
  });
}
