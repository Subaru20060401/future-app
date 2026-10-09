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

  // ⚠️ 締め期間で集計するのは利用明細だけ。分割払い・カード払いのローン・頭金は
  //   月ごとに積まれるので、別で足さないと予想から丸ごと消える。
  //   （注記には「うち分割払い」と出るのに合計に入っていない、という形で出た）
  group('締め日を設定したカードに乗っているもの', () {
    Installment monthly(String card, int amount) => Installment(
          id: 'i_$card',
          name: 'PC',
          cardName: card,
          totalAmount: amount * 12,
          installmentCount: 12,
          remainingMonths: 12,
          monthlyAmount: amount,
          interestRate: 15.0,
          startDate: DateTime(2026, 9, 1),
        );

    int drawOf(AppState app, String card, DateTime payMonth) => app
        .drawBreakdownOf(payMonth)
        .where((e) => e.label == card)
        .fold(0, (s, e) => s + e.amount);

    test('分割払いも請求に合算される（月末締めと同じ額になる）', () {
      // 15日締め・翌月10日払い: 9/16〜10/15 の利用が11月の引き落とし
      final app = AppState()
        ..setCardPaymentDay('三菱UFJカード', 10)
        ..setCardClosingDay('三菱UFJカード', 15);
      app.payments.add(usage('三菱UFJカード', 20000, DateTime(2026, 9, 20)));
      app.installments.add(monthly('三菱UFJカード', 10000));
      expect(drawOf(app, '三菱UFJカード', DateTime(2026, 11)), 30000);

      // 月末締めのカードと同じ扱いであること
      final other = AppState()..setCardPaymentDay('楽天カード', 27);
      other.payments.add(usage('楽天カード', 20000, DateTime(2026, 10, 20)));
      other.installments.add(monthly('楽天カード', 10000));
      expect(drawOf(other, '楽天カード', DateTime(2026, 11)), 30000);
    });

    test('カード払いのローンも合算される', () {
      final app = AppState()
        ..setCardPaymentDay('三菱UFJカード', 10)
        ..setCardClosingDay('三菱UFJカード', 15);
      app.loans.add(Loan(
        id: 'l1',
        name: '車',
        principal: 240000,
        interestRate: 0,
        totalCount: 24,
        startMonth: DateTime(2026, 9),
        payDay: 10,
        method: '三菱UFJカード', // カードの請求に含める
      ));
      expect(drawOf(app, '三菱UFJカード', DateTime(2026, 11)), 10000);
    });

    test('銀行の引落確定がある月は足さない（確定額が正本）', () {
      final app = AppState()
        ..setCardPaymentDay('三菱UFJカード', 10)
        ..setCardClosingDay('三菱UFJカード', 15);
      app.installments.add(monthly('三菱UFJカード', 10000));
      app.payments.add(Payment(
        id: 'b1',
        cardName: '三菱UFJカード',
        amount: 25000,
        paymentDate: DateTime(2026, 11, 10), // 11月の引落確定
        source: PaymentSource.bank,
      ));
      // 確定の25000だけ。分割の10000を足して35000にしない
      expect(drawOf(app, '三菱UFJカード', DateTime(2026, 11)), 25000);
    });

    // ⚠️ 反映済みかどうか（残高の基準日より前か）は、銀行の確定に載っている
    //   実際の引き落とし日で決める。設定した日（土日祝ずらし込み）で決めると、
    //   日付がズレたときに「残高から引いたのに予想でもまた引く」二重計上になる。
    test('銀行確定の実際の日付が基準日より前なら、予想ではもう引かない', () {
      final app = AppState()..setCardPaymentDay('三菱UFJカード', 10);
      // 11月の引き落としは 11/6 に実際に落ちた（設定の10日より前）
      app.payments.add(Payment(
        id: 'b1',
        cardName: '三菱UFJカード',
        amount: 32000,
        paymentDate: DateTime(2026, 11, 6),
        source: PaymentSource.bank,
      ));
      app.balanceUpdatedAt = DateTime(2026, 11, 8); // 11/8 に残高へ反映済み
      expect(drawOf(app, '三菱UFJカード', DateTime(2026, 11)), 0,
          reason: '11/6に落ちたものは11/8の残高に入っている');
    });

    test('銀行確定の実際の日付が基準日より後なら、予想で引く', () {
      final app = AppState()..setCardPaymentDay('三菱UFJカード', 10);
      app.payments.add(Payment(
        id: 'b1',
        cardName: '三菱UFJカード',
        amount: 32000,
        paymentDate: DateTime(2026, 11, 12), // 設定の10日より後に落ちる
        source: PaymentSource.bank,
      ));
      app.balanceUpdatedAt = DateTime(2026, 11, 11);
      expect(drawOf(app, '三菱UFJカード', DateTime(2026, 11)), 32000);
    });

    test('注記の「うち分割払い」と合計が食い違わない', () {
      final app = AppState()
        ..setCardPaymentDay('三菱UFJカード', 10)
        ..setCardClosingDay('三菱UFJカード', 15);
      app.installments.add(monthly('三菱UFJカード', 10000));
      final payMonth = DateTime(2026, 11);
      // 注記に出る額は、合計の中に含まれていること
      expect(app.installmentPartOfDraw(payMonth), 10000);
      expect(app.drawnInMonth(payMonth), greaterThanOrEqualTo(10000));
    });
  });
}
