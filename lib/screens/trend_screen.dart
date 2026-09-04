import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:provider/provider.dart';
import '../app_state.dart';

// 収入・支出の月次推移（折れ線）と前月比。
class TrendScreen extends StatelessWidget {
  const TrendScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final data = appState.monthlyTrend(6);
    final maxY = data
        .expand((e) => [e.income, e.expense])
        .fold<int>(10000, (m, v) => v > m ? v : m)
        .toDouble();

    // 前月比（最新と1つ前）
    String diffLabel(int cur, int prev) {
      final d = cur - prev;
      if (prev == 0) return d == 0 ? '±0' : '+¥$d';
      final pct = (d / prev * 100).round();
      final sign = d >= 0 ? '+' : '';
      return '$sign¥$d（$sign$pct%）';
    }

    final hasPrev = data.length >= 2;
    final cur = data.isNotEmpty ? data.last : null;
    final prev = hasPrev ? data[data.length - 2] : null;

    List<FlSpot> spots(int Function(({DateTime month, int income, int expense})) sel) =>
        [for (var i = 0; i < data.length; i++) FlSpot(i.toDouble(), sel(data[i]).toDouble())];

    return Scaffold(
      appBar: AppBar(title: const Text('収入・支出の推移')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 前月比サマリー
          if (cur != null && prev != null)
            Row(
              children: [
                Expanded(
                  child: _diffCard('収入（前月比）', cur.income, diffLabel(cur.income, prev.income),
                      Colors.green, cur.income >= prev.income),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _diffCard('支出（前月比）', cur.expense, diffLabel(cur.expense, prev.expense),
                      Colors.red, cur.expense <= prev.expense),
                ),
              ],
            ),
          const SizedBox(height: 16),
          const Text('過去6か月の推移', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          SizedBox(
            height: 260,
            child: LineChart(
              LineChartData(
                minY: 0,
                maxY: maxY * 1.2,
                gridData: const FlGridData(show: true, drawVerticalLine: false),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      interval: 1,
                      getTitlesWidget: (value, meta) {
                        final i = value.toInt();
                        if (i < 0 || i >= data.length) return const Text('');
                        return Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text('${data[i].month.month}月',
                              style: const TextStyle(fontSize: 11)),
                        );
                      },
                    ),
                  ),
                ),
                lineBarsData: [
                  _line(spots((e) => e.income), Colors.green),
                  _line(spots((e) => e.expense), Colors.red),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _legend('収入', Colors.green),
              const SizedBox(width: 24),
              _legend('支出', Colors.red),
            ],
          ),
          const SizedBox(height: 16),
          // 月別の数値リスト
          ...data.reversed.map((e) => Card(
                child: ListTile(
                  dense: true,
                  title: Text('${e.month.year}年${e.month.month}月'),
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('収入 ¥${e.income}',
                          style: const TextStyle(color: Colors.green, fontSize: 13)),
                      Text('支出 ¥${e.expense}',
                          style: const TextStyle(color: Colors.red, fontSize: 13)),
                    ],
                  ),
                ),
              )),
        ],
      ),
    );
  }

  LineChartBarData _line(List<FlSpot> spots, Color color) => LineChartBarData(
        spots: spots,
        color: color,
        isCurved: true,
        barWidth: 3,
        dotData: const FlDotData(show: true),
        belowBarData: BarAreaData(show: true, color: color.withValues(alpha: 0.08)),
      );

  Widget _legend(String label, Color color) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 12, height: 12, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(label),
        ],
      );

  Widget _diffCard(String title, int value, String diff, Color color, bool good) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 4),
            Text('¥$value', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color)),
            const SizedBox(height: 2),
            Text(diff,
                style: TextStyle(
                    fontSize: 12,
                    color: good ? Colors.green : Colors.red,
                    fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}
