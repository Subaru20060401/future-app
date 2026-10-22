import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:provider/provider.dart';
import '../app_state.dart';
import '../widgets/legend_dot.dart';
import '../card_styles.dart';
import '../money_format.dart';

// 💡 月々の収入(給与)と支出を棒グラフで振り返る。横スクロールで過去に遡れる。
class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();

    // 表示する月（過去24か月〜今月）
    final now = DateTime(DateTime.now().year, DateTime.now().month);
    final months = List.generate(24, (i) => DateTime(now.year, now.month - 23 + i));

    final incomes = months.map((m) => appState.salaryOf(m)).toList();
    final expenses = months.map((m) => appState.monthlyExpenseOf(m)).toList();
    final maxV = [
      ...incomes,
      ...expenses,
      10000,
    ].reduce((a, b) => a > b ? a : b).toDouble() * 1.2;

    // 各月の支出をカード色＋定期/分割/ATMのセグメントに分解
    List<({Color color, int value})> segmentsOf(DateTime m) {
      return [
        for (final e in appState.cardChargesOf(m).entries)
          (color: cardColorOf(e.key), value: e.value),
        if (appState.subscriptionTotal > 0) (color: Colors.purple, value: appState.subscriptionTotal),
        if (appState.installmentTotal > 0) (color: Colors.deepOrange, value: appState.installmentTotal),
        if (appState.withdrawalsOf(m) > 0) (color: Colors.brown, value: appState.withdrawalsOf(m)),
      ];
    }

    List<BarChartRodStackItem> stackOf(DateTime m) {
      final items = <BarChartRodStackItem>[];
      double from = 0;
      for (final s in segmentsOf(m)) {
        items.add(BarChartRodStackItem(from, from + s.value, s.color));
        from += s.value;
      }
      return items;
    }

    // 凡例用: 期間内に登場するカード名
    final cardsInRange = <String>{};
    for (final m in months) {
      cardsInRange.addAll(appState.cardChargesOf(m).keys);
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
                const LegendDot(color: Colors.green, label: '収入(給与)'),
                ...cardsInRange.map((c) => LegendDot(color: cardColorOf(c), label: c)),
                const LegendDot(color: Colors.purple, label: '定期'),
                const LegendDot(color: Colors.deepOrange, label: '分割'),
                const LegendDot(color: Colors.brown, label: 'ATM'),
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
                            rodStackItems: stackOf(months[i]), // カード色で積み上げ
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
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('$y年', style: const TextStyle(fontWeight: FontWeight.bold)),
                        Text('年収 ¥${yenNum(appState.salaryOfYear(y))}',
                            style: const TextStyle(color: Colors.green)),
                        Text('支出 ¥${yenNum(appState.cardSpendingOfYear(y))}',
                            style: const TextStyle(color: Colors.red)),
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

