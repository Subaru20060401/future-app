// 💡 GmailもDriveも同じGoogleアカウントを使うので、連携はここ1か所にまとめる。
//   （設定のあちこちにログイン導線があると、どれを押せばいいのか分からなくなる）
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../gmail_service.dart';
import 'drive_sync_dialog.dart';

// 連携済みなら true。未連携ならその場で連携を求める（ボタン操作から呼ぶこと）。
Future<bool> ensureGoogleConnected(BuildContext context) async {
  // 「連携したことがある」ではなく「いま叩けるか」で判定する
  if (await GmailService.instance.isUsable) return true;
  final ok = await GmailService.instance.requestGmailAccess();
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
        content: Text('Googleとの連携が必要です。ポップアップがブロックされていないか確認してください。'),
      ));
  }
  return ok;
}

class GoogleAccountTile extends StatefulWidget {
  const GoogleAccountTile({super.key});

  @override
  State<GoogleAccountTile> createState() => _GoogleAccountTileState();
}

class _GoogleAccountTileState extends State<GoogleAccountTile> {
  final _gmail = GmailService.instance;
  bool _busy = false;
  bool _connected = false; // いま本当にAPIを叩けるか
  bool _known = false; // 連携したことがある（トークンが切れているだけ）
  String? _email;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    // 起動直後は currentUser が空のことがあるので、静かにサインインを試す
    await _gmail.loadAuthState();
    if (!_gmail.isSignedIn) await _gmail.signInSilently();
    final ok = await _gmail.hasGmailAccess();
    if (!mounted) return;
    setState(() {
      // 💡 「連携したことがある」と「いま使える」は別。
      //   使えないのに連携中と出すと、同期で未連携と言われて混乱する。
      _connected = ok;
      _known = _gmail.signedInOnce;
      _email = _gmail.displayEmail;
    });
  }

  Future<void> _connect() async {
    setState(() => _busy = true);
    final ok = await _gmail.requestGmailAccess();
    await _refresh();
    if (mounted) setState(() => _busy = false);
    if (!ok || !mounted) return;
    // 💡 連携できたら、ドライブに自分のデータが置いてないか見に行く。
    //   （同期OFFのままだと勝手には上げない＝降ろす方向だけ聞く）
    final appState = context.read<AppState>();
    await runDriveSync(context, appState,
        silent: true, pullOnly: !appState.driveSyncEnabled);
  }

  Future<void> _disconnect(AppState appState) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Google連携を解除'),
        content: const Text(
            'メールの取り込みとドライブ同期が止まります。\n'
            'この端末に入っているデータは消えません。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('キャンセル')),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('解除する')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    await _gmail.signOut();
    // 連携が無いと同期できないので、あわせてOFFにする
    if (appState.driveSyncEnabled) await appState.setDriveSyncEnabled(false);
    await _refresh();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.read<AppState>();
    return ListTile(
      leading: Icon(
        _connected
            ? Icons.account_circle
            : (_known ? Icons.error_outline : Icons.account_circle_outlined),
        color: _connected
            ? Colors.green
            : (_known ? Colors.orange : Colors.grey),
      ),
      title: const Text('Googleアカウント'),
      subtitle: Text(
        _connected
            ? '連携中${_email == null ? '' : '：$_email'}\nメール取り込みとドライブ同期に使います'
            : (_known
                ? '${_email ?? ''}\n有効期限が切れています。「連携し直す」を押してください'
                : '未連携。メール取り込みとドライブ同期に必要です'),
        style: const TextStyle(fontSize: 12),
      ),
      isThreeLine: _connected || _known,
      trailing: _busy
          ? const SizedBox(
              width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: _connect,
                  child: Text(_connected ? '更新' : (_known ? '連携し直す' : '連携する')),
                ),
                if (_connected || _known)
                  TextButton(
                    onPressed: () => _disconnect(appState),
                    child: const Text('解除', style: TextStyle(color: Colors.grey)),
                  ),
              ],
            ),
    );
  }
}
