// 💡 端末をまたいでデータを持ち回るための、Googleドライブ同期。
//   保存先は Drive の「アプリ専用フォルダ(appDataFolder)」。ユーザーのDrive上では
//   見えない領域で、このアプリが作ったファイルしか読み書きできない。
//
//   ⚠️ 家計データなので「新しい方で黙って上書き」はしない。
//     どちらも変わっている（＝競合）ときは呼び出し側に判断させる。
import 'dart:async';
import 'dart:convert';

import 'package:googleapis/drive/v3.dart' as drive;

import 'app_state.dart';
import 'gmail_service.dart';

// ドライブ上の中身
class DriveSnapshot {
  final DateTime updatedAt; // 書き込んだ端末での更新時刻
  final String device; // 書き込んだ端末の名前（表示用）
  final String json; // AppState.exportJson() の中身

  const DriveSnapshot({
    required this.updatedAt,
    required this.device,
    required this.json,
  });
}

// 同期の状況
enum DriveSyncState {
  notSignedIn, // 未連携
  noRemote, // ドライブにまだ無い
  upToDate, // 同じ
  localNewer, // こちらが新しい → アップロードすべき
  remoteNewer, // 向こうが新しい → 取り込むべき
  conflict, // 両方変わっている → ユーザーに選ばせる
  error,
}

class DriveSyncResult {
  final DriveSyncState state;
  final DriveSnapshot? remote;
  final String? error;

  const DriveSyncResult(this.state, {this.remote, this.error});

  String get message {
    switch (state) {
      case DriveSyncState.notSignedIn:
        return 'Googleに未連携です（設定から連携してください）';
      case DriveSyncState.noRemote:
        return 'ドライブにまだバックアップがありません';
      case DriveSyncState.upToDate:
        return '最新の状態です';
      case DriveSyncState.localNewer:
        return 'この端末の方が新しいです';
      case DriveSyncState.remoteNewer:
        return '別の端末の変更があります';
      case DriveSyncState.conflict:
        return 'この端末と別の端末の両方が変更されています';
      case DriveSyncState.error:
        return describeDriveError(error ?? '');
    }
  }
}


// 💡 どちらが新しいかの判定。データ消失に直結するので純粋関数にして
//   test/drive_sync_test.dart で固めている。
//   - knownRemoteAt: 前回そろえた時点の「ドライブ側の更新時刻」
//   - dataUpdatedAt: この端末でデータが最後に変わった時刻
//   - syncedAt: 最後にドライブとそろえた時刻
DriveSyncState decideSyncState({
  required DateTime remoteUpdatedAt,
  required DateTime? knownRemoteAt,
  required DateTime? dataUpdatedAt,
  required DateTime? syncedAt,
}) {
  // ドライブ側が、前回そろえたときから変わっているか
  final remoteChanged =
      knownRemoteAt == null || remoteUpdatedAt.isAfter(knownRemoteAt);
  // この端末が、前回そろえたときから変わっているか
  final localChanged = dataUpdatedAt != null &&
      (syncedAt == null || dataUpdatedAt.isAfter(syncedAt));

  if (remoteChanged && localChanged) return DriveSyncState.conflict;
  if (remoteChanged) return DriveSyncState.remoteNewer;
  if (localChanged) return DriveSyncState.localNewer;
  return DriveSyncState.upToDate;
}


// 💡 同期の失敗は原因が分かれば自分で直せるものが多いので、
//   生のAPIエラーではなく「次に何をすればいいか」を返す。
String describeDriveError(String raw) {
  final lower = raw.toLowerCase();
  if (lower.contains('has not been used') || lower.contains('is disabled')) {
    return 'ドライブの利用が有効になっていません。'
        'Google Cloudのプロジェクトで「Google Drive API」を有効にしてください。';
  }
  if (lower.contains('insufficient') ||
      lower.contains('scope') ||
      lower.contains('403')) {
    return 'ドライブへのアクセスが許可されていません。'
        '設定→Google連携で一度「解除」してから連携し直してください。';
  }
  if (lower.contains('401') || lower.contains('unauthorized')) {
    return 'ログインの有効期限が切れています。設定→Google連携で連携し直してください。';
  }
  if (lower.contains('network') || lower.contains('failed to fetch')) {
    return '通信に失敗しました。電波の良い場所でもう一度お試しください。';
  }
  return '同期に失敗: $raw';
}

class DriveSync {
  DriveSync._();
  static final DriveSync instance = DriveSync._();

  static const String fileName = 'pocket_maid_backup.json';
  static const String _appFolder = 'appDataFolder';

  String? _fileId; // 見つけたファイルID（毎回探さないように覚える）

  Future<String?> _findFileId(drive.DriveApi api) async {
    if (_fileId != null) return _fileId;
    final res = await api.files.list(
      spaces: _appFolder,
      q: "name = '$fileName' and trashed = false",
      $fields: 'files(id,modifiedTime)',
      pageSize: 10,
    );
    final files = res.files;
    if (files == null || files.isEmpty) return null;
    return _fileId = files.first.id;
  }

