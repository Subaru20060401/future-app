// 💡 Googleドライブ同期の実行と、競合したときの選択ダイアログ。
//   家計データなので、どちらも変わっているときは必ずユーザーに選ばせる。
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../drive_sync.dart';

String _fmt(DateTime? d) =>
    d == null ? '—' : DateFormat('M/d HH:mm').format(d.toLocal());

// 同期を1回まわす。競合したらダイアログで選ばせる。
// 戻り値: 実際に何かした（アップロード/取り込み）なら true。
Future<bool> runDriveSync(BuildContext context, AppState appState,
    {bool silent = false}) async {
  void toast(String text, {Color? color}) {
    if (!context.mounted || silent) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), backgroundColor: color));
  }

  final r = await DriveSync.instance.check(appState);
  if (!context.mounted) return false;

  switch (r.state) {
    case DriveSyncState.upToDate:
      toast('ドライブと同じ内容です');
      return false;

    case DriveSyncState.notSignedIn:
    case DriveSyncState.error:
      toast(r.message, color: Colors.orange[800]);
      return false;

    case DriveSyncState.noRemote:
    case DriveSyncState.localNewer:
      final up = await DriveSync.instance.pushNow(appState);
      toast(up.state == DriveSyncState.error
          ? up.message
          : 'ドライブへ保存しました');
      return up.state != DriveSyncState.error;

    case DriveSyncState.remoteNewer:
      // こちらに未同期の変更が無いので、そのまま取り込んで安全
      final down = await DriveSync.instance.pullNow(appState, snapshot: r.remote);
      toast(down.state == DriveSyncState.error
          ? down.message
          : '別の端末の変更を取り込みました（${r.remote?.device ?? ''}）');
      return down.state != DriveSyncState.error;

    case DriveSyncState.conflict:
      final keep = await _askConflict(context, appState, r.remote!);
      if (keep == null || !context.mounted) return false;
      if (keep == _Keep.local) {
        final up = await DriveSync.instance.pushNow(appState);
        toast(up.state == DriveSyncState.error ? up.message : 'この端末の内容で上書きしました');
        return up.state != DriveSyncState.error;
      }
      final down = await DriveSync.instance.pullNow(appState, snapshot: r.remote);
      toast(down.state == DriveSyncState.error ? down.message : 'ドライブの内容で置き換えました');
      return down.state != DriveSyncState.error;
  }
}

enum _Keep { local, remote }

Future<_Keep?> _askConflict(
    BuildContext context, AppState appState, DriveSnapshot remote) {
  return showDialog<_Keep>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AlertDialog(
      title: const Text('どちらの内容を残しますか？'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'この端末と別の端末の両方でデータが変わっています。'
            '選ばなかった方の変更は消えます。',
            style: TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 12),
          Text('この端末（${appState.deviceLabel}）\n'
              '最終変更 ${_fmt(appState.dataUpdatedAt)}'),
          const SizedBox(height: 8),
          Text('ドライブ（${remote.device}）\n'
              '最終変更 ${_fmt(remote.updatedAt)}'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('あとで'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _Keep.remote),
          child: const Text('ドライブを残す'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(context, _Keep.local),
          child: const Text('この端末を残す'),
        ),
      ],
    ),
  );
}
