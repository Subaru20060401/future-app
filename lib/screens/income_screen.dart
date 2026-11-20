import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app_state.dart';
import '../widgets/gmail_refresh_button.dart';
import '../widgets/home_cards.dart';
import '../widgets/home_sections.dart';
import '../ui/components.dart';
import '../ui/tokens.dart';
import '../widgets/sync_status.dart';
import '../widgets/add_entry_sheets.dart';
import 'history_screen.dart';
import 'breakdown_screen.dart';
import 'trend_screen.dart';
import '../widgets/app_sheet.dart';
import '../money_format.dart';

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
                Text('${f.date.year}年${f.date.month}月までに ¥${yenNum(f.goal)}',
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
                  ? '✅ このペース（月 ¥${yenNum(f.pace)}）なら達成見込み（予測 ¥${yenNum(f.projected)}）'
                  : '⚠ このペース（月 ¥${yenNum(f.pace)}）では不足（予測 ¥${yenNum(f.projected)}）',
              style: TextStyle(fontSize: 13, color: color),
            ),
            if (f.monthsLeft > 0)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('残り${f.monthsLeft}か月・必要月額 ¥${yenNum(f.requiredMonthly)}',
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
                Expanded(
                  child: Text('固定費（サブスク）の見直し',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text('月 ¥${yenNum(monthly)} ・ 年 ¥${yenNum(yearly)}',
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.bold, color: Colors.purple)),
            const SizedBox(height: 6),
            ...subs.map((s) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Expanded(child: Text(s.title, style: const TextStyle(fontSize: 13))),
                      Flexible(
                        child: Text('¥${yenNum(s.amount)}/月（年¥${yenNum(s.amount * 12)}）',
                            textAlign: TextAlign.end,
                            style: const TextStyle(fontSize: 12, color: Colors.black54)),
                      ),
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
                // 💡 スマホ幅（375px前後）で右の金額とぶつかってはみ出していたので、
                //   見出しの方を縮める（金額は削らない）
                Expanded(
                  child: Text('扶養・社保の壁（$year年）',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis),
                ),
                const SizedBox(width: 6),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('見込み ¥${yenNum(appState.estimatedSalaryOfYear(year))}',
                        style: TextStyle(fontWeight: FontWeight.bold, color: color, fontSize: 13)),
                    if (appState.hasActualSalaryInYear(year))
                      Text('実 ¥${yenNum(appState.actualSalaryOfYear(year))}',
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
                  : '次の壁: ${wall.label} まで あと ¥${yenNum(st.remaining)}'
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
            headerRow('給料見込み（合計）', '¥${yenNum(totalEstimated)}', Colors.green),
            const Divider(height: 8),
            headerRow('実給料（合計）', anyActual ? '¥${yenNum(totalActual)}' : '未入力',
                anyActual ? Colors.blue : Colors.grey),
            const Divider(height: 12),
            const Padding(
              padding: EdgeInsets.only(left: 4, bottom: 4),
              child: Text('バイト別（タップで実給料を入力）',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
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
                              Text('勤務 ${w.hours.toStringAsFixed(1)}h ・ 見込み ¥${yenNum(w.estimated)}',
                                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
                            ],
                          ),
                        ),
                        Text(
                          w.actual != null ? '実 ¥${yenNum(w.actual!)}' : '実給料 未入力',
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
  // 💡 まだ何も入っていないときの案内（空のグラフの代わり）
  Widget _homeEmptyGuide(BuildContext context, AppState appState) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('はじめに', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            const Text(
              '今の口座残高を入れると、月末の予想残高が出ます。'
              'シフトを入れると給料の見込みが、カードを連携すると引き落としが入ります。',
              style: TextStyle(fontSize: 13, color: Colors.black87),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                FilledButton.tonal(
                  onPressed: () => _showEditDialog(
                      context, '現在の残高', appState.currentBalance, appState.updateBalance),
                  child: const Text('残高を入力'),
                ),
                OutlinedButton(
                  onPressed: () {
                    final now = DateTime.now();
                    showAddShiftSheet(context, appState, DateTime(now.year, now.month, now.day));
                  },
                  child: const Text('シフトを追加'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // 💡 引き落としで足りなくなる日の一覧。日付・カード名・そのときの残高を出す。
  Widget _shortfallCard(AppState appState) {
    final days = appState.shortfallDaysAhead();
    return Card(
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
                Text('引き落としに足りない日',
                    style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red)),
              ],
            ),
            const SizedBox(height: 6),
            ...days.take(5).map((e) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 52,
                        child: Text('${e.date.month}/${e.date.day}',
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.bold, color: Colors.red)),
                      ),
                      Expanded(
                        child: Text(
                          e.labels.isEmpty ? '引き落とし' : e.labels.join('・'),
                          style: const TextStyle(fontSize: 13, color: Colors.red),
                        ),
                      ),
                      Text('¥${yenNum(e.balance)}',
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.bold, color: Colors.red)),
                    ],
                  ),
                )),
            if (days.length > 5)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('ほか${days.length - 5}日',
                    style: const TextStyle(fontSize: 12, color: Colors.red)),
              ),
            const SizedBox(height: 4),
            const Text('その日の引き落とし後の残高です。入金を早めるか、支払いを分ける必要があります',
                style: TextStyle(fontSize: 12, color: Colors.black54)),
          ],
        ),
      ),
    );
  }

  // 谷までの内訳（いつ・何で減って、どこで底を打つか）
  void _showLowPointDetail(BuildContext context, AppState appState) {
    final low = appState.lowestBalanceAhead();
    if (low == null) return;
    final events = appState
        .cashEventsAhead()
        .where((e) => !e.date.isAfter(low.date))
        .toList();

    Widget row(String label, int value, {String? date, bool bold = false}) {
      final color = value > 0 ? Colors.green[700]! : (value < 0 ? Colors.red : Colors.black54);
      final sign = value > 0 ? '+' : '';
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            SizedBox(
              width: 58,
              child: Text(date ?? '',
                  style: const TextStyle(fontSize: 12, color: Colors.black45)),
            ),
            Expanded(child: Text(label, style: const TextStyle(fontSize: 14))),
            Text('$sign¥${yenNum(value)}',
                style: TextStyle(
                    fontWeight: bold ? FontWeight.bold : FontWeight.w600,
                    color: color,
                    fontSize: 14)),
          ],
        ),
      );
    }

    showAppSheet(context, (_) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('最低残高までの内訳',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              '${low.date.month}月${low.date.day}日が、いちばん残高が少なくなる日です。'
              '月末の予想だけでは見えません',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 12),
            row('現在の残高', appState.effectiveBalance),
            ...events.map((e) => row(
                  e.label,
                  e.amount,
                  date: '${e.date.month}/${e.date.day}',
                )),
            const Divider(height: 20),
            Row(
              children: [
                Expanded(
                  child: Text('= ${low.date.month}月${low.date.day}日の残高',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15)),
                ),
                Text('¥${yenNum(low.balance)}',
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: low.balance < 0 ? Colors.red : Colors.pink)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 💡 監視開始（データが変わるとこの画面が自動リビルドされます）
    final appState = context.watch<AppState>();

    // 💡 保存データを読み終えるまでは金額を出さない。
    //   初期値の0円を出してから実際の金額に切り替わると、一瞬ちらついて見えるうえ、
    //   金額の動き（AnimatedAmount）が「0円からの増加」として動いてしまう。
    if (!appState.isLoaded) {
      return Scaffold(
        appBar: AppBar(title: const Text('ホーム')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    void editBalance() =>
        _showEditDialog(context, '口座の残高', appState.currentBalance, appState.updateBalance);
    void editWallet() =>
        _showEditDialog(context, '財布の現金', appState.walletCash, appState.updateWalletCash);

    // 💡 何も入っていない（残高も明細もシフトも無い）ときは、最初にやることを案内する
    final isEmpty = appState.balanceUpdatedAt == null &&
        appState.currentBalance == 0 &&
        appState.payments.isEmpty &&
        appState.shifts.isEmpty;

    // ── 読む順: いまの残高 → 月末の見込み → 注意 → 次の引き落とし → 確認待ち → 操作 → 予定 → 内訳 → 目安 ──
    final primary = <Widget>[
      BalanceCard(appState: appState, onEditBalance: editBalance, onEditWallet: editWallet),
      ForecastCard(
        appState: appState,
        onShowLowPoint: () => _showLowPointDetail(context, appState),
      ),
      // 💡 収支の内訳は月末の見込みと同じ行から作る（合計と内訳が食い違わない）
      MonthFlowCard(appState: appState),
    ];
    final secondary = <Widget>[
      // 💡 引き落としで残高が足りなくなる日。どのカードで割るかまで出す
      if (appState.shortfallDaysAhead().isNotEmpty) _shortfallCard(appState),
      UpcomingDrawsCard(appState: appState),
      // 💡 確認待ち（入出金の反映待ちなど）。起動時に順番に聞くのをやめ、ここに集める。
      HomeNoticesCard(appState: appState),
      MoneyActionsCard(appState: appState, onEditWallet: editWallet),
      // 今日・直近の予定
      UpcomingScheduleCard(appState: appState),
    ];
    final guides = <Widget>[
      // 扶養・社保の「壁」アラート
      if (appState.salaryOfYear(appState.clockNow().year) > 0) _fuyouWallCard(appState),
      // 目標貯金と達成予測
      _goalCard(context, appState),
      // 固定費（サブスク）の見直しサジェスト
      if (appState.subscriptions.isNotEmpty) _subscriptionReviewCard(appState),
      // 予算超過の警告
      if (appState.overBudgetThisMonth.isNotEmpty)
        StatusBanner(
          kind: BannerKind.caution,
          message: '予算オーバー',
          detail: appState.overBudgetThisMonth
              .map((e) =>
                  '${e.label}: ¥${yenNum(e.spent)} / ¥${yenNum(e.budget)}（+¥${yenNum(e.spent - e.budget)}）')
              .join('\n'),
        ),
      _detailButtons(context),
      _yearSummary(appState),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('ホーム'),
        actions: [
          // 💡 確認待ちの件数。開いても件数は減らない（反映・スキップで解消する）
          IconButton(
            tooltip: '確認待ち',
            onPressed: () => showAllNotices(context, appState),
            icon: Badge(
              isLabelVisible: appState.homeNotices.isNotEmpty,
              label: Text('${appState.homeNotices.length}'),
              child: const Icon(Icons.notifications_none),
            ),
          ),
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
      body: LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth >= kWideLayoutWidth;
        final head = <Widget>[
          // 💡 メール更新の結果（一行。失敗・見送りなら再試行を出す）
          const SyncStatusBar(),
          // 💡 保存の失敗・回復待ち（端末の保存が整っていない間は、ここで知らせる）
          StorageStatusBanner(appState: appState),
          // 💡 ドライブ同期の競合・失敗（自動保存が止まっているとき）
          DriveSyncBanner(appState: appState),
          if (isEmpty) _homeEmptyGuide(context, appState),
        ];
        if (!wide) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 32),
            children: [...head, ...primary, ...secondary, ...guides],
          );
        }
        // 💡 PCの広い画面: 左に残高と見込み、右に引き落とし・確認待ち・操作
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 32),
          child: Column(
            children: [
              ...head,
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: Column(children: [...primary, ...guides])),
                  Expanded(child: Column(children: secondary)),
                ],
              ),
            ],
          ),
        );
      }),
    );
  }

  // 月ごとの収入／支出の詳細（円グラフ）へ
  Widget _detailButtons(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.income,
                minimumSize: const Size.fromHeight(AppSpace.minTap),
              ),
              icon: const Icon(Icons.pie_chart),
              label: const Text('月ごとの収入'),
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
          const SizedBox(width: AppSpace.m),
          Expanded(
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.expense,
                minimumSize: const Size.fromHeight(AppSpace.minTap),
              ),
              icon: const Icon(Icons.pie_chart),
              label: const Text('月ごとの支出'),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => BreakdownScreen(
                    title: '月ごとの支出',
                    totalLabel: '支出合計',
                    accent: Colors.red,
                    builder: (s, m) => s.expenseBreakdownOf(m),
                    centerLabel: '年間支出',
                    yearValueBuilder: (s, y) => s.expenseOfYear(y),
                    detailBuilder: (s, m, label) => s.expenseDetailOf(m, label),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // 💡 年間サマリー（年収の見込み・実績と、年間支出）
  Widget _yearSummary(AppState appState) {
    if (appState.dataYears.isEmpty) return const SizedBox.shrink();
    return SectionCard(
      title: '年間サマリー',
      icon: Icons.calendar_today_outlined,
      child: Column(
        children: [
          for (final year in appState.dataYears)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
              child: Builder(builder: (context) {
                final spending = appState.expenseSummaryOfYear(year);
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('$year年', style: AppText.title),
                          Text('年間支出 ¥${yenNum(spending.total)}', style: AppText.body),
                          if (spending.fromSettings > 0)
                            Text('うち設定から計算 ¥${yenNum(spending.fromSettings)}（定期・分割・ローン）',
                                style: AppText.caption),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        const Text('年収（見込み）', style: AppText.caption),
                        Text('¥${yenNum(appState.estimatedSalaryOfYear(year))}',
                            style: AppText.amount.copyWith(color: AppColors.income)),
                        if (appState.hasActualSalaryInYear(year)) ...[
                          const Text('年収（実績）', style: AppText.caption),
                          Text('¥${yenNum(appState.actualSalaryOfYear(year))}',
                              style: AppText.amount.copyWith(color: AppColors.confirmed)),
                        ],
                      ],
                    ),
                  ],
                );
              }),
            ),
        ],
      ),
    );
  }
}