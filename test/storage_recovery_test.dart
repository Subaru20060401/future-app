// 💡 保存の途中で失敗・終了したときの回復（公開前の確認 3）。
//   ⚠️ すべて「永続化された状態から再起動」して確かめる（SharedPreferences のメモリ上のキャッシュを捨てる）。
//   以前のテストはキャッシュを読んでいて、端末の保存が混ざることを見落としていた。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:my_counter_app/app_state.dart';
import 'package:my_counter_app/drive_sync.dart';
import 'package:my_counter_app/gmail_service.dart';

import 'support/rich_fixture.dart';
import 'support/test_app.dart';

/// 書き込みの何回目で失敗させるかを決められるストア（中身は永続化されたものとして扱う）
class DiskStore extends InMemorySharedPreferencesStore {
  DiskStore(Map<String, Object> d) : super.withData(d);
  int writes = 0;
  int? failFrom; // この回数目以降の書き込み・削除をすべて失敗させる（容量不足など）
  int? failOnlyAt; // この回数目だけ失敗させる（一時的）
  bool failRemoves = false;
  // このキーの削除で失敗し、それ以降の書き込みもすべて失敗させる（その時点でアプリが終わったのと同じ）
  Set<String> crashOnRemove = {};

  void _check(String what) {
    final n = writes++;
    if ((failFrom != null && n >= failFrom!) || n == failOnlyAt) {
      throw StateError('保存に失敗（テスト）: $what');
    }
  }

  @override
  Future<bool> setValue(String t, String k, Object v) async {
    _check(k);
    return super.setValue(t, k, v);
  }

  @override
  Future<bool> remove(String k) async {
    if (failRemoves) throw StateError('削除に失敗（テスト）: $k');
    if (crashOnRemove.contains(k)) {
      failFrom = writes;
      throw StateError('ここで終了（テスト）: $k');
    }
    _check('remove $k');
    return super.remove(k);
  }

  void heal() {
    failFrom = null;
    failOnlyAt = null;
    failRemoves = false;
    crashOnRemove = {};
  }
}

final now = DateTime(2026, 11, 19, 10);

/// 今のストアを保ったまま「アプリを終了して起動し直す」
Future<AppState> restart() async {
  SharedPreferences.resetStatic();
  final app = AppState(clock: () => now);
  await app.ready;
  return app;
}

/// 小さな家計データ（残高 1,234・明細 1 件）を保存したストアを用意する
Future<(AppState, DiskStore, String)> setUpSmall() async {
  final a = await fixedApp(now);
  a.currentBalance = 1234;
  a.payments.add(usage('A', 500, DateTime(2026, 11, 1, 12)));
  await a.saveData();
  final store = DiskStore(await SharedPreferencesStorePlatform.instance.getAll());
  SharedPreferencesStorePlatform.instance = store;
  SharedPreferences.resetStatic();
  return (a, store, exportWithoutStamp(a));
}

Future<String> richJson() async {
  final json = (await richApp(now)).exportJson();
  return json;
}

