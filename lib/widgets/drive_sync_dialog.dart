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
//
// 💡 pullOnly: 同期をONにしていない状態（ログインしただけ）で使う。
//   勝手にアップロードはせず、ドライブに置いてあるものを降ろす方向だけ行う。
Future<bool> runDriveSync(BuildContext context, AppState appState,
    {bool silent = false, bool pullOnly = false}) async {
  // 💡 silent は「順調なときに黙る」ためのもの。
  //   失敗まで黙ると「ログインしても何も起きない」になるので、エラーは必ず出す。
  void toast(String text, {Color? color, bool always = false}) {
    if (!context.mounted || (silent && !always)) return;
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
      toast(r.message, color: Colors.orange[800], always: true);
      return false;

    case DriveSyncState.noRemote:
    case DriveSyncState.localNewer:
      // 同期OFFのまま勝手に上げない（ユーザーが許可していない）
      if (pullOnly) return false;
      final up = await DriveSync.instance.pushNow(appState);
      toast(up.state == DriveSyncState.error ? up.message : 'ドライブへ保存しました',
          color: up.state == DriveSyncState.error ? Colors.orange[800] : null,
          always: up.state == DriveSyncState.error);
      return up.state != DriveSyncState.error;

    case DriveSyncState.remoteNewer:
      // こちらに未同期の変更が無いので、そのまま取り込んで安全
      final down = await DriveSync.instance.pullNow(appState, snapshot: r.remote);
      toast(
          down.state == DriveSyncState.error
              ? down.message
              : '別の端末の変更を取り込みました（${r.remote?.device ?? ''}）',
          color: down.state == DriveSyncState.error ? Colors.orange[800] : null,
          always: down.state == DriveSyncState.error);
      return down.state != DriveSyncState.error;

    case DriveSyncState.conflict:
      // 💡 ここを取りこぼすと「ログインしたのに何も起きない」になる。
      //   両方にデータがあるのは普通の状況なので、必ず選ばせる。
      final keep = await _askConflict(context, appState, r.remote!, pullOnly: pullOnly);
      if (keep == null || !context.mounted) return false;
      if (keep == _Keep.local) {
        if (pullOnly) return false; // 同期OFFなら「この端末のまま」＝何もしない
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
    BuildContext context, AppState appState, DriveSnapshot remote,
    {bool pullOnly = false}) {
  return showDialog<_Keep>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AlertDialog(
      title: Text(pullOnly ? 'ドライブのデータを取り込みますか？' : 'どちらの内容を残しますか？'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            pullOnly
                ? 'ドライブに別の端末のデータがあります。'
                  '取り込むと、この端末のデータは置き換わります。'
                : 'この端末と別の端末の両方でデータが変わっています。'
                  '選ばなかった方の変更は消えます。',
            style: const TextStyle(fontSize: 13),
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
          onPressed: () => Navigator.pop(context, _Keep.local),
          child: Text(pullOnly ? 'このまま使う' : 'この端末を残す'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(context, _Keep.remote),
          child: Text(pullOnly ? '取り込む' : 'ドライブを残す'),
        ),
      ],
    ),
  );
}
