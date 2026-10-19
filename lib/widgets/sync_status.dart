// 💡 メール更新の結果を、画面を覆わずに出す（UI改善計画 2026-10-14 の段階2）。
//   以前は大きな通知（SnackBar）が明細や＋ボタンを覆い、
//   「◯件追加 / ◯件削除」の削除が、自分で消したものと混同されやすかった。
//   ・ホームの上に一行だけ「メールを確認しました 22:00 ・詳細」
//   ・失敗や見送りのときは色を変え、再試行を出す（消える通知だけにしない）
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../gmail_service.dart';
import '../gmail_sync.dart';

Future<void> showSyncDetail(BuildContext context, ({DateTime at, GmailSyncResult result}) s) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(s.result.shortMessage),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('今回の確認 ${DateFormat('M/d HH:mm').format(s.at)}',
              style: const TextStyle(fontSize: 12, color: Colors.black54)),
          // 💡 失敗していても、いつまでのメールが反映済みかを分かるようにする
          if (!s.result.ok)
            Text(
              lastGmailSuccessAt == null
                  ? '最後に成功: この画面を開いてからはまだありません'
                  : '最後に成功 ${DateFormat('M/d HH:mm').format(lastGmailSuccessAt!)}',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
          if (!s.result.ok)
            const Text('保存済みの明細と残高はそのままです',
                style: TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 8),
          for (final line in s.result.detailLines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(line, style: const TextStyle(fontSize: 13)),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('閉じる')),
      ],
    ),
  );
}

class SyncStatusBar extends StatefulWidget {
  const SyncStatusBar({super.key});

  @override
  State<SyncStatusBar> createState() => _SyncStatusBarState();
}

class _SyncStatusBarState extends State<SyncStatusBar> {
  bool _retrying = false;

  Future<void> _retry() async {
    setState(() => _retrying = true);
    final appState = context.read<AppState>();
    var r = await syncGmail(appState);
    // 💡 期限切れは、ただ取り直しても直らない。このボタン操作の中で許可を求めてから
    //   もう一度だけ確認する（更新ボタンと同じ流れ）。
    if (r.needsPermission && await GmailService.instance.requestGmailAccess()) {
      r = await syncGmail(appState);
    }
    if (mounted) setState(() => _retrying = false);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: lastGmailSync,
      builder: (context, s, _) {
        if (s == null) return const SizedBox.shrink();
        // ⚠️ 一度も連携していない人に「期限切れ」「再試行」と出さない
        //   （メール取り込みを使っていないだけ。連携は設定から）。
        if (s.result.notSignedIn) return const SizedBox.shrink();
        if (s.result.needsPermission && !GmailService.instance.signedInOnce) {
          return const SizedBox.shrink();
        }
        final ok = s.result.ok;
        final color = ok ? Colors.black54 : Colors.orange[900]!;
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: ok ? Colors.white.withValues(alpha: 0.5) : Colors.orange[50],
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(ok ? Icons.check_circle_outline : Icons.error_outline,
                    size: 16, color: color),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${s.result.shortMessage}  ${DateFormat('HH:mm').format(s.at)}',
                    style: TextStyle(fontSize: 12, color: color),
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                  onPressed: () => showSyncDetail(context, s),
                  child: const Text('詳細', style: TextStyle(fontSize: 12)),
                ),
                if (!ok && !s.result.restoringAuth)
                  TextButton(
                    style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                    onPressed: _retrying ? null : _retry,
                    child: Text(
                        _retrying
                            ? '確認中…'
                            : s.result.needsPermission
                                ? '連携し直す'
                                : '再試行',
                        style: const TextStyle(fontSize: 12)),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
