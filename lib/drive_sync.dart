// 💡 端末をまたいでデータを持ち回るための、Googleドライブ同期。
//   保存先は Drive の「アプリ専用フォルダ(appDataFolder)」。ユーザーのDrive上では
//   見えない領域で、このアプリが作ったファイルしか読み書きできない。
//
//   ⚠️ 家計データなので「新しい方で黙って上書き」はしない。
//     どちらも変わっている（＝競合）ときは呼び出し側に判断させる。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;

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
  restoringAuth, // 認証を取り直すためページ移動中
  notSignedIn, // 未連携
  noRemote, // ドライブにまだ無い
  upToDate, // 同じ
  localNewer, // こちらが新しい → アップロードすべき
  remoteNewer, // 向こうが新しい → 取り込むべき
  conflict, // 両方変わっている → ユーザーに選ばせる
  localChangedSinceCheck, // 判定のあとにこの端末で変更があった → 取り込まずに止めた
  error,
}

class DriveSyncResult {
  final DriveSyncState state;
  final DriveSnapshot? remote;
  final String? error;
  // 💡 判定したときの「この端末の最終変更時刻」。取り込む直前に変わっていたら、
  //   判定のあとにこの端末で変更があった＝黙って置き換えると消えるので取り込まない。
  final DateTime? localAtCheck;

  const DriveSyncResult(this.state, {this.remote, this.error, this.localAtCheck});

