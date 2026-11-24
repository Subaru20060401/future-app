// 💡 ホームの各まとまり。読む順に「いまの残高 → 月末の見込み → 次の引き落とし → 確認待ち → 操作」。
//   ⚠️ どれも計算しない。金額・日付・確定／見込みは AppState（forecastMonths・upcomingOutflows など）から
//     受け取ったものをそのまま出す。月末の見込みとその根拠・収支の内訳は同じ行から作られている。
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../card_styles.dart';
import '../drive_sync.dart';
import '../screens/balance_history_screen.dart';
import '../ui/components.dart';
import '../ui/tokens.dart';
import '../money_format.dart';
import 'animated_amount.dart';
import 'app_sheet.dart';
import 'deposit_dialog.dart';
import 'drive_sync_dialog.dart';
import 'planned_expense_sheet.dart';
import 'planned_income_sheet.dart';

String _md(DateTime d) => '${d.month}/${d.day}';

/// いまの残高（口座・財布）と、いつ書いた残高か。
class BalanceCard extends StatelessWidget {
  const BalanceCard({
    super.key,
    required this.appState,
    required this.onEditBalance,
    required this.onEditWallet,
  });

  final AppState appState;
  final VoidCallback onEditBalance;
  final VoidCallback onEditWallet;

  @override
  Widget build(BuildContext context) {
    final days = appState.daysSinceBalanceUpdate;
    final at = appState.balanceUpdatedAt;
    final updated = at == null
        ? 'まだ入力していません'
        : '${_md(at)} に入力（${days == 0 ? '今日' : '$days日前'}）';
    final debit = appState.debitsAfterSnapshot();
    return SectionCard(
      title: 'いまの残高',
      icon: Icons.account_balance_wallet_outlined,
      child: Column(
        children: [
          _row(
            label: '口座',
            caption: updated,
            amount: AnimatedAmount(value: appState.effectiveBalance, style: AppText.amountLarge),
            editLabel: '口座の残高を書き直す',
            onEdit: onEditBalance,
          ),
          if (debit > 0)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: AppSpace.xs),
              child: Text(
                '入力した ¥${yenNum(appState.currentBalance)} から、その後のデビット −¥${yenNum(debit)} を引いています',
                style: AppText.caption,
              ),
            ),
          if (appState.showWalletCash)
            _row(
              label: '財布',
              caption: '口座の見込みには入れません',
              amount: MoneyText(appState.walletCash, style: AppText.amount),
              editLabel: '財布の現金を書き直す',
              onEdit: onEditWallet,
            ),
          // 💡 古い残高のままだと予想もずれる。2週間を目安に知らせる
          if (days != null && days >= 14)
            StatusBanner(
              kind: BannerKind.caution,
              message: '残高を$days日間書き直していません',
              detail: '通帳やアプリの残高に合わせると、見込みが正確になります',
              actionLabel: '書き直す',
              onAction: onEditBalance,
            ),
          if (at == null)
            StatusBanner(
              kind: BannerKind.info,
              message: '口座の残高を入れると、月末の見込みが出ます',
              actionLabel: '入力する',
              onAction: onEditBalance,
            ),
        ],
      ),
    );
  }

  Widget _row({
    required String label,
    required String caption,
    required Widget amount,
    required String editLabel,
    required VoidCallback onEdit,
  }) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: AppText.body),
              Text(caption, style: AppText.caption),
            ],
          ),
        ),
        // 💡 文字を大きくしたときは金額を縮めて収める（はみ出して隠れないように）
        Flexible(
          child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: amount),
        ),
        IconButton(
          tooltip: editLabel,
          icon: const Icon(Icons.edit_outlined),
          onPressed: onEdit,
        ),
      ],
    );
  }
}


/// 月末の見込み（今月・来月・翌々月）と、いちばん少なくなる日。
class ForecastCard extends StatelessWidget {
  const ForecastCard({super.key, required this.appState, required this.onShowLowPoint});

  final AppState appState;
  final VoidCallback onShowLowPoint;

