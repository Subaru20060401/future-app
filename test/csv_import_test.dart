// シフトCSVの取り込み（交通費・割増の逆算を含む）のテスト。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const header = '日付,勤務先,開始,終了,休憩(分),時給,給与';

  group('importShiftsCsv', () {
    test('交通費のみの勤務先を逆算して給与を再現する', () {
      final app = AppState();
      // 時給1000・4時間 → 4000 + 交通費500 = 4500
      final csv = [
        header,
        '2026-06-01,テスト,2026-06-01T09:00:00.000,2026-06-01T13:00:00.000,0,1000,4500',
        '2026-06-02,テスト,2026-06-02T09:00:00.000,2026-06-02T12:00:00.000,0,1000,3500',
      ].join('\n');

      final r = app.importShiftsCsv(csv);
      expect(r.imported, 2);
      expect(r.mismatched, 0);
      expect(app.shifts['2026-06-01']!.single.earnings, 4500);
      expect(app.shifts['2026-06-01']!.single.transportPerDay, 500);
    });

    test('深夜割増を含む勤務先も再現する', () {
      final app = AppState();
      // 17:30-22:30（5h）時給1030、深夜0.5h×1.25、交通費500 → 5779
      final csv = [
        header,
        '2026-06-01,夜勤,2026-06-01T15:30:00.000,2026-06-01T20:00:00.000,0,1030,5135',
        '2026-06-03,夜勤,2026-06-03T17:30:00.000,2026-06-03T22:30:00.000,0,1030,5779',
        '2026-06-04,夜勤,2026-06-04T20:00:00.000,2026-06-04T22:30:00.000,0,1030,3204',
      ].join('\n');

      final r = app.importShiftsCsv(csv);
      expect(r.imported, 3);
      expect(r.mismatched, 0);
      expect(app.shifts['2026-06-03']!.single.earnings, 5779);
      expect(app.shifts['2026-06-03']!.single.nightMultiplier, closeTo(1.25, 0.001));
    });

    test('勤務先マスタが作られ workplaceId が紐づく', () {
      final app = AppState();
      final csv = [
        header,
        '2026-06-01,新規バイト,2026-06-01T09:00:00.000,2026-06-01T13:00:00.000,0,1200,5300',
      ].join('\n');

      app.importShiftsCsv(csv);
      final wp = app.workplaces.firstWhere((w) => w.name == '新規バイト');
      expect(wp.wagePeriods.single.hourlyWage, 1200);
      expect(wp.wagePeriods.single.transportPerDay, 500);
      expect(app.shifts['2026-06-01']!.single.workplaceId, wp.id);
    });

    test('同じシフトの再取り込みはスキップされる', () {
      final app = AppState();
      final csv = [
        header,
        '2026-06-01,テスト,2026-06-01T09:00:00.000,2026-06-01T13:00:00.000,0,1000,4000',
      ].join('\n');

      expect(app.importShiftsCsv(csv).imported, 1);
      final second = app.importShiftsCsv(csv);
      expect(second.imported, 0);
      expect(second.skipped, 1);
      expect(app.shifts['2026-06-01']!.length, 1);
    });

    test('replace:true は既存シフトを置き換える', () {
      final app = AppState();
      app.importShiftsCsv([
        header,
        '2026-05-01,旧,2026-05-01T09:00:00.000,2026-05-01T13:00:00.000,0,1000,4000',
      ].join('\n'));
      expect(app.shifts.containsKey('2026-05-01'), isTrue);

      app.importShiftsCsv([
        header,
        '2026-06-01,新,2026-06-01T09:00:00.000,2026-06-01T13:00:00.000,0,1000,4000',
      ].join('\n'), replace: true);
      expect(app.shifts.containsKey('2026-05-01'), isFalse);
      expect(app.shifts.containsKey('2026-06-01'), isTrue);
    });

    test('壊れた行は failed に数え、他の行は取り込む', () {
      final app = AppState();
      final csv = [
        header,
        'ぐちゃぐちゃ',
        '2026-06-01,テスト,2026-06-01T09:00:00.000,2026-06-01T13:00:00.000,0,1000,4000',
      ].join('\n');

      final r = app.importShiftsCsv(csv);
      expect(r.failed, 1);
      expect(r.imported, 1);
    });

    test('書き出したCSVを読み直すと給与が一致する（往復）', () {
      final src = AppState();
      src.importShiftsCsv([
        header,
        '2026-06-01,往復,2026-06-01T15:30:00.000,2026-06-01T20:00:00.000,0,1030,5135',
        '2026-06-03,往復,2026-06-03T17:30:00.000,2026-06-03T22:30:00.000,0,1030,5779',
        '2026-06-05,往復,2026-06-05T20:00:00.000,2026-06-05T22:30:00.000,0,1030,3204',
      ].join('\n'));

      final dst = AppState();
      final r = dst.importShiftsCsv(src.exportShiftsCsv());
      expect(r.mismatched, 0);
      expect(dst.exportShiftsCsv(), src.exportShiftsCsv());
    });
  });
}
