// 💡 カレンダー形式のシフト画面（ジョブカンの「確定シフト」など）のスクリーンショットを、
//   端末の中の文字読み取り（OCR）の結果からシフトの候補にする（AIを使わない。画像はどこにも送らない）。
//   OCR は数字と「:」だけを、位置（枠）つきで返す。
// ⚠️ 実際の画面で試すと（2026-10-25）、時刻はほぼ正確に読めるが、日付の数字は
//   灰色の日・「1」「3」「7」を読み落としたり、「11」を「1」と読んだりした。
//   そこで日付の数字は1つずつ信じず、カレンダーの「マス目」から日付を決める:
//   ・列 … 横の位置（画面の幅を7等分）
//   ・行 … 読めた日付の数字が並ぶ高さ
//   ・日付 … 行×7＋列 − 「1日が何列目か」。1日の列は、読めた日付の数字の多数決で決める
//     （読み違えた「1」などは多数決で負ける）
// ⚠️ 推測で埋めない。時刻が1つしか無いマスは警告。画面の「シフト合計時間」が読めたら、
//   読み取った合計と比べる。休憩はこの画面に無いので未確定のまま（確認画面で本人が入れる）。
import 'shift_image_import.dart';

class OcrWord {
  final String text;
  final double x0, y0, x1, y1;
  const OcrWord(this.text, this.x0, this.y0, this.x1, this.y1);
  double get cy => (y0 + y1) / 2;
  double get h => y1 - y0;
}

// 読み取り結果1枚ぶん（width は画像の幅。0なら不明）
class OcrPage {
  final double width;
  final double height;
  final List<OcrWord> words;
  const OcrPage(this.width, this.height, this.words);
}

class CalendarOcrResult {
  final ShiftReadResult read;
  final int year;
  final int month;
  // 画面の「シフト合計時間」と読み取った合計が一致したか（合計が読めなければ null）
  final bool? totalMatched;
  const CalendarOcrResult(this.read, this.year, this.month, [this.totalMatched]);
}

final _timeRe = RegExp(r'^(\d{1,2})[:.](\d{2})$');
final _dayRe = RegExp(r'^\d{1,2}$');
final _totalRe = RegExp(r'(\d{1,3})[:.](\d{2})$');

int? _clockOf(String t) {
  final m = _timeRe.firstMatch(t);
  if (m == null) return null;
  final mi = int.parse(m.group(2)!);
  if (mi > 59) return null;
  return int.parse(m.group(1)!) * 60 + mi;
}

double _median(List<double> v) {
  if (v.isEmpty) return 0;
  final s = [...v]..sort();
  return s[s.length ~/ 2];
}

String _hm(int m) => '${m ~/ 60}:${(m % 60).toString().padLeft(2, '0')}';

