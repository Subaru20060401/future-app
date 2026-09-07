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
  String? _detail; // 失敗の詳細（原因の切り分け用）

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _error = null;
      _detail = null;
    });
    final ok = await GmailService.instance.requestGmailAccess();
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _busy = false;
        _error = 'ログインできませんでした。';
        _detail = GmailService.instance.lastAuthError;
      });
      return;
    }
    // 💡 「ログインしたらどの端末でも同じデータ」がこの画面の目的なので、
    //   ログインできた時点で同期もONにする（スイッチを2つ探させない）。
    if (!widget.appState.driveSyncEnabled) {
      await widget.appState.setDriveSyncEnabled(true);
    }
    if (!mounted) return;
    await runDriveSync(context, widget.appState, silent: true);
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
                if (_error != null) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(_error!,
                        style: const TextStyle(color: Colors.red, fontSize: 13),
                        textAlign: TextAlign.center),
                  ),
                  // 💡 iPhoneはポップアップが既定でブロックされていることが多い。
                  //   どこを触ればいいかまで書く。
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'iPhoneのChromeなら\n'
                      '「…」→ 設定 → コンテンツの設定 → ポップアップをブロック\n'
                      'をオフにしてから、もう一度お試しください。\n\n'
                      'ログインせずに移したいときは、パソコン側で\n'
                      '設定 → データのバックアップ → ファイルに書き出し（JSON）\n'
                      'を保存して、この端末の「ファイルから読み込み」で取り込めます。',
                      style: TextStyle(fontSize: 11, color: Colors.grey),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  if (_detail != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(_detail!,
                          style: const TextStyle(fontSize: 10, color: Colors.grey),
                          textAlign: TextAlign.center),
                    ),
                ],
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
