// カレンダー形式のシフト画面（ジョブカンの「確定シフト」）を、文字読み取り（OCR）の結果から
// シフトにするテスト。
// 💡 2026-10-25 に本人のスクリーンショット（幅923×高さ2000）を端末内のOCR（tesseract.js）に
//   かけたときの「読み方のくせ」をそのまま再現している（時刻は架空のものに置き換えた）:
//   ・見出し「2026年 10月度」が「20265108」になる
//   ・灰色の日（前の月）と「1」「3」「7」「9」を読み落とす。「11」を「1」と読む
//   ・ステータスバーの時計やアイコンが数字として混ざる
//   ・「シフト合計時間 : 58:00」が「7:58:00」になる
//   それでも、マス目（列＝横の位置、行＝日付の並ぶ高さ）から日付を決めるので正しく読めること。
import 'package:flutter_test/flutter_test.dart';
import 'package:my_counter_app/shift_calendar_ocr.dart';

const width = 923.0;
const rowY = [725.0, 894.0, 1063.0, 1232.0, 1402.0];
double colX(int c) => c * width / 7 + 1;

// 画面のマス（行・列）→ 日付（2026年10月。日曜はじまり、1日は木曜）
const dayGrid = [
  [27, 28, 29, 30, 1, 2, 3],
  [4, 5, 6, 7, 8, 9, 10],
  [11, 12, 13, 14, 15, 16, 17],
  [18, 19, 20, 21, 22, 23, 24],
  [25, 26, 27, 28, 29, 30, 31],
];

// 架空のシフト（日 → 開始・終了）
const fake = {
  2: ('10:00', '14:00'),
  3: ('9:00', '13:00'),
  7: ('18:00', '22:00'),
  9: ('12:00', '17:00'),
  11: ('10:00', '15:30'),
  15: ('17:00', '21:30'),
  19: ('9:30', '12:30'),
  22: ('18:00', '23:00'),
  25: ('13:00', '18:00'),
  30: ('16:00', '20:00'),
};

// 読み落とす日付の数字（実際のOCRのくせ）
const missedDays = {27, 28, 29, 30, 1, 3, 7, 9};

OcrWord w(String t, double x, double y, [double wd = 78]) => OcrWord(t, x, y, x + wd, y + 24);

int minutesOf(Map<int, (String, String)> s) {
  var sum = 0;
  int m(String hm) => int.parse(hm.split(':')[0]) * 60 + int.parse(hm.split(':')[1]);
  for (final v in s.values) {
    var d = m(v.$2) - m(v.$1);
    if (d <= 0) d += 24 * 60;
    sum += d;
  }
  return sum;
}

OcrPage screenshot({
  Map<int, (String, String)> s = fake,
  String? total,
  bool header = true,
  bool withWidth = true,
}) {
  final sum = minutesOf(s);
  final words = <OcrWord>[
    w('1752', 34, 37, 273), // ステータスバーの時計
    w('537', 243, 124, 436), // ロゴの一部
    w('0', 45, 327, 67), // アイコン
    w('9', 833, 327, 13),
    w('7', 27, 381, 173),
    if (header) w('20265108', 329, 611, 242), // 「2026年 10月度」
    w('2', 732, 602, 178),
  ];
  for (var r = 0; r < dayGrid.length; r++) {
    for (var c = 0; c < 7; c++) {
      final d = dayGrid[r][c];
      final gray = r == 0 && d > 20;
      if (!missedDays.contains(d) && !gray) {
        // 11 は「1」と読まれる
        words.add(w(d == 11 ? '1' : '$d', colX(c) + 1, rowY[r], d >= 10 ? 32 : 15));
      }
      if (gray || (r == 4 && d < 20)) continue;
      final t = s[d];
      if (t == null) continue;
      words.add(w(t.$1, colX(c) + 26, rowY[r] + 60));
      words.add(w(t.$2, colX(c) + 25, rowY[r] + 107));
    }
  }
  words.add(w(total ?? '7:${sum ~/ 60}:${(sum % 60).toString().padLeft(2, '0')}', 556, 1605, 365));
  words.add(w('0', 146, 1891, 37)); // 下のタブのアイコン
  return OcrPage(withWidth ? width : 0, 2000, words);
}