  String get message {
    switch (state) {
      case DriveSyncState.restoringAuth:
        return 'Google連携を復帰しています…';
      case DriveSyncState.notSignedIn:
        return 'Googleとの連携を更新してください（設定→Google連携で「連携し直す」）';
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
      case DriveSyncState.localChangedSinceCheck:
        return 'この端末で変更があったため、取り込みを見送りました（もう一度同期すると選べます）';
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
  final localChanged =
      dataUpdatedAt != null &&
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

// 💡 ドライブ上のファイルの読み書きと、認証の窓口。
//   テストで偽物に差し替えて「送信中・認証待ち・再試行中の変更が未同期として残るか」を確かめる。
abstract interface class DriveStore {
  Future<GoogleAccessState> ensureAccess();
  Future<T> withFreshToken<T>(Future<T> Function() run);
  Future<void> invalidateRejectedToken();
  Future<DriveSnapshot?> read();
  Future<void> write({required DateTime updatedAt, required String device, required String dataJson});
}

class GoogleDriveStore implements DriveStore {
  static const String fileName = 'pocket_maid_backup.json';
  static const String _appFolder = 'appDataFolder';

  String? _fileId; // 見つけたファイルID（毎回探さないように覚える）

  @override
  Future<GoogleAccessState> ensureAccess() => GmailService.instance.ensureAccess();

  @override
  Future<T> withFreshToken<T>(Future<T> Function() run) =>
      GmailService.instance.withFreshToken(run);

  @override
  Future<void> invalidateRejectedToken() => GmailService.instance.invalidateRejectedToken();

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
  @override
  Future<DriveSnapshot?> read() async {
    final api = await GmailService.instance.driveApi();
    if (api == null) return null;
    final id = await _findFileId(api);
    if (id == null) return null;

    final media =
        await api.files.get(
              id,
              downloadOptions: drive.DownloadOptions.fullMedia,
            )
            as drive.Media;

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

  // ドライブへ書き込む（無ければ作る）。
  @override
  Future<void> write({
    required DateTime updatedAt,
    required String device,
    required String dataJson,
  }) async {
    final api = await GmailService.instance.driveApi();
    if (api == null) throw StateError('Googleに未連携です');

    final payload = jsonEncode({
      'updatedAt': updatedAt.toIso8601String(),
      'device': device,
      'data': jsonDecode(dataJson),
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
  }
}

class DriveSync {
  DriveSync._(this._store);
  static final DriveSync instance = DriveSync._(GoogleDriveStore());

  /// テスト用: ドライブの窓口を差し替えた同期
  @visibleForTesting
  factory DriveSync.withStore(DriveStore store) => DriveSync._(store);

  static const String fileName = GoogleDriveStore.fileName;

  final DriveStore _store;

  // ドライブの中身を読む。無ければ null。
  Future<DriveSnapshot?> fetch() => _store.read();

  // 💡 いまの状況を判定する（何もしない）。
  //   「向こうが新しい」「両方変わっている」を区別して、勝手に上書きしないための入口。
  Future<DriveSyncResult> check(AppState app) async {
    try {
      // 💡 「連携したことがある」ではなく「いま本当に叩けるか」で判定する。
      final localAt = app.dataUpdatedAt;
      final access = await _store.ensureAccess();
      if (access == GoogleAccessState.redirecting) {
        return const DriveSyncResult(DriveSyncState.restoringAuth);
      }
      if (access == GoogleAccessState.needsInteraction) {
        return const DriveSyncResult(DriveSyncState.notSignedIn);
      }
      final remote = await _store.withFreshToken(fetch);
      if (remote == null) {
        return DriveSyncResult(DriveSyncState.noRemote, localAtCheck: localAt);
      }

      return DriveSyncResult(
        decideSyncState(
          remoteUpdatedAt: remote.updatedAt,
          knownRemoteAt: app.driveKnownRemoteAt,
          dataUpdatedAt: app.dataUpdatedAt,
          syncedAt: app.driveSyncedAt,
        ),
        remote: remote,
        localAtCheck: localAt,
      );
    } catch (e) {
      return _failure(e);
    }
  }

  // 💡 失敗の振り分け。トークン拒否はエラー文ではなく「連携の更新」を案内する。
  //   ⚠️ 取り直したトークンまで拒否されたら、捨ててここで止める（繰り返さない）。
  Future<DriveSyncResult> _failure(Object e) async {
    if (e is GoogleAuthRejected) {
      return DriveSyncResult(e.state == GoogleAccessState.redirecting
          ? DriveSyncState.restoringAuth
          : DriveSyncState.notSignedIn);
    }
    if (isRejectedTokenError(e)) {
      await _store.invalidateRejectedToken();
      return const DriveSyncResult(DriveSyncState.notSignedIn);
    }
    return DriveSyncResult(DriveSyncState.error, error: e.toString());
  }

  // 💡 何が起きているのかを端末の画面で確認するための説明文。
  //   「ログインしたのにデータが出ない」の原因（未連携／Drive未有効／
  //   そもそもドライブに何も無い）を切り分けられるようにする。
  Future<String> diagnose(AppState app) async {
    final sb = StringBuffer();
    final signedIn = await GmailService.instance.hasGmailAccess();
    sb.writeln('Google連携: ${signedIn ? 'OK' : '未連携'}');
    sb.writeln('────── 連携の内訳 ──────');
    sb.write(await GmailService.instance.authDiagnostics());
    sb.writeln('────────────');
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
  // ⚠️ 「送ったデータ」に対応するこの端末の状態だけを同期済みにする。
  //   書き出すのと同じ瞬間に「この端末の最終変更時刻」と送信時刻を控え、成功したらその値で記録する。
  //   以前は送信の途中（認証の取り直し・通信待ち）で時刻を取っていたため、その間の変更が
  //   送られていないのに同期済み扱いになり、次の自動保存で上がらなかった（B7）。
  Future<DriveSyncResult> pushNow(AppState app) async {
    try {
      final sentAt = app.clockNow();
      final localAt = app.dataUpdatedAt ?? sentAt;
      final json = app.exportJson();
      await _store.withFreshToken(
        () => _store.write(updatedAt: sentAt, device: app.deviceLabel, dataJson: json),
      );
      await app.markDriveSynced(localAt: localAt, remoteAt: sentAt);
      return const DriveSyncResult(DriveSyncState.upToDate);
    } catch (e) {
      return _failure(e);
    }
  }

  // ドライブの内容をこの端末へ取り込む
  // 💡 basedOn: 判定（check）の結果を元に取り込むとき。判定のあとにこの端末で変更があれば
  //   取り込まずに止める（置き換えでその変更が消えるため）。利用者が「置き換える」を
  //   明示的に選んだときは渡さない。
  // ⚠️ 取り込みの保存まで成功したときだけ同期済みにする（保存に失敗したらエラーを返す）。
  Future<DriveSyncResult> pullNow(
    AppState app, {
    DriveSnapshot? snapshot,
    DriveSyncResult? basedOn,
  }) async {
    try {
      final remote = snapshot ?? await _store.withFreshToken(fetch);
      if (remote == null) return const DriveSyncResult(DriveSyncState.noRemote);
      if (basedOn != null && app.dataUpdatedAt != basedOn.localAtCheck) {
        return DriveSyncResult(DriveSyncState.localChangedSinceCheck, remote: remote);
      }
      await app.importJson(remote.json);
      await app.markDriveSynced(localAt: app.clockNow(), remoteAt: remote.updatedAt);
      return DriveSyncResult(DriveSyncState.upToDate, remote: remote);
    } catch (e) {
      return _failure(e);
    }
  }
}
