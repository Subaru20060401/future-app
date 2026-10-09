// 予想の谷（月末と月末のあいだ）のテスト。
// 💡 10日引き落としのカードのように、月末を越えてから落ちるものがあると、
//   月末の予想だけでは「次の給料日まで足りない」が見えない。
// ⚠️ 日次の積み上げは月末の予想と同じ材料でなければならない。
//   ここがズレると、同じデータなのに画面ごとに違う金額が出る。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final now = DateTime.now();
  final thisMonth = DateTime(now.year, now.month);
  final nextMonth = DateTime(now.year, now.month + 1);
  final monthAfterNext = DateTime(now.year, now.month + 2);

  Payment usage(String card, int amount, DateTime d) => Payment(
        id: '${card}_${d.toIso8601String()}_$amount',
        cardName: card,
        amount: amount,
        paymentDate: d,
        source: PaymentSource.usage,
      );

  // 月末締め・10日引き落としのカード（三菱関連）と、月末寄りのカード。
  AppState build() {
    final app = AppState();
    app.currentBalance = 50000; // 編集日は付けない＝ゲート無しで全部予想に入る
    app.cardPaymentDays['三菱カード'] = 10;
    app.cardPaymentDays['三井OLIVE'] = 26;
    return app;
  }

  // 指定日までの累計残高（日次の積み上げ）
  int balanceAt(AppState app, DateTime until) {
    var running = app.effectiveBalance + app.effectiveWalletCash;
    for (final e in app.cashEventsAhead()) {
      if (e.date.isAfter(until)) continue;
      running += e.amount;
    }
    return running;
  }

  DateTime endOf(DateTime m) => DateTime(m.year, m.month + 1, 0);

  group('月末の予想と食い違わない', () {
    test('月末時点の積み上げが、今月末・来月末・翌々月末の予想と一致する', () {
      final app = build();
      app.payments.addAll([
        usage('三菱カード', 90000, DateTime(now.year, now.month - 1, 5)),
        usage('三井OLIVE', 30000, DateTime(now.year, now.month - 1, 20)),
        usage('三菱カード', 20000, DateTime(now.year, now.month, 3)),
      ]);
      app.plannedIncomes.add(PlannedIncome(
        id: 'salary',
        title: 'バイト代',
        amount: 100000,
        date: DateTime(now.year, now.month, 25),
        monthly: true,
      ));

      expect(balanceAt(app, endOf(thisMonth)), app.thisMonthBalance);
      expect(balanceAt(app, endOf(nextMonth)), app.nextMonthBalance);
      expect(balanceAt(app, endOf(monthAfterNext)), app.monthAfterNextBalance);
    });

    test('カードも入金も無ければ、ずっと今の残高のまま', () {
      final app = build();
      expect(app.cashEventsAhead(), isEmpty);
      expect(app.lowestBalanceAhead(), isNull);
      expect(app.thisMonthBalance, 50000);
    });
  });

  group('谷（最低残高）', () {
    // 今月の利用が来月10日に落ちる。給料は25日なので、10日〜25日が谷になる。
    AppState dipCase() {
      final app = build();
      app.payments.add(usage('三菱カード', 90000, DateTime(now.year, now.month, 5)));
      app.plannedIncomes.add(PlannedIncome(
        id: 'salary',
        title: 'バイト代',
        amount: 100000,
        date: DateTime(now.year, now.month, 25),
        monthly: true,
      ));
      return app;
    }

    test('月末の予想では見えない谷を見つける', () {
      final app = dipCase();
      final low = app.lowestBalanceAhead()!;
      // 50000 ＋今月25日の10万 −来月10日の9万 ＝ 60000
      expect(low.balance, 60000);
      expect(low.date, app.cardDrawDateOf('三菱カード', nextMonth));
      // 月末だけ見ていると 16万あるように見えてしまう
      expect(app.nextMonthBalance, 160000);
      expect(low.balance, lessThan(app.nextMonthBalance));
    });

    test('引き落としが大きいと谷はマイナスになる（足りないと分かる）', () {
      final app = dipCase();
      app.currentBalance = 0;
      // 10日落ちのカードの利用を増やす（9万＋6万＝15万が来月10日に落ちる）
      app.payments.add(usage('三菱カード', 60000, DateTime(now.year, now.month, 7)));
      final low = app.lowestBalanceAhead()!;
      // 0 ＋今月25日の10万 −来月10日の15万 ＝ −50000
      expect(low.balance, -50000);
      expect(low.date, app.cardDrawDateOf('三菱カード', nextMonth));
      // 来月末まで待てば戻るので、月末だけ見ていると気づけない
      expect(app.nextMonthBalance, greaterThan(0));
    });

    test('足りない日は、日付とカード名つきで全部出す', () {
      final app = dipCase();
      app.currentBalance = 0;
      app.payments.add(usage('三菱カード', 60000, DateTime(now.year, now.month, 7)));
      final days = app.shortfallDaysAhead();
      expect(days, hasLength(1));
      expect(days.single.date, app.cardDrawDateOf('三菱カード', nextMonth));
      expect(days.single.labels, ['三菱カード']);
      expect(days.single.balance, -50000);
    });

    test('入金だけの日は「足りない日」に出さない（引き落としが無いのに引き落としと出ていた）', () {
      final app = build();
      app.currentBalance = 0;
      app.payments.add(usage('三菱カード', 90000, DateTime(now.year, now.month, 5)));
      app.plannedIncomes.add(PlannedIncome(
        id: 'salary',
        title: 'バイト代',
        amount: 10000,
        date: DateTime(now.year, now.month, 25),
        monthly: true,
      ));
      // 来月10日に −80000。その後の25日は入金で −70000 に戻るだけ（引き落としは無い）
      final days = app.shortfallDaysAhead();
      expect(days, hasLength(1));
      expect(days.single.date, app.cardDrawDateOf('三菱カード', nextMonth));
      expect(days.single.labels, ['三菱カード']);
    });

    test('同じ日に複数の引き落としがあれば両方の名前を出す', () {
      final app = build();
      app.currentBalance = 0;
      app.cardPaymentDays['三井OLIVE'] = 10; // 三菱と同じ日に落ちる設定にする
      app.payments.addAll([
        usage('三菱カード', 50000, DateTime(now.year, now.month, 5)),
        usage('三井OLIVE', 30000, DateTime(now.year, now.month, 6)),
      ]);
      final days = app.shortfallDaysAhead();
      expect(days, hasLength(1));
      expect(days.single.labels, containsAll(['三菱カード', '三井OLIVE']));
      expect(days.single.balance, -80000);
    });

    test('足りる場合は警告を出さない', () {
      final app = dipCase(); // 残高5万＋給料10万 −9万 ＝ 6万で足りる
      expect(app.shortfallDaysAhead(), isEmpty);
      expect(app.lowestBalanceAhead()!.balance, 60000);
    });

    test('同じ日に入金があるぶんは相殺して見る（一瞬のヘコみで騒がない）', () {
      final app = build();
      // 26日引き落としと同じ日に、同額の入金がある
      app.payments.add(usage('三井OLIVE', 30000, DateTime(now.year, now.month - 1, 5)));
      app.plannedIncomes.add(PlannedIncome(
        id: 'bonus',
        title: '臨時収入',
        amount: 30000,
        date: app.cardDrawDateOf('三井OLIVE', thisMonth),
        monthly: false,
      ));
      final low = app.lowestBalanceAhead()!;
      expect(low.balance, 50000); // 減らない
    });
  });
}