DateTime at(int day, String hm, [int addDays = 0]) {
  final p = hm.split(':');
  return DateTime(2026, 10, day + addDays, int.parse(p[0]), int.parse(p[1]));
}

void main() {
  test('読み落とし・読み違いがあっても、マス目から全部の日を正しく読む（合計も一致）', () {
    final r = parseShiftCalendarOcr(screenshot(), year: 2026, month: 10);
    expect(r.read.warnings, isEmpty, reason: '${r.read.warnings}');
    expect(r.totalMatched, isTrue);
    expect(r.year, 2026);
    expect(r.month, 10);
    final c = r.read.candidates;
    expect(c.map((x) => x.date.day).toList(), fake.keys.toList()..sort());
    for (final e in fake.entries) {
      final s = c.firstWhere((x) => x.date.day == e.key);
      expect(s.start, at(e.key, e.value.$1), reason: '${e.key}日の開始');
      expect(s.end, at(e.key, e.value.$2), reason: '${e.key}日の終了');
      expect(s.needsBreak, isTrue, reason: '休憩はこの画面に無い（0分と決めつけない）');
    }
  });

  test('違う月を選んでいても、日付の並びが合う月に読み替えて知らせる', () {
    final r = parseShiftCalendarOcr(screenshot(), year: 2026, month: 11);
    expect(r.month, 10);
    expect(r.read.candidates.first.date, DateTime(2026, 10, 2));
    expect(r.read.warnings.single, contains('2026年10月として読みました'));
  });

  test('時刻が1つ読めなかったマスは警告し、合計の食い違いでも知らせる', () {
    final page = screenshot();
    final words = [...page.words]..removeWhere((x) => x.text == '15:30'); // 11日の終了
    final r = parseShiftCalendarOcr(OcrPage(width, 2000, words), year: 2026, month: 10);
    expect(r.totalMatched, isFalse);
    expect(r.read.warnings.first, contains('画面の合計'));
    expect(r.read.warnings.join(), contains('11日：時刻が1つしか'));
    expect(r.read.candidates.any((x) => x.date.day == 11), isFalse);
  });

  test('画像の幅が分からなくても、日付の数字の間隔から列を決める', () {
    final r = parseShiftCalendarOcr(screenshot(withWidth: false), year: 2026, month: 10);
    expect(r.read.candidates, hasLength(fake.length));
    expect(r.totalMatched, isTrue);
  });

  test('日をまたぐ勤務（22:00〜5:00）は翌日の終わりにする', () {
    final r = parseShiftCalendarOcr(screenshot(s: {8: ('22:00', '5:00')}), year: 2026, month: 10);
    final c = r.read.candidates.single;
    expect(c.start, at(8, '22:00'));
    expect(c.end, at(8, '5:00', 1));
    expect(r.totalMatched, isTrue);
  });

  test('前の月（灰色の日）に書かれた時刻は、この月のシフトにしない', () {
    final page = screenshot();
    final words = [...page.words, w('9:00', colX(2) + 26, rowY[0] + 60), w('12:00', colX(2) + 25, rowY[0] + 107)];
    final r = parseShiftCalendarOcr(OcrPage(width, 2000, words), year: 2026, month: 10);
    expect(r.read.candidates, hasLength(fake.length));
  });

  test('日付や時刻が読めなければ、何も登録せずに理由を出す', () {
    final r = parseShiftCalendarOcr(OcrPage(width, 2000, [w('1752', 34, 37)]), year: 2026, month: 10);
    expect(r.read.candidates, isEmpty);
    expect(r.read.warnings.single, contains('読み取れませんでした'));
  });
}