CalendarOcrResult parseShiftCalendarOcr(OcrPage page, {required int year, required int month}) {
  // ⚠️ 画面の並びと合わないとき、下で前後の月に読み替えることがある
  final warnings = <String>[];
  final words = [
    for (final w in page.words)
      if (w.text.trim().isNotEmpty) OcrWord(w.text.trim(), w.x0, w.y0, w.x1, w.y1)
  ];
  CalendarOcrResult fail(String why) =>
      CalendarOcrResult(ShiftReadResult(const [], [why]), year, month);

  // ── 見出し（「2026年 10月度」は「20265108」のように読まれる）。見出しより上は読まない ──
  var top = double.negativeInfinity;
  final heads = words.where((w) => RegExp(r'^20\d\d').hasMatch(w.text)).toList()
    ..sort((a, b) => a.y0.compareTo(b.y0));
  if (heads.isNotEmpty) {
    top = heads.first.y1;
    final hy = int.parse(heads.first.text.substring(0, 4));
    if (hy != year) {
      warnings.add('画面の見出しは$hy年のようです。選んだ年（$year年）を確かめてください');
    }
  }

  // ── 時刻と、日付の数字（1〜31）を分ける ──
  final times = <({OcrWord w, int min})>[];
  final dayWords = <OcrWord>[];
  for (final w in words) {
    if (w.y0 <= top) continue;
    final c = _clockOf(w.text);
    if (c != null) {
      times.add((w: w, min: c));
    } else if (_dayRe.hasMatch(w.text)) {
      final d = int.parse(w.text);
      if (d >= 1 && d <= 31) dayWords.add(w);
    }
  }
  if (dayWords.isEmpty || times.isEmpty) {
    return fail('カレンダーの日付や時刻が読み取れませんでした。シフトの画面全体が入るように撮ってください');
  }

  // ── 行（日付の数字が並ぶ高さ）を見つける ──
  final tol = _median([for (final d in dayWords) d.h]) * 1.2;
  dayWords.sort((a, b) => a.cy.compareTo(b.cy));
  final rowYs = <List<double>>[];
  for (final d in dayWords) {
    if (rowYs.isNotEmpty && (d.cy - rowYs.last.first).abs() <= tol) {
      rowYs.last.add(d.cy);
    } else {
      rowYs.add([d.cy]);
    }
  }
  var rows = [for (final r in rowYs) _median(r)];
  // 行の間隔（カレンダーのマスの高さ）。間隔が大きく外れる行（画面の下のアイコンなど）は外す
  final gaps = [for (var i = 1; i < rows.length; i++) rows[i] - rows[i - 1]];
  final cellH = gaps.isEmpty ? 170.0 : _median(gaps);
  final kept = <double>[rows.first];
  for (var i = 1; i < rows.length; i++) {
    if (rows[i] - kept.last > cellH * 1.5) break;
    kept.add(rows[i]);
  }
  rows = kept;

  // ── 列（画面の幅を7等分。幅が分からなければ日付の数字の間隔から） ──
  double colW;
  if (page.width > 0) {
    colW = page.width / 7;
  } else {
    final xs = [for (final d in dayWords) d.x0]..sort();
    final g = [for (var i = 1; i < xs.length; i++) xs[i] - xs[i - 1]]..removeWhere((v) => v < 20);
    colW = g.isEmpty ? 130 : g.reduce((a, b) => a < b ? a : b);
  }
  int colOf(OcrWord w) => (w.x0 / colW).floor().clamp(0, 6);
  int? rowOf(double y, {required bool below}) {
    for (var r = rows.length - 1; r >= 0; r--) {
      final dy = y - rows[r];
      if (below ? (dy > 0 && dy < cellH) : dy.abs() <= tol) return r;
    }
    return null;
  }

  // ── 「1日が何列目か」を、読めた日付の数字の多数決で決める ──
  final votes = <int, int>{};
  for (final d in dayWords) {
    final r = rowOf(d.cy, below: false);
    if (r == null) continue;
    final offset = r * 7 + colOf(d) + 1 - int.parse(d.text);
    if (offset < 0 || offset > 6) continue; // 前の月の灰色の日・読み違い
    votes[offset] = (votes[offset] ?? 0) + 1;
  }
  if (votes.isEmpty) return fail('カレンダーの日付の並びが読み取れませんでした');
  final offset = votes.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  // 💡 選んだ月の1日の曜日と、画面の並び（1日の列）が合うか。日曜はじまり・月曜はじまりのどちらでもよい。
  //   合わなければ、前後の月で合うものを探して読み直す（違う月のまま読むと、日付が全部ずれる）
  bool fits(DateTime m) {
    final wd = m.weekday; // 1=月..7=日
    return offset == wd % 7 || offset == wd - 1;
  }
  final chosen = DateTime(year, month);
  if (!fits(chosen)) {
    final alt = [1, -1, 2].map((d) => DateTime(year, month + d)).where(fits).firstOrNull;
    if (alt == null) {
      warnings.add('選んだ年月（$year年$month月）と、画面の日付の並びが合いません。年月を確かめてください');
    } else {
      warnings.add('選んだ$month月とは日付の並びが合わないので、${alt.year}年${alt.month}月として読みました。違っていたら年月を選び直してください');
      year = alt.year;
      month = alt.month;
    }
  }

  // ── 時刻を、その上の行・同じ列のマスへ入れる ──
  final lastDay = DateTime(year, month + 1, 0).day;
  final cells = <int, List<({OcrWord w, int min})>>{};
  ({OcrWord w, int min})? total; // 画面の「シフト合計時間」
  final gridBottom = rows.last + cellH;
  for (final t in times) {
    if (t.w.cy > gridBottom) continue;
    final r = rowOf(t.w.cy, below: true);
    if (r == null) continue;
    final day = r * 7 + colOf(t.w) + 1 - offset;
    if (day < 1 || day > lastDay) continue; // 前後の月
    cells.putIfAbsent(day, () => []).add(t);
  }
  for (final w in words) {
    if (w.cy <= gridBottom) continue;
    final m = _totalRe.firstMatch(w.text); // 「7:58:00」のように前に字が付くことがある
    if (m != null) {
      total = (w: w, min: int.parse(m.group(1)!) * 60 + int.parse(m.group(2)!));
      break;
    }
  }

  // ── マスごとに「開始・終了」の組にする ──
  final out = <ShiftCandidate>[];
  var sum = 0;
  for (final day in cells.keys.toList()..sort()) {
    final ts = cells[day]!..sort((a, b) => a.w.y0.compareTo(b.w.y0));
    if (ts.length.isOdd) {
      warnings.add('$day日：時刻が${ts.length}つしか読めませんでした。画像と見比べて入れてください');
    }
    for (var i = 0; i + 1 < ts.length; i += 2) {
      final date = DateTime(year, month, day);
      final start = date.add(Duration(minutes: ts[i].min));
      var end = date.add(Duration(minutes: ts[i + 1].min));
      if (!end.isAfter(start)) end = end.add(const Duration(days: 1)); // 日をまたぐ
      if (end.difference(start).inHours > 16) {
        warnings.add('$day日：16時間を超えるので外しました（読み違いの可能性）');
        continue;
      }
      sum += end.difference(start).inMinutes;
      out.add(ShiftCandidate(date: date, start: start, end: end, breakMinutes: null));
    }
  }
  if (total != null && total.min != sum) {
    warnings.insert(0,
        '画面の合計（${_hm(total.min)}）と、読み取った合計（${_hm(sum)}）が違います。読み落とし・読み違いが無いか画像と見比べてください');
  }
  if (out.isEmpty) warnings.add('シフトの時刻が読み取れませんでした');
  return CalendarOcrResult(
      ShiftReadResult(out, warnings), year, month, total == null ? null : total.min == sum);
}
