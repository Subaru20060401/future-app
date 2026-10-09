// 💡 ホームに並べるカード（確認待ち・今日の予定）。
//   計算はしない。中身は AppState（homeNotices / upcomingSchedule）が組み立てる。
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import 'add_entry_sheets.dart';
import 'app_sheet.dart';
import 'deposit_dialog.dart';
import 'planned_income_sheet.dart';

// 確認待ちを1件開く（種類ごとに既存の確認処理へ渡す）。
// 💡 開いただけでは残高を動かさない。反映・スキップの操作で解消する。
Future<void> openHomeNotice(
    BuildContext context, AppState appState, HomeNotice notice) async {
  switch (notice.kind) {
    case HomeNoticeKind.draw:
      await showDrawDialog(context, appState, notice.draw!);
    case HomeNoticeKind.deposit:
      // 引き落としの先確認は showDepositDialog の中で行う
      await showDepositDialog(context, appState, notice.deposit!);
    case HomeNoticeKind.plannedIncome:
      await showPlannedIncomeSheet(context, appState);
    case HomeNoticeKind.installmentWithoutCard:
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('分割払いのカードを設定'),
          content: const Text(
            '「支払い」→「分割」で、カードが空欄の分割払いを開き、'
            'どのカードの請求に入るかを選んでください。\n'
            '設定するまでは、銀行の引落確定メールが届いた月に予想から外れることがあります。',
            style: TextStyle(fontSize: 13),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context), child: const Text('閉じる')),
          ],
        ),
      );
  }
}

IconData _iconOf(HomeNoticeKind kind) => switch (kind) {
      HomeNoticeKind.draw => Icons.north_east,
      HomeNoticeKind.deposit => Icons.south_west,
      HomeNoticeKind.plannedIncome => Icons.event_available,
      HomeNoticeKind.installmentWithoutCard => Icons.credit_card_off,
    };

Color _colorOf(HomeNoticeKind kind) => switch (kind) {
      HomeNoticeKind.draw => Colors.red,
      HomeNoticeKind.deposit => Colors.green,
      HomeNoticeKind.plannedIncome => Colors.teal,
      HomeNoticeKind.installmentWithoutCard => Colors.orange,
    };

Widget _noticeTile(BuildContext context, AppState appState, HomeNotice n) {
  final color = _colorOf(n.kind);
  final amount = n.amount;
  return ListTile(
    contentPadding: EdgeInsets.zero,
    dense: true,
    leading: CircleAvatar(
      radius: 16,
      backgroundColor: color.withValues(alpha: 0.12),
      child: Icon(_iconOf(n.kind), color: color, size: 16),
    ),
    title: Text(n.title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
    subtitle: Text(n.detail, style: const TextStyle(fontSize: 12)),
    trailing: amount == null
        ? const Icon(Icons.chevron_right)
        : Text(
            '${n.kind == HomeNoticeKind.draw ? '-' : '+'}¥$amount',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: color),
          ),
    onTap: () => openHomeNotice(context, appState, n),
  );
}

// 確認待ちをすべて表示する（ホームには上位3件だけ出す）
Future<void> showAllNotices(BuildContext context, AppState appState) async {
  await showAppSheet<void>(context, (ctx) {
    final notices = appState.homeNotices;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('確認待ち（${notices.length}件）',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          const Text('上から順に処理すると、予想残高がずれません',
              style: TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 8),
          if (notices.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('確認待ちはありません'),
            ),
          for (final n in notices)
            _noticeTile(ctx, appState, n),
        ],
      ),
    );
  });
}

// 💡 ホームの「確認待ち」。重要な順に3件まで出し、残りは「すべて見る」から。
class HomeNoticesCard extends StatelessWidget {
  const HomeNoticesCard({super.key, required this.appState});

  final AppState appState;

  @override
  Widget build(BuildContext context) {
    final notices = appState.homeNotices;
    if (notices.isEmpty) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.notifications_active, size: 18, color: Colors.pink),
                const SizedBox(width: 6),
                Text('確認待ち（${notices.length}件）',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                if (notices.length > 3)
                  TextButton(
                    onPressed: () => showAllNotices(context, appState),
                    child: const Text('すべて見る'),
                  ),
              ],
            ),
            for (final n in notices.take(3)) _noticeTile(context, appState, n),
          ],
        ),
      ),
    );
  }
}

// 💡 今日・直近の予定（承認済みのシフトと予定だけ）。
class UpcomingScheduleCard extends StatelessWidget {
  const UpcomingScheduleCard({super.key, required this.appState});

  final AppState appState;

  @override
  Widget build(BuildContext context) {
    final items = appState.upcomingSchedule();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    String dayLabel(DateTime d) {
      final diff = DateTime(d.year, d.month, d.day).difference(today).inDays;
      if (diff == 0) return '今日';
      if (diff == 1) return '明日';
      return DateFormat('M/d(E)', 'ja_JP').format(d);
    }

    String timeLabel(({DateTime start, DateTime? end, String title, bool isShift, bool allDay}) e) {
      if (e.allDay) return '終日';
      final f = DateFormat('H:mm');
      final end = e.end;
      return end == null ? f.format(e.start) : '${f.format(e.start)}–${f.format(end)}';
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.today, size: 18, color: Colors.pink),
                SizedBox(width: 6),
                Text('今日・直近の予定', style: TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 6),
            if (items.isEmpty)
              const Text('3日以内の予定はありません',
                  style: TextStyle(fontSize: 13, color: Colors.black54)),
            for (final e in items.take(5))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    SizedBox(
                      width: 64,
                      child: Text(dayLabel(e.start),
                          style: const TextStyle(fontSize: 13, color: Colors.black54)),
                    ),
                    SizedBox(
                      width: 92,
                      child: Text(timeLabel(e), style: const TextStyle(fontSize: 13)),
                    ),
                    Icon(e.isShift ? Icons.work_outline : Icons.event,
                        size: 15, color: e.isShift ? Colors.indigo : Colors.orange),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(e.title,
                          style: const TextStyle(fontSize: 13),
                          overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
              ),
            if (items.length > 5)
              Text('ほか${items.length - 5}件（カレンダーで確認）',
                  style: const TextStyle(fontSize: 12, color: Colors.black54)),
            const SizedBox(height: 8),
            // 💡 カレンダーと同じ追加画面を開く。
            //   シフトの入力画面には日付の欄が無い（カレンダーで選んだ日に入る作り）ので、
            //   先に日付を選んでもらう。予定の画面は中で日付を変えられるので今日で開く。
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final day = await showDatePicker(
                        context: context,
                        initialDate: today,
                        firstDate: today.subtract(const Duration(days: 365)),
                        lastDate: today.add(const Duration(days: 365)),
                        helpText: 'シフトの日付',
                      );
                      if (day == null || !context.mounted) return;
                      showAddShiftSheet(context, appState, day);
                    },
                    icon: const Icon(Icons.work_outline, size: 18),
                    label: const FittedBox(child: Text('シフト追加')), // 狭い幅で2行に折れないように
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => openAddEvent(context, appState, today),
                    icon: const Icon(Icons.event, size: 18),
                    label: const FittedBox(child: Text('予定追加')),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