  // ドライブの中身を読む。無ければ null。
  Future<DriveSnapshot?> fetch() async {
    final api = await GmailService.instance.driveApi();
    if (api == null) return null;
    final id = await _findFileId(api);
    if (id == null) return null;

    final media = await api.files.get(
      id,
      downloadOptions: drive.DownloadOptions.fullMedia,
    ) as drive.Media;

    final bytes = <int>[];
    await for (final chunk in media.stream) {
      bytes.addAll(chunk);
    }
    final map = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final at = DateTime.tryParse(map['updatedAt'] as String? ?? '');
    if (at == null) return null;
    return DriveSnapshot(
      updatedAt: at,
      device: map['device'] as String? ?? '不明な端末',
      json: jsonEncode(map['data']),
    );
  }

  // ドライブへ書き込む（無ければ作る）。書き込んだ更新時刻を返す。
  Future<DateTime> upload(String exportedJson, {required String device}) async {
    final api = await GmailService.instance.driveApi();
    if (api == null) throw StateError('Googleに未連携です');

    final now = DateTime.now();
    final payload = jsonEncode({
      'updatedAt': now.toIso8601String(),
      'device': device,
      'data': jsonDecode(exportedJson),
    });
    final bytes = utf8.encode(payload);
    final media = drive.Media(Stream.value(bytes), bytes.length);

    final id = await _findFileId(api);
    if (id == null) {
      final created = await api.files.create(
        drive.File()
          ..name = fileName
          ..parents = [_appFolder],
        uploadMedia: media,
        $fields: 'id',
      );
      _fileId = created.id;
    } else {
      await api.files.update(drive.File(), id, uploadMedia: media);
    }
    return now;
  }

  // 💡 いまの状況を判定する（何もしない）。
  //   「向こうが新しい」「両方変わっている」を区別して、勝手に上書きしないための入口。
  Future<DriveSyncResult> check(AppState app) async {
    try {
      if (!await GmailService.instance.hasGmailAccess()) {
        return const DriveSyncResult(DriveSyncState.notSignedIn);
      }
      final remote = await fetch();
      if (remote == null) return const DriveSyncResult(DriveSyncState.noRemote);

      return DriveSyncResult(
        decideSyncState(
          remoteUpdatedAt: remote.updatedAt,
          knownRemoteAt: app.driveKnownRemoteAt,
          dataUpdatedAt: app.dataUpdatedAt,
          syncedAt: app.driveSyncedAt,
        ),
        remote: remote,
      );
    } catch (e) {
      return DriveSyncResult(DriveSyncState.error, error: e.toString());
    }
  }

  // 💡 何が起きているのかを端末の画面で確認するための説明文。
  //   「ログインしたのにデータが出ない」の原因（未連携／Drive未有効／
  //   そもそもドライブに何も無い）を切り分けられるようにする。
  Future<String> diagnose(AppState app) async {
    final sb = StringBuffer();
    final signedIn = await GmailService.instance.hasGmailAccess();
    sb.writeln('Google連携: ${signedIn ? 'OK' : '未連携'}');
    sb.writeln('この端末: ${app.deviceLabel}');
    sb.writeln('同期の設定: ${app.driveSyncEnabled ? 'ON' : 'OFF'}');
    sb.writeln('この端末の最終変更: ${_fmt(app.dataUpdatedAt)}');
    sb.writeln('最後にそろえた時刻: ${_fmt(app.driveSyncedAt)}');
    sb.writeln('────────────');

    if (!signedIn) {
      sb.writeln('→ まず「連携する」を押してください。');
      return sb.toString();
    }
    try {
      final remote = await fetch();
      if (remote == null) {
        sb.writeln('ドライブ: まだ何も置かれていません');
        sb.writeln('→ データがある端末で同期をONにして、先にアップロードしてください。');
      } else {
        sb.writeln('ドライブ: あり');
        sb.writeln('  書き込んだ端末: ${remote.device}');
        sb.writeln('  更新時刻: ${_fmt(remote.updatedAt)}');
        sb.writeln('  データ量: ${remote.json.length} 文字');
        final r = await check(app);
        sb.writeln('判定: ${r.message}');
      }
    } catch (e) {
      sb.writeln('ドライブの確認に失敗しました');
      sb.writeln(describeDriveError(e.toString()));
    }
    return sb.toString();
  }

  static String _fmt(DateTime? d) =>
      d == null ? '—' : d.toLocal().toString().substring(0, 16);

  // こちらの内容でドライブを更新する
  Future<DriveSyncResult> pushNow(AppState app) async {
    try {
      final at = await upload(app.exportJson(), device: app.deviceLabel);
      app.markDriveSynced(localAt: at, remoteAt: at);
      return const DriveSyncResult(DriveSyncState.upToDate);
    } catch (e) {
      return DriveSyncResult(DriveSyncState.error, error: e.toString());
    }
  }

  // ドライブの内容をこの端末へ取り込む
  Future<DriveSyncResult> pullNow(AppState app, {DriveSnapshot? snapshot}) async {
    try {
      final remote = snapshot ?? await fetch();
      if (remote == null) return const DriveSyncResult(DriveSyncState.noRemote);
      app.importJson(remote.json);
      app.markDriveSynced(localAt: DateTime.now(), remoteAt: remote.updatedAt);
      return DriveSyncResult(DriveSyncState.upToDate, remote: remote);
    } catch (e) {
      return DriveSyncResult(DriveSyncState.error, error: e.toString());
    }
  }
}
