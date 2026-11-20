// 💡 取り込み中（ドライブ・バックアップ・貼り付け）は家計データの変更を止める（GPT 再レビューの残件）。
//   ⚠️ 以前は取り込みの保存を待っている間の編集を受け付けていて、取り込みが失敗すると
//     巻き戻しで一緒に消えた（「入力できたのに消えた」）。いまは始める前に断る。
//   確かめること:
//   ・画面・AppState からの変更は DataLockedException で断られ、メモリにも端末にも入らない
//   ・自動の処理（Gmail の反映・カレンダーの記録）は、取り込みが終わるまで待ってから行う（保留）
//   ・二重の取り込みは後から来た方を断る。ドライブへの保存も止める
//   ・取り込みより前に始まっていた保存とぶつからない（復旧点を消されない）
//   ・成功でも失敗でも鍵が外れ、画面の覆いが消えて、そのまま操作できる
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/app_state.dart';
import 'package:my_counter_app/drive_sync.dart';
import 'package:my_counter_app/gmail_sync.dart';
import 'package:my_counter_app/widgets/data_lock_overlay.dart';

import 'drive_push_pull_test.dart' show FakeDriveStore;
import 'gmail_sync_safety_test.dart' show FakeGmail, mail;
import 'save_paths_test.dart' show ProbeStore, install, restart, f, day;
import 'support/test_app.dart';

/// 残高 1000 円で保存した端末と、残高 9000 円の取り込み用データ
Future<(AppState, String)> balanceApp() async {
  final a = await fixedApp(day);
  a.currentBalance = 1000;
  await a.saveData();
  final data = jsonDecode(a.exportJson()) as Map<String, dynamic>;
  data['currentBalance'] = 9000;
  return (a, jsonEncode(data));
}

