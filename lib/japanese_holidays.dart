// 💡 日本の祝日判定（1980〜2099年）。給料日が休日のときの前後ズラしに使う。
//   ・固定日の祝日
//   ・ハッピーマンデー（第N月曜）
//   ・春分/秋分（近似式。1980〜2099で実用上一致）
//   ・振替休日（日曜と重なったら翌日が休み）
//   ※ 国民の休日（前後を祝日に挟まれた平日）も考慮する。

// その年のN番目の指定曜日の日付（例: 1月第2月曜）
int _nthWeekday(int year, int month, int weekday, int nth) {
  final first = DateTime(year, month, 1).weekday;
  final offset = (weekday - first + 7) % 7;
  return 1 + offset + (nth - 1) * 7;
}

int _shunbun(int year) =>
    (20.8431 + 0.242194 * (year - 1980) - ((year - 1980) ~/ 4)).floor();

int _shubun(int year) =>
    (23.2488 + 0.242194 * (year - 1980) - ((year - 1980) ~/ 4)).floor();

// 振替休日・国民の休日を含まない「本来の祝日」か
bool _isBaseHoliday(DateTime d) {
  final y = d.year, m = d.month, day = d.day;
  switch (m) {
    case 1:
      if (day == 1) return true; // 元日
      if (day == _nthWeekday(y, 1, DateTime.monday, 2)) return true; // 成人の日
      return false;
    case 2:
      if (day == 11) return true; // 建国記念の日
      if (day == 23 && y >= 2020) return true; // 天皇誕生日
      return false;
    case 3:
      return day == _shunbun(y); // 春分の日
    case 4:
      return day == 29; // 昭和の日
    case 5:
      return day == 3 || day == 4 || day == 5; // 憲法記念日・みどりの日・こどもの日
    case 7:
      return day == _nthWeekday(y, 7, DateTime.monday, 3); // 海の日
    case 8:
      return day == 11; // 山の日
    case 9:
      if (day == _nthWeekday(y, 9, DateTime.monday, 3)) return true; // 敬老の日
      return day == _shubun(y); // 秋分の日
    case 10:
      return day == _nthWeekday(y, 10, DateTime.monday, 2); // スポーツの日
    case 11:
      return day == 3 || day == 23; // 文化の日・勤労感謝の日
    default:
      return false;
  }
}

// 祝日（振替休日・国民の休日を含む）か
bool isJapaneseHoliday(DateTime date) {
  final d = DateTime(date.year, date.month, date.day);
  if (_isBaseHoliday(d)) return true;

  // 振替休日: 直前の日曜が祝日で、そこから今日まで祝日が連続している
  if (d.weekday != DateTime.sunday) {
    var prev = d.subtract(const Duration(days: 1));
    while (true) {
      if (!_isBaseHoliday(prev)) break;
      if (prev.weekday == DateTime.sunday) return true;
      prev = prev.subtract(const Duration(days: 1));
    }
  }

  // 国民の休日: 前日と翌日がどちらも祝日の平日（例: 敬老の日と秋分の日に挟まれた日）
  if (d.weekday != DateTime.sunday &&
      _isBaseHoliday(d.subtract(const Duration(days: 1))) &&
      _isBaseHoliday(d.add(const Duration(days: 1)))) {
    return true;
  }
  return false;
}

// 土日または祝日か（銀行が休みの日）
bool isBankHoliday(DateTime date) =>
    date.weekday == DateTime.saturday ||
    date.weekday == DateTime.sunday ||
    isJapaneseHoliday(date);

// 直前の営業日（その日が営業日ならそのまま）
DateTime previousBusinessDay(DateTime date) {
  var d = DateTime(date.year, date.month, date.day);
  while (isBankHoliday(d)) {
    d = d.subtract(const Duration(days: 1));
  }
  return d;
}

// 直後の営業日（その日が営業日ならそのまま）
DateTime nextBusinessDay(DateTime date) {
  var d = DateTime(date.year, date.month, date.day);
  while (isBankHoliday(d)) {
    d = d.add(const Duration(days: 1));
  }
  return d;
}
