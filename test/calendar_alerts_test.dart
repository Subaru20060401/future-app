// シフト前・残高不足の通知（Googleカレンダーの通知として届ける）のテスト。
// 💡 サーバーが無いので、アプリを閉じていても届くのはカレンダーの通知だけ。
// ⚠️ 不足が無くなったのに予定が残ると、払えるのに「足りない」と通知が来てしまう。
//   同じ内容で何度も書くと、APIを無駄に使い通知も重複しうる。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/app_state.dart';

class FakeCalendar implements CalendarSyncHook {
  final upserts = <({String existingCalId, String title, DateTime date, String description, List<int>? reminders})>[];
  final deleted = <String>[];
  final shiftSyncs = <ShiftData>[];
  int _n = 0;

  @override
  Future<String?> upsertSpecialEvent({
    required String existingCalId,
    required String title,
    required DateTime date,
    required String description,
    bool remind = false,
    List<int>? reminderMinutes,
  }) async {
    upserts.add((
      existingCalId: existingCalId,
      title: title,
      date: date,
      description: description,
      reminders: reminderMinutes,
    ));
    await Future<void>.delayed(Duration.zero);
    return existingCalId.isNotEmpty ? existingCalId : 'ev${_n++}';
  }

  @override
  void deleteEvent(String calendarEventId) => deleted.add(calendarEventId);
  @override
  Future<bool> enableAndSyncAll() async => true;
  @override
  void upsertShift(DateTime date, ShiftData shift) {}
  @override
  Future<void> syncShiftNow(DateTime date, ShiftData shift) async => shiftSyncs.add(shift);
  @override
  void upsertEvent(EventData event) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('シフトの通知の時刻', () {
    final evening = DateTime(2026, 10, 20, 17); // 17時開始

    test('設定ごとの「開始の何分前」', () {
      expect(shiftReminderMinutes(ShiftReminder.calendarDefault, evening), isNull,
          reason: '既定のまま＝以前と同じ動き');
      expect(shiftReminderMinutes(ShiftReminder.none, evening), isEmpty);
      expect(shiftReminderMinutes(ShiftReminder.hourBefore, evening), [60]);
      // 前日21時 → 17時開始は20時間前
      expect(shiftReminderMinutes(ShiftReminder.eveningBefore, evening), [20 * 60]);
      expect(shiftReminderMinutes(ShiftReminder.both, evening), [20 * 60, 60]);
    });

    test('朝のシフト・月初めのシフトでも前日の21時', () {
      expect(shiftReminderMinutes(ShiftReminder.eveningBefore, DateTime(2026, 10, 20, 9)),
          [12 * 60]);
      // 11/1 10時 → 10/31 21時（月をまたぐ）
      expect(shiftReminderMinutes(ShiftReminder.eveningBefore, DateTime(2026, 11, 1, 10)),
          [13 * 60]);
    });
  });

  group('シフトの通知を変えたとき', () {
    test('まだ始まっていないシフトだけ書き直す', () async {
      final app = AppState();
      await app.ready;
      final cal = FakeCalendar();
      app.calendarSync = cal;
      app.calendarAutoSync = true;
      final now = DateTime.now();
      ShiftData shift(DateTime start) => ShiftData(
            workplace: 'カフェ',
            hourlyWage: 1100,
            start: start,
            end: start.add(const Duration(hours: 4)),
          );
      final past = shift(now.subtract(const Duration(days: 2)));
      final future = shift(now.add(const Duration(days: 2)));
      // キーは日付（yyyy-MM-dd）
      app.shifts[past.start.toIso8601String().substring(0, 10)] = [past];
      app.shifts[future.start.toIso8601String().substring(0, 10)] = [future];

      await app.setShiftReminder(ShiftReminder.both);
      expect(cal.shiftSyncs, [future]);
      expect(app.shiftReminderFor(future), isNotNull);
    });

    test('カレンダー連携がOFFなら何も書かない', () async {
      final app = AppState();
      await app.ready;
      final cal = FakeCalendar();
      app.calendarSync = cal;
      final start = DateTime.now().add(const Duration(days: 1));
      app.shifts[start.toIso8601String().substring(0, 10)] = [
        ShiftData(workplace: 'カフェ', hourlyWage: 1100, start: start, end: start)
      ];
      await app.setShiftReminder(ShiftReminder.hourBefore);
      expect(cal.shiftSyncs, isEmpty);
    });
  });

