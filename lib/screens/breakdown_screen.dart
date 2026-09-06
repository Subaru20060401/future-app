import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:provider/provider.dart';
import '../app_state.dart';
import '../widgets/app_sheet.dart';

typedef BreakdownItem = ({String label, int amount, int colorValue});
typedef DetailRow = ({String title, String subtitle, int amount});

// 月ごとの内訳を円グラフ＋凡例で表示する汎用画面。収入・支出で共用。
class BreakdownScreen extends StatefulWidget {
  final String title;
  final String totalLabel; // 例: 「収入合計」「支出合計」
  final Color accent;
  // 指定月の内訳（金額降順）を返す関数
  final List<BreakdownItem> Function(AppState, DateTime) builder;
  // 円グラフ中央のラベル（例: 「年収」「年支出」）と、その年の金額を返す関数
  final String centerLabel;
  final int Function(AppState, int year) yearValueBuilder;
  // 合計の下に表示する追加情報（収入画面の総労働時間・給料見込み・実給料など）
  final Widget Function(BuildContext, AppState, DateTime)? subInfoBuilder;
  // カテゴリ（ラベル）をタップしたときの個々の明細。null なら詳細を出さない。
  final List<DetailRow> Function(AppState, DateTime, String label)? detailBuilder;
  // 凡例の各行に、ラベル下のサブ情報（例: 勤務先の総労働時間）を表示する。null なら出さない。
  final String? Function(AppState, DateTime, String label)? legendSubBuilder;

  const BreakdownScreen({
    super.key,
    required this.title,
    required this.totalLabel,
    required this.accent,
    required this.builder,
    required this.centerLabel,
    required this.yearValueBuilder,
    this.subInfoBuilder,
    this.detailBuilder,
    this.legendSubBuilder,
  });

  @override
  State<BreakdownScreen> createState() => _BreakdownScreenState();
}

