import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:my_counter_app/app_state.dart';
import 'package:my_counter_app/drive_sync.dart';
import 'drive_push_pull_test.dart' show FakeDriveStore;
import 'support/test_app.dart';

class GateStore extends InMemorySharedPreferencesStore {
  GateStore(Map<String, Object> data) : super.withData(data);
  String? blockKey;
  final entered = Completer<void>();
  final release = Completer<void>();
  bool returnFalse = false;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (returnFalse) return false;
    if (key == blockKey) {
      blockKey = null;
      entered.complete();
      await release.future;
    }
    return super.setValue(type, key, value);
  }
}

Future<GateStore> installStore() async {
  final s = GateStore(await SharedPreferencesStorePlatform.instance.getAll());
  SharedPreferencesStorePlatform.instance = s;
  SharedPreferences.resetStatic();
  return s;
}

void main() {
  // 💡 GPT 実装レビューの再現テスト（元は「取り込み中の編集が未同期として残る」）。
  //   取り込みの間は編集を断る方式にしたので（GPT 再レビューの残件）、
  //   「編集ははっきり断られ、取り込んだ内容も、終わったあとの編集も失われない」を確かめる形に変えた。
  //   画面を通らずに項目を直接書き換えて保存した場合（安全網）も、保存されずに取り込んだ内容へ戻る。
  test('Drive取り込みの保存中の編集は断られ、終わったあとの編集は未同期として残る', () async {
    var t = DateTime(2026, 11, 20, 10);
    final a = await clockApp(() => t);
    a.currentBalance = 1000;
    await a.saveData();
    final remoteData = jsonDecode(a.exportJson()) as Map<String, dynamic>;
    remoteData['currentBalance'] = 2000;
    final remote = DriveSnapshot(updatedAt: t, device: 'test', json: jsonEncode(remoteData));
    final d = FakeDriveStore()..remote = remote;
    final s = await installStore();
    s.blockKey = 'flutter.saved_pending_write';
    final pulling = DriveSync.withStore(d).pullNow(a, snapshot: remote);
    await s.entered.future;
    t = t.add(const Duration(seconds: 1));
    expect(() => a.updateBalance(3000), throwsA(isA<DataLockedException>()));
    a.currentBalance = 3000; // 断る確認を通らない書き換え
    await expectLater(a.saveData(), throwsA(isA<DataLockedException>()));
    expect(a.currentBalance, 2000); // 保存せず、取り込んだ内容へ戻す
    s.release.complete();
    expect((await pulling).state, DriveSyncState.upToDate);
    expect(a.currentBalance, 2000);
    expect(decideSyncState(remoteUpdatedAt: remote.updatedAt,
      knownRemoteAt: a.driveKnownRemoteAt, dataUpdatedAt: a.dataUpdatedAt,
      syncedAt: a.driveSyncedAt), DriveSyncState.upToDate);
    t = t.add(const Duration(seconds: 1));
    a.updateBalance(3000);
    await settle();
    expect(decideSyncState(remoteUpdatedAt: remote.updatedAt,
      knownRemoteAt: a.driveKnownRemoteAt, dataUpdatedAt: a.dataUpdatedAt,
      syncedAt: a.driveSyncedAt), DriveSyncState.localNewer);
  });

  test('保存中のカード設定変更が再起動後にも残る', () async {
    final a = await fixedApp(DateTime(2026, 11, 20));
    a.cardPaymentDays['A'] = 27;
    await a.saveData();
    final s = await installStore();
    s.blockKey = 'flutter.saved_card_payment_days';
    final saving = a.saveData();
    await s.entered.future;
    a.setCardPaymentDay('A', 26);
    await settle();
    s.release.complete();
    await saving;
    SharedPreferences.resetStatic();
    final b = AppState(clock: () => DateTime(2026, 11, 20));
    await b.ready;
    expect(b.cardPaymentDays['A'], 26);
  });

  test('ストアがfalseを返したら取り込み成功扱いにしない', () async {
    final a = await fixedApp(DateTime(2026, 11, 20));
    a.currentBalance = 1000;
    await a.saveData();
    final data = jsonDecode(a.exportJson()) as Map<String, dynamic>;
    data['currentBalance'] = 9000;
    final s = await installStore();
    s.returnFalse = true;
    await expectLater(a.importJson(jsonEncode(data)), throwsA(isA<StorageWriteFailure>()));
  });
}