  @override
  Widget build(BuildContext context) {
    final count = appState.showMonthAfterNext ? 3 : 2;
    final months = appState.forecastMonths(count: count);
    final low = appState.lowestBalanceAhead();
    final thisMonth = months.first;
    return SectionCard(
      title: '月末の見込み',
      icon: Icons.trending_up,
      subtitle: '残高を書いた日より後の入金・引き落としから計算',
      child: Column(
        children: [
          Semantics(
            button: true,
            label: '${thisMonth.month.month}月末の見込み。根拠を見る',
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => showForecastDetail(context, appState, 0),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpace.s),
                child: Column(
                  children: [
                    Text('${thisMonth.month.month}月末', style: AppText.body),
                    AnimatedAmount(
                      value: thisMonth.end,
                      alignment: CrossAxisAlignment.center,
                      style: AppText.amountHero.copyWith(
                          color: thisMonth.end < 0 ? AppColors.warning : AppColors.brand),
                    ),
                    const SizedBox(height: 2),
                    const Text('根拠を見る ›', style: AppText.caption),
                  ],
                ),
              ),
            ),
          ),
          if (thisMonth.end < 0)
            const StatusBanner(
              kind: BannerKind.error,
              message: '今月末に残高がマイナスになる見込みです',
              detail: '入金を早めるか、支払いを分ける必要があります',
            ),
          const SizedBox(height: AppSpace.s),
          Row(
            children: [
              for (var i = 1; i < months.length; i++) ...[
                if (i > 1) const SizedBox(width: AppSpace.s),
                Expanded(child: _smallTile(context, months[i], i)),
              ],
            ],
          ),
          if (low != null) ...[
            const Divider(height: AppSpace.xl),
            Semantics(
              button: true,
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: onShowLowPoint,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: AppSpace.minTap),
                  child: Row(
                    children: [
                      Icon(low.balance < 0 ? Icons.warning_amber : Icons.south_east,
                          color: low.balance < 0 ? AppColors.warning : AppColors.subtle, size: 20),
                      const SizedBox(width: AppSpace.s),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              low.balance < 0
                                  ? 'いちばん少なくなる日（引き落としに足りません）'
                                  : 'いちばん少なくなる日',
                              style: AppText.body.copyWith(
                                  color: low.balance < 0 ? AppColors.warning : null),
                            ),
                            Text('${low.date.month}月${low.date.day}日 ・ 内訳を見る ›',
                                style: AppText.caption),
                          ],
                        ),
                      ),
                      MoneyText(low.balance, style: AppText.amount),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _smallTile(BuildContext context, MonthForecast f, int offset) {
    return Semantics(
      button: true,
      label: '${f.month.month}月末の見込み。根拠を見る',
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => showForecastDetail(context, appState, offset),
        child: Container(
          constraints: const BoxConstraints(minHeight: AppSpace.minTap),
          padding: const EdgeInsets.symmetric(vertical: AppSpace.s, horizontal: AppSpace.m),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              Text('${f.month.month}月末', style: AppText.caption),
              MoneyText(f.end,
                  style: AppText.amount, color: f.end < 0 ? AppColors.warning : AppColors.brandDeep),
            ],
          ),
        ),
      ),
    );
  }
}

