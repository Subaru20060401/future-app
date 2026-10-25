// 💡 日時・場所・確認事項を一覧で読んでから、本人が登録を判断する。
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app_state.dart';
import '../mail_schedule_service.dart';
import '../widgets/google_account_tile.dart';
import '../widgets/mail_schedule_review_sheet.dart';

class MailScheduleScreen extends StatefulWidget {
  const MailScheduleScreen({super.key});
  @override
  State<MailScheduleScreen> createState() => _MailScheduleScreenState();
}

class _MailScheduleScreenState extends State<MailScheduleScreen> {
  bool _busy = false;
  String? _scanMessage;
  bool _scanFailed = false;

  Future<void> _scan() async {
    if (_busy) return;
    final app = context.read<AppState>();
    setState(() {
      _busy = true;
      _scanMessage = null;
    });
    try {
      if (!await ensureGoogleConnected(context) || !mounted) return;
      final result = await scanScheduleMails(app);
      if (!mounted) return;
      setState(() {
        _scanMessage = result.error?.startsWith('メールを確認できませんでした（') == true
            ? 'メールを確認できませんでした。Google連携と接続状況を確認してください。'
            : result.message;
        _scanFailed = !result.complete;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _scanMessage = 'メールを確認できませんでした。接続を確かめて、もう一度お試しください。';
          _scanFailed = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _restore(AppState app, ScheduleSuggestion s) {
    app.reopenScheduleSuggestion(s.id);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('確認待ちに戻しました')));
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pending = app.pendingScheduleSuggestions;
    final held =
        app.scheduleSuggestions
            .where((s) => s.status == SuggestionStatus.held)
            .toList()
          ..sort(
            (a, b) =>
                (a.start ?? a.receivedAt).compareTo(b.start ?? b.receivedAt),
          );
    final done = app.scheduleSuggestions.where((s) => !s.isOpen).toList()
      ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
    final colors = Theme.of(context).colorScheme;
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: colors.surface,
        appBar: AppBar(
          title: const Text('メールの予定'),
          actions: [
            IconButton(
              tooltip: 'メールを再確認',
              onPressed: _busy ? null : _scan,
              icon: _busy
                  ? const SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
            ),
          ],
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.center,
            tabs: [
              Tab(text: '確認待ち ${pending.length}'),
              Tab(text: '保留 ${held.length}'),
              const Tab(text: '履歴'),
            ],
          ),
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              if (_scanMessage != null)
                Material(
                  color: _scanFailed
                      ? colors.errorContainer
                      : colors.secondaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Semantics(
                            liveRegion: true,
                            child: Text(
                              _scanMessage!,
                              style: TextStyle(
                                color: _scanFailed
                                    ? colors.onErrorContainer
                                    : colors.onSecondaryContainer,
                              ),
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '確認結果を閉じる',
                          onPressed: () => setState(() => _scanMessage = null),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  ),
                ),
              Expanded(
                child: TabBarView(
                  children: [
                    _list(app, pending, section: 0),
                    _list(app, held, section: 1),
                    _list(app, done, section: 2),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _list(
    AppState app,
    List<ScheduleSuggestion> items, {
    required int section,
  }) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView.builder(
          key: PageStorageKey('mail-schedules-$section'),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          itemCount: items.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: items.isEmpty
                    ? _empty(section)
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            switch (section) {
                              0 => '登録する前に確認',
                              1 => 'あとで確認する予定',
                              _ => 'これまでの確認結果',
                            },
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            switch (section) {
                              0 => '日時と内容を確かめて、必要な予定を登録してください。',
                              1 => '準備ができたら、ここから内容を確認して登録できます。',
                              _ => '登録済み・不要・取消などの結果を確認できます。',
                            },
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
              );
            }
            return _card(app, items[index - 1]);
          },
        ),
      ),
    );
  }

  Widget _empty(int section) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 40),
    child: Column(
      children: [
        Icon(
          switch (section) {
            0 => Icons.mark_email_read_outlined,
            1 => Icons.bookmark_border,
            _ => Icons.history,
          },
          size: 48,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(height: 20),
        Text(
          switch (section) {
            0 => '確認待ちはありません',
            1 => '保留中の予定はありません',
            _ => '履歴はまだありません',
          },
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(switch (section) {
          0 => '新しい予約メールが届いたら、ここから探せます。\n見つかった予定は確認後に登録できます。',
          1 => '判断をあとにしたい予定は、詳細画面で「保留」にできます。',
          _ => '予定を登録したり、不要にしたりすると、ここに残ります。',
        }, textAlign: TextAlign.center),
        if (section == 0) ...[
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _busy ? null : _scan,
            icon: const Icon(Icons.manage_search),
            label: Text(_busy ? 'メールを確認中…' : 'メールから予定を探す'),
          ),
        ],
      ],
    ),
  );

  Widget _card(AppState app, ScheduleSuggestion s) {
    final colors = Theme.of(context).colorScheme;
    final action = switch (s.action) {
      SuggestionAction.add => s.kind == SuggestionKind.shift ? 'シフト' : '予定',
      SuggestionAction.change => '変更の確認',
      SuggestionAction.cancel => '取消の確認',
    };
    final warning = s.blockers.isNotEmpty
        ? s.blockers.first
        : s.missing.firstOrNull;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: colors.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                _badge(
                  action,
                  s.action == SuggestionAction.cancel
                      ? colors.errorContainer
                      : colors.secondaryContainer,
                  s.action == SuggestionAction.cancel
                      ? colors.onErrorContainer
                      : colors.onSecondaryContainer,
                ),
                if (s.sample)
                  _badge(
                    '見本',
                    colors.surfaceContainerHighest,
                    colors.onSurfaceVariant,
                  ),
                if (!s.isOpen || s.status == SuggestionStatus.held)
                  _badge(
                    suggestionStatusLabel(s.status),
                    colors.surfaceContainerHighest,
                    colors.onSurfaceVariant,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              s.title,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            _detail(
              Icons.schedule,
              AppState.scheduleWhenLabel(s),
              strong: true,
            ),
            if (s.location.isNotEmpty) ...[
              const SizedBox(height: 6),
              _detail(Icons.place_outlined, s.location),
            ],
            if (s.sender.isNotEmpty) ...[
              const SizedBox(height: 6),
              _detail(Icons.mail_outline, s.sender),
            ],
            if (warning != null &&
                s.isOpen &&
                s.action != SuggestionAction.cancel) ...[
              const SizedBox(height: 12),
              _detail(Icons.info_outline, '確認が必要：$warning'),
            ],
            const SizedBox(height: 12),
            if (s.isOpen)
              FilledButton.tonalIcon(
                onPressed: () => showSuggestionReviewSheet(context, app, s),
                icon: const Icon(Icons.chevron_right),
                label: Text(
                  s.action == SuggestionAction.cancel ? '取消内容を確認' : '内容を確認',
                ),
              )
            else
              OutlinedButton(
                onPressed: () => showSuggestionReviewSheet(context, app, s),
                child: const Text('詳細を見る'),
              ),
            if (s.status == SuggestionStatus.held ||
                s.status == SuggestionStatus.rejected)
              TextButton(
                onPressed: () => _restore(app, s),
                child: const Text('確認待ちに戻す'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _badge(String text, Color background, Color foreground) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      text,
      style: TextStyle(
        color: foreground,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  Widget _detail(IconData icon, String text, {bool strong = false}) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(
        icon,
        size: 20,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          text,
          style: TextStyle(
            fontWeight: strong ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    ],
  );
}
