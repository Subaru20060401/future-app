// 💡 引き落とし・締め期間の日付規則（純粋関数）。期待値は暦から手で決めた。
//   2026-10-31 土 / 11-02 月 / 11-26 木 / 12-26 土 / 12-28 月 / 2027-02-28 日 / 03-01 月
import 'package:flutter_test/flutter_test.dart';
import 'package:my_counter_app/finance/billing_dates.dart';

void main() {
  group('clampedDay', () {
    test('月の日数を超えたら月末、2月は28日（2027年は平年）', () {
      expect(clampedDay(2027, 2, 31), DateTime(2027, 2, 28));
      expect(clampedDay(2028, 2, 31), DateTime(2028, 2, 29)); // うるう年
      expect(clampedDay(2026, 11, 31), DateTime(2026, 11, 30));
    });
    test('月の繰り上がり（13月＝翌年1月、0月＝前年12月）', () {
      expect(clampedDay(2026, 13, 31), DateTime(2027, 1, 31));
      expect(clampedDay(2027, 0, 15), DateTime(2026, 12, 15));
    });
    test('1未満は1日', () => expect(clampedDay(2026, 11, 0), DateTime(2026, 11, 1)));
  });

  group('drawDateInMonth（休みなら翌営業日）', () {
    test('平日はそのまま', () {
      expect(drawDateInMonth(26, DateTime(2026, 11)), DateTime(2026, 11, 26));
    });
    test('土曜は月曜へ', () {
      expect(drawDateInMonth(26, DateTime(2026, 12)), DateTime(2026, 12, 28));
    });
    test('月末が休みなら翌月へずれる（10/31土 → 11/2月）', () {
      expect(drawDateInMonth(31, DateTime(2026, 10)), DateTime(2026, 11, 2));
    });
    test('2月の31日払いは月末（2/28日）→ 翌営業日 3/1', () {
      expect(drawDateInMonth(31, DateTime(2027, 2)), DateTime(2027, 3, 1));
    });
  });

  group('closingPeriod', () {
    test('月末締めは前月まるごと', () {
      final r = closingPeriod(closingDay: 31, payMonth: DateTime(2026, 12));
      expect(r.start, DateTime(2026, 11, 1));
      expect(r.end, DateTime(2026, 11, 30));
    });
    test('15日締めは前々月16日〜前月15日（年をまたぐ）', () {
      final r = closingPeriod(closingDay: 15, payMonth: DateTime(2027, 1));
      expect(r.start, DateTime(2026, 11, 16));
      expect(r.end, DateTime(2026, 12, 15));
    });
    test('30日締めの2月は28日まで', () {
      final r = closingPeriod(closingDay: 30, payMonth: DateTime(2027, 3));
      expect(r.start, DateTime(2027, 1, 31));
      expect(r.end, DateTime(2027, 2, 28));
    });
  });

  group('payMonthOfUsage', () {
    test('月末締めは利用月の翌月（12月利用 → 翌年1月）', () {
      expect(payMonthOfUsage(closingDay: 31, usageDate: DateTime(2026, 12, 31)),
          DateTime(2027, 1));
    });
    test('15日締め: 15日までは翌月、16日以降は翌々月', () {
      expect(payMonthOfUsage(closingDay: 15, usageDate: DateTime(2026, 11, 15, 23)),
          DateTime(2026, 12));
      expect(payMonthOfUsage(closingDay: 15, usageDate: DateTime(2026, 11, 16)),
          DateTime(2027, 1));
    });
    test('締め期間と対応する（期間内の日はその payMonth に入る）', () {
      for (final c in [5, 15, 25, 31]) {
        for (var d = DateTime(2026, 10, 1); d.isBefore(DateTime(2027, 3, 1));
            d = d.add(const Duration(days: 1))) {
          final pm = payMonthOfUsage(closingDay: c, usageDate: d);
          final r = closingPeriod(closingDay: c, payMonth: pm);
          expect(!d.isBefore(r.start) && !d.isAfter(r.end), isTrue,
              reason: '締め$c日 利用$d → $pm（${r.start}〜${r.end}）');
        }
      }
    });
  });
}
