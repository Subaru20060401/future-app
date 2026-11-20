// 💡 残高の予想の「形」と、行の並びだけで決まる計算（純粋関数）。
//   ・予想の行（ForecastLine）は AppState.forecastMonths が作る。ここは受け取った行を
//     足し合わせる・並べる・谷を探すだけで、規則（何をいつ引くか）は持たない
//   ・月末の金額・内訳・日ごとの並び・最低残高・足りなくなる日は、すべて同じ行から作る。
//     ⚠️ 以前は「起点＋入金−引き落とし−一度きり」の式が 7 か所にあり、直すたびに
//       そろえる必要があった（docs/survey.md）。式はここ（MonthForecast.end）だけに置く
//   ・DateTime.now() を読まない。今日は引数で受け取る

/// 確からしさ。画面では「確定」と「見込み」の 2 段階で見せる（scheduled は見込みに含める）。
/// ⚠️ 「支払済み」「残高に反映済み」「確認待ち」は別の状態で、ここでは扱わない。
enum Certainty {
  confirmed, // 確定: 銀行の引落確定・入力した実給料
  scheduled, // 予定: 自分で登録した定期・ローン・予定の入出金、メールで分かった出金
  estimated, // 見込み: シフトからの推定給料、利用通知・請求予定からの推定
}

extension CertaintyLabel on Certainty {
  /// 画面に出す言葉（2 段階）
  String get label => this == Certainty.confirmed ? '確定' : '見込み';
}

enum ForecastKind { income, transfer, draw, oneTime }

/// 予想の 1 行。入金は +、出金は −。
class ForecastLine {
  final ForecastKind kind;
  final String label; // 日ごとの並びに出す名前（例: カフェ、定期: スマホ）
  final String group; // 月の内訳でまとめる名前（例: 給料入金、定期支払い）
  final int amount;
  final DateTime date; // 入金日・引落日（その日の 0 時）
  final Certainty certainty;
  // 💡 請求の月を判定できない銀行確定が関わる行（金額が二重・抜けの可能性があり、利用者の確認が要る）
  final bool needsReview;

  const ForecastLine({
    required this.kind,
    required this.label,
    required this.group,
    required this.amount,
    required this.date,
    required this.certainty,
    this.needsReview = false,
  });
}

/// ひと月ぶんの予想。起点に行を足したものが月末。
class MonthForecast {
  final DateTime month; // その月の 1 日
  final int start; // 起点（今月は「残高−未反映デビット＋財布」、翌月以降は前月末）
  final List<ForecastLine> lines;

  const MonthForecast({required this.month, required this.start, required this.lines});

  int get end => start + lines.fold(0, (s, l) => s + l.amount);
  int get incomeTotal => lines.where((l) => l.amount > 0).fold(0, (s, l) => s + l.amount);
  int get outgoTotal => lines.where((l) => l.amount < 0).fold(0, (s, l) => s - l.amount);

  /// 内訳（group ごとに合計。行の順に並べ、合計 0 の group は出さない）。
  /// 💡 同じ名前の行は上書きせずに足す（以前の Map 版は同じ名前の予定支出が 1 件ぶん消えた）。
  List<({String group, int amount})> grouped() {
    final order = <String>[];
    final sum = <String, int>{};
    for (final l in lines) {
      if (!sum.containsKey(l.group)) order.add(l.group);
      sum[l.group] = (sum[l.group] ?? 0) + l.amount;
    }
    return [
      for (final g in order)
        if (sum[g] != 0) (group: g, amount: sum[g]!),
    ];
  }
}

/// 日付順の行（同じ日の順は作った順のまま）。
List<ForecastLine> linesByDate(Iterable<MonthForecast> months) {
  final all = [for (final m in months) ...m.lines];
  // ⚠️ List.sort は安定ソートではない。同じ日の並びが変わらないよう、元の順番を第2キーにする
  final indexed = [for (var i = 0; i < all.length; i++) (i, all[i])];
  indexed.sort((a, b) {
    final c = a.$2.date.compareTo(b.$2.date);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$2];
}

/// 今日から先で、残高がいちばん少なくなる日とそのときの残高。
///   同じ日の入金と引き落としは相殺してから見る。今日より前の日付の行（残高の基準日より後で、
///   まだ反映していないもの）は今の残高に織り込むが、谷の候補にはしない。
///   今この時点の残高も候補にする（入金が先に来るとき、入金後の額を最低と出さないため）。
({DateTime date, int balance})? lowestBalance({
  required int start,
  required List<ForecastLine> events,
  required DateTime today,
}) {
  if (events.isEmpty) return null;
  final day = DateTime(today.year, today.month, today.day);
  var running = start;
  var i = 0;
  while (i < events.length && events[i].date.isBefore(day)) {
    running += events[i].amount;
    i++;
  }
  var low = running;
  var lowDate = day;
  while (i < events.length) {
    final date = events[i].date;
    while (i < events.length && events[i].date == date) {
      running += events[i].amount;
      i++;
    }
    if (running < low) {
      low = running;
      lowDate = date;
    }
  }
  return (date: lowDate, balance: low);
}

/// 残高が足りなくなる日と、その日の引き落とし。
///   ⚠️ 引き落としがある日だけ。入金だけの日は「引き落としに足りない日」ではない。
List<({DateTime date, int balance, List<String> labels})> shortfallDays({
  required int start,
  required List<ForecastLine> events,
  required DateTime today,
}) {
  final day = DateTime(today.year, today.month, today.day);
  var running = start;
  final out = <({DateTime date, int balance, List<String> labels})>[];
  var i = 0;
  while (i < events.length) {
    final date = events[i].date;
    final draws = <String>[];
    while (i < events.length && events[i].date == date) {
      running += events[i].amount;
      if (events[i].amount < 0) draws.add(events[i].label);
      i++;
    }
    if (date.isBefore(day)) continue; // 今の残高に織り込み済み
    if (running < 0 && draws.isNotEmpty) {
      out.add((date: date, balance: running, labels: draws));
    }
  }
  return out;
}