  group('残高不足の通知', () {
    final now = DateTime.now();
    late AppState app;
    late FakeCalendar cal;

    setUp(() async {
      app = AppState();
      await app.ready;
      cal = FakeCalendar();
      app.calendarSync = cal;
      app.calendarAutoSync = true;
      app.currentBalance = 0;
      app.cardPaymentDays['三菱カード'] = 10;
      // 今月の利用6万 → 来月10日に落ちるが、残高0なので足りない
      app.payments.add(Payment(
        id: 'p1',
        cardName: '三菱カード',
        amount: 60000,
        paymentDate: DateTime(now.year, now.month, 1),
        source: PaymentSource.usage,
      ));
    });

    test('足りない日に、3日前と前日の9時に鳴る予定を置く', () async {
      final day = app.shortfallDaysAhead().single.date;
      await app.syncShortfallsToCalendar();
      expect(cal.upserts, hasLength(1));
      final e = cal.upserts.single;
      expect(e.date, day);
      expect(e.reminders, [3 * 1440 - 540, 1440 - 540]);
      expect(e.description, contains('三菱カード'));
      expect(e.description, contains('60,000'));
      // ⚠️ ロック画面に出るタイトルには金額を入れない
      expect(e.title, isNot(contains('¥')));
      expect(e.title, isNot(contains('60,000')));
    });

    test('同じ内容なら書き直さない', () async {
      await app.syncShortfallsToCalendar();
      await app.syncShortfallsToCalendar();
      expect(cal.upserts, hasLength(1));
    });

    test('不足額が変わったら、同じ予定を書き直す（増やさない）', () async {
      await app.syncShortfallsToCalendar();
      app.currentBalance = 10000;
      await app.syncShortfallsToCalendar();
      expect(cal.upserts, hasLength(2));
      expect(cal.upserts.last.existingCalId, 'ev0');
      expect(cal.upserts.last.description, contains('50,000'));
    });

    test('足りるようになったら予定を消す', () async {
      await app.syncShortfallsToCalendar();
      app.currentBalance = 100000;
      await app.syncShortfallsToCalendar();
      expect(cal.deleted, ['ev0']);
      expect(app.specialCalendarIds.keys.where((k) => k.startsWith('shortfall_')), isEmpty);
    });

    test('通知をOFFにしたら、置いた予定を消す', () async {
      await app.syncShortfallsToCalendar();
      await app.setShortfallAlerts(false);
      expect(cal.deleted, ['ev0']);
    });

    test('同時に呼ばれても同じ日の予定を2つ作らない', () async {
      await Future.wait([
        app.syncShortfallsToCalendar(),
        app.syncShortfallsToCalendar(),
      ]);
      expect(cal.upserts.where((e) => e.existingCalId.isEmpty), hasLength(1));
    });

    test('カレンダー連携がOFFなら何もしない', () async {
      app.calendarAutoSync = false;
      await app.syncShortfallsToCalendar();
      expect(cal.upserts, isEmpty);
    });

    test('給料日の予定には触らない', () async {
      app.specialCalendarIds['payday_w1_202610'] = 'pay';
      app.specialCalendarSigs['payday_w1_202610'] = '2099-01-01|💰|x';
      app.currentBalance = 100000; // 不足なし
      await app.syncShortfallsToCalendar();
      expect(cal.deleted, isEmpty);
      expect(app.specialCalendarIds['payday_w1_202610'], 'pay');
    });
  });
}
