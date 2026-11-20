// 💡 GPT 実装レビュー（83d9ca5）の 3 件の周辺: 保存の入口の統一・取り込み中の編集・false を返す保存先。
//   すべて永続化されたストアから読み直して確かめる（SharedPreferences.resetStatic）。
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:my_counter_app/app_state.dart';
import 'package:my_counter_app/drive_sync.dart';

import 'drive_push_pull_test.dart' show FakeDriveStore;
import 'support/test_app.dart';

/// 指定したキーで待たせる・false を返す・例外を投げる、を選べるストア
class ProbeStore extends InMemorySharedPreferencesStore {
  ProbeStore(Map<String, Object> d) : super.withData(d);
  String? blockKey;
  Completer<void> entered = Completer<void>();
  Completer<void> release = Completer<void>();
  Set<String> falseOnSet = {};
  Set<String> falseOnRemove = {};
  String? crashOnSet; // このキー以降の書き込みをすべて失敗させる（終了と同じ）
  bool crashed = false;

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (crashed || key == crashOnSet) {
      crashed = true;
      throw StateError('終了（テスト）: $key');
    }
    if (falseOnSet.contains(key)) return false;
    if (key == blockKey) {
      blockKey = null;
      entered.complete();
      await release.future;
    }
    return super.setValue(type, key, value);
  }

  @override
  Future<bool> remove(String key) async {
    if (crashed) throw StateError('終了（テスト）: remove $key');
    if (falseOnRemove.contains(key)) return false;
    return super.remove(key);
  }

  void heal() {
    falseOnSet = {};
    falseOnRemove = {};
    crashOnSet = null;
    crashed = false;
  }
}

Future<ProbeStore> install() async {
  final s = ProbeStore(await SharedPreferencesStorePlatform.instance.getAll());
  SharedPreferencesStorePlatform.instance = s;
  SharedPreferences.resetStatic();
  return s;
}

final day = DateTime(2026, 11, 20, 10);
Future<AppState> restart() async {
  SharedPreferences.resetStatic();
  final a = AppState(clock: () => day);
  await a.ready;
  return a;
}

String f(String k) => 'flutter.$k';

