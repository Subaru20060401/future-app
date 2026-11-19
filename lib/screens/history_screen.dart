import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:provider/provider.dart';
import '../app_state.dart';
import '../widgets/legend_dot.dart';
import '../money_format.dart';

// 💡 月々の収入(給与)と支出を棒グラフで振り返る。横スクロールで過去に遡れる。
//   支出は「利用月の支出」（AppState.expenseBreakdownOf。予想と同じ規則・残高のゲートは無し）。
//   ⚠️ 以前は別の規則（カード名で決め打ちした引落日・今月時点の分割の合計）で計算していて、
//     同じ月でも推移の画面や予想と違う金額が出ていた。
class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();

    // 表示する月（過去24か月〜今月）
    final today = appState.clockNow();
    final now = DateTime(today.year, today.month);
    final months = List.generate(24, (i) => DateTime(now.year, now.month - 23 + i));

    final incomes = months.map((m) => appState.salaryOf(m)).toList();
    final breakdowns = months.map((m) => appState.expenseBreakdownOf(m)).toList();
    final expenses = [for (final b in breakdowns) b.fold<int>(0, (s, e) => s + e.amount)];
    final maxV = [
      ...incomes,
      ...expenses,
      10000,
    ].reduce((a, b) => a > b ? a : b).toDouble() * 1.2;

    // 各月の支出を、内訳（カード・定期・ローン・分割・ATM）ごとの色で積み上げる
    List<({Color color, int value})> segmentsOf(int i) => [
          for (final e in breakdowns[i]) (color: Color(e.colorValue), value: e.amount),
        ];

    List<BarChartRodStackItem> stackOf(int i) {
      final items = <BarChartRodStackItem>[];
      double from = 0;
      for (final s in segmentsOf(i)) {
        items.add(BarChartRodStackItem(from, from + s.value, s.color));
        from += s.value;
      }
      return items;
    }

    // 凡例用: 期間内に登場する内訳（名前 → 色）
    final legend = <String, Color>{};
    for (final b in breakdowns) {
      for (final e in b) {
        legend.putIfAbsent(e.label, () => Color(e.colorValue));
      }
    }

    const barW = 56.0; // 1か月あたりの幅

    return Scaffold(
      appBar: AppBar(title: const Text('収支の履歴')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                const LegendDot(color: Colors.green, label: '収入（給与の見込み）'),
                for (final e in legend.entries) LegendDot(color: e.value, label: e.key),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true, // 初期表示を直近月に
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: SizedBox(
                width: months.length * barW,
                child: BarChart(
                  BarChartData(
                    maxY: maxV,
                    barTouchData: BarTouchData(
                      touchTooltipData: BarTouchTooltipData(
                        getTooltipItem: (group, a, rod, b) {
                          return BarTooltipItem(
                            '¥${yenNum(rod.toY.toInt())}',
                            const TextStyle(color: Colors.white, fontSize: 11),
                          );
                        },
                      ),
                    ),
                    titlesData: FlTitlesData(
                      leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 28,
                          getTitlesWidget: (value, meta) {
                            final i = value.toInt();
                            if (i < 0 || i >= months.length) return const Text('');
                            final m = months[i];
                            return Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text('${m.month}月\n${m.year % 100}',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(fontSize: 10)),
                            );
                          },
                        ),
                      ),
                    ),
                    borderData: FlBorderData(show: false),
                    barGroups: [
                      for (int i = 0; i < months.length; i++)
                        BarChartGroupData(x: i, barsSpace: 2, barRods: [
                          BarChartRodData(toY: incomes[i].toDouble(), color: Colors.green, width: 10),
                          BarChartRodData(
                            toY: expenses[i].toDouble(),
                            width: 10,
                            color: Colors.red,
                            rodStackItems: stackOf(i), // 内訳の色で積み上げ
                          ),
                        ]),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // 年間合計（年収/支出）
          if (appState.dataYears.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: appState.dataYears.map((y) {
                  final ex = appState.expenseSummaryOfYear(y);
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('$y年', style: const TextStyle(fontWeight: FontWeight.bold)),
                        const Spacer(),
                        Text('年収 ¥${yenNum(appState.salaryOfYear(y))}',
                            style: const TextStyle(color: Colors.green)),
                        const SizedBox(width: 12),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text('年間支出 ¥${yenNum(ex.total)}',
                                style: const TextStyle(color: Colors.red)),
                            // 💡 定期・分割・ローンは今の設定から計算したもの（明細の記録ではない）
                            if (ex.fromSettings > 0)
                              Text('うち設定から計算 ¥${yenNum(ex.fromSettings)}',
                                  style: const TextStyle(fontSize: 12, color: Colors.black54)),
                          ],
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
        ],
      ),
    );
  }
}

