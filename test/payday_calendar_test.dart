// 給料日をGoogleカレンダーへ書き出す（「💰 給料日」の通知）テスト。
// ⚠️ 以前は書き出し処理がどこからも呼ばれず、給料日のイベントは一度も作られていなかった。
//   給料日を変えたら、まだ来ていない給料日は新しい日へ移し、もう来た給料日は動かさない。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/app_state.dart';

// カレンダーに何を書いたかを記録するだけの偽物
class FakeCalendar implements CalendarSyncHook {
  final upserts = <({String existingCalId, String title, DateTime date, bool remind})>[];
  final deleted = <String>[];
  int _n = 0;

  @override
  Future<String?> upsertSpecialEvent({
    required String existingCalId,
    required String title,
    required DateTime date,
    required String description,
    bool remind = false,
  }) async {
    upserts.add((existingCalId: existingCalId, title: title, date: date, remind: remind));
    await Future<void>.delayed(Duration.zero); // 通信の待ちに見立てる
    return existingCalId.isNotEmpty ? existingCalId : 'ev${_n++}';
  }

  @override
  void deleteEvent(String calendarEventId) => deleted.add(calendarEventId);
  @override
  Future<bool> enableAndSyncAll() async => true;
  @override
  void upsertShift(DateTime date, ShiftData shift) {}
  @override
  void upsertEvent(EventData event) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // 「今」は 2026/10/15。10月に働いたぶんが翌月25日（11/25・水）に入る勤務先
  final now = DateTime(2026, 10, 15, 12);
  late AppState app;
  late FakeCalendar cal;

  Workplace cafe({int day = 25}) => Workplace(
        id: 'w1',
        name: 'カフェ',
        paydayDay: day,
        paydayMonthOffset: 1,
        paydayAdjust: PaydayAdjust.none,
      );

  setUp(() async {
    app = AppState();
    // ⚠️ 読み込み（loadData）が終わる前に足すと、途中で保存データに上書きされる
    await app.ready;
    cal = FakeCalendar();
    app.calendarSync = cal;
    app.workplaces.add(cafe());
    app.shifts['2026-10-05'] = [
      ShiftData(
        workplace: 'カフェ',
        workplaceId: 'w1',
        hourlyWage: 1100,
        start: DateTime(2026, 10, 5, 9),
        end: DateTime(2026, 10, 5, 17),
      ),
    ];
  });

  List<({String existingCalId, String title, DateTime date, bool remind})> paydaysOf(
          FakeCalendar c) =>
      c.upserts.where((u) => u.title.contains('給料日')).toList();

  test('カレンダー自動連携がOFFなら何も書かない', () async {
    app.calendarAutoSync = false;
    await app.syncPaydaysToCalendar(now: now);
    expect(cal.upserts, isEmpty);
  });

  test('ONなら給料日を書き出し、当日に通知が出るようにする', () async {
    app.calendarAutoSync = true;
    await app.syncPaydaysToCalendar(now: now);
    final p = paydaysOf(cal).single;
    expect(p.date, DateTime(2026, 11, 25));
    expect(p.title, '💰 給料日（カフェ）');
    expect(p.remind, isTrue, reason: '通知を付けないと、カレンダーの既定次第で鳴らない');
  });

  test('何も変わっていなければ書き直さない（重複も作らない）', () async {
    app.calendarAutoSync = true;
    await app.syncPaydaysToCalendar(now: now);
    await app.syncPaydaysToCalendar(now: now);
    expect(paydaysOf(cal), hasLength(1));
  });

  test('給料日を変えたら、まだ来ていない給料日は同じイベントを新しい日へ移す', () async {
    app.calendarAutoSync = true;
    await app.syncPaydaysToCalendar(now: now);
    final firstId = app.specialCalendarIds.values.single;

    app.workplaces[0].paydayDay = 20;
    await app.syncPaydaysToCalendar(now: now);
    final moved = paydaysOf(cal).last;
    expect(moved.existingCalId, firstId, reason: '新しく作らず、同じイベントを動かす');
    expect(moved.date, DateTime(2026, 11, 20));
  });

  test('もう来た給料日は動かさない（その日で通知済み。同じ月の通知が二度出る）', () async {
    app.calendarAutoSync = true;
    await app.syncPaydaysToCalendar(now: now);
    // 給料日（11/25）を過ぎた 11/30 に、給料日を28日へ変えた
    app.workplaces[0].paydayDay = 28;
    cal.upserts.clear();
    await app.syncPaydaysToCalendar(now: DateTime(2026, 11, 30));
    expect(cal.upserts.where((u) => u.existingCalId == app.specialCalendarIds.values.first),
        isEmpty);
  });

  test('同時に2回走っても、同じ給料日を2つ作らない', () async {
    app.calendarAutoSync = true;
    await Future.wait([
      app.syncPaydaysToCalendar(now: now),
      app.syncPaydaysToCalendar(now: now),
    ]);
    final created = paydaysOf(cal).where((u) => u.existingCalId.isEmpty);
    expect(created, hasLength(1));
  });

  test('作ったイベントの記録は保存・同期で保たれる（開き直しても重複しない）', () async {
    app.calendarAutoSync = true;
    await app.syncPaydaysToCalendar(now: now);
    final restored = AppState()..importJson(app.exportJson());
    expect(restored.specialCalendarIds, app.specialCalendarIds);
    expect(restored.specialCalendarSigs, app.specialCalendarSigs);
  });

  test('勤務先を消したら、まだ来ていない給料日のイベントも消す', () async {
    app.calendarAutoSync = true;
    await app.syncPaydaysToCalendar(now: now);
    final id = app.specialCalendarIds.values.single;
    app.removeWorkplace('w1');
    expect(cal.deleted, [id]);
    expect(app.specialCalendarIds, isEmpty);
  });
}