/// 月末の見込みの根拠。起点 → 入金 → 引き落とし → 一度きり → 月末。行の合計が月末の金額に一致する。
Future<void> showForecastDetail(BuildContext context, AppState appState, int offset) {
  final months = appState.forecastMonths(count: offset + 1);
  final f = months[offset];
  final title = '${f.month.month}月末の見込みの根拠';
  final lines = [...f.lines]..sort((a, b) => a.date.compareTo(b.date));
  final incomes = [for (final l in lines) if (l.amount > 0) l];
  final outs = [for (final l in lines) if (l.amount < 0) l];

  Widget lineRow(ForecastLine l) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            SizedBox(width: 48, child: Text(_md(l.date), style: AppText.caption)),
            Expanded(
              child: Wrap(
                spacing: AppSpace.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(l.label, style: AppText.body),
                  CertaintyBadge(l.certainty),
                  if (l.needsReview) const ReviewBadge(),
                ],
              ),
            ),
            const SizedBox(width: AppSpace.s),
            MoneyText(l.amount, signed: true, style: AppText.body.copyWith(fontWeight: FontWeight.bold)),
          ],
        ),
      );

  Widget totalRow(String label, int amount, {bool signed = false, TextStyle? style}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Expanded(child: Text(label, style: style ?? AppText.body)),
            MoneyText(amount, signed: signed, style: style ?? AppText.amount),
          ],
        ),
      );

  return showAppSheet(
    context,
    (_) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          const Text(
            '残高を書いた日より後の動きだけを足し引きしています。'
            '「確定」は銀行の引落確定・入力した実給料、「見込み」はシフト・利用通知・登録した予定からの計算です。',
            style: AppText.caption,
          ),
          const SizedBox(height: AppSpace.m),
          if (offset == 0) ...[
            totalRow('口座の残高', appState.currentBalance),
            if (appState.debitsAfterSnapshot() > 0)
              totalRow('その後のデビット', -appState.debitsAfterSnapshot(), signed: true),
          ] else
            totalRow('${months[offset - 1].month.month}月末の見込み', f.start),
          const Divider(height: AppSpace.xl),
          Text('入金', style: AppText.title.copyWith(color: AppColors.income)),
          if (incomes.isEmpty) const Text('なし', style: AppText.caption),
          ...incomes.map(lineRow),
          const SizedBox(height: AppSpace.m),
          Text('引き落とし・支払い', style: AppText.title.copyWith(color: AppColors.expense)),
          if (outs.isEmpty) const Text('なし', style: AppText.caption),
          ...outs.map(lineRow),
          // 💡 分割払いは各カードの請求に含まれて落ちる。参考表示で、合計には足さない
          if (appState.installmentPartOfDraw(f.month) > 0)
            Padding(
              padding: const EdgeInsets.only(top: AppSpace.xs),
              child: Text(
                '※ カードの金額のうち分割払い ¥${yenNum(appState.installmentPartOfDraw(f.month))}（合計には足していません）',
                style: AppText.caption,
              ),
            ),
          const Divider(height: AppSpace.xl),
          totalRow('= ${f.month.month}月末の見込み', f.end,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        ],
      ),
    ),
  );
}

/// 次の引き落とし（30日以内）。日付・名前・金額・確定／見込み。
class UpcomingDrawsCard extends StatelessWidget {
  const UpcomingDrawsCard({super.key, required this.appState});
  final AppState appState;

  @override
  Widget build(BuildContext context) {
    final items = appState.upcomingOutflows();
    final shortDates = {for (final d in appState.shortfallDaysAhead()) d.date};
    return SectionCard(
      title: '次の引き落とし',
      icon: Icons.event_note,
      subtitle: '今日から30日以内',
      child: items.isEmpty
          ? const Text('30日以内の引き落とし・支払いの予定はありません', style: AppText.caption)
          : Column(
              children: [
                for (final l in items.take(8))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 48,
                          child: Text(_md(l.date),
                              style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
                        ),
                        Container(
                          width: 8,
                          height: 8,
                          margin: const EdgeInsets.only(right: AppSpace.s),
                          decoration:
                              BoxDecoration(color: cardColorOf(l.label), shape: BoxShape.circle),
                        ),
                        // 💡 狭い画面・文字を大きくしたときも溢れないよう、名前と状態を2段にする
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(l.label, style: AppText.body),
                              Wrap(
                                spacing: AppSpace.xs,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  CertaintyBadge(l.certainty),
                                  if (l.needsReview) const ReviewBadge(),
                                  if (shortDates.contains(l.date))
                                    const Text('⚠ 残高が足りない日',
                                        style: TextStyle(fontSize: 12, color: AppColors.warning)),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: AppSpace.s),
                        MoneyText(l.amount, signed: true, style: AppText.body.copyWith(fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                if (items.length > 8)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text('ほか${items.length - 8}件（月末の見込みの根拠で見られます）',
                        style: AppText.caption),
                  ),
              ],
            ),
    );
  }
}

/// 収支の内訳（今月）。月末の見込みと同じ行から、入金・出金の合計と内訳を出す。
class MonthFlowCard extends StatelessWidget {
  const MonthFlowCard({super.key, required this.appState});
  final AppState appState;