void main() {
  group('カード設定の保存も列を通る（保存の途中の変更が古い値で上書きされない）', () {
    final edits = <String, void Function(AppState)>{
      '引落日を変える': (a) => a.setCardPaymentDay('A', 26),
      '締め日を変える': (a) => a.setCardClosingDay('A', 15),
      'カードを外す': (a) => a.removeCard('A'),
      '名前を変える': (a) => a.renameOrMergeCard('A', 'A2'),
    };
    for (final e in edits.entries) {
      test(e.key, () async {
        final a = await fixedApp(day);
        a.cardPaymentDays['A'] = 27;
        await a.saveData();
        final s = await install();
        s.blockKey = f('saved_card_payment_days');
        final saving = a.saveData();
        await s.entered.future;
        e.value(a);
        final wantDays = Map.of(a.cardPaymentDays);
        final wantClosing = Map.of(a.cardClosingDays);
        s.release.complete();
        await saving;
        final b = await restart();
        expect(b.cardPaymentDays, wantDays);
        expect(b.cardClosingDays, wantClosing);
        final all = await s.getAll();
        expect(all.containsKey(f(AppState.kPendingWriteKey)), isFalse);
      });
    }

    test('後から並んだ保存が途中で止まっても、次の起動で新しい設定に整う（一時記録が新しい設定を巻き戻さない）',
        () async {
      final a = await fixedApp(day);
      a.cardPaymentDays['A'] = 27;
      await a.saveData();
      final s = await install();
      s.blockKey = f('saved_card_payment_days');
      final first = a.saveData();
      await s.entered.future;
      a.setCardPaymentDay('A', 26); // 2 回目の保存が後ろに並ぶ
      s.crashOnSet = f('saved_shifts'); // 2 回目の保存の本体（1 件目）で終了
      s.release.complete();
      await first.catchError((_) {});
      await settle();
      s.heal();
      final b = await restart();
      expect(b.cardPaymentDays['A'], 26); // 一時記録は 2 回目（26 日）のもの
    });
  });

  group('Drive の取り込みと、その間の編集', () {
    Future<(AppState, DriveSnapshot, void Function())> setUp() async {
      var t = DateTime(2026, 11, 20, 10);
      final a = await clockApp(() => t);
      a.currentBalance = 1000;
      await a.saveData();
      final data = jsonDecode(a.exportJson()) as Map<String, dynamic>;
      data['currentBalance'] = 2000;
      return (a, DriveSnapshot(updatedAt: t, device: 'test', json: jsonEncode(data)), () {
        t = t.add(const Duration(seconds: 1));
      });
    }

    // 💡 取り込みの間は編集を断る（GPT 再レビューの残件への対応）。以前は受け付けて「未同期」として残していたが、
    //   取り込みが失敗すると巻き戻しで一緒に消えた。いまは始める前に断るので、受け付けた変更が消えることは無い。
    test('時計が進まなくても、取り込み中の編集ははっきり断られ、終わったあとの編集は未同期として残る', () async {
      final a = await fixedApp(day);
      a.currentBalance = 1000;
      await a.saveData();
      final data = jsonDecode(a.exportJson()) as Map<String, dynamic>;
      data['currentBalance'] = 2000;
      final remote = DriveSnapshot(updatedAt: day, device: 'test', json: jsonEncode(data));
      final s = await install();
      s.blockKey = f(AppState.kPendingWriteKey);
      final pulling = DriveSync.withStore(FakeDriveStore()..remote = remote).pullNow(a, snapshot: remote);
      await s.entered.future;
      expect(a.dataLocked, isTrue);
      expect(() => a.updateBalance(3000), throwsA(isA<DataLockedException>()));
      expect(a.currentBalance, 2000); // 断った編集は、メモリにも入っていない（取り込んだ内容のまま）
      s.release.complete();
      final r = await pulling;
      expect(r.state, DriveSyncState.upToDate);
      expect(a.dataLocked, isFalse);
      a.updateBalance(3000); // 終わったら編集できる（時計は止まったまま）
      await settle();
      expect(
          decideSyncState(
              remoteUpdatedAt: remote.updatedAt,
              knownRemoteAt: a.driveKnownRemoteAt,
              dataUpdatedAt: a.dataUpdatedAt,
              syncedAt: a.driveSyncedAt),
          DriveSyncState.localNewer);
      final b = await restart();
      expect(b.currentBalance, 3000);
    });

    test('取り込みが失敗したら同期済みにせず、端末の保存とメモリは同じ整った状態', () async {
      final (a, remote, tick) = await setUp();
      final syncedBefore = a.driveSyncedAt;
      final s = await install();
      s.falseOnSet = {f('saved_payments')}; // 取り込んだ状態の保存の途中で false
      tick();
      final r = await DriveSync.withStore(FakeDriveStore()..remote = remote).pullNow(a, snapshot: remote);
      expect(r.state, DriveSyncState.error);
      expect(a.driveSyncedAt, syncedBefore);
      expect(a.currentBalance, 1000);
      s.heal();
      final b = await restart();
      expect(b.currentBalance, 1000);
      expect(exportWithoutStamp(b), exportWithoutStamp(a));
    });
  });

  group('保存先が false を返したら失敗として扱う（段階ごと）', () {
    Future<(AppState, ProbeStore, String, String)> setUp() async {
      final a = await fixedApp(day);
      a.currentBalance = 1000;
      await a.saveData();
      final before = exportWithoutStamp(a);
      final data = jsonDecode(a.exportJson()) as Map<String, dynamic>;
      data['currentBalance'] = 9000;
      final s = await install();
      return (a, s, before, jsonEncode(data));
    }

    test('復旧点: 上書きを始めない', () async {
      final (a, s, before, json) = await setUp();
      s.falseOnSet = {f(AppState.kRestorePointKey)};
      await expectLater(a.importJson(json), throwsA(isA<StorageWriteFailure>()));
      expect(exportWithoutStamp(a), before);
      expect((await s.getAll())[f('saved_balance')], 1000);
    });

    test('一時記録: 既存のキーを書き換えない', () async {
      final (a, s, before, _) = await setUp();
      s.falseOnSet = {f(AppState.kPendingWriteKey)};
      a.currentBalance = 5000;
      await expectLater(a.saveData(), throwsA(isA<StorageWriteFailure>()));
      expect(a.storageIssue, StorageIssue.saveFailed);
      expect((await s.getAll())[f('saved_balance')], 1000);
      s.heal();
      final b = await restart();
      expect(exportWithoutStamp(b), before);
    });

    test('本体の途中のキー: 失敗にし、次の起動で一時記録から整える', () async {
      final (a, s, _, _) = await setUp();
      s.falseOnSet = {f('saved_payments')};
      a.currentBalance = 5000;
      final want = exportWithoutStamp(a);
      await expectLater(a.saveData(), throwsA(isA<StorageWriteFailure>()));
      s.heal();
      final b = await restart();
      expect(exportWithoutStamp(b), want);
    });

    test('記録の削除: 成功扱いにせず、次の起動で整った状態（同じ値）になる', () async {
      final (a, s, _, _) = await setUp();
      s.falseOnRemove = {f(AppState.kPendingWriteKey)};
      a.currentBalance = 5000;
      final want = exportWithoutStamp(a);
      await expectLater(a.saveData(), throwsA(isA<StorageWriteFailure>()));
      expect(a.storageIssue, StorageIssue.saveFailed);
      s.heal();
      final b = await restart();
      expect(exportWithoutStamp(b), want);
      expect((await s.getAll()).containsKey(f(AppState.kPendingWriteKey)), isFalse);
    });

    test('起動時の書き戻しで false → 回復待ち（記録の値で読む）', () async {
      final (a, s, _, _) = await setUp();
      s.falseOnSet = {f('saved_payments')};
      a.currentBalance = 5000;
      final want = exportWithoutStamp(a);
      await expectLater(a.saveData(), throwsA(isA<StorageWriteFailure>()));
      final b = await restart(); // まだ false を返す
      expect(b.storageIssue, StorageIssue.recoveryPending);
      expect(exportWithoutStamp(b), want);
    });
  });
}
