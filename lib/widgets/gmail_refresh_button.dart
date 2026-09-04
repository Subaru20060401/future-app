import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app_state.dart';
import '../gmail_service.dart';
import '../gmail_sync.dart';

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
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(result.message),
        backgroundColor: result.skipped ? Colors.orange[800] : null,
        duration: Duration(seconds: result.skipped ? 6 : 4),
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