  @override
  Widget build(BuildContext context) {
    final f = appState.forecastMonths(count: 1).first;
    final groups = f.grouped();
    final outs = [for (final g in groups) if (g.amount < 0) g];
    final total = f.outgoTotal;
    return SectionCard(
      title: '収支の内訳（${f.month.month}月）',
      icon: Icons.stacked_bar_chart,
      subtitle: '月末の見込みと同じ計算です',
      child: Column(
        children: [
          _flowRow('いまの口座残高', f.start), // 💡 財布は口座の予想に入れない（2026-11）
          _flowRow('入金', f.incomeTotal, signed: true),
          _flowRow('出金', -total, signed: true),
          const Divider(height: AppSpace.l),
          _flowRow('= ${f.month.month}月末', f.end, bold: true),
          if (total > 0) ...[
            const SizedBox(height: AppSpace.m),
            // 出金の割合（帯）。色に加えて下に名前と金額を並べる（色だけで区別しない）
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                height: 12,
                child: Row(
                  children: [
                    for (final g in outs)
                      Expanded(
                        flex: (-g.amount * 1000 ~/ total).clamp(1, 1000),
                        child: Container(color: cardColorOf(g.group)),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpace.s),
            for (final g in outs)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      margin: const EdgeInsets.only(right: AppSpace.s),
                      decoration: BoxDecoration(color: cardColorOf(g.group), shape: BoxShape.circle),
                    ),
                    Expanded(child: Text(g.group, style: AppText.body)),
                    MoneyText(g.amount, signed: true, style: AppText.body),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _flowRow(String label, int amount, {bool signed = false, bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Expanded(
                child: Text(label,
                    style: bold ? AppText.body.copyWith(fontWeight: FontWeight.bold) : AppText.body)),
            MoneyText(amount, signed: signed, style: bold ? AppText.amountLarge : AppText.amount),
          ],
        ),
      );
}

/// お金の操作（入金・引き落としの反映・予定・履歴・財布）。以前ホームに縦に並んでいた項目をまとめた。
class MoneyActionsCard extends StatelessWidget {
  const MoneyActionsCard({super.key, required this.appState, required this.onEditWallet});
  final AppState appState;
  final VoidCallback onEditWallet;

  @override
  Widget build(BuildContext context) {
    final pending = appState.pendingDraws.length;
    final dueIncome = appState.duePlannedIncomes.length;
    final actions = <({IconData icon, String label, String? badge, VoidCallback onTap})>[
      (
        icon: Icons.savings_outlined,
        label: '口座に入金',
        badge: null,
        onTap: () => showManualDepositDialog(context, appState),
      ),
      (
        icon: Icons.money_off,
        label: '引き落としを反映',
        badge: pending > 0 ? '$pending' : null,
        onTap: () => showDrawSheet(context, appState),
      ),
      (
        icon: Icons.event_available,
        label: '予定の入金',
        badge: dueIncome > 0 ? '$dueIncome' : null,
        onTap: () => showPlannedIncomeSheet(context, appState),
      ),
      (
        icon: Icons.event_busy,
        label: '予定の支出',
        badge: null,
        onTap: () => showPlannedExpenseSheet(context, appState),
      ),
      (
        icon: Icons.receipt_long,
        label: '入出金の履歴',
        badge: null,
        onTap: () => Navigator.push(
            context, MaterialPageRoute(builder: (_) => const BalanceHistoryScreen())),
      ),
      if (appState.showWalletCash)
        (icon: Icons.wallet, label: '財布の現金', badge: null, onTap: onEditWallet),
    ];
    return SectionCard(
      title: 'お金の操作',
      icon: Icons.touch_app_outlined,
      child: LayoutBuilder(builder: (context, c) {
        final cols = c.maxWidth >= 480 ? 3 : 2;
        final w = (c.maxWidth - AppSpace.s * (cols - 1)) / cols;
        return Wrap(
          spacing: AppSpace.s,
          runSpacing: AppSpace.s,
          children: [
            for (final a in actions)
              SizedBox(
                width: w,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(AppSpace.minTap),
                    padding: const EdgeInsets.symmetric(horizontal: AppSpace.s, vertical: AppSpace.s),
                    alignment: Alignment.centerLeft,
                  ),
                  onPressed: a.onTap,
                  child: Row(
                    children: [
                      Badge(
                        isLabelVisible: a.badge != null,
                        label: Text(a.badge ?? ''),
                        child: Icon(a.icon, size: 20),
                      ),
                      const SizedBox(width: AppSpace.s),
                      Expanded(
                        child: Text(
                          a.badge != null ? '${a.label}（${a.badge}件）' : a.label,
                          style: AppText.body,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      }),
    );
  }
}

/// ドライブ同期で、自分の操作が要る状態（競合・連携切れ・失敗）だけを知らせる。順調なときは何も出さない。
class DriveSyncBanner extends StatelessWidget {
  const DriveSyncBanner({super.key, required this.appState});
  final AppState appState;

  @override
  Widget build(BuildContext context) {
    if (!appState.driveSyncEnabled) return const SizedBox.shrink();
    return ValueListenableBuilder<DriveSyncState?>(
      valueListenable: lastDriveSyncState,
      builder: (context, state, _) {
        void sync() => runDriveSync(context, appState);
        return switch (state) {
          DriveSyncState.conflict => StatusBanner(
              kind: BannerKind.caution,
              message: 'この端末と別の端末の両方でデータが変わっています',
              detail: 'どちらを残すか選ぶまで、ドライブへの自動保存を止めています',
              actionLabel: '選ぶ',
              onAction: sync,
            ),
          DriveSyncState.notSignedIn => StatusBanner(
              kind: BannerKind.caution,
              message: 'ドライブと同期できていません',
              detail: 'Googleとの連携を更新してください',
              actionLabel: '同期する',
              onAction: sync,
            ),
          DriveSyncState.error => StatusBanner(
              kind: BannerKind.error,
              message: 'ドライブとの同期に失敗しました',
              detail: '保存済みのデータはそのままです。電波の良い場所でもう一度お試しください',
              actionLabel: 'もう一度',
              onAction: sync,
            ),
          _ => const SizedBox.shrink(),
        };
      },
    );
  }
}

/// 保存の状態（失敗・回復待ち・回復不能・起動時に戻したこと）と、次にする操作。
class StorageStatusBanner extends StatelessWidget {
  const StorageStatusBanner({super.key, required this.appState});
  final AppState appState;

  Future<void> _retry(BuildContext context) async {
    final ok = await appState.retryStorage();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok ? '保存しました' : 'まだ保存できません。空き容量を確認してください')));
  }

  Future<void> _pullFromDrive(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('ドライブから取り込み直しますか？'),
        content: const Text('この端末のデータを、ドライブに保存されている内容で置き換えます。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('やめる')),
          ElevatedButton(onPressed: () => Navigator.pop(c, true), child: const Text('取り込む')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final r = await DriveSync.instance.pullNow(appState);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(r.state == DriveSyncState.upToDate ? 'ドライブの内容にしました' : r.message)));
  }

  @override
  Widget build(BuildContext context) {
    return switch (appState.storageIssue) {
      StorageIssue.saveFailed => StatusBanner(
          kind: BannerKind.error,
          message: '保存できませんでした',
          detail: 'いまの画面の内容は、まだこの端末に保存されていません。空き容量を確認してから、もう一度保存してください',
          actionLabel: 'もう一度保存',
          onAction: () => _retry(context),
        ),
      StorageIssue.recoveryPending => StatusBanner(
          kind: BannerKind.error,
          message: '前回止まった保存を、まだ元に戻せていません',
          detail: '表示中のデータは記録から読んだ整った状態です。戻せるまで、ドライブへの保存と自動バックアップを止めています',
          actionLabel: 'もう一度保存',
          onAction: () => _retry(context),
        ),
      StorageIssue.unrecoverable => StatusBanner(
          kind: BannerKind.error,
          message: '保存データが途中で混ざっている可能性があります',
          detail: 'ドライブから取り込み直すか、設定の「バックアップから復元」で戻してください。それまでドライブへの保存と自動バックアップを止めています',
          actionLabel: 'ドライブから取り込む',
          onAction: () => _pullFromDrive(context),
        ),
      null => appState.recoveredOnStartup
          ? const StatusBanner(
              kind: BannerKind.info,
              message: '前回の保存が途中で止まっていたため、整った状態に戻しました',
            )
          : const SizedBox.shrink(),
    };
  }
}
