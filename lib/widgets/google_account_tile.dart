// 💡 GmailもDriveも同じGoogleアカウントを使うので、連携はここ1か所にまとめる。
//   （設定のあちこちにログイン導線があると、どれを押せばいいのか分からなくなる）
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../gmail_service.dart';
import 'drive_sync_dialog.dart';

// 連携済みなら true。未連携ならその場で連携を求める（ボタン操作から呼ぶこと）。
Future<bool> ensureGoogleConnected(BuildContext context) async {
  if (await GmailService.instance.hasGmailAccess()) return true;
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
  bool _connected = false;
  String? _email;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    // 起動直後は currentUser が空のことがあるので、静かにサインインを試す
    if (!_gmail.isSignedIn) await _gmail.signInSilently();
    final ok = await _gmail.hasGmailAccess();
    if (!mounted) return;
    setState(() {
      _connected = ok;
      _email = _gmail.account?.email;
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
        _connected ? Icons.account_circle : Icons.account_circle_outlined,
        color: _connected ? Colors.green : Colors.grey,
      ),
      title: const Text('Googleアカウント'),
      subtitle: Text(
        _connected
            ? '連携中${_email == null ? '' : '：$_email'}\nメール取り込みとドライブ同期に使います'
            : '未連携。メール取り込みとドライブ同期に必要です',
        style: const TextStyle(fontSize: 12),
      ),
      isThreeLine: _connected,
      trailing: _busy
          ? const SizedBox(
              width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : TextButton(
              onPressed: _connected ? () => _disconnect(appState) : _connect,
              child: Text(_connected ? '解除' : '連携する'),
            ),
    );
  }
}
