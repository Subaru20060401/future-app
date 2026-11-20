// 💡 引き落とし・締め期間の日付の規則（純粋関数）。
//   ・引数だけで決まる。DateTime.now() を読まない・保存しない・AppState を参照しない
//   ・AppState の cardDrawDateOf / drawDateOf / cardClosingPeriodOf / drawDateForUsage /
//     subscriptionDrawsIn / pendingDraws は、ここを呼ぶ（同じ規則を2か所に書かない）
//   ⚠️ 銀行の引落確定に載っている日付は「実際の日付」なので、ここで再調整しない
//     （呼び出し側で確定日付があればそれを優先する）。
import '../japanese_holidays.dart';

/// [year]年[month]月の[day]日。月の日数を超えたら月末、1 未満なら 1 日にそろえる。
/// 💡 月は 13 や 0 でもよい（DateTime と同じく前後の年に繰り上がる）。
DateTime clampedDay(int year, int month, int day) {
  final first = DateTime(year, month, 1);
  final lastDay = DateTime(first.year, first.month + 1, 0).day;
  final d = day < 1 ? 1 : (day > lastDay ? lastDay : day);
  return DateTime(first.year, first.month, d);
}

/// [month]月の[day]日に口座から引かれるものの、実際の引落日（休みなら翌営業日）。
/// カードの引き落とし、口座振替の定期支払い、口座払いのローンが同じ規則。
DateTime drawDateInMonth(int day, DateTime month) =>
    nextBusinessDay(clampedDay(month.year, month.month, day));

/// 締め日が月末か（31 以上を月末締めとして扱う）
bool isMonthEndClosingDay(int closingDay) => closingDay >= 31;

/// [payMonth]に引き落とされる利用の対象期間。
///   締め日 C なら「前々月 C 日の翌日 〜 前月 C 日」。
///   月末締めなら前月 1 日〜前月末日（暦月の集計と同じ）。
({DateTime start, DateTime end}) closingPeriod({
  required int closingDay,
  required DateTime payMonth,
}) {
  final endMonth = DateTime(payMonth.year, payMonth.month - 1);
  final end = clampedDay(endMonth.year, endMonth.month, closingDay);
  final start = clampedDay(endMonth.year, endMonth.month - 1, closingDay)
      .add(const Duration(days: 1));
  return (start: start, end: end);
}

/// [usageDate]に使ったぶんが、どの月に引き落とされるか（その月の 1 日を返す）。
///   月末締め … 利用月の翌月
///   C 日締め … C 日までの利用は翌月、C+1 日以降は翌々月
DateTime payMonthOfUsage({required int closingDay, required DateTime usageDate}) {
  final d = DateTime(usageDate.year, usageDate.month, usageDate.day);
  if (isMonthEndClosingDay(closingDay)) return DateTime(d.year, d.month + 1);
  final closing = clampedDay(d.year, d.month, closingDay);
  return d.isAfter(closing) ? DateTime(d.year, d.month + 2) : DateTime(d.year, d.month + 1);
}