/// 次に [key] を書くところで止める（止まったら entered が完了する）
void blockNext(ProbeStore s, String key) {
  s.entered = Completer<void>();
  s.release = Completer<void>();
  s.blockKey = key;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('取り込みの保存が失敗するとき（残件の再現）', () {
    test('取り込み中の編集ははっきり断られ、失敗のあとは取り込む前の内容で、そのまま編集できる', () async {
      final (a, json) = await balanceApp();
      final s = await install();
      blockNext(s, f(AppState.kPendingWriteKey));
      s.falseOnSet = {f('saved_payments')}; // 取り込んだ状態の保存の途中で失敗させる
      final importing = a.importJson(json);
      await s.entered.future;

      // 取り込み中: 編集は始める前に断られる（受け付けてから消す、をしない）
      expect(a.dataLocked, isTrue);
      expect(a.dataLockLabel, 'データを取り込んでいます');
      expect(() => a.updateBalance(3000), throwsA(isA<DataLockedException>()));
      expect(() => a.addWithdrawal(date: DateTime(2026, 11, 20), amount: 500), throwsA(isA<DataLockedException>()));
      expect(a.withdrawals, isEmpty);
      expect(a.currentBalance, 9000); // 取り込み中の中身（断った 3000 は入っていない）

      s.release.complete();
      await expectLater(importing, throwsA(isA<StorageWriteFailure>()));

      // 失敗: 取り込む前に戻り、鍵が外れて操作できる
      expect(a.dataLocked, isFalse);
      expect(a.currentBalance, 1000);
      s.heal();
      a.updateBalance(1500);
      await settle();
      final b = await restart();
      expect(b.currentBalance, 1500); // 失敗のあとの編集は保存される
    });

    test('ドライブからの取り込みが失敗しても同じ（同期済みにしない・鍵は外れる）', () async {
      final (a, json) = await balanceApp();
      final remote = DriveSnapshot(updatedAt: day, device: 'test', json: json);
      final syncedBefore = a.driveSyncedAt;
      final s = await install();
      blockNext(s, f(AppState.kPendingWriteKey));
      s.falseOnSet = {f('saved_payments')};
      final pulling = DriveSync.withStore(FakeDriveStore()..remote = remote).pullNow(a, snapshot: remote);
      await s.entered.future;
      expect(a.dataLockLabel, 'ドライブから取り込んでいます');
      expect(() => a.setCardPaymentDay('A', 26), throwsA(isA<DataLockedException>()));
      expect(a.cardPaymentDays.containsKey('A'), isFalse);
      s.release.complete();
      final r = await pulling;
      expect(r.state, DriveSyncState.error);
      expect(a.dataLocked, isFalse);
      expect(a.driveSyncedAt, syncedBefore);
      expect(a.currentBalance, 1000);
    });

    test('取得（通信）を待っている間から止める（取得の後で置き換わって消える編集を受け付けない）', () async {
      final (a, json) = await balanceApp();
      final store = FakeDriveStore()
        ..remote = DriveSnapshot(updatedAt: day, device: 'test', json: json)
        ..authGate = Completer<void>();
      final pulling = DriveSync.withStore(store).pullNow(a);
      await Future<void>.delayed(Duration.zero);
      expect(a.dataLocked, isTrue);
      expect(() => a.updateBalance(3000), throwsA(isA<DataLockedException>()));
      store.authGate!.complete();
      expect((await pulling).state, DriveSyncState.upToDate);
      expect(a.dataLocked, isFalse);
      expect(a.currentBalance, 9000);
    });
  });

  group('二重の取り込み・ドライブへの保存', () {
    test('取り込み中のもう 1 回は断られ、先の取り込みはそのまま終わる', () async {
      final (a, json) = await balanceApp();
      final other = (jsonDecode(json) as Map<String, dynamic>)..['currentBalance'] = 5;
      final s = await install();
      blockNext(s, f(AppState.kPendingWriteKey));
      final first = a.importJson(json);
      await s.entered.future;
      await expectLater(a.importJson(jsonEncode(other)), throwsA(isA<DataLockedException>()));
      final remote = DriveSnapshot(updatedAt: day, device: 'test', json: jsonEncode(other));
      final r = await DriveSync.withStore(FakeDriveStore()..remote = remote).pullNow(a, snapshot: remote);
      expect(r.state, DriveSyncState.error);
      expect(r.error, contains('取り込んでいます'));
      expect(a.dataLocked, isTrue); // 断った側は、先の取り込みの鍵を外さない
      s.release.complete();
      await first;
      expect(a.dataLocked, isFalse);
      final b = await restart();
      expect(b.currentBalance, 9000);
    });

    test('取り込み中はドライブへ保存しない（終わったら保存できる）', () async {
      final (a, json) = await balanceApp();
      final s = await install();
      blockNext(s, f(AppState.kPendingWriteKey));
      final store = FakeDriveStore();
      final importing = a.importJson(json);
      await s.entered.future;
      final r = await DriveSync.withStore(store).pushNow(a);
      expect(r.state, DriveSyncState.error);
      expect(store.writes, 0);
      s.release.complete();
      await importing;
      expect((await DriveSync.withStore(store).pushNow(a)).state, DriveSyncState.upToDate);
      expect(store.writes, 1);
    });
  });

  group('取り込みより前に始まっていた保存', () {
    test('先に走っていた保存が終わってから復旧点を書く（途中で止まっても、取り込む前の状態へ戻る）', () async {
      final (a, json) = await balanceApp();
      final s = await install();
      blockNext(s, f('saved_shifts')); // 取り込む前の編集の保存が、本体の途中で止まっている
      a.updateBalance(1200);
      await s.entered.future;
      final importing = a.importJson(json); // その間に取り込みを始める
      await Future<void>.delayed(Duration.zero);
      final firstRelease = s.release;
      blockNext(s, f(AppState.kPendingWriteKey)); // 次に止めるのは取り込みの保存（一時保存）
      firstRelease.complete();
      await s.entered.future;
      // ⚠️ 先の保存は成功すると復旧点を消す。先に書いていたら、ここで復旧点が無くなっていた
      final rp = (await s.getAll())[f(AppState.kRestorePointKey)] as String?;
      expect(rp, isNotNull);
      final before = (jsonDecode(rp!) as Map)['before'] as Map;
      expect(before['saved_balance'], 1200);
      s.crashOnSet = f('saved_shifts'); // 取り込みの保存の本体で終了
      s.release.complete();
      await expectLater(importing, throwsA(anything));
      s.heal();
      final b = await restart();
      expect(b.currentBalance, 1200); // 取り込む前（先の編集は入っている）
    });
  });

  group('自動の処理は取り込みが終わるまで待つ（断らずに保留）', () {
    test('Gmail の反映は、取り込みが終わってから取り込んだ中身に行う', () async {
      final (a, json) = await balanceApp();
      final s = await install();
      blockNext(s, f(AppState.kPendingWriteKey));
      final importing = a.importJson(json);
      await s.entered.future;
      final now = DateTime.now();
      final g = FakeGmail()..cards = [mail('楽天カード', 3000, DateTime(now.year, now.month, 1), 'm1')];
      final syncing = syncGmail(a, source: g);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(a.payments, isEmpty); // 取り込み中は反映しない
      s.release.complete();
      await importing;
      final r = await syncing;
      expect(r.ok, isTrue);
      expect(a.payments.map((p) => p.sourceId), ['m1']);
      expect(a.currentBalance, 9000);
      await settle();
      final b = await restart();
      expect(b.payments.map((p) => p.sourceId), ['m1']);
    });

    test('確認と変更は同じ同期区間: 鍵が外れた直後に次の取り込みが始まったら、それも待つ', () async {
      final a = await fixedApp(day);
      final l1 = a.acquireDataLock('1 回目');
      var ran = false;
      final waiting = a.runWhenEditable(() => ran = true);
      a.releaseDataLock(l1);
      final l2 = a.acquireDataLock('2 回目'); // 待っていた処理が動く前に始まる
      await Future<void>.delayed(Duration.zero);
      expect(ran, isFalse);
      a.releaseDataLock(l2);
      await waiting;
      expect(ran, isTrue);
    });

    test('鍵を持つ処理が例外で終わっても鍵は外れる', () async {
      final a = await fixedApp(day);
      await expectLater(
          a.runWithDataLock('テスト', (_) async => throw StateError('失敗')), throwsA(isA<StateError>()));
      expect(a.dataLocked, isFalse);
      a.updateBalance(10); // 操作できる
      expect(a.currentBalance, 10);
    });
  });

  group('画面: 取り込み中の表示', () {
    Widget host(AppState app, VoidCallback onTap) => ChangeNotifierProvider.value(
          value: app,
          child: MaterialApp(
            builder: (context, child) => DataLockOverlay(child: child!),
            home: Scaffold(body: Center(child: ElevatedButton(onPressed: onTap, child: const Text('押す')))),
          ),
        );

    testWidgets('取り込み中は覆って操作できず、成功・失敗のどちらでも元に戻る', (tester) async {
      SharedPreferences.setMockInitialValues({});
      late AppState app;
      await tester.runAsync(() async {
        app = AppState(clock: () => day);
        await app.ready;
      });
      var taps = 0;
      await tester.pumpWidget(host(app, () => taps++));
      expect(find.byKey(const Key('data-lock-cover')), findsNothing);

      for (final fail in [false, true]) {
        final gate = Completer<void>();
        final running = app.runWithDataLock('ドライブから取り込んでいます', (_) async {
          await gate.future;
          if (fail) throw StateError('失敗');
        });
        await tester.pump();
        expect(find.byKey(const Key('data-lock-cover')), findsOneWidget);
        expect(find.text('ドライブから取り込んでいます…'), findsOneWidget);
        await tester.tap(find.text('押す'), warnIfMissed: false);
        expect(taps, 0); // 覆いの下のボタンは押せない
        gate.complete();
        await running.catchError((_) {});
        await tester.pump();
        expect(find.byKey(const Key('data-lock-cover')), findsNothing, reason: fail ? '失敗のあと' : '成功のあと');
        await tester.tap(find.text('押す'));
        expect(taps, 1);
        taps = 0;
      }
    });
  });
}
