// 💡 予想を 1 つの行の並び（forecastMonths）から作ることの性質を確かめる。
import 'package:flutter_test/flutter_test.dart';
import 'package:my_counter_app/app_state.dart';

import 'support/rich_fixture.dart';
import 'support/test_app.dart';

void main() {
  final clocks = [
    DateTime(2026, 10, 30, 9),
    DateTime(2026, 11, 19, 10),
    DateTime(2026, 12, 20, 10),
    DateTime(2027, 1, 30, 10),
  ];

  test('予想の計算は読み取りだけ（保存・状態の変更をしない）', () async {
    final app = await richApp(DateTime(2026, 11, 19, 10));
    final before = app.exportJson().replaceAll(RegExp(r'"exportedAt": "[^"]*"'), '');
    final updatedAt = app.dataUpdatedAt;
    var notified = 0;
    app.addListener(() => notified++);
    app.forecastMonths();
    app.thisMonthBreakdown;
    app.nextMonthBreakdown;
    app.monthAfterNextBreakdown;
    app.lowestBalanceAhead();
    app.shortfallDaysAhead();
    app.pendingDraws;
    app.homeNotices;
    final after = app.exportJson().replaceAll(RegExp(r'"exportedAt": "[^"]*"'), '');
    expect(after, before);
    expect(app.dataUpdatedAt, updatedAt);
    expect(notified, 0);
  });

  for (final c in clocks) {
    test('内訳の合計・日ごとの積み上げが月末と一致する（$c）', () async {
      final app = await richApp(c);
      final months = app.forecastMonths();
      final ends = [app.thisMonthBalance, app.nextMonthBalance, app.monthAfterNextBalance];
      final breakdowns = [
        app.thisMonthBreakdown,
        app.nextMonthBreakdown,
        app.monthAfterNextBreakdown,
      ];
      for (var i = 0; i < 3; i++) {
        expect(months[i].end, ends[i]);
        // 今月の内訳は「現在の残高」から始まり、デビットと財布を含めて月末になる
        expect(breakdowns[i].values.fold<int>(0, (s, v) => s + v), ends[i]);
        if (i > 0) expect(months[i].start, months[i - 1].end);
      }
    });
  }

  test('同じ日・同じ名前の予定支出が2件あっても、内訳で上書きされない（B6）', () async {
    final app = await fixedApp(DateTime(2026, 11, 19, 10));
    app.currentBalance = 50000;
    app.plannedExpenses.addAll([
      PlannedExpense(id: 'a', title: '飲み会', amount: 3000, date: DateTime(2026, 11, 28)),
      PlannedExpense(id: 'b', title: '飲み会', amount: 4000, date: DateTime(2026, 11, 28)),
    ]);
    expect(app.thisMonthBalance, 43000);
    final b = app.thisMonthBreakdown;
    expect(b['飲み会（11/28）'], -7000); // 以前は -4000（1件ぶん消えていた）
    expect(b.values.fold<int>(0, (s, v) => s + v), 43000);
  });

  test('確からしさ: 銀行確定のカードは確定、利用通知だけなら見込み、定期は予定', () async {
    final app = await richApp(DateTime(2026, 11, 19, 10));
    final nov = app.forecastMonths()[0].lines;
    final olive = nov.firstWhere((l) => l.label == '三井OLIVE');
    expect(olive.certainty, Certainty.confirmed); // 11/26 の銀行確定がある
    final rakuten = nov.firstWhere((l) => l.label == '楽天カード');
    expect(rakuten.certainty, Certainty.estimated);
    expect(nov.where((l) => l.label.startsWith('定期:')).map((l) => l.certainty).toSet(),
        {Certainty.scheduled});
    expect(Certainty.scheduled.label, '見込み'); // 画面は 2 段階
    expect(Certainty.confirmed.label, '確定');
  });
}
