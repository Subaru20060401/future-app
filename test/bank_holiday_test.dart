// 💡 銀行の休業日（年末年始を含む）と、給料日・引落日の調整。暦は手で確かめた:
//   2026-12-30 水 / 12-31 木 / 2027-01-01 金・元日 / 01-02 土 / 01-03 日 / 01-04 月
import 'package:flutter_test/flutter_test.dart';
import 'package:my_counter_app/app_state.dart';
import 'package:my_counter_app/finance/billing_dates.dart';
import 'package:my_counter_app/japanese_holidays.dart';

void main() {
  test('12/31 と 1/2・1/3 は銀行の休業日。ただし国民の祝日ではない', () {
    expect(isBankHoliday(DateTime(2026, 12, 31)), isTrue);
    expect(isBankHoliday(DateTime(2027, 1, 2)), isTrue);
    expect(isBankHoliday(DateTime(2027, 1, 3)), isTrue);
    expect(isJapaneseHoliday(DateTime(2026, 12, 31)), isFalse);
    expect(isJapaneseHoliday(DateTime(2027, 1, 2)), isFalse);
    expect(isJapaneseHoliday(DateTime(2027, 1, 1)), isTrue); // 元日は祝日
    expect(isBankHoliday(DateTime(2026, 12, 30)), isFalse);
  });

  test('引き落としは翌営業日: 12/31 → 1/4（年をまたぐ）', () {
    expect(drawDateInMonth(31, DateTime(2026, 12)), DateTime(2027, 1, 4));
    expect(nextBusinessDay(DateTime(2027, 1, 2)), DateTime(2027, 1, 4));
  });

  test('給料は前営業日: 1/3 払い → 12/30（年をまたぐ）', () {
    final w = Workplace(id: 'w', name: '店', paydayDay: 3, paydayAdjust: PaydayAdjust.before);
    expect(w.paydayIn(DateTime(2027, 1)), DateTime(2026, 12, 30));
    final after = Workplace(id: 'w2', name: '店', paydayDay: 31, paydayAdjust: PaydayAdjust.after);
    expect(after.paydayIn(DateTime(2026, 12)), DateTime(2027, 1, 4));
  });

  test('休日割増は土日だけ（年末年始の銀行休業日を休日割増に広げない）', () {
    final s = ShiftData(
      workplace: '店',
      hourlyWage: 1000,
      start: DateTime(2026, 12, 31, 10), // 木曜・銀行は休み
      end: DateTime(2026, 12, 31, 14),
      holidayMultiplier: 1.5,
    );
    expect(s.wageEarnings, 4000);
  });
}
