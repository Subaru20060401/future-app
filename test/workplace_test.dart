// 勤務先マスタ・シフト給与計算のテスト。
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ShiftData.earnings の手当計算', () {
    test('手当なしは 時給×実働時間', () {
      final s = ShiftData(
        workplace: 'バイト',
        hourlyWage: 1000,
        start: DateTime(2026, 6, 15, 9, 0), // 月曜
        end: DateTime(2026, 6, 15, 17, 0),
        breakMinutes: 60,
      );
      expect(s.workHours, 7.0);
      expect(s.earnings, 7000);
    });

    test('交通費は定額で上乗せ', () {
      final s = ShiftData(
        workplace: 'バイト',
        hourlyWage: 1000,
        start: DateTime(2026, 6, 15, 9, 0),
        end: DateTime(2026, 6, 15, 17, 0),
        breakMinutes: 60,
        transportPerDay: 300,
      );
      expect(s.earnings, 7300);
    });

    test('深夜割増は22:00〜翌5:00の重なりぶん（休憩0）', () {
      final s = ShiftData(
        workplace: 'バイト',
        hourlyWage: 1000,
        start: DateTime(2026, 6, 15, 22, 0),
        end: DateTime(2026, 6, 16, 6, 0), // 翌6時まで8時間
        breakMinutes: 0,
        nightMultiplier: 1.25,
      );
      expect(s.workHours, 8.0);
      expect(s.nightHours, 7.0); // 22-翌5 の7時間
      // 8000 + 7*1000*0.25 = 9750
      expect(s.earnings, 9750);
    });

    test('残業割増は8時間超ぶん', () {
      final s = ShiftData(
        workplace: 'バイト',
        hourlyWage: 1000,
        start: DateTime(2026, 6, 15, 9, 0),
        end: DateTime(2026, 6, 15, 20, 0), // 11時間
        breakMinutes: 60, // 実働10時間
        overtimeMultiplier: 1.25,
      );
      expect(s.workHours, 10.0);
      // 10000 + (10-8)*1000*0.25 = 10500
      expect(s.earnings, 10500);
    });

    test('休日割増は土日のみ全体に適用', () {
      final sat = ShiftData(
        workplace: 'バイト',
        hourlyWage: 1000,
        start: DateTime(2026, 6, 13, 9, 0), // 土曜
        end: DateTime(2026, 6, 13, 17, 0),
        breakMinutes: 60,
        holidayMultiplier: 1.35,
      );
      expect(sat.start.weekday, DateTime.saturday);
      // 7000 + 7*1000*0.35 = 9450
      expect(sat.earnings, 9450);

      final mon = ShiftData(
        workplace: 'バイト',
        hourlyWage: 1000,
        start: DateTime(2026, 6, 15, 9, 0), // 月曜
        end: DateTime(2026, 6, 15, 17, 0),
        breakMinutes: 60,
        holidayMultiplier: 1.35,
      );
      expect(mon.earnings, 7000); // 平日は割増なし
    });
  });

  group('wagePeriodFor の期間選択', () {
    test('effectiveFrom の境界で正しい時給を返す', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();

      final w = Workplace(id: 'w1', name: 'テスト', wagePeriods: [
        WagePeriod(hourlyWage: 1000), // null = 最古
        WagePeriod(effectiveFrom: DateTime(2025, 2, 1), hourlyWage: 1050),
        WagePeriod(effectiveFrom: DateTime(2026, 3, 1), hourlyWage: 1100),
      ]);

      expect(app.wagePeriodFor(w, DateTime(2025, 1, 15))!.hourlyWage, 1000);
      expect(app.wagePeriodFor(w, DateTime(2025, 2, 1))!.hourlyWage, 1050); // 境界含む
      expect(app.wagePeriodFor(w, DateTime(2025, 12, 31))!.hourlyWage, 1050);
      expect(app.wagePeriodFor(w, DateTime(2026, 3, 1))!.hourlyWage, 1100);
      expect(app.wagePeriodFor(w, DateTime(2026, 5, 1))!.hourlyWage, 1100);
    });

    test('payPeriodStartFor は月末締めで月初へスナップ', () {
      final w = Workplace(id: 'w', name: 'x', closingDay: 31);
      expect(w.payPeriodStartFor(DateTime(2026, 4, 17)), DateTime(2026, 4, 1));
    });

    test('payPeriodStartFor は15日締めで締日翌日へスナップ', () {
      final w = Workplace(id: 'w', name: 'x', closingDay: 15);
      // 4/10 は 3/16〜4/15 の期間 → 開始 3/16
      expect(w.payPeriodStartFor(DateTime(2026, 4, 10)), DateTime(2026, 3, 16));
      // 4/20 は 4/16〜5/15 の期間 → 開始 4/16
      expect(w.payPeriodStartFor(DateTime(2026, 4, 20)), DateTime(2026, 4, 16));
    });
  });

  group('交通費の月上限と収入内訳', () {
    test('月上限を超える交通費は上限で頭打ち（賃金は満額）', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();

      // 時給1000・7h・交通費500/日・月上限1000円のシフトを3日分（交通費1500→上限1000）
      ShiftData mk(int day) => ShiftData(
            workplace: 'A',
            workplaceId: 'wA',
            hourlyWage: 1000,
            start: DateTime(2026, 6, day, 9, 0),
            end: DateTime(2026, 6, day, 17, 0),
            breakMinutes: 60,
            transportPerDay: 500,
            transportMonthlyCap: 1000,
          );
      app.addShift(DateTime(2026, 6, 1), mk(1));
      app.addShift(DateTime(2026, 6, 2), mk(2));
      app.addShift(DateTime(2026, 6, 3), mk(3));

      // 賃金 7000*3 = 21000、交通費 1500→上限1000 = 合計 22000
      expect(app.salaryOf(DateTime(2026, 6)), 22000);
    });

    test('incomeBreakdownOf は勤務先ごとに金額降順', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();

      app.addShift(
        DateTime(2026, 6, 1),
        ShiftData(
            workplace: 'A',
            workplaceId: 'wA',
            hourlyWage: 1000,
            start: DateTime(2026, 6, 1, 9, 0),
            end: DateTime(2026, 6, 1, 17, 0),
            breakMinutes: 60), // 7000
      );
      app.addShift(
        DateTime(2026, 6, 2),
        ShiftData(
            workplace: 'B',
            workplaceId: 'wB',
            hourlyWage: 2000,
            start: DateTime(2026, 6, 2, 9, 0),
            end: DateTime(2026, 6, 2, 17, 0),
            breakMinutes: 60), // 14000
      );

      final bd = app.incomeBreakdownOf(DateTime(2026, 6));
      expect(bd.length, 2);
      expect(bd.first.label, 'B'); // 降順
      expect(bd.first.amount, 14000);
      expect(bd[1].amount, 7000);
    });
  });

  group('総労働時間・実給料', () {
    test('workHoursOf は月内シフトの実働合計', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.addShift(
        DateTime(2026, 6, 1),
        ShiftData(
            workplace: 'A',
            hourlyWage: 1000,
            start: DateTime(2026, 6, 1, 9, 0),
            end: DateTime(2026, 6, 1, 17, 0),
            breakMinutes: 60), // 7h
      );
      app.addShift(
        DateTime(2026, 6, 2),
        ShiftData(
            workplace: 'A',
            hourlyWage: 1000,
            start: DateTime(2026, 6, 2, 9, 0),
            end: DateTime(2026, 6, 2, 14, 0),
            breakMinutes: 0), // 5h
      );
      expect(app.workHoursOf(DateTime(2026, 6)), 12.0);
    });

    test('実給料は手入力で保存・0でクリア', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      expect(app.actualSalaryOf(DateTime(2026, 6)), isNull);
      app.setActualSalary(DateTime(2026, 6), 123456);
      expect(app.actualSalaryOf(DateTime(2026, 6)), 123456);
      app.setActualSalary(DateTime(2026, 6), 0); // クリア
      expect(app.actualSalaryOf(DateTime(2026, 6)), isNull);
    });
  });

  group('予算・エクスポート/インポート', () {
    test('budgetStatus は超過を検出', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.payments = [
        Payment(id: '1', cardName: '楽天カード', amount: 8000, paymentDate: DateTime.now(), source: PaymentSource.billing),
      ];
      app.setBudget('楽天カード', 5000);
      final over = app.overBudgetThisMonth;
      expect(over.length, 1);
      expect(over.first.spent, 8000);
      expect(over.first.over, isTrue);
    });

    test('exportJson→importJson でデータが復元される', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.updateBalance(50000);
      app.setGoal(300000, DateTime(2026, 12));
      app.setBudget('食費', 30000);
      app.addWorkplace(Workplace(id: 'w1', name: 'カフェ', wagePeriods: [WagePeriod(hourlyWage: 1100)]));
      final json = app.exportJson();

      // 別インスタンスへ取り込み
      SharedPreferences.setMockInitialValues({});
      final app2 = AppState();
      await app2.loadData();
      app2.importJson(json);
      expect(app2.currentBalance, 50000);
      expect(app2.goalAmount, 300000);
      expect(app2.budgets['食費'], 30000);
      expect(app2.workplaces.any((w) => w.name == 'カフェ'), isTrue);
    });
  });

  group('手動追加と正式メールの統合', () {
    test('同カード・同年月日・同金額の正式取り込みが来たら手動を置き換える', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      // メール受信が遅いカードを手動追加
      app.addPayment(cardName: '楽天カード', amount: 3000, date: DateTime(2026, 6, 10), source: PaymentSource.manual);
      expect(app.payments.where((p) => p.source == PaymentSource.manual).length, 1);

      // 後日、同じ内容の正式メール（利用通知）が届く
      app.reconcilePayments([
        (cardName: '楽天カード', amount: 3000, date: DateTime(2026, 6, 10, 14, 30), source: PaymentSource.usage, sourceId: 'mail-x', note: 'AMAZON'),
      ]);

      // 手動は消え、正式（usage）1件だけに統合される
      final rakuten = app.payments.where((p) => p.cardName == '楽天カード' && p.amount == 3000).toList();
      expect(rakuten.length, 1);
      expect(rakuten.first.source, PaymentSource.usage);
    });

    test('日付か金額が違えば置き換えない（別決済として残す）', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.addPayment(cardName: '楽天カード', amount: 3000, date: DateTime(2026, 6, 10), source: PaymentSource.manual);
      app.reconcilePayments([
        (cardName: '楽天カード', amount: 3000, date: DateTime(2026, 6, 11), source: PaymentSource.usage, sourceId: 'mail-y', note: ''),
      ]);
      // 日付違い→両方残る
      expect(app.payments.where((p) => p.cardName == '楽天カード').length, 2);
    });
  });

  group('ゴミ箱・墓石（削除の永続化）', () {
    test('削除でゴミ箱へ退避し、復元で戻る', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.payments = [
        Payment(id: 'x', cardName: '楽天カード', amount: 1980, paymentDate: DateTime(2026, 5, 1), source: PaymentSource.usage, sourceId: 'mail-1'),
      ];
      app.removePayment('x');
      expect(app.payments.any((p) => p.id == 'x'), isFalse);
      expect(app.trashedPayments.any((p) => p.id == 'x'), isTrue);
      app.restorePayment('x');
      expect(app.payments.any((p) => p.id == 'x'), isTrue);
      expect(app.trashedPayments.isEmpty, isTrue);
    });

    test('更新(reconcile)は削除済み(墓石)を復活させない', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.payments = [
        Payment(id: 'x', cardName: '楽天カード', amount: 1980, paymentDate: DateTime(2026, 5, 1), source: PaymentSource.usage, sourceId: 'mail-1'),
      ];
      app.removePayment('x'); // 墓石記録

      // 同じ明細が再取得されても復活しない
      app.reconcilePayments([
        (cardName: '楽天カード', amount: 1980, date: DateTime(2026, 5, 1), source: PaymentSource.usage, sourceId: 'mail-1', note: ''),
      ]);
      expect(app.payments.any((p) => p.sourceId == 'mail-1'), isFalse);

      // 復元すると墓石解除 → 次の更新では戻ってくる
      app.restorePayment('x');
      app.reconcilePayments([
        (cardName: '楽天カード', amount: 1980, date: DateTime(2026, 5, 1), source: PaymentSource.usage, sourceId: 'mail-1', note: ''),
      ]);
      expect(app.payments.where((p) => p.sourceId == 'mail-1').length, 1);
    });
  });

  group('支出: 銀行確定と手動の二重計上防止 / 分割は利用月', () {
    test('銀行確定があるカードの手動追加は上乗せしない（確定額に含まれるため）', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.payments = [
        // 4月利用→5月引き落とし（確定）。この確定額に手動分も既に含まれている
        Payment(id: 'b', cardName: '三井OLIVE', amount: 42446, paymentDate: DateTime(2026, 5, 27), source: PaymentSource.bank),
        // ユーザーが4月に手動追加（メール受信が遅くて先に登録した分）
        Payment(id: 'm', cardName: '三井OLIVE', amount: 1980, paymentDate: DateTime(2026, 4, 15), source: PaymentSource.manual),
      ];
      final apr = {for (final e in app.expenseBreakdownOf(DateTime(2026, 4))) e.label: e.amount};
      expect(apr['三井OLIVE'], 42446); // 銀行確定のみ（手動は二重計上しない）
    });

    test('未確定カード（メルカード）は他カードが確定しても消えない', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.payments = [
        // 三井OLIVEだけ6月分が7月に銀行確定
        Payment(id: 'b', cardName: '三井OLIVE', amount: 44238, paymentDate: DateTime(2026, 7, 27), source: PaymentSource.bank),
        // メルカードは未確定（利用通知のみ）→ 消えずに計上され続ける
        Payment(id: 'u', cardName: 'メルカード', amount: 1800, paymentDate: DateTime(2026, 6, 5), source: PaymentSource.usage),
      ];
      final jun = {for (final e in app.expenseBreakdownOf(DateTime(2026, 6))) e.label: e.amount};
      expect(jun['三井OLIVE'], 44238);
      expect(jun['メルカード'], 1800); // 未確定でも残る
      // 明細も合計と一致
      final detail = app.expenseDetailOf(DateTime(2026, 6), 'メルカード');
      expect(detail.fold<int>(0, (s, e) => s + e.amount), 1800);
    });

    test('AmazonマスターはOLIVEの銀行確定に含まれるので別計上しない', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.payments = [
        Payment(id: 'b', cardName: '三井OLIVE', amount: 44238, paymentDate: DateTime(2026, 7, 27), source: PaymentSource.bank),
        Payment(id: 'a', cardName: 'Amazonマスター', amount: 2000, paymentDate: DateTime(2026, 6, 3), source: PaymentSource.usage),
      ];
      final jun = {for (final e in app.expenseBreakdownOf(DateTime(2026, 6))) e.label: e.amount};
      expect(jun['三井OLIVE'], 44238);
      expect(jun['Amazonマスター'], isNull); // OLIVE確定に含まれるので消える
    });

    test('OLIVE未確定ならAmazonマスターは今まで通り計上される', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.payments = [
        // 楽天だけ確定、OLIVEは未確定
        Payment(id: 'b', cardName: '楽天カード', amount: 5000, paymentDate: DateTime(2026, 7, 29), source: PaymentSource.bank),
        Payment(id: 'a', cardName: 'Amazonマスター', amount: 2000, paymentDate: DateTime(2026, 6, 3), source: PaymentSource.usage),
      ];
      final jun = {for (final e in app.expenseBreakdownOf(DateTime(2026, 6))) e.label: e.amount};
      expect(jun['Amazonマスター'], 2000);
    });

    test('銀行確定が無いカードの手動追加は上乗せする', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.payments = [
        // 三井だけ銀行確定あり
        Payment(id: 'b', cardName: '三井OLIVE', amount: 42446, paymentDate: DateTime(2026, 5, 27), source: PaymentSource.bank),
        // 楽天は銀行確定が無い→手動分は計上される
        Payment(id: 'm', cardName: '楽天カード', amount: 1980, paymentDate: DateTime(2026, 4, 15), source: PaymentSource.manual),
      ];
      final apr = {for (final e in app.expenseBreakdownOf(DateTime(2026, 4))) e.label: e.amount};
      expect(apr['三井OLIVE'], 42446);
      expect(apr['楽天カード'], 1980);
    });

    test('楽天カードの引き落としは翌月27日（1ヶ月後）', () {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      // 4月利用 → 5月27日引き落とし（銀行確定データと一致）
      final d = app.debitDateFor('楽天カード', DateTime(2026, 4, 15));
      expect(d.year, 2026);
      expect(d.month, 5); // 翌々月(6月)ではなく翌月(5月)
    });

    test('分割の残り回数: 楽天4月購入5回払い→7月末で残り2回', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      final inst = Installment(
        id: 'r1', name: '楽天の分割', totalAmount: 37172, monthlyAmount: 7434,
        installmentCount: 5, remainingMonths: 5,
        cardName: '楽天カード', startDate: DateTime(2026, 4, 10),
      );
      // 引落: 5/27, 6/27, 7/27, 8/27, 9/27 → 2026-07-31時点で5,6,7が支払済み=残り2
      // （テスト実行日に依存しないよう、経過回数の算出ロジックを直接検証）
      var paid = 0;
      final now = DateTime(2026, 7, 31);
      for (var k = 0; k < inst.installmentCount; k++) {
        if (!app.debitDateForNth('楽天カード', inst.startDate!, k).isAfter(now)) paid++;
      }
      expect(inst.installmentCount - paid, 2);
    });

    test('分割は利用開始月(startDate)を1回目として集計', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.addInstallment(
        name: 'テスト分割',
        totalAmount: 30000,
        count: 3,
        cardName: '楽天カード',
        interestRate: 0,
        startDate: DateTime(2026, 4, 10),
      );
      // 4月(利用月)から3か月＝4,5,6月がアクティブ。3月は0。
      expect(app.installmentTotalOf(DateTime(2026, 3)), 0);
      expect(app.installmentTotalOf(DateTime(2026, 4)), greaterThan(0));
      expect(app.installmentTotalOf(DateTime(2026, 6)), greaterThan(0));
      expect(app.installmentTotalOf(DateTime(2026, 7)), 0);
    });
  });

  group('支出の明細（詳細）', () {
    test('expenseDetailOf の合計は expenseBreakdownOf のカード額と一致（非確定月）', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.payments = [
        Payment(id: '1', cardName: '三井OLIVE', amount: 1300, paymentDate: DateTime(2026, 6, 1), source: PaymentSource.usage, note: 'APPLE.COM/BILL'),
        Payment(id: '2', cardName: '三井OLIVE', amount: 612, paymentDate: DateTime(2026, 6, 2), source: PaymentSource.usage, note: 'ローソン'),
        Payment(id: '3', cardName: '楽天カード', amount: 500, paymentDate: DateTime(2026, 6, 3), source: PaymentSource.usage),
      ];
      final bd = {for (final e in app.expenseBreakdownOf(DateTime(2026, 6))) e.label: e.amount};
      final detail = app.expenseDetailOf(DateTime(2026, 6), '三井OLIVE');
      final detailSum = detail.fold<int>(0, (s, e) => s + e.amount);
      expect(detail.length, 2);
      expect(detailSum, bd['三井OLIVE']); // 1300+612
    });

    test('確定月の明細は銀行確定のみ（手動は確定額に含まれるので出さない）', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.payments = [
        Payment(id: 'b', cardName: '三井OLIVE', amount: 42446, paymentDate: DateTime(2026, 5, 27), source: PaymentSource.bank),
        Payment(id: 'm', cardName: '三井OLIVE', amount: 1980, paymentDate: DateTime(2026, 4, 15), source: PaymentSource.manual, note: '補正'),
      ];
      final detail = app.expenseDetailOf(DateTime(2026, 4), '三井OLIVE');
      final sum = detail.fold<int>(0, (s, e) => s + e.amount);
      // 明細合計＝円グラフのカード額と一致する
      final apr = {for (final e in app.expenseBreakdownOf(DateTime(2026, 4))) e.label: e.amount};
      expect(sum, 42446);
      expect(sum, apr['三井OLIVE']);
    });
  });

  group('Appleカレンダー連携（データ層）', () {
    test('ShiftData/EventData の calendarEventId が JSON 往復で保持', () {
      final s = ShiftData(
        workplace: 'A',
        hourlyWage: 1000,
        start: DateTime(2026, 6, 18, 9, 0),
        end: DateTime(2026, 6, 18, 17, 0),
        calendarEventId: 'cal-123',
      );
      expect(ShiftData.fromJson(s.toJson()).calendarEventId, 'cal-123');

      final e = EventData(id: 'e1', title: 'x', start: DateTime(2026, 6, 18), calendarEventId: 'cal-999');
      expect(EventData.fromJson(e.toJson()).calendarEventId, 'cal-999');
    });

    test('calendarAutoSync は永続化される（hook無しならtrueを返す）', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      // コンストラクタの初回loadData(非同期)が確定するのを待つ（本番は起動時1回）
      await Future.delayed(const Duration(milliseconds: 50));
      expect(app.calendarAutoSync, isFalse);
      final ok = await app.setCalendarAutoSync(true); // calendarSync=null
      expect(ok, isTrue);
      expect(app.calendarAutoSync, isTrue);
    });
  });

  group('予定の詳細・シフト履歴', () {
    test('EventData JSON 往復（新フィールド保持＆旧データ吸収）', () {
      final e = EventData(
        id: 'ev1',
        title: '会議',
        location: '渋谷',
        url: 'https://example.com',
        memo: 'メモ',
        colorValue: 0xFF2196F3,
        allDay: false,
        start: DateTime(2026, 6, 16, 9, 0),
        end: DateTime(2026, 6, 16, 10, 0),
        notifyMinutesBefore: 30,
      );
      final back = EventData.fromJson(e.toJson());
      expect(back.title, '会議');
      expect(back.location, '渋谷');
      expect(back.colorValue, 0xFF2196F3);
      expect(back.start, DateTime(2026, 6, 16, 9, 0));
      expect(back.notifyMinutesBefore, 30);

      // 旧データ（title のみ）も読める
      final old = EventData.fromJson({'title': '旧予定'});
      expect(old.title, '旧予定');
      expect(old.start, isNull);
    });

    test('TodoData: ラベル・通知日・時刻指定がJSON往復で保持', () {
      final t = TodoData(
        id: 't1',
        title: '課題提出',
        deadline: DateTime(2026, 8, 10, 17, 30),
        label: '学校',
        reminderDaysBefore: [7, 3, 1, 0],
        hasTime: true,
      );
      final back = TodoData.fromJson(t.toJson());
      expect(back.label, '学校');
      expect(back.reminderDaysBefore, [7, 3, 1, 0]);
      expect(back.hasTime, true);
      expect(back.deadline, DateTime(2026, 8, 10, 17, 30));
      // 旧データ（新フィールド無し）は既定値を吸収
      final old = TodoData.fromJson({'id': 'o', 'title': '旧', 'deadline': '2026-08-01T00:00:00.000'});
      expect(old.label, '');
      expect(old.reminderDaysBefore, [1, 0]);
      expect(old.hasTime, false);
    });

    test('upsertEvent は開始日のバケットへ入れ、日付変更で移動', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      final e = EventData(id: 'e1', title: 'A', start: DateTime(2026, 6, 16, 9, 0));
      app.upsertEvent(e);
      expect(app.events['2026-06-16']?.length, 1);
      // 日付を変更して更新
      final moved = EventData(id: 'e1', title: 'A', start: DateTime(2026, 6, 20, 9, 0));
      app.upsertEvent(moved);
      expect(app.events.containsKey('2026-06-16'), isFalse);
      expect(app.events['2026-06-20']?.length, 1);
    });

    test('recentShiftTemplates は新しい順・重複なし', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      ShiftData mk(int d, int sh, int eh) => ShiftData(
            workplace: 'A',
            hourlyWage: 1000,
            start: DateTime(2026, 6, d, sh, 0),
            end: DateTime(2026, 6, d, eh, 0),
            breakMinutes: 0,
          );
      app.addShift(DateTime(2026, 6, 1), mk(1, 9, 17));
      app.addShift(DateTime(2026, 6, 2), mk(2, 9, 17)); // 同パターン（重複）
      app.addShift(DateTime(2026, 6, 3), mk(3, 17, 22)); // 別パターン
      final t = app.recentShiftTemplates();
      // 重複は1つに、別パターンと合わせて2件。新しい順（6/3が先頭）
      expect(t.length, 2);
      expect(t.first.startHour, 17);
    });
  });

  group('給料日タイミング', () {
    test('incomeArrivingIn は給料日offsetぶん前の労働月の手取り', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      // 給料日: 翌月(offset=1) の勤務先
      app.addWorkplace(Workplace(
          id: 'w1', name: 'A', paydayMonthOffset: 1, wagePeriods: [WagePeriod(hourlyWage: 1000)]));
      // 5月に7000円ぶん働く
      app.addShift(
        DateTime(2026, 5, 10),
        ShiftData(
            workplace: 'A',
            workplaceId: 'w1',
            hourlyWage: 1000,
            start: DateTime(2026, 5, 10, 9, 0),
            end: DateTime(2026, 5, 10, 17, 0),
            breakMinutes: 60),
      );
      // 5月労働分は6月に入金される
      expect(app.incomeArrivingIn(DateTime(2026, 6)), 7000);
      expect(app.incomeArrivingIn(DateTime(2026, 5)), 0); // 5月にはまだ入金されない
    });

    test('実給料があれば見込みより優先して入金計上', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.addWorkplace(Workplace(id: 'w1', name: 'A', paydayMonthOffset: 1));
      app.setActualSalary(DateTime(2026, 5), 88000);
      expect(app.incomeArrivingIn(DateTime(2026, 6)), 88000);
    });

    test('#4 給料日の金額は勤務先ごとの手取り（月総額ではない）', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.addWorkplace(Workplace(id: 'a', name: 'A', paydayMonthOffset: 1, paydayDay: 25, wagePeriods: [WagePeriod(hourlyWage: 1000)]));
      app.addWorkplace(Workplace(id: 'b', name: 'B', paydayMonthOffset: 1, paydayDay: 15, wagePeriods: [WagePeriod(hourlyWage: 2000)]));
      // Aで7000、Bで14000ぶん5月に働く
      app.addShift(DateTime(2026, 5, 10), ShiftData(workplace: 'A', workplaceId: 'a', hourlyWage: 1000, start: DateTime(2026, 5, 10, 9), end: DateTime(2026, 5, 10, 17), breakMinutes: 60));
      app.addShift(DateTime(2026, 5, 11), ShiftData(workplace: 'B', workplaceId: 'b', hourlyWage: 2000, start: DateTime(2026, 5, 11, 9), end: DateTime(2026, 5, 11, 17), breakMinutes: 60));
      final pds = app.paydaysInMonth(DateTime(2026, 5)); // 6月に入金
      final a = pds.firstWhere((e) => e.workplace.id == 'a');
      final b = pds.firstWhere((e) => e.workplace.id == 'b');
      expect(a.amount, 7000);   // Aだけ
      expect(b.amount, 14000);  // Bだけ（月総額21000ではない）
    });

    test('#3 実給料は勤務先別に入力でき、#2 実年収はその合計', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.addWorkplace(Workplace(id: 'a', name: 'A', wagePeriods: [WagePeriod(hourlyWage: 1000)]));
      app.addShift(DateTime(2026, 5, 10), ShiftData(workplace: 'A', workplaceId: 'a', hourlyWage: 1000, start: DateTime(2026, 5, 10, 9), end: DateTime(2026, 5, 10, 17), breakMinutes: 60));
      app.setActualSalaryOfWorkplace(DateTime(2026, 5), 'a', 9000);
      expect(app.actualSalaryOfWorkplace(DateTime(2026, 5), 'a'), 9000);
      expect(app.takeHomeOfWorkplace(DateTime(2026, 5), 'a'), 9000); // 実給料優先
      expect(app.actualSalaryOfYear(2026), 9000);
      expect(app.hasActualSalaryInYear(2026), isTrue);
    });
  });

  group('支出ソース（利用月＝引落月−1）', () {
    test('過去月の支出＝翌月に引き落とされる銀行確定（1ヶ月戻して計上）', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.payments = [
        // 4月利用分は 5/27 に引き落とし（事前お知らせ＝bank）
        Payment(id: '1', cardName: '楽天カード', amount: 31002, paymentDate: DateTime(2026, 5, 27), source: PaymentSource.bank),
        Payment(id: '2', cardName: 'PayPayカード', amount: 3000, paymentDate: DateTime(2026, 5, 27), source: PaymentSource.bank),
        // 4月の利用通知（同じ買い物の利用日ベース）→ 銀行確定があるので無視されるべき
        Payment(id: '3', cardName: '楽天カード', amount: 99999, paymentDate: DateTime(2026, 4, 10), source: PaymentSource.usage),
      ];

      final apr = {for (final e in app.expenseBreakdownOf(DateTime(2026, 4))) e.label: e.amount};
      expect(apr['楽天カード'], 31002); // 5月引落＝4月の支出
      expect(apr['PayPayカード'], 3000);
      // 利用通知(99999)は銀行確定があるので二重計上しない
      expect(apr['楽天カード'], isNot(99999 + 31002));
    });

    test('銀行確定が無い先月・今月は その月の支払い管理（利用通知等）で代替', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.payments = [
        Payment(id: '1', cardName: '楽天カード', amount: 4000, paymentDate: DateTime(2026, 6, 10), source: PaymentSource.usage),
        Payment(id: '2', cardName: '三井OLIVE', amount: 2000, paymentDate: DateTime(2026, 6, 20), source: PaymentSource.billing, paid: true),
      ];
      // 6月の翌月(7月)に銀行確定が無いので、6月の支払い管理で代替
      final jun = {for (final e in app.expenseBreakdownOf(DateTime(2026, 6))) e.label: e.amount};
      expect(jun['楽天カード'], 4000);
      expect(jun['三井OLIVE'], 2000); // paid含む
    });

    test('分割払い: 銀行確定済みの月は足さない・未確定月はカードの請求に含める', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      // 三井OLIVE分割（startDate=5月 → 1回目引落 debitDateFor(三井,5月)=6月、6〜11月がアクティブ）
      app.addInstallment(
        name: '三井OLIVE 分割',
        totalAmount: 60000,
        count: 6,
        cardName: '三井OLIVE',
        interestRate: 0,
        startDate: DateTime(2026, 5, 1),
      );
      // 6月利用分は 7月に銀行引き落とし（分割の月額も含む）→ 6月は確定済み
      app.payments = [
        Payment(id: 'b', cardName: '三井OLIVE', amount: 42446, paymentDate: DateTime(2026, 7, 27), source: PaymentSource.bank),
      ];

      // 6月は銀行確定済み → 確定額に分割が含まれるので、カードに足さない
      expect(app.installmentTotalOf(DateTime(2026, 6)), greaterThan(0));
      expect(app.isExpenseConfirmedByBank(DateTime(2026, 6)), isTrue);
      final jun = app.expenseBreakdownOf(DateTime(2026, 6));
      expect(jun.map((e) => e.label).contains('分割払い'), isFalse);
      expect(jun.firstWhere((e) => e.label == '三井OLIVE').amount, 42446);
      expect(app.installmentFoldedInto(DateTime(2026, 6)), 0);

      // 8月は銀行確定が無い → 分割の月額を三井OLIVEの請求に足し込む
      // （「分割払い」という独立した引き落としは存在しないため）
      expect(app.installmentTotalOf(DateTime(2026, 8)), greaterThan(0));
      expect(app.isExpenseConfirmedByBank(DateTime(2026, 8)), isFalse);
      final aug = app.expenseBreakdownOf(DateTime(2026, 8));
      expect(aug.map((e) => e.label).contains('分割払い'), isFalse);
      final monthly = app.installmentTotalOf(DateTime(2026, 8));
      expect(aug.firstWhere((e) => e.label == '三井OLIVE').amount, monthly);
      expect(app.installmentFoldedInto(DateTime(2026, 8)), monthly);
    });
  });

  group('残高予測（前回方式）と現在残高のデビット調整', () {
    test('drawnInMonth は前月の支出詳細を合計し、デビット/Vポイント/ATMを除外', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      // 6月利用分（7月引落の銀行確定が無いので6月の支払い管理で代替＝6月支出）
      app.payments = [
        Payment(id: '1', cardName: '三井OLIVE', amount: 11307, paymentDate: DateTime(2026, 6, 1), source: PaymentSource.usage),
        Payment(id: '2', cardName: '楽天カード', amount: 1550, paymentDate: DateTime(2026, 6, 2), source: PaymentSource.usage),
        Payment(id: '3', cardName: '三井OLIVE（Vポイントペイ）', amount: 491, paymentDate: DateTime(2026, 6, 3), source: PaymentSource.usage),
        Payment(id: '4', cardName: '三井OLIVE（デビット）', amount: 350, paymentDate: DateTime(2026, 6, 4), source: PaymentSource.usage),
      ];
      app.subscriptions = [Subscription(id: 's', title: 'Netflix', amount: 14300, payDay: 1)];
      app.withdrawals = [Withdrawal(id: 'w', amount: 9999, date: DateTime(2026, 6, 5))];
      // 7月の引き落とし＝6月支出（三井OLIVE 11307 + 楽天 1550 + 定期 14300）。デビット/Vポイント/ATM除外
      expect(app.drawnInMonth(DateTime(2026, 7)), 11307 + 1550 + 14300);
      final labels = app.drawBreakdownOf(DateTime(2026, 7)).map((e) => e.label).toList();
      expect(labels.contains('三井OLIVE（デビット）'), isFalse);
      expect(labels.contains('三井OLIVE（Vポイントペイ）'), isFalse);
      expect(labels.contains('ATM'), isFalse);
      expect(labels.contains('定期支払い'), isTrue);
    });

    test('給料・引き落としは編集日より後だけ予想に反映（二重計上防止）', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      // 勤務先A: 給料日=毎月25日（当月offset0）
      app.addWorkplace(Workplace(id: 'a', name: 'A', paydayMonthOffset: 0, paydayDay: 25, wagePeriods: [WagePeriod(hourlyWage: 1000)]));
      // 6月に7000ぶん働く（→6月25日に入金）
      app.addShift(DateTime(2026, 6, 10), ShiftData(workplace: 'A', workplaceId: 'a', hourlyWage: 1000, start: DateTime(2026, 6, 10, 9), end: DateTime(2026, 6, 10, 17), breakMinutes: 60));

      // ケース1: 給料日(25)より前の20日に残高編集 → 6月給料はまだ→予想に足す
      app.balanceUpdatedAt = DateTime(2026, 6, 20);
      expect(app.incomeForecastIn(DateTime(2026, 6)), 7000);

      // ケース2: 給料日後の26日に残高編集（給料込みの残高を入力）→ 二重に足さない
      app.balanceUpdatedAt = DateTime(2026, 6, 26);
      expect(app.incomeForecastIn(DateTime(2026, 6)), 0);
    });

    test('引き落としも編集日より後だけ予想で引く', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      // 三井OLIVE(引落26日)の6月利用＝7月26日引き落とし
      app.payments = [
        Payment(id: '1', cardName: '三井OLIVE', amount: 10000, paymentDate: DateTime(2026, 6, 1), source: PaymentSource.usage),
      ];
      // 7月20日に残高編集 → 26日の引き落としは後→引く
      app.balanceUpdatedAt = DateTime(2026, 7, 20);
      expect(app.drawnInMonth(DateTime(2026, 7)), 10000);
      // 7月27日に残高編集（引き落とし済みの残高）→ 引かない
      app.balanceUpdatedAt = DateTime(2026, 7, 27);
      expect(app.drawnInMonth(DateTime(2026, 7)), 0);
    });

    test('デビットは編集後の利用のみ現在残高から引く（二重計上防止 #5#6）', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.updateBalance(100000);
      app.balanceUpdatedAt = DateTime(2026, 6, 12);
      app.payments = [
        // 11日のデビット＝編集前→既に残高に含まれるので引かない
        Payment(id: 'd1', cardName: '三井OLIVE（デビット）', amount: 1000, paymentDate: DateTime(2026, 6, 11), source: PaymentSource.usage),
        // 13日のデビット＝編集後→引く
        Payment(id: 'd2', cardName: '三井OLIVE（デビット）', amount: 2000, paymentDate: DateTime(2026, 6, 13), source: PaymentSource.usage),
      ];
      expect(app.debitsAfterSnapshot(), 2000);
      expect(app.effectiveBalance, 100000 - 2000);
    });
  });

  group('給料日の土日祝調整', () {
    test('前営業日/翌営業日/調整なし を勤務先ごとに切り替えられる', () {
      // 2026/7/25 は土曜日
      expect(DateTime(2026, 7, 25).weekday, DateTime.saturday);
      final before = Workplace(id: 'a', name: 'A', paydayDay: 25, paydayAdjust: PaydayAdjust.before);
      final after = Workplace(id: 'b', name: 'B', paydayDay: 25, paydayAdjust: PaydayAdjust.after);
      final none = Workplace(id: 'c', name: 'C', paydayDay: 25, paydayAdjust: PaydayAdjust.none);
      final m = DateTime(2026, 7);
      expect(before.paydayIn(m), DateTime(2026, 7, 24)); // 金曜へ前倒し
      expect(after.paydayIn(m), DateTime(2026, 7, 27)); // 月曜へ後ろ倒し
      expect(none.paydayIn(m), DateTime(2026, 7, 25)); // そのまま
    });

    test('祝日も休みとして扱う（2026/5/3 憲法記念日は日曜→振替5/6まで連休）', () {
      // 5/3(日) 5/4(みどり) 5/5(こども) 5/6(振替) → 前営業日は5/1(金)
      final w = Workplace(id: 'a', name: 'A', paydayDay: 5, paydayAdjust: PaydayAdjust.before);
      expect(w.paydayIn(DateTime(2026, 5)), DateTime(2026, 5, 1));
      final w2 = Workplace(id: 'b', name: 'B', paydayDay: 5, paydayAdjust: PaydayAdjust.after);
      expect(w2.paydayIn(DateTime(2026, 5)), DateTime(2026, 5, 7)); // 木曜
    });

    test('月末より大きい給料日は月末に丸める', () {
      final w = Workplace(id: 'a', name: 'A', paydayDay: 31, paydayAdjust: PaydayAdjust.none);
      expect(w.paydayIn(DateTime(2026, 2)), DateTime(2026, 2, 28));
    });

    test('カレンダーの給料日にも調整が反映される', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.addWorkplace(Workplace(
          id: 'g', name: 'グローバル', paydayMonthOffset: 1, paydayDay: 25,
          paydayAdjust: PaydayAdjust.after, wagePeriods: [WagePeriod(hourlyWage: 1000)]));
      app.addShift(DateTime(2026, 6, 10), ShiftData(
          workplace: 'グローバル', workplaceId: 'g', hourlyWage: 1000,
          start: DateTime(2026, 6, 10, 9), end: DateTime(2026, 6, 10, 17), breakMinutes: 60));
      // 6月労働 → 7/25(土)が給料日 → 後ろ倒しで 7/27(月)
      final pds = app.paydaysInMonth(DateTime(2026, 6));
      expect(pds.first.date, DateTime(2026, 7, 27));
    });
  });

  group('口座からの引き落とし', () {
    test('銀行確定の引き落としを口座残高から引ける', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.updateBalance(120000);
      // 「昨日引き落とし・一昨日に残高を記録」（実行日に依存させない）
      final yst = DateTime.now().subtract(const Duration(days: 1));
      app.balanceUpdatedAt = DateTime.now().subtract(const Duration(days: 2));
      app.payments = [
        Payment(id: 'b', cardName: '三井OLIVE', amount: 44238,
            paymentDate: DateTime(yst.year, yst.month, yst.day),
            source: PaymentSource.bank, sourceId: 'mail-b'),
      ];
      final pending = app.pendingDraws;
      expect(pending.length, 1);
      expect(pending.first.amount, 44238);

      app.applyDraw(pending.first.id, 44238);
      expect(app.currentBalance, 120000 - 44238);
      expect(app.pendingDraws, isEmpty); // 二度は聞かれない
    });

    test('入金を反映して残高編集日が今日になっても、過去の引き落としは消えない', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      final yst = DateTime.now().subtract(const Duration(days: 1));
      app.payments = [
        Payment(id: 'b', cardName: '三井OLIVE', amount: 44238,
            paymentDate: DateTime(yst.year, yst.month, yst.day),
            source: PaymentSource.bank, sourceId: 'mail-b'),
      ];
      // 給料入金を反映 → balanceUpdatedAt が「今」になる
      app.addDeposit(91009);
      // それでも昨日の引き落としは未反映として残る（以前はここで消えていた）
      expect(app.pendingDraws.length, 1);
      expect(app.pendingDraws.first.amount, 44238);
    });

    test('すべてスキップで未反映をまとめて消せる', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      final yst = DateTime.now().subtract(const Duration(days: 1));
      app.payments = [
        Payment(id: 'b1', cardName: '三井OLIVE', amount: 1000,
            paymentDate: DateTime(yst.year, yst.month, yst.day),
            source: PaymentSource.bank, sourceId: 'm1'),
        Payment(id: 'b2', cardName: '楽天カード', amount: 2000,
            paymentDate: DateTime(yst.year, yst.month, yst.day),
            source: PaymentSource.bank, sourceId: 'm2'),
      ];
      expect(app.pendingDraws.length, 2);
      app.skipAllDraws();
      expect(app.pendingDraws, isEmpty);
    });

    test('引き落とし日が土日祝なら翌営業日にずれる（全カード共通）', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.setCardPaymentDay('楽天カード', 27);
      // 2026/6/27 は土曜 → 翌営業日の6/29(月)
      expect(DateTime(2026, 6, 27).weekday, DateTime.saturday);
      expect(app.cardDrawDateOf('楽天カード', DateTime(2026, 6)), DateTime(2026, 6, 29));

      // 平日ならそのまま（2026/7/27 は月曜）
      expect(DateTime(2026, 7, 27).weekday, DateTime.monday);
      expect(app.cardDrawDateOf('楽天カード', DateTime(2026, 7)), DateTime(2026, 7, 27));

      // 祝日も避ける: 2026/5/3〜5/6 は連休 → 3日設定なら5/7(木)
      app.setCardPaymentDay('テストカード', 3);
      expect(app.cardDrawDateOf('テストカード', DateTime(2026, 5)), DateTime(2026, 5, 7));
    });

    test('月末より大きい引き落とし日は月末に丸めてから営業日調整', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.setCardPaymentDay('テストカード', 31);
      // 2026年2月は28日まで → 2/28(土) → 翌営業日 3/2(月)
      expect(DateTime(2026, 2, 28).weekday, DateTime.saturday);
      expect(app.cardDrawDateOf('テストカード', DateTime(2026, 2)), DateTime(2026, 3, 2));
    });

    test('事前お知らせが無くても、設定した引き落とし日を過ぎたら知らせる（見込み額）', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.setCardPaymentDay('楽天カード', 27);
      // 先月の楽天利用ぶんが、今月27日に引き落とされる
      final now = DateTime.now();
      final prev = DateTime(now.year, now.month - 1);
      app.payments = [
        Payment(id: 'u', cardName: '楽天カード', amount: 5000,
            paymentDate: DateTime(prev.year, prev.month, 5), source: PaymentSource.usage),
      ];
      final drawDate = DateTime(now.year, now.month, 27);
      final pending = app.pendingDraws.where((d) => d.label.contains('楽天')).toList();
      if (!drawDate.isAfter(DateTime(now.year, now.month, now.day))) {
        // 27日を過ぎていれば「（予定）」として出る
        expect(pending.length, 1);
        expect(pending.first.amount, 5000);
        expect(pending.first.label.contains('予定'), isTrue);
      }
    });

    test('事前お知らせメールがあるカードは見込みを二重に出さない', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.setCardPaymentDay('楽天カード', 27);
      final now = DateTime.now();
      final prev = DateTime(now.year, now.month - 1);
      final drawDate = DateTime(now.year, now.month, 27);
      app.payments = [
        Payment(id: 'u', cardName: '楽天カード', amount: 5000,
            paymentDate: DateTime(prev.year, prev.month, 5), source: PaymentSource.usage),
        // 同じ月の事前お知らせ（こちらが正）
        Payment(id: 'b', cardName: '楽天カード', amount: 5200,
            paymentDate: drawDate, source: PaymentSource.bank, sourceId: 'mail-r'),
      ];
      final rakuten = app.pendingDraws.where((d) => d.label.contains('楽天')).toList();
      if (!drawDate.isAfter(DateTime(now.year, now.month, now.day))) {
        expect(rakuten.length, 1); // 1件だけ
        expect(rakuten.first.amount, 5200); // メールの金額が優先
        expect(rakuten.first.label.contains('予定'), isFalse);
      }
    });

    test('まだ引き落とし日が来ていないものは出ない', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.updateBalance(100000);
      final future = DateTime.now().add(const Duration(days: 10));
      app.payments = [
        Payment(id: 'b', cardName: '三井OLIVE', amount: 1000,
            paymentDate: future, source: PaymentSource.bank, sourceId: 'mail-f'),
      ];
      expect(app.pendingDraws, isEmpty);
    });

    test('スキップした引き落としは二度と出ない', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.updateBalance(100000);
      // 実行日に依存しないよう「昨日引き落とし・一昨日に残高記録」で作る
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      app.balanceUpdatedAt = DateTime.now().subtract(const Duration(days: 2));
      app.payments = [
        Payment(id: 'b', cardName: '楽天カード', amount: 5000,
            paymentDate: DateTime(yesterday.year, yesterday.month, yesterday.day),
            source: PaymentSource.bank, sourceId: 'mail-r'),
      ];
      final id = app.pendingDraws.first.id;
      app.skipDraw(id);
      expect(app.pendingDraws, isEmpty);
      expect(app.currentBalance, 100000); // 残高は変わらない
    });

    test('口座振替の定期支払いは引き落とし一覧に出る／カード払いは出ない', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.updateBalance(100000);
      app.balanceUpdatedAt = DateTime(DateTime.now().year, DateTime.now().month, 1)
          .subtract(const Duration(days: 1));
      app.subscriptions = [
        Subscription(id: 's1', title: '車代', amount: 10000, payDay: 1), // 口座振替
        Subscription(id: 's2', title: 'prime会員', amount: 300, payDay: 1, method: '三井OLIVE'),
      ];
      final labels = app.pendingDraws.map((d) => d.label).toList();
      expect(labels.contains('車代'), isTrue);
      expect(labels.contains('prime会員'), isFalse); // カード払いは口座から別途引かない
    });

    test('手動払いの定期は一覧に出る／記録した月はもう出ない', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.updateBalance(50000);
      app.subscriptions = [
        Subscription(id: 's1', title: '車代', amount: 10000, payDay: 1,
            method: kManualPayMethod),
      ];
      final pending = app.pendingDraws;
      expect(pending.length, greaterThan(0));
      expect(pending.first.label.contains('手動'), isTrue);

      // 払ったので記録 → 残高が減り、その月はもう出ない
      final id = pending.first.id;
      final before = app.currentBalance;
      app.applyDraw(id, 10000);
      expect(app.currentBalance, before - 10000);
      expect(app.pendingDraws.any((d) => d.id == id), isFalse);
    });

    test('手動払いはカード請求に含まれないので銀行確定月でも支出に計上する', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.subscriptions = [
        Subscription(id: 's1', title: '車代', amount: 10000, payDay: 1,
            method: kManualPayMethod),
        Subscription(id: 's2', title: 'prime会員', amount: 300, payDay: 1,
            method: '三井OLIVE'),
      ];
      app.payments = [
        Payment(id: 'b', cardName: '三井OLIVE', amount: 44238,
            paymentDate: DateTime(2026, 7, 26), source: PaymentSource.bank),
      ];
      // 確定月でも手動払いは残る（カード請求に含まれないため）
      expect(app.subscriptionTotalOf(DateTime(2026, 6)), 10000);
    });

    test('カード払いの定期は銀行確定月では支出に二重計上しない', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.subscriptions = [
        Subscription(id: 's1', title: '車代', amount: 10000, payDay: 1), // 口座振替
        Subscription(id: 's2', title: 'prime会員', amount: 300, payDay: 1, method: '三井OLIVE'),
      ];
      // 6月分が7月に銀行確定 → prime会員はカード請求に含まれるので除く
      app.payments = [
        Payment(id: 'b', cardName: '三井OLIVE', amount: 44238,
            paymentDate: DateTime(2026, 7, 26), source: PaymentSource.bank),
      ];
      expect(app.subscriptionTotalOf(DateTime(2026, 6)), 10000); // 車代のみ
      // 確定していない月は両方（カード請求にまだ現れていないため）
      expect(app.subscriptionTotalOf(DateTime(2026, 9)), 10300);
    });
  });

  group('口座への入金', () {
    test('入金は現在の残高に加算され、編集日時も更新される（二重計上防止）', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.updateBalance(10000);
      app.addDeposit(50000);
      expect(app.currentBalance, 60000);
      expect(app.balanceUpdatedAt, isNotNull);
    });

    test('バイトを選ぶとその労働月の実給料としても記録される', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      // 給料日=翌月25日の勤務先
      app.addWorkplace(Workplace(id: 'a', name: 'A', paydayMonthOffset: 1, paydayDay: 25));
      // 7/25の入金 → 6月分の労働の給料
      app.addDeposit(73837, workplaceId: 'a', date: DateTime(2026, 7, 25));
      expect(app.currentBalance, 73837);
      expect(app.actualSalaryOfWorkplace(DateTime(2026, 6), 'a'), 73837);
    });

    test('入金日が給料日に近い勤務先を候補として返す（土日ズレを許容）', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.addWorkplace(Workplace(id: 'a', name: 'A', paydayDay: 25));
      app.addWorkplace(Workplace(id: 'b', name: 'B', paydayDay: 10));
      // 7/27の入金 → 25日払いのAが候補（27は10日から遠い）
      final near = app.workplacesWithPaydayNear(DateTime(2026, 7, 27));
      expect(near.map((w) => w.id).toList(), ['a']);
      // 10日払いのBは10日前後で候補になる
      expect(app.workplacesWithPaydayNear(DateTime(2026, 7, 11)).map((w) => w.id).toList(), ['b']);
    });

    test('入金通知は重複せず、スキップ/処理済みは再表示しない', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      final n = (sourceId: 'mail-1', date: DateTime(2026, 7, 25));
      expect(app.addDepositNotices([n]), 1);
      expect(app.addDepositNotices([n]), 0); // 既にキューにある
      expect(app.pendingDeposits.length, 1);

      app.skipDepositNotice('mail-1');
      expect(app.pendingDeposits, isEmpty);
      expect(app.addDepositNotices([n]), 0); // 処理済みは復活しない
    });

    test('通知に金額を入力すると残高へ反映され、キューから消える', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.updateBalance(5000);
      app.addDepositNotices([(sourceId: 'mail-2', date: DateTime(2026, 7, 25))]);
      app.applyDepositNotice('mail-2', 91009);
      expect(app.currentBalance, 5000 + 91009);
      expect(app.pendingDeposits, isEmpty);
      // 同じメールをもう一度取り込んでも再表示しない
      expect(app.addDepositNotices([(sourceId: 'mail-2', date: DateTime(2026, 7, 25))]), 0);
    });
  });

  group('入出金の履歴・入金済みバイトの除外', () {
    test('入金と引き落としが履歴に残る', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.updateBalance(10000);
      app.addDeposit(50000);
      app.subtractFromBalance(3000, label: 'テスト引き落とし');
      expect(app.balanceHistory.length, 2);
      expect(app.balanceHistory.first.kind, BalanceEntryKind.draw); // 新しい順
      expect(app.balanceHistory.first.amount, 3000);
      expect(app.balanceHistory.last.kind, BalanceEntryKind.deposit);
      expect(app.balanceHistory.last.balanceAfter, 60000);
    });

    test('履歴を取り消すと残高が戻り、通知も未処理に戻る', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.updateBalance(10000);
      app.addDepositNotices([(sourceId: 'mail-1', date: DateTime(2026, 9, 25))]);
      app.applyDepositNotice('mail-1', 50000);
      expect(app.currentBalance, 60000);

      app.undoBalanceEntry(app.balanceHistory.first.id);
      expect(app.currentBalance, 10000); // 元に戻る
      expect(app.balanceHistory, isEmpty);
      expect(app.handledDepositIds.contains('mail-1'), isFalse); // 入力し直せる
    });

    test('入金済みのバイトは次の入金の選択肢に出ない', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.addWorkplace(Workplace(id: 'a', name: 'A', paydayDay: 25));
      app.addWorkplace(Workplace(id: 'b', name: 'B', paydayDay: 10));
      final pay = DateTime(2026, 9, 25);

      // 最初は両方出る（移行の締めは2026-08なので9月は対象）
      expect(app.workplacesAwaitingSalary(pay).length, 2);

      // Aの給料を受け取った → 次の入金では A は出ない
      app.addDeposit(70000, workplaceId: 'a', date: pay);
      final awaiting = app.workplacesAwaitingSalary(DateTime(2026, 9, 27));
      expect(awaiting.map((w) => w.id).toList(), ['b']);
    });

    test('2026年8月までの給料は受け取り済み（9月から選択肢に出る）', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData(); // 移行で salaryPaidThroughMonth = 2026-08
      app.addWorkplace(Workplace(id: 'g', name: 'グローバル', paydayDay: 25));
      expect(app.workplacesAwaitingSalary(DateTime(2026, 8, 25)), isEmpty); // 8月は済み
      expect(app.workplacesAwaitingSalary(DateTime(2026, 9, 25)).length, 1); // 9月から
    });

    test('勤務先を削除すると選択肢からも関連データからも消える', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.addWorkplace(Workplace(id: 'a', name: 'A', paydayDay: 25));
      final pay = DateTime(2026, 9, 25);
      app.setActualSalaryOfWorkplace(DateTime(2026, 9), 'a', 1000);
      app.addDeposit(70000, workplaceId: 'a', date: pay);

      app.removeWorkplace('a');
      expect(app.workplacesAwaitingSalary(pay), isEmpty); // 選択肢に出ない
      expect(app.actualSalaryOfWorkplace(DateTime(2026, 9), 'a'), isNull); // 残らない
      expect(app.paidSalaryKeys.any((k) => k.startsWith('a|')), isFalse);
    });
  });

  group('予定入金', () {
    test('登録して受け取ると残高に加算され、履歴にも残る', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.updateBalance(10000);
      app.addPlannedIncome(
          title: '仕送り', amount: 30000, date: DateTime(2026, 9, 5));
      expect(app.plannedIncomes.length, 1);

      app.receivePlannedIncome(
          app.plannedIncomes.first.id, 30000, DateTime(2026, 9, 5));
      expect(app.currentBalance, 40000);
      expect(app.balanceHistory.first.label, '仕送り');
      // 受け取り済みなので同じ月にはもう出ない
      expect(app.plannedIncomesIn(DateTime(2026, 9)), isEmpty);
    });

    test('毎月繰り返しは登録月以降の各月に出る', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.addPlannedIncome(
          title: '仕送り', amount: 30000, date: DateTime(2026, 9, 5), monthly: true);
      expect(app.plannedIncomesIn(DateTime(2026, 9)).length, 1);
      expect(app.plannedIncomesIn(DateTime(2026, 10)).length, 1);
      expect(app.plannedIncomesIn(DateTime(2026, 10)).first.date, DateTime(2026, 10, 5));
      // 登録月より前には出ない
      expect(app.plannedIncomesIn(DateTime(2026, 8)), isEmpty);
    });

    test('予定入金は予想残高に足される', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.updateBalance(10000);
      app.balanceUpdatedAt = DateTime.now().subtract(const Duration(days: 40));
      final next = DateTime(DateTime.now().year, DateTime.now().month + 1);
      app.addPlannedIncome(
          title: '仕送り', amount: 30000, date: DateTime(next.year, next.month, 5));
      expect(app.plannedIncomeForecastIn(next), 30000);
    });

    test('削除すると受け取り記録も消える', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.addPlannedIncome(
          title: '返金', amount: 5000, date: DateTime(2026, 9, 10));
      final id = app.plannedIncomes.first.id;
      app.receivePlannedIncome(id, 5000, DateTime(2026, 9, 10));
      app.removePlannedIncome(id);
      expect(app.plannedIncomes, isEmpty);
      expect(app.receivedPlannedKeys.any((k) => k.startsWith('$id|')), isFalse);
    });
  });

  group('履歴に過去の記録を追加', () {
    test('残高は変えずに記録だけ残せる', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await app.loadData();
      app.updateBalance(50000);
      app.addPastBalanceEntry(
        kind: BalanceEntryKind.draw,
        label: '三井OLIVE',
        amount: 44238,
        at: DateTime(2026, 8, 26),
      );
      expect(app.currentBalance, 50000); // 残高は動かない
      expect(app.balanceHistory.length, 1);
      expect(app.balanceHistory.first.label, '三井OLIVE');
    });
  });

  group('既存シフトの勤務先マイグレーション', () {
    test('フリーテキスト勤務先から勤務先マスタを生成し workplaceId を紐付ける', () async {
      final shiftJson = {
        '2026-06-15': [
          {
            'workplace': 'グローバル',
            'hourlyWage': 1000,
            'start': '2026-06-15T09:00:00.000',
            'end': '2026-06-15T17:00:00.000',
            'breakMinutes': 60,
          }
        ]
      };
      SharedPreferences.setMockInitialValues({
        'saved_shifts': jsonEncode(shiftJson),
      });
      final app = AppState();
      await app.loadData();

      // 勤務先が自動生成される
      final wp = app.workplaces.where((w) => w.name == 'グローバル').toList();
      expect(wp.length, 1);
      expect(wp.first.wagePeriods.first.hourlyWage, 1000);

      // シフトに workplaceId が紐付く
      final shift = app.shifts['2026-06-15']!.first;
      expect(shift.workplaceId, wp.first.id);
    });
  });
}