void main() {
  group('ふつうの保存', () {
    test('成功したら一時保存は残らない', () async {
      final (a, store, _) = await setUpSmall();
      a.currentBalance = 2000;
      await a.saveData();
      final all = await store.getAll();
      expect(all.containsKey('flutter.${AppState.kPendingWriteKey}'), isFalse);
      expect(a.storageIssue, isNull);
    });

    test('一時保存が書けなければ、既存のキーは1つも書き換えない', () async {
      final (a, store, before) = await setUpSmall();
      store.failFrom = store.writes; // 最初の書き込み（一時保存）から失敗
      a.currentBalance = 2000;
      await expectLater(a.saveData(), throwsA(isA<StorageWriteFailure>()));
      expect(a.storageIssue, StorageIssue.saveFailed);
      store.heal();
      final r = await restart();
      expect(exportWithoutStamp(r), before); // 端末は前の整った状態
      expect(r.storageIssue, isNull);
    });

    for (final k in [1, 5, 30]) {
      test('キーの書き込みの $k 件目で止まって終了 → 次の起動で、保存しようとした状態に整う', () async {
        final (a, store, _) = await setUpSmall();
        a.currentBalance = 2000;
        a.payments.add(usage('A', 700, DateTime(2026, 11, 2, 12)));
        final want = exportWithoutStamp(a);
        store.failFrom = store.writes + 1 + k; // 一時保存は成功、キーの途中から失敗（終了と同じ）
        await expectLater(a.saveData(), throwsA(isA<StorageWriteFailure>()));
        store.heal();
        final r = await restart();
        expect(exportWithoutStamp(r), want);
        expect(r.recoveredOnStartup, isTrue);
        expect((await store.getAll()).containsKey('flutter.${AppState.kPendingWriteKey}'), isFalse);
      });
    }

    test('次の起動での書き直しも失敗 → 回復待ち。中身は記録から読んだ整った状態、ドライブへの保存は止める', () async {
      final (a, store, _) = await setUpSmall();
      a.currentBalance = 2000;
      final want = exportWithoutStamp(a);
      store.failFrom = store.writes + 3;
      await expectLater(a.saveData(), throwsA(isA<StorageWriteFailure>()));
      // 起動しても書けない（容量不足が続いている）
      final r = await restart();
      expect(r.storageIssue, StorageIssue.recoveryPending);
      expect(exportWithoutStamp(r), want); // 混ざった保存ではなく、記録の値で読む
      expect(r.uploadsBlocked, isTrue);
      final drive = _RecordingStore();
      final pushed = await DriveSync.withStore(drive).pushNow(r);
      expect(pushed.state, DriveSyncState.error);
      expect(drive.writes, 0); // ドライブの正常なコピーを上書きしない
      // 空きができてから保存し直す → 整った状態になり、止めていたものも戻る
      store.heal();
      expect(await r.retryStorage(), isTrue);
      expect(r.storageIssue, isNull);
      expect(r.uploadsBlocked, isFalse);
      final r2 = await restart();
      expect(exportWithoutStamp(r2), want);
      expect(r2.storageIssue, isNull);
    });

    test('一時保存が壊れている → 回復不能。ふつうの保存では解消せず、取り込み直しで解消する', () async {
      final (_, store, _) = await setUpSmall();
      await store.setValue('String', 'flutter.${AppState.kPendingWriteKey}', '{壊れた');
      final r = await restart();
      expect(r.storageIssue, StorageIssue.unrecoverable);
      expect(r.uploadsBlocked, isTrue);
      await r.saveData();
      expect(r.storageIssue, StorageIssue.unrecoverable); // 混ざっているかもしれないものを正常扱いしない
      await r.importJson(await richJson()); // 取り込み直し（ドライブ・バックアップと同じ経路）
      expect(r.storageIssue, isNull);
      final r2 = await restart();
      expect(r2.storageIssue, isNull);
      expect(r2.currentBalance, 150000);
    });
  });

  group('取り込み（importJson）', () {
    test('復旧点が書けなければ、上書きを始めない（メモリも端末も元のまま）', () async {
      final (a, store, before) = await setUpSmall();
      final json = await richJson();
      SharedPreferencesStorePlatform.instance = store;
      SharedPreferences.resetStatic();
      store.failFrom = store.writes; // 復旧点の書き込みから失敗
      await expectLater(a.importJson(json), throwsA(isA<StorageWriteFailure>()));
      expect(exportWithoutStamp(a), before);
      store.heal();
      final r = await restart();
      expect(exportWithoutStamp(r), before);
    });

    test('一時的な失敗（1回だけ）→ メモリも端末も取り込む前に戻る', () async {
      final (a, store, before) = await setUpSmall();
      final json = await richJson();
      SharedPreferencesStorePlatform.instance = store;
      SharedPreferences.resetStatic();
      store.failOnlyAt = store.writes + 6; // 取り込んだ状態の保存の途中で1回だけ
      await expectLater(a.importJson(json), throwsA(isA<StorageWriteFailure>()));
      expect(exportWithoutStamp(a), before);
      expect(a.storageIssue, isNot(StorageIssue.recoveryPending));
      final r = await restart();
      expect(exportWithoutStamp(r), before);
      expect(r.storageIssue, isNull);
    });

    for (final k in [2, 10, 40]) {
      test('失敗し続ける（$k 件目から）→ 回復待ち。次の起動で取り込む前の状態に戻る', () async {
        final (a, store, before) = await setUpSmall();
        final json = await richJson();
        SharedPreferencesStorePlatform.instance = store;
        SharedPreferences.resetStatic();
        store.failFrom = store.writes + 2 + k; // 復旧点・一時保存は成功、キーの途中から失敗し続ける
        await expectLater(a.importJson(json), throwsA(isA<StorageWriteFailure>()));
        expect(exportWithoutStamp(a), before); // メモリは元
        expect(a.storageIssue, StorageIssue.recoveryPending);
        expect(a.uploadsBlocked, isTrue);
        // 終了 → 空きができてから起動
        store.heal();
        final r = await restart();
        expect(exportWithoutStamp(r), before); // 端末も取り込む前の状態（混ざっていない）
        expect(r.storageIssue, isNull);
        final all = await store.getAll();
        expect(all.containsKey('flutter.${AppState.kRestorePointKey}'), isFalse);
        expect(all.containsKey('flutter.${AppState.kPendingWriteKey}'), isFalse);
      });
    }

    test('取り込みの途中でアプリが終わった（復旧点と一時保存が残る）→ 取り込む前に戻る', () async {
      final (a, store, before) = await setUpSmall();
      final json = await richJson();
      SharedPreferencesStorePlatform.instance = store;
      SharedPreferences.resetStatic();
      store.failFrom = store.writes + 2 + 7;
      await expectLater(a.importJson(json), throwsA(anything)); // 書き戻しも失敗＝終了と同じ状態
      store.heal();
      final r = await restart();
      expect(exportWithoutStamp(r), before);
    });

    test('取り込んだ状態を全部書いた直後に終了（復旧点だけ残る）→ 次の起動で取り込み後の状態を保つ', () async {
      final (a, store, _) = await setUpSmall();
      final json = await richJson();
      SharedPreferencesStorePlatform.instance = store;
      SharedPreferences.resetStatic();
      store.crashOnRemove = {'flutter.${AppState.kRestorePointKey}'};
      await expectLater(a.importJson(json), throwsA(anything));
      store.heal();
      final all = await store.getAll();
      expect(all.containsKey('flutter.${AppState.kRestorePointKey}'), isTrue);
      expect(all.containsKey('flutter.${AppState.kPendingWriteKey}'), isFalse);
      final r = await restart();
      // 💡 端末の各キーが取り込み後の状態と一致する（指紋が同じ）ので、戻さずに記録だけ消す
      expect(r.currentBalance, 150000);
      expect(r.storageIssue, isNull);
      expect((await store.getAll()).containsKey('flutter.${AppState.kRestorePointKey}'), isFalse);
    });

    test('取り込みの途中で削除に失敗し続けた → 次の起動で取り込む前に戻る（混ざらない）', () async {
      final (a, store, before) = await setUpSmall();
      final json = await richJson();
      SharedPreferencesStorePlatform.instance = store;
      SharedPreferences.resetStatic();
      store.failRemoves = true;
      await expectLater(a.importJson(json), throwsA(anything));
      store.heal();
      final r = await restart();
      expect(exportWithoutStamp(r), before);
    });

    test('成功したら記録は残らず、再起動しても取り込んだ状態', () async {
      final (a, store, _) = await setUpSmall();
      final json = await richJson();
      SharedPreferencesStorePlatform.instance = store;
      SharedPreferences.resetStatic();
      await a.importJson(json);
      final all = await store.getAll();
      expect(all.containsKey('flutter.${AppState.kRestorePointKey}'), isFalse);
      expect(all.containsKey('flutter.${AppState.kPendingWriteKey}'), isFalse);
      final r = await restart();
      expect(r.currentBalance, 150000);
      expect(r.storageIssue, isNull);
    });
  });

  group('確認待ちの引き落とし × 保存の失敗（公開前の確認 1）', () {
    test('引いた直後の保存が途中で止まっても、次の起動で「引いた・処理済み」がそろう（二重に引けない）', () async {
      final (a, store, _) = await setUpSmall();
      a.cardPaymentDays['A'] = 26;
      a.payments.add(usage('A', 300, DateTime(2026, 9, 5, 12))); // 10/26 に落ちた
      SharedPreferencesStorePlatform.instance = store;
      SharedPreferences.resetStatic();
      await a.saveData();
      final id = a.pendingDraws.singleWhere((d) => d.label == 'A（予定）').id;
      store.failFrom = store.writes + 1 + 20; // 引いた後の保存がキーの途中で止まる
      a.applyDraw(id, 300);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      store.heal();
      final r = await restart();
      expect(r.currentBalance, 1234 - 300);
      expect(r.handledDrawIds, contains(id));
      expect(r.applyDraw(id, 300), isFalse);
      expect(r.currentBalance, 1234 - 300);
    });

    test('一時保存の段階で失敗したら、次の起動では引く前の状態（もう一度1回だけ引ける）', () async {
      final (a, store, _) = await setUpSmall();
      a.cardPaymentDays['A'] = 26;
      a.payments.add(usage('A', 300, DateTime(2026, 9, 5, 12))); // 10/26 に落ちた
      SharedPreferencesStorePlatform.instance = store;
      SharedPreferences.resetStatic();
      await a.saveData();
      final id = a.pendingDraws.singleWhere((d) => d.label == 'A（予定）').id;
      store.failFrom = store.writes;
      a.applyDraw(id, 300);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(a.storageIssue, StorageIssue.saveFailed);
      store.heal();
      final r = await restart();
      expect(r.currentBalance, 1234);
      expect(r.applyDraw(id, 300), isTrue);
      expect(r.applyDraw(id, 300), isFalse);
      expect(r.currentBalance, 934);
    });
  });
}

class _RecordingStore implements DriveStore {
  int writes = 0;
  @override
  Future<GoogleAccessState> ensureAccess() async => GoogleAccessState.ready;
  @override
  Future<T> withFreshToken<T>(Future<T> Function() run) => run();
  @override
  Future<void> invalidateRejectedToken() async {}
  @override
  Future<DriveSnapshot?> read() async => null;
  @override
  Future<void> write({required DateTime updatedAt, required String device, required String dataJson}) async =>
      writes++;
}
