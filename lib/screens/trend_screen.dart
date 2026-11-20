import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:provider/provider.dart';
import '../app_state.dart';
import '../money_format.dart';
import '../ui/tokens.dart';

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
    // 💡 増減は記号と言葉で示す（色だけにしない）。⚠️ 以前はマイナスが「¥-5,000」になっていた
    String diffLabel(int cur, int prev) {
      final d = cur - prev;
      final word = d > 0 ? '前月より多い' : (d < 0 ? '前月より少ない' : '前月と同じ');
      if (prev == 0) return '$word ${yen(d, signed: true)}';
      final pct = (d / prev * 100).round();
      return '$word ${yen(d, signed: true)}（${pct > 0 ? '+' : (pct < 0 ? '−' : '')}${pct.abs()}%）';
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
                      AppColors.income, cur.income >= prev.income),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _diffCard('支出（前月比）', cur.expense, diffLabel(cur.expense, prev.expense),
                      AppColors.expense, cur.expense <= prev.expense),
                ),
              ],
            ),
          const SizedBox(height: 16),
          const Text('過去6か月の推移', style: AppText.title),
          const Text('収入はシフトからの給与の見込み、支出は利用月の支出（月ごとの支出詳細と同じ）',
              style: AppText.caption),
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
                              style: const TextStyle(fontSize: 12)),
                        );
                      },
                    ),
                  ),
                ),
                lineBarsData: [
                  _line(spots((e) => e.income), AppColors.income),
                  // 💡 支出は点線（色が見分けにくくても線の種類で分かる）
                  _line(spots((e) => e.expense), AppColors.expense, dashed: true),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _legend('収入（実線）', AppColors.income),
              const SizedBox(width: 24),
              _legend('支出（点線）', AppColors.expense),
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
                      Text('収入 ${yen(e.income)}',
                          style: const TextStyle(color: AppColors.income, fontSize: 13)),
                      Text('支出 ${yen(e.expense)}',
                          style: const TextStyle(color: AppColors.expense, fontSize: 13)),
                    ],
                  ),
                ),
              )),
        ],
      ),
    );
  }

  LineChartBarData _line(List<FlSpot> spots, Color color, {bool dashed = false}) =>
      LineChartBarData(
        spots: spots,
        color: color,
        dashArray: dashed ? const [8, 4] : null,
        // ⚠️ 曲線で結ぶと、0円の月の前後で線がマイナスへ膨らんで見えていた（実際の値には無い）
        preventCurveOverShooting: true,
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
            Text(title, style: AppText.caption),
            const SizedBox(height: 4),
            Text(yen(value), style: AppText.amountLarge.copyWith(color: color)),
            const SizedBox(height: 2),
            Text(diff,
                style: TextStyle(
                    fontSize: 12,
                    color: good ? AppColors.income : AppColors.expense,
                    fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}
