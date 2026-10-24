// 💡 メールから見つけた予定の提案の一覧（計画書 §4）。確認待ち／保留／履歴に分ける。
//   今は Gmail・AI につないでいない。設定の「見本の提案を入れて試す」で、確認の流れだけ試せる。
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../widgets/mail_schedule_review_sheet.dart';

class MailScheduleScreen extends StatelessWidget {
  const MailScheduleScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final all = app.scheduleSuggestions;
    final pending = app.pendingScheduleSuggestions;
    final held = all.where((s) => s.status == SuggestionStatus.held).toList();
    final done = all.where((s) => !s.isOpen).toList()
      ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('メールから見つけた予定'),
          bottom: TabBar(tabs: [
            Tab(text: '確認待ち（${pending.length}）'),
            Tab(text: '保留（${held.length}）'),
            const Tab(text: '履歴'),
          ]),
        ),
        body: TabBarView(children: [
          _list(context, app, pending, '確認待ちの提案はありません'),
          _list(context, app, held, '保留中の提案はありません', reopen: true),
          _list(context, app, done, 'まだ履歴はありません'),
        ]),
      ),
    );
  }

  Widget _list(BuildContext context, AppState app, List<ScheduleSuggestion> items, String empty,
      {bool reopen = false}) {
    if (items.isEmpty) {
      return Center(child: Text(empty, style: const TextStyle(color: Colors.black54)));
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final s = items[i];
        final icon = switch (s.action) {
          SuggestionAction.add => s.kind == SuggestionKind.shift ? Icons.work_outline : Icons.event,
          SuggestionAction.change => Icons.edit_calendar,
          SuggestionAction.cancel => Icons.event_busy,
        };
        return ListTile(
          leading: Icon(icon, color: s.isOpen ? Colors.indigo : Colors.grey),
          title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            [
              AppState.scheduleWhenLabel(s),
              if (!s.isOpen) suggestionStatusLabel(s.status),
              if (s.sample) '見本',
            ].join('・'),
            style: const TextStyle(fontSize: 12),
          ),
          trailing: reopen
              ? TextButton(
                  onPressed: () => app.reopenScheduleSuggestion(s.id),
                  child: const Text('確認待ちに戻す'),
                )
              : const Icon(Icons.chevron_right),
          onTap: () => showSuggestionReviewSheet(context, app, s),
        );
      },
    );
  }
}
