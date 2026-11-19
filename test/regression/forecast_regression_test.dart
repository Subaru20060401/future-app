// 💡 回帰テスト: 構造を直しても予想・集計の出力が変わらないことを確かめる。
//   ⚠️ 期待値（forecast_snapshot.json）は「記録した時点の実装の出力」。正しさの根拠ではない。
//     正しさは手計算のテスト（forecast_hand_calc_test.dart など）で確かめる。
//   ⚠️ 計算を意図して変えたときだけ、次で記録し直し、変わった項目と理由をコミットに書く:
//     flutter test test/regression --dart-define=UPDATE_SNAPSHOT=true
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_counter_app/app_state.dart';

import '../support/rich_fixture.dart';

String _d(DateTime d) => d.toIso8601String().substring(0, 10);

Map<String, Object?> snapshotOf(AppState app) {
  final now = app.clockNow();
  final months = [for (var i = -2; i <= 2; i++) DateTime(now.year, now.month + i)];
  String ym(DateTime m) => '${m.year}-${m.month.toString().padLeft(2, '0')}';
  final lowest = app.lowestBalanceAhead();
  return {
    'balances': {
      'this': app.thisMonthBalance,
      'next': app.nextMonthBalance,
      'after': app.monthAfterNextBalance,
      'effective': app.effectiveBalance,
    },
    'breakdowns': {
      'this': app.thisMonthBreakdown,
      'next': app.nextMonthBreakdown,
      'after': app.monthAfterNextBreakdown,
    },
    'cashEvents': [
      for (final e in app.cashEventsAhead()) '${_d(e.date)} ${e.label} ${e.amount}',
    ],
    'lowest': lowest == null ? null : '${_d(lowest.date)} ${lowest.balance}',
    'shortfalls': [
      for (final s in app.shortfallDaysAhead()) '${_d(s.date)} ${s.balance} ${s.labels.join('/')}',
    ],
    'pendingDraws': [
      for (final d in app.pendingDraws) '${d.id} ${d.label} ${d.amount} ${_d(d.date)}',
    ],
    'months': {
      for (final m in months)
        ym(m): {
          'expense': {for (final e in app.expenseBreakdownOf(m)) e.label: e.amount},
          'expenseDetail': {
            for (final e in app.expenseBreakdownOf(m))
              e.label: [
                for (final x in app.expenseDetailOf(m, e.label)) '${x.title}|${x.subtitle}|${x.amount}',
              ],
          },
          'draw': {for (final e in app.drawBreakdownOf(m)) e.label: e.amount},
          'drawDates': {
            for (final e in app.drawBreakdownOf(m)) e.label: _d(app.drawDateOf(e.label, m)),
          },
          'income': {for (final e in app.incomeBreakdownOf(m)) e.label: e.amount},
          'incomeForecast': app.incomeForecastIn(m),
          'oneTime': [
            for (final e in app.oneTimeExpensesIn(m)) '${_d(e.date)} ${e.label} ${e.amount}',
          ],
        },
    },
    'years': {
      for (final y in [2026, 2027])
        '$y': {
          'salary': app.salaryOfYear(y),
          'expense': app.expenseOfYear(y),
        },
    },
  };
}

void main() {
  const update = bool.fromEnvironment('UPDATE_SNAPSHOT');
  final file = File('test/regression/forecast_snapshot.json');
  // 💡 月末が休み、年末年始、月の途中など、通る道が変わる日を選ぶ
  final clocks = [
    DateTime(2026, 10, 30, 9), // 金。10/31 が土曜（月末払いが翌月へずれる）
    DateTime(2026, 11, 19, 10),
    DateTime(2026, 12, 20, 10),
    DateTime(2027, 1, 5, 10), // 年明け
    DateTime(2027, 1, 30, 10),
  ];

  test('予想・集計の出力が記録と一致する（回帰）', () async {
    final actual = <String, Object?>{};
    for (final c in clocks) {
      final app = await richApp(c);
      actual[c.toIso8601String()] = snapshotOf(app);
    }
    final encoded = const JsonEncoder.withIndent('  ').convert(actual);
    if (update || !file.existsSync()) {
      file.writeAsStringSync('$encoded\n');
      markTestSkipped('記録し直した: ${file.path}');
      return;
    }
    final expected = jsonDecode(file.readAsStringSync());
    final now = jsonDecode(encoded);
    for (final c in clocks) {
      final k = c.toIso8601String();
      expect(now[k], expected[k], reason: '時刻 $k の出力が記録と違う');
    }
  });
}
