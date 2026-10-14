import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app_state.dart';
import '../gmail_service.dart';
import '../gmail_sync.dart';
import 'sync_status.dart';

// 💡 どの画面にも置けるGmail取得ボタン（AppBarのアクション用）。
//   取得中はスピナー、結果はSnackBarで通知。
class GmailRefreshButton extends StatefulWidget {
  const GmailRefreshButton({super.key});

  @override
  State<GmailRefreshButton> createState() => _GmailRefreshButtonState();
}

class _GmailRefreshButtonState extends State<GmailRefreshButton> {
  bool _loading = false;

  Future<void> _run() async {
    if (_loading) return;
    setState(() => _loading = true);
    final appState = context.read<AppState>();
    var result = await syncGmail(appState);
    // 💡 Webで読み取り許可が無いときは、この場（ボタン操作の延長）で許可を求めて
    //   もう一度だけ同期する。ここを逃すとポップアップがブロックされる。
    if (result.needsPermission) {
      if (await GmailService.instance.requestGmailAccess()) {
        result = await syncGmail(appState);
      }
    }
    if (!mounted) return;
    setState(() => _loading = false);
    // 💡 結果は短い一言だけ。浮かせて出すので、＋ボタンや下のタブを覆わない。
    //   内訳（新しく入った件数・取り込み直しで外れた件数）は「詳細」から。
    final s = lastGmailSync.value;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(result.shortMessage),
        backgroundColor: result.ok ? null : Colors.orange[800],
        duration: Duration(seconds: result.ok ? 3 : 6),
        action: s == null
            ? null
            : SnackBarAction(label: '詳細', onPressed: () => showSyncDetail(context, s)),
      ));
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'メールから更新',
      onPressed: _loading ? null : _run,
      icon: _loading
          ? const SizedBox(
              width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.sync),
    );
  }
}
