import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:provider/provider.dart';
import '../app_state.dart';
import '../card_styles.dart';
import '../widgets/gmail_refresh_button.dart';
import '../widgets/deposit_dialog.dart';
import '../widgets/planned_income_sheet.dart';
import 'history_screen.dart';
import 'balance_history_screen.dart';
import 'breakdown_screen.dart';
import 'trend_screen.dart';

class IncomeScreen extends StatelessWidget {
  const IncomeScreen({super.key});

  // 編集用のダイアログを表示する関数
  void _showEditDialog(BuildContext context, String title, int currentValue, Function(int) onSave) {
    final controller = TextEditingController(text: currentValue.toString());
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('$title を編集'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: '金額(円)'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
          ElevatedButton(
            onPressed: () {
              onSave(int.tryParse(controller.text) ?? 0);
              Navigator.pop(context);
            },
            child: const Text('保存'),
          )
        ],
      ),
    );
  }

  // 目標貯金の設定ダイアログ
  Future<void> _editGoal(BuildContext context, AppState appState) async {
    final amountCtrl =
        TextEditingController(text: appState.goalAmount > 0 ? appState.goalAmount.toString() : '');
    DateTime date = appState.goalDate ?? DateTime(DateTime.now().year, DateTime.now().month + 6);
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('目標貯金の設定'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: amountCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '目標額', suffixText: '円'),
              ),
              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('目標の年月'),
                subtitle: Text('${date.year}年${date.month}月'),
                trailing: const Icon(Icons.calendar_month),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: date,
                    firstDate: DateTime(DateTime.now().year - 1),
                    lastDate: DateTime(2040, 12, 31),
                    helpText: '目標の年月を選択',
                  );
                  if (picked != null) setLocal(() => date = picked);
                },
              ),
            ],
          ),
          actions: [
            if (appState.goalAmount > 0)
              TextButton(
                onPressed: () {
                  appState.setGoal(0, null);
                  Navigator.pop(context, false);
                },
                child: const Text('目標を削除', style: TextStyle(color: Colors.red)),
              ),
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('キャンセル')),
            ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('保存')),
          ],
        ),
      ),
    );
    if (result == true) {
      appState.setGoal(int.tryParse(amountCtrl.text) ?? 0, DateTime(date.year, date.month));
    }
  }

  // 目標貯金と達成予測カード
  Widget _goalCard(BuildContext context, AppState appState) {
    final f = appState.savingsForecast();
    if (f == null) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.savings, color: Colors.pink),
          title: const Text('目標貯金を設定'),
          subtitle: const Text('いつまでにいくら貯めるか'),
          trailing: const Icon(Icons.add),
          onTap: () => _editGoal(context, appState),
        ),
      );
    }
    final ratio = (appState.currentBalance / f.goal).clamp(0.0, 1.0);
    final ok = f.achievable;
    final color = ok ? Colors.green : Colors.orange[800]!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.savings, color: Colors.pink, size: 20),
                const SizedBox(width: 6),
                Text('${f.date.year}年${f.date.month}月までに ¥${f.goal}',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.edit, size: 18),
                  onPressed: () => _editGoal(context, appState),
                ),
              ],
            ),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: ratio.toDouble(),
                minHeight: 8,
                backgroundColor: Colors.grey[200],
                color: color,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              ok
                  ? '✅ このペース（月 ¥${f.pace}）なら達成見込み（予測 ¥${f.projected}）'
                  : '⚠ このペース（月 ¥${f.pace}）では不足（予測 ¥${f.projected}）',
              style: TextStyle(fontSize: 13, color: color),
            ),
            if (f.monthsLeft > 0)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('残り${f.monthsLeft}か月・必要月額 ¥${f.requiredMonthly}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ),
          ],
        ),
      ),
    );
  }

  // 固定費（サブスク）の見直しサジェストカード
  Widget _subscriptionReviewCard(AppState appState) {
    final monthly = appState.subscriptionTotal;
    final yearly = monthly * 12;
    final subs = [...appState.subscriptions]..sort((a, b) => b.amount.compareTo(a.amount));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.subscriptions, color: Colors.purple, size: 20),
                SizedBox(width: 6),
                Text('固定費（サブスク）の見直し',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 6),
            Text('月 ¥$monthly ・ 年 ¥$yearly',
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.bold, color: Colors.purple)),
            const SizedBox(height: 6),
            ...subs.map((s) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Expanded(child: Text(s.title, style: const TextStyle(fontSize: 13))),
                      Text('¥${s.amount}/月（年¥${s.amount * 12}）',
                          style: const TextStyle(fontSize: 12, color: Colors.black54)),
                    ],
                  ),
                )),
            const SizedBox(height: 4),
            const Text('使っていないものは解約を検討しましょう。',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
      ),
    );
  }

  // 扶養・社保の「壁」までの進捗カード
  Widget _fuyouWallCard(AppState appState) {
    final year = DateTime.now().year;
    final st = appState.incomeWallStatus(year);
    final wall = st.nextWall;
    // 壁の手前5万円以内で警告色（オレンジ）、超過直前/超過はさらに強調
    final near = wall != null && st.remaining <= 50000;
    final color = wall == null
        ? Colors.red
        : near
            ? Colors.orange[800]!
            : Colors.teal;
    final ratio = wall != null ? (st.income / wall.amount).clamp(0.0, 1.0) : 1.0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.flag, color: color, size: 20),
                const SizedBox(width: 6),
                Text('扶養・社保の壁（$year年）',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('見込み ¥${appState.estimatedSalaryOfYear(year)}',
                        style: TextStyle(fontWeight: FontWeight.bold, color: color, fontSize: 13)),
                    if (appState.hasActualSalaryInYear(year))
                      Text('実 ¥${appState.actualSalaryOfYear(year)}',
                          style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blue, fontSize: 13)),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: ratio.toDouble(),
                minHeight: 8,
                backgroundColor: Colors.grey[200],
                color: color,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              wall == null
                  ? 'すべての壁（〜150万）を超えています'
                  : '次の壁: ${wall.label} まで あと ¥${st.remaining}'
                      '${near ? ' ⚠ もうすぐ到達！' : ''}',
              style: TextStyle(fontSize: 13, color: color),
            ),
          ],
        ),
      ),
    );
  }

  // 月ごとの収入画面に表示する追加情報（勤務先別: 労働時間・見込み・実給料）
  Widget _incomeSubInfo(BuildContext context, AppState s, DateTime month) {
    final byWp = s.incomeByWorkplaceOf(month);
    final totalHours = s.workHoursOf(month);
    final totalEstimated = s.salaryOf(month);
    // 実給料の合計（入力済みは実、未入力は見込みで補完）
    final totalActual = byWp.fold<int>(0, (sum, w) => sum + (w.actual ?? w.estimated));
    final anyActual = byWp.any((w) => w.actual != null);

    Widget headerRow(String label, String value, Color color) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
          child: Row(
            children: [
              Expanded(child: Text(label, style: const TextStyle(color: Colors.black54))),
              Text(value, style: TextStyle(fontWeight: FontWeight.bold, color: color)),
            ],
          ),
        );

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            headerRow('総労働時間', '${totalHours.toStringAsFixed(1)} h', Colors.black87),
            const Divider(height: 8),
            headerRow('給料見込み（合計）', '¥$totalEstimated', Colors.green),
            const Divider(height: 8),
            headerRow('実給料（合計）', anyActual ? '¥$totalActual' : '未入力',
                anyActual ? Colors.blue : Colors.grey),
            const Divider(height: 12),
            const Padding(
              padding: EdgeInsets.only(left: 4, bottom: 4),
              child: Text('バイト別（タップで実給料を入力）',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
            ),
            // #3 勤務先ごとに見込み・実給料を入力
            ...byWp.map((w) => InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => _showEditDialog(
                    context,
                    '${w.name} の実給料（${month.month}月）',
                    w.actual ?? w.estimated,
                    (v) => s.setActualSalaryOfWorkplace(month, w.key, v),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                    child: Row(
                      children: [
                        Container(
                            width: 12, height: 12,
                            decoration: BoxDecoration(color: Color(w.colorValue), shape: BoxShape.circle)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(w.name, style: const TextStyle(fontSize: 13)),
                              Text('勤務 ${w.hours.toStringAsFixed(1)}h ・ 見込み ¥${w.estimated}',
                                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
                            ],
                          ),
                        ),
                        Text(
                          w.actual != null ? '実 ¥${w.actual}' : '実給料 未入力',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: w.actual != null ? Colors.blue : Colors.grey),
                        ),
                        const Icon(Icons.edit, size: 16, color: Colors.grey),
                      ],
                    ),
                  ),
                )),
          ],
        ),
      ),
    );
  }

  // which: 0=今月末, 1=来月末, 2=翌々月末
  void _showBalanceDetail(BuildContext context, AppState appState, {required int which}) {
    final now = DateTime.now();
    final month = DateTime(now.year, now.month + which);
    final breakdown = which == 0
        ? appState.thisMonthBreakdown
        : which == 1
            ? appState.nextMonthBreakdown
            : appState.monthAfterNextBreakdown;
    final total = which == 0
        ? appState.thisMonthBalance
        : which == 1
            ? appState.nextMonthBalance
            : appState.monthAfterNextBalance;
    final title = '${month.month}月末の予想残高 詳細';

    Widget row(String label, int value) {
      final color = value > 0 ? Colors.green[700]! : (value < 0 ? Colors.red : Colors.black54);
      final sign = value >= 0 ? '+' : '';
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Expanded(child: Text(label, style: const TextStyle(fontSize: 14))),
            Text('$sign¥$value', style: TextStyle(fontWeight: FontWeight.bold, color: color, fontSize: 14)),
          ],
        ),
      );
    }

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            ...breakdown.entries.map((e) => row(e.key, e.value)),
            const Divider(height: 20),
            Row(
              children: [
                const Expanded(child: Text('= 予想残高', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15))),
                Text('¥$total',
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: total < 0 ? Colors.red : Colors.pink)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // グラフの棒を作成する補助関数
  BarChartGroupData _makeGroupData(int x, double y, Color color) {
    return BarChartGroupData(
      x: x,
      barRods: [
        BarChartRodData(
          toY: y,
          color: color,
          width: 25,
          borderRadius: BorderRadius.circular(4),
        )
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // 💡 監視開始（データが変わるとこの画面が自動リビルドされます）
    final appState = context.watch<AppState>();

    // データの計算（新仕様の残高予測）
    final now = DateTime.now();
    // 給料は給料日に入金される前提（給料日offsetぶん前の労働月の手取り）
    final int expectedIncome = appState.incomeForecastIn(now);
    final int cardExpenses = appState.cardPaymentsOf(now);
    final int subscriptions = appState.subscriptionTotal;
    final int installments = appState.installmentTotal;
    final int withdrawals = appState.withdrawalsOf(now);
    final int thisMonth = appState.thisMonthBalance;
    final int nextMonth = appState.nextMonthBalance;
    final int futureBalance = nextMonth;
    final int monthAfterNext = appState.monthAfterNextBalance;
    final int thisMonthNum = now.month;
    final int nextMonthNum = DateTime(now.year, now.month + 1, 1).month;
    final int monthAfterNextNum = DateTime(now.year, now.month + 2, 1).month;

    final cardBreakdown = appState.cardChargesOf(now);

    // 💡 支出を色分けセグメントに（カード別＋定期＋分割＋ATM）
    final segments = <({String label, int value, Color color})>[
      for (final e in cardBreakdown.entries)
        (label: e.key, value: e.value, color: cardColorOf(e.key)),
      if (subscriptions > 0) (label: '定期支払い', value: subscriptions, color: Colors.purple),
      if (installments > 0) (label: '分割払い', value: installments, color: Colors.deepOrange),
      if (withdrawals > 0) (label: 'ATM', value: withdrawals, color: Colors.brown),
    ];
    final totalExpense = segments.fold<int>(0, (s, e) => s + e.value);

    // 積み上げ棒のスタックアイテムを作成
    final stackItems = <BarChartRodStackItem>[];
    double from = 0;
    for (final s in segments) {
      stackItems.add(BarChartRodStackItem(from, from + s.value, s.color));
      from += s.value;
    }
    final maxY = [
      appState.currentBalance.toDouble(),
      expectedIncome.toDouble(),
      totalExpense.toDouble(),
      futureBalance.toDouble(),
      10000,
    ].reduce((a, b) => a > b ? a : b) * 1.2;

    return Scaffold(
      appBar: AppBar(
        title: const Text('未来の口座残高'),
        actions: [
          IconButton(
            tooltip: '収入・支出の推移',
            icon: const Icon(Icons.show_chart),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const TrendScreen()),
            ),
          ),
          IconButton(
            tooltip: '収支の履歴',
            icon: const Icon(Icons.bar_chart),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const HistoryScreen()),
            ),
          ),
          const GmailRefreshButton(),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          children: [
            // 合計表示部分
            Container(
              padding: const EdgeInsets.all(20),
              width: double.infinity,
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [Colors.pink[100]!, Colors.pink[50]!]),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                children: [
                  // 今月末（◯月末）タップで詳細
                  InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => _showBalanceDetail(context, appState, which: 0),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(
                        children: [
                          Text('$thisMonthNum月末の予想残高',
                              style: const TextStyle(fontSize: 14, color: Colors.black54)),
                          const SizedBox(height: 4),
                          Text('¥ $thisMonth',
                              style: TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.bold,
                                  color: thisMonth < 0 ? Colors.red : Colors.pink[400])),
                          const SizedBox(height: 2),
                          const Text('タップで詳細', style: TextStyle(fontSize: 11, color: Colors.black38)),
                        ],
                      ),
                    ),
                  ),
                  const Divider(height: 24),
                  // 来月末（◯月末）タップで詳細
                  InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => _showBalanceDetail(context, appState, which: 1),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(
                        children: [
                          Text('$nextMonthNum月末の予想残高',
                              style: const TextStyle(fontSize: 16, color: Colors.grey)),
                          const SizedBox(height: 6),
                          Text('¥ $futureBalance',
                              style: TextStyle(
                                  fontSize: appState.showMonthAfterNext ? 34 : 40,
                                  fontWeight: FontWeight.bold,
                                  color: futureBalance < 0 ? Colors.red : Colors.pink)),
                          const SizedBox(height: 2),
                          const Text('タップで詳細', style: TextStyle(fontSize: 11, color: Colors.black38)),
                        ],
                      ),
                    ),
                  ),
                  // 翌々月末（#2 表示ON時のみ）
                  if (appState.showMonthAfterNext) ...[
                    const Divider(height: 24),
                    InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => _showBalanceDetail(context, appState, which: 2),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Column(
                          children: [
                            Text('$monthAfterNextNum月末の予想残高',
                                style: const TextStyle(fontSize: 14, color: Colors.grey)),
                            const SizedBox(height: 4),
                            Text('¥ $monthAfterNext',
                                style: TextStyle(
                                    fontSize: 26,
                                    fontWeight: FontWeight.bold,
                                    color: monthAfterNext < 0 ? Colors.red : Colors.pink[300])),
                            const SizedBox(height: 2),
                            const Text('タップで詳細', style: TextStyle(fontSize: 11, color: Colors.black38)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),

            // 扶養・社保の「壁」アラート
            if (appState.salaryOfYear(DateTime.now().year) > 0) _fuyouWallCard(appState),

            // 目標貯金と達成予測
            _goalCard(context, appState),

            // 固定費（サブスク）の見直しサジェスト
            if (appState.subscriptions.isNotEmpty) _subscriptionReviewCard(appState),

            // 予算超過の警告
            if (appState.overBudgetThisMonth.isNotEmpty)
              Card(
                color: Colors.red[50],
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.warning_amber, color: Colors.red, size: 20),
                          SizedBox(width: 6),
                          Text('予算オーバー', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red)),
                        ],
                      ),
                      const SizedBox(height: 4),
                      ...appState.overBudgetThisMonth.map((e) => Text(
                          '${e.label}: ¥${e.spent} / ¥${e.budget}（+¥${e.spent - e.budget}）',
                          style: const TextStyle(fontSize: 13, color: Colors.red))),
                    ],
                  ),
                ),
              ),

            // 月ごとの収入／支出の詳細（円グラフ）へ遷移
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.green,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    icon: const Icon(Icons.pie_chart),
                    label: const Text('月ごとの収入詳細'),
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => BreakdownScreen(
                          title: '月ごとの収入',
                          totalLabel: '給料見込み合計',
                          accent: Colors.green,
                          builder: (s, m) => s.incomeBreakdownOf(m),
                          centerLabel: '年収',
                          yearValueBuilder: (s, y) => s.salaryOfYear(y),
                          subInfoBuilder: _incomeSubInfo,
                          detailBuilder: (s, m, label) => s.incomeDetailOf(m, label),
                          legendSubBuilder: (s, m, label) {
                            final h = s.workHoursOfWorkplace(m, label);
                            return h > 0 ? '勤務 ${h.toStringAsFixed(1)}h' : null;
                          },
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    icon: const Icon(Icons.pie_chart),
                    label: const Text('月ごとの支出詳細'),
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => BreakdownScreen(
                          title: '月ごとの支出',
                          totalLabel: '支出合計',
                          accent: Colors.red,
                          builder: (s, m) => s.expenseBreakdownOf(m),
                          centerLabel: '年支出',
                          yearValueBuilder: (s, y) => s.expenseOfYear(y),
                          detailBuilder: (s, m, label) => s.expenseDetailOf(m, label),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // ⚠ 残高不足アラート
            if (appState.shortagePayments.isNotEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.red[50],
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.red),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('⚠ 残高不足の恐れ',
                        style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red)),
                    const SizedBox(height: 4),
                    Text('今月末残高がマイナスになる見込みです (¥$thisMonth)',
                        style: const TextStyle(color: Colors.red)),
                  ],
                ),
              ),
            const SizedBox(height: 30),

            // グラフ表示部分
            const Text('収支の内訳', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 20),
            SizedBox(
              height: 250,
              child: BarChart(
                BarChartData(
                  alignment: BarChartAlignment.spaceAround,
                  maxY: maxY,
                  barTouchData: BarTouchData(enabled: false),
                  titlesData: FlTitlesData(
                    show: true,
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (double value, TitleMeta meta) {
                          const style = TextStyle(fontWeight: FontWeight.bold, fontSize: 12);
                          switch (value.toInt()) {
                            case 0: return const Text('現在', style: style);
                            case 1: return const Text('給与', style: style);
                            case 2: return const Text('支出', style: style);
                            case 3: return const Text('来月', style: style);
                            default: return const Text('');
                          }
                        },
                      ),
                    ),
                    leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  ),
                  borderData: FlBorderData(show: false),
                  // 💡 支出はカード色で積み上げ表示
                  barGroups: [
                    _makeGroupData(0, appState.currentBalance.toDouble(), Colors.blue),
                    _makeGroupData(1, expectedIncome.toDouble(), Colors.green),
                    BarChartGroupData(x: 2, barRods: [
                      BarChartRodData(
                        toY: totalExpense.toDouble(),
                        width: 25,
                        borderRadius: BorderRadius.circular(4),
                        rodStackItems: stackItems,
                        color: Colors.red,
                      )
                    ]),
                    _makeGroupData(3, futureBalance.toDouble().clamp(0, double.infinity), Colors.pink),
                  ],
                ),
              ),
            ),
            // 凡例（支出セグメントの色）
            if (segments.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  alignment: WrapAlignment.center,
                  children: segments.map((s) {
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(width: 10, height: 10, decoration: BoxDecoration(color: s.color, shape: BoxShape.circle)),
                        const SizedBox(width: 4),
                        Text('${s.label} ¥${s.value}', style: const TextStyle(fontSize: 11)),
                      ],
                    );
                  }).toList(),
                ),
              ),
            
            const SizedBox(height: 30),

            // 設定リスト
            ListTile(
              leading: const Icon(Icons.account_balance_wallet, color: Colors.blue),
              title: const Text('現在の残高'),
              subtitle: appState.debitsAfterSnapshot() > 0
                  ? Text('編集後のデビット利用 -¥${appState.debitsAfterSnapshot()} を反映',
                      style: const TextStyle(fontSize: 11, color: Colors.orange))
                  : null,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('¥ ${appState.effectiveBalance}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      if (appState.debitsAfterSnapshot() > 0)
                        Text('編集時 ¥${appState.currentBalance}',
                            style: const TextStyle(fontSize: 11, color: Colors.grey)),
                    ],
                  ),
                  IconButton(icon: const Icon(Icons.edit), onPressed: () => _showEditDialog(context, '現在の残高', appState.currentBalance, appState.updateBalance)),
                ],
              ),
            ),
            // 💡 口座への入金を加算（給料・振込など）
            ListTile(
              leading: const Icon(Icons.savings, color: Colors.green),
              title: const Text('口座に入金'),
              subtitle: const Text('入金額を現在の残高に加算します'),
              trailing: const Icon(Icons.add_circle_outline, color: Colors.green),
              onTap: () => showManualDepositDialog(context, appState),
            ),
            // 💡 予定入金（給料以外に入ってくるお金）
            ListTile(
              leading: Badge(
                isLabelVisible: appState.duePlannedIncomes.isNotEmpty,
                label: Text('${appState.duePlannedIncomes.length}'),
                child: const Icon(Icons.event_available, color: Colors.green),
              ),
              title: const Text('予定入金'),
              subtitle: Text(appState.duePlannedIncomes.isNotEmpty
                  ? '受け取り待ちが${appState.duePlannedIncomes.length}件あります'
                  : '仕送り・返金など、これから入る予定のお金'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showPlannedIncomeSheet(context, appState),
            ),
            // 💡 入出金の履歴
            ListTile(
              leading: const Icon(Icons.receipt_long, color: Colors.indigo),
              title: const Text('入出金の履歴'),
              subtitle: const Text('残高に反映した入金・引き落としの記録'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const BalanceHistoryScreen()),
              ),
            ),
            // 💡 口座からの引き落としを反映（未反映があればバッジで知らせる）
            ListTile(
              leading: Badge(
                isLabelVisible: appState.pendingDraws.isNotEmpty,
                label: Text('${appState.pendingDraws.length}'),
                child: const Icon(Icons.money_off, color: Colors.red),
              ),
              title: const Text('口座から引き落とし'),
              subtitle: Text(appState.pendingDraws.isNotEmpty
                  ? '未反映の引き落としが${appState.pendingDraws.length}件あります'
                  : '引き落とし額を現在の残高から引きます'),
              trailing: const Icon(Icons.remove_circle_outline, color: Colors.red),
              onTap: () => showDrawSheet(context, appState),
            ),
            if (appState.showWalletCash)
            ListTile(
              leading: const Icon(Icons.wallet, color: Colors.brown),
              title: const Text('財布の現金'),
              subtitle: const Text('予想残高に加算されます'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('¥ ${appState.walletCash}', style: const TextStyle(fontSize: 16)),
                  IconButton(icon: const Icon(Icons.edit), onPressed: () => _showEditDialog(context, '財布の現金', appState.walletCash, appState.updateWalletCash)),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.work, color: Colors.green),
              title: const Text('給料入金（今月）'),
              subtitle: const Text('給料日に入金される見込み'),
              trailing: Text('+ ¥ $expectedIncome', style: const TextStyle(fontSize: 16, color: Colors.green, fontWeight: FontWeight.bold)),
            ),
            ListTile(
              leading: const Icon(Icons.credit_card, color: Colors.red),
              title: const Text('カード請求(未払い)'),
              trailing: Text('- ¥ $cardExpenses', style: const TextStyle(fontSize: 16, color: Colors.red)),
            ),
            // 💡 カード別の内訳
            if (cardBreakdown.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 24, right: 16, bottom: 8),
                child: Column(
                  children: cardBreakdown.entries.map((e) {
                    final style = cardStyleOf(e.key);
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          Container(width: 10, height: 10, decoration: BoxDecoration(color: style.color, shape: BoxShape.circle)),
                          const SizedBox(width: 8),
                          Expanded(child: Text(e.key, style: const TextStyle(fontSize: 13, color: Colors.black54))),
                          Text('¥ ${e.value}', style: const TextStyle(fontSize: 13, color: Colors.black54)),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),
            ListTile(
              leading: const Icon(Icons.subscriptions, color: Colors.purple),
              title: const Text('定期支払い'),
              trailing: Text('- ¥ $subscriptions', style: const TextStyle(fontSize: 16, color: Colors.red)),
            ),
            ListTile(
              leading: const Icon(Icons.calendar_view_month, color: Colors.deepOrange),
              title: const Text('分割払い(今月)'),
              trailing: Text('- ¥ $installments', style: const TextStyle(fontSize: 16, color: Colors.red)),
            ),
            ListTile(
              leading: const Icon(Icons.atm, color: Colors.brown),
              title: const Text('ATM引き出し'),
              trailing: Text('- ¥ $withdrawals', style: const TextStyle(fontSize: 16, color: Colors.red)),
            ),

            // 💡 年間サマリー（過去2年分・年収/カード支出）
            if (appState.dataYears.isNotEmpty) ...[
              const SizedBox(height: 24),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('年間サマリー', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(height: 8),
              ...appState.dataYears.map((year) {
                final estimated = appState.estimatedSalaryOfYear(year);
                final actual = appState.actualSalaryOfYear(year);
                final hasActual = appState.hasActualSalaryInYear(year);
                final spending = appState.cardSpendingOfYear(year);
                return Card(
                  child: ListTile(
                    title: Text('$year年'),
                    subtitle: Text('カード支出 ¥$spending'),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        const Text('年収（見込み）', style: TextStyle(fontSize: 10, color: Colors.grey)),
                        Text('¥$estimated',
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.green)),
                        if (hasActual) ...[
                          const SizedBox(height: 2),
                          const Text('年収（実）', style: TextStyle(fontSize: 10, color: Colors.grey)),
                          Text('¥$actual',
                              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.blue)),
                        ],
                      ],
                    ),
                  ),
                );
              }),
            ],
          ],
        ),
      ),
    );
  }
}