// 💡 Googleログイン画面。「ログインしたら自分のデータが出てくる」ための入口。
//   ⚠️ これは他人からデータを守る仕組みではない（データはこの端末の中にある）。
//     ここでログインを求めるのは、ドライブから自分のデータを降ろすため。
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../gmail_service.dart';
import '../widgets/drive_sync_dialog.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    required this.appState,
    required this.onDone,
  });

  final AppState appState;
  final VoidCallback onDone;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await GmailService.instance.requestGmailAccess();
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _busy = false;
        _error = 'ログインできませんでした。ポップアップがブロックされていないか確認してください。';
      });
      return;
    }
    // 💡 ログインできたら、ドライブから自分のデータを降ろす。
    //   同期がOFFのときは「降ろす方向だけ」。勝手にアップロードはしない。
    //   （以前は競合状態を取りこぼして、ログインしても何も起きなかった）
    await runDriveSync(
      context,
      widget.appState,
      silent: true,
      pullOnly: !widget.appState.driveSyncEnabled,
    );
    if (mounted) widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    // 💡 ログインできない状況で自分のデータに触れなくなるのを防ぐ逃げ道。
    //   （そもそも他人を締め出す仕組みではないので、閉じ込める意味がない）
    final hasLocalData = widget.appState.shifts.isNotEmpty ||
        widget.appState.payments.isNotEmpty;

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.savings, size: 56, color: Colors.pink),
                const SizedBox(height: 12),
                const Text('ポケットメイド',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                const Text(
                  'Googleでログインすると、どの端末でも同じデータが使えます。',
                  style: TextStyle(fontSize: 13, color: Colors.grey),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                if (_busy)
                  const CircularProgressIndicator()
                else
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _login,
                      icon: const Icon(Icons.login),
                      label: const Text('Googleでログイン'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(_error!,
                        style: const TextStyle(color: Colors.red, fontSize: 12),
                        textAlign: TextAlign.center),
                  ),
                if (hasLocalData && !_busy)
                  TextButton(
                    onPressed: widget.onDone,
                    child: const Text('この端末のデータで続ける',
                        style: TextStyle(fontSize: 12)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