class _BreakdownScreenState extends State<BreakdownScreen> {
  late DateTime _month;
  int? _touchedIndex;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = DateTime(now.year, now.month);
  }

  void _shiftMonth(int delta) {
    setState(() {
      _month = DateTime(_month.year, _month.month + delta);
      _touchedIndex = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final items = widget.builder(appState, _month);
    final total = items.fold<int>(0, (s, e) => s + e.amount);

    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 月セレクタ
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                  onPressed: () => _shiftMonth(-1), icon: const Icon(Icons.chevron_left)),
              Text('${_month.year}年${_month.month}月',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              IconButton(
                  onPressed: () => _shiftMonth(1), icon: const Icon(Icons.chevron_right)),
            ],
          ),
          const SizedBox(height: 8),
          // 合計
          Center(
            child: Column(
              children: [
                Text(widget.totalLabel,
                    style: const TextStyle(fontSize: 13, color: Colors.grey)),
                Text('¥ $total',
                    style: TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.bold,
                        color: widget.accent)),
              ],
            ),
          ),
          // 追加情報（収入: 総労働時間・給料見込み・実給料）
          if (widget.subInfoBuilder != null) ...[
            const SizedBox(height: 12),
            widget.subInfoBuilder!(context, appState, _month),
          ],
          const SizedBox(height: 16),
          if (items.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 60),
              child: Center(
                  child: Text('この月のデータはありません',
                      style: TextStyle(color: Colors.grey))),
            )
          else ...[
            // 円グラフ（中央に年収/年支出を表示）
            SizedBox(
              height: 240,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  PieChart(
                    PieChartData(
                      sectionsSpace: 2,
                      centerSpaceRadius: 72,
                      pieTouchData: PieTouchData(
                        touchCallback: (event, response) {
                          setState(() {
                            _touchedIndex =
                                response?.touchedSection?.touchedSectionIndex;
                          });
                        },
                      ),
                      sections: [
                        for (var i = 0; i < items.length; i++)
                          _section(items[i], total, i == _touchedIndex),
                      ],
                    ),
                  ),
                  // 中央のドーナツ穴に年間値を表示
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(widget.centerLabel,
                          style: const TextStyle(fontSize: 12, color: Colors.grey)),
                      const SizedBox(height: 2),
                      Text('¥${widget.yearValueBuilder(appState, _month.year)}',
                          style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: widget.accent)),
                      Text('${_month.year}年', style: const TextStyle(fontSize: 10, color: Colors.grey)),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            // 凡例（金額・割合）。タップで個々の明細を表示。
            if (widget.detailBuilder != null)
              const Padding(
                padding: EdgeInsets.only(left: 4, bottom: 4),
                child: Text('項目をタップで明細',
                    style: TextStyle(fontSize: 11, color: Colors.grey)),
              ),
            ...items.map((e) {
              final pct = total > 0 ? (e.amount / total * 100) : 0;
              final tappable = widget.detailBuilder != null;
              return InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: tappable ? () => _showDetail(appState, e) : null,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                  child: Row(
                    children: [
                      Container(
                          width: 14,
                          height: 14,
                          decoration: BoxDecoration(
                              color: Color(e.colorValue), shape: BoxShape.circle)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Builder(builder: (_) {
                          final sub = widget.legendSubBuilder?.call(appState, _month, e.label);
                          if (sub == null || sub.isEmpty) return Text(e.label);
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(e.label),
                              Text(sub, style: const TextStyle(fontSize: 11, color: Colors.grey)),
                            ],
                          );
                        }),
                      ),
                      Text('¥${e.amount}',
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 40,
                        child: Text('${pct.toStringAsFixed(0)}%',
                            textAlign: TextAlign.right,
                            style: const TextStyle(fontSize: 12, color: Colors.grey)),
                      ),
                      if (tappable)
                        const Icon(Icons.chevron_right, size: 18, color: Colors.grey),
                    ],
                  ),
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  // カテゴリをタップ → 個々の明細をボトムシートで表示
  void _showDetail(AppState appState, BreakdownItem e) {
    final rows = widget.detailBuilder!(appState, _month, e.label);
    showAppSheet(context, dragHandle: true, (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  Container(
                      width: 14,
                      height: 14,
                      decoration:
                          BoxDecoration(color: Color(e.colorValue), shape: BoxShape.circle)),
                  const SizedBox(width: 10),
                  Text('${e.label}（${_month.month}月）',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  Text('¥${e.amount}',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold, color: widget.accent)),
                ],
              ),
            ),
            // 💡 カードの中で分割払いがどれくらいを占めるか（1段下の内訳）。
            //   分割は独立した引き落としではなくカードの請求に含まれるため、
            //   カテゴリを分けずにここで割合を見せる。
            if (appState.installmentTotalByCardOf(_month)[e.label] != null &&
                e.amount > 0)
              Builder(builder: (_) {
                final part = appState.installmentTotalByCardOf(_month)[e.label]!;
                final pct = (part * 100 / e.amount).round();
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text('うち分割払い（$pct%）',
                            style: TextStyle(
                                fontSize: 12, color: Colors.deepOrange[700])),
                      ),
                      Text('¥$part',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Colors.deepOrange[700])),
                    ],
                  ),
                );
              }),
            const Divider(height: 1),
            Flexible(
              child: rows.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('明細はありません', style: TextStyle(color: Colors.grey)))
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: rows.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final r = rows[i];
                        return ListTile(
                          dense: true,
                          title: Text(r.title),
                          subtitle: r.subtitle.isNotEmpty ? Text(r.subtitle) : null,
                          trailing: Text('¥${r.amount}',
                              style: const TextStyle(fontWeight: FontWeight.bold)),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  PieChartSectionData _section(BreakdownItem item, int total, bool touched) {
    final pct = total > 0 ? item.amount / total * 100 : 0;
    return PieChartSectionData(
      value: item.amount.toDouble(),
      color: Color(item.colorValue),
      title: pct >= 6 ? '${pct.toStringAsFixed(0)}%' : '',
      radius: touched ? 70 : 60,
      titleStyle: const TextStyle(
          fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
    );
  }
}
