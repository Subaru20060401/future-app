// 💡 ドライブ同期: 「送ったデータに対応する状態」だけを同期済みにすること。
//   送信の途中（認証の取り直し・通信待ち・再試行）にこの端末で変えたものは、
//   ドライブに上がっていないので未同期のまま残らなければならない（B7）。
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_counter_app/app_state.dart';
import 'package:my_counter_app/drive_sync.dart';
import 'package:my_counter_app/gmail_service.dart';

import 'support/failing_prefs.dart';
import 'support/test_app.dart';

class FakeDriveStore implements DriveStore {
  DriveSnapshot? remote;
  Completer<void>? authGate; // 認証の取り直し中（完了するまで止める）
  Completer<void>? writeGate; // 通信待ち（完了するまで止める）
  int failFirstWrites = 0; // 最初の n 回の送信は 401 で失敗させ、取り直して再試行する
  final void Function()? onRetry;
  int writes = 0;

  FakeDriveStore({this.onRetry});

  @override
  Future<GoogleAccessState> ensureAccess() async => GoogleAccessState.ready;

  @override
  Future<T> withFreshToken<T>(Future<T> Function() run) async {
    if (authGate != null) await authGate!.future;
    try {
      return await run();
    } on _Rejected {
      onRetry?.call(); // 取り直しの間に変更が入る状況
      return run();
    }
  }

  @override
  Future<void> invalidateRejectedToken() async {}

  @override
  Future<DriveSnapshot?> read() async => remote;

  @override
  Future<void> write({
    required DateTime updatedAt,
    required String device,
    required String dataJson,
  }) async {
    writes++;
    if (failFirstWrites > 0) {
      failFirstWrites--;
      throw _Rejected();
    }
    if (writeGate != null) await writeGate!.future;
    remote = DriveSnapshot(updatedAt: updatedAt, device: device, json: dataJson);
  }
}

class _Rejected implements Exception {}

void main() {
  late DateTime t;
  Future<AppState> app() async {
    t = DateTime(2026, 11, 19, 10);
    final a = await clockApp(() => t);
    a.currentBalance = 1000;
    await a.saveData(); // dataUpdatedAt = 10:00
    return a;
  }

  void tick() => t = t.add(const Duration(seconds: 1));

  DriveSyncState localState(AppState a, FakeDriveStore s) => decideSyncState(
        remoteUpdatedAt: s.remote!.updatedAt,
        knownRemoteAt: a.driveKnownRemoteAt,
        dataUpdatedAt: a.dataUpdatedAt,
        syncedAt: a.driveSyncedAt,
      );

  test('何も変えなければ、送ったあとは最新', () async {
    final a = await app();
    final s = FakeDriveStore();
    tick();
    final r = await DriveSync.withStore(s).pushNow(a);
    expect(r.state, DriveSyncState.upToDate);
    expect(localState(a, s), DriveSyncState.upToDate);
  });

  test('通信待ちの間の変更は未同期のまま残る', () async {
    final a = await app();
    final s = FakeDriveStore()..writeGate = Completer();
    tick();
    final push = DriveSync.withStore(s).pushNow(a);
    await Future<void>.delayed(Duration.zero);
    tick();
    a.updateBalance(2000); // 送信中の変更
    await settle();
    s.writeGate!.complete();
    await push;
    expect(jsonDecode(s.remote!.json)['currentBalance'], 1000); // 送ったのは変更前
    expect(localState(a, s), DriveSyncState.localNewer); // 次の自動保存で上がる
  });

  test('認証の取り直し中の変更は未同期のまま残る', () async {
    final a = await app();
    final s = FakeDriveStore()..authGate = Completer();
    tick();
    final push = DriveSync.withStore(s).pushNow(a);
    await Future<void>.delayed(Duration.zero);
    tick();
    a.updateWalletCash(500);
    await settle();
    s.authGate!.complete();
    await push;
    expect(localState(a, s), DriveSyncState.localNewer);
  });

  test('再試行の間の変更は未同期のまま残る', () async {
    late AppState a;
    final s = FakeDriveStore(onRetry: () {
      tick();
      a.updateWalletCash(700);
    })
      ..failFirstWrites = 1;
    a = await app();
    tick();
    await DriveSync.withStore(s).pushNow(a);
    await settle();
    expect(s.writes, 2);
    expect(localState(a, s), DriveSyncState.localNewer);
  });

  test('送信に失敗したら同期済みにしない', () async {
    final a = await app();
    final s = FakeDriveStore()..failFirstWrites = 2; // 再試行も失敗
    tick();
    final r = await DriveSync.withStore(s).pushNow(a);
    expect(r.state, DriveSyncState.error);
    expect(a.driveSyncedAt, isNull);
  });

  group('取り込み', () {
    Future<DriveSnapshot> remoteWith(int balance) async {
      final other = await fixedApp(DateTime(2026, 11, 19, 9));
      other.currentBalance = balance;
      return DriveSnapshot(
          updatedAt: DateTime(2026, 11, 19, 9, 30), device: '別の端末', json: other.exportJson());
    }

    test('判定のあとにこの端末で変えたら、取り込まない（変更が置き換えで消えないように）', () async {
      final remote = await remoteWith(9999);
      final a = await app();
      final s = FakeDriveStore()..remote = remote;
      final sync = DriveSync.withStore(s);
      final checked = await sync.check(a);
      tick();
      a.updateBalance(3333); // 判定のあとの変更
      await settle();
      final r = await sync.pullNow(a, snapshot: checked.remote, basedOn: checked);
      expect(r.state, DriveSyncState.localChangedSinceCheck);
      expect(a.currentBalance, 3333);
    });

    test('保存に失敗したら同期済みにせず、エラーを返す', () async {
      final remote = await remoteWith(9999);
      final a = await app();
      final store = await useFailingStore();
      store.failAfter = store.writes + 2;
      final r = await DriveSync.withStore(FakeDriveStore()..remote = remote)
          .pullNow(a, snapshot: remote);
      expect(r.state, DriveSyncState.error);
      expect(a.driveSyncedAt, isNull);
      expect(a.currentBalance, 1000); // 取り込む前に戻る
    });

    test('成功したら取り込んだ内容になり、最新になる', () async {
      final remote = await remoteWith(9999);
      final a = await app();
      final s = FakeDriveStore()..remote = remote;
      final r = await DriveSync.withStore(s).pullNow(a, snapshot: remote);
      expect(r.state, DriveSyncState.upToDate);
      expect(a.currentBalance, 9999);
      expect(localState(a, s), DriveSyncState.upToDate);
    });
  });
}
