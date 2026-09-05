// パスコードの保存・照合のテスト。平文で持たないこと、誤りを弾くことを見る。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/lock_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LockService.instance.clearPasscode();
  });

  group('パスコード', () {
    test('未設定ならロックしない', () {
      expect(LockService.instance.isEnabled, isFalse);
      expect(LockService.instance.isLocked, isFalse);
    });

    test('設定すると正しいコードだけ通る', () async {
      await LockService.instance.setPasscode('1234');
      expect(LockService.instance.isEnabled, isTrue);
      expect(LockService.instance.verify('1234'), isTrue);
      expect(LockService.instance.verify('1235'), isFalse);
      expect(LockService.instance.verify(''), isFalse);
    });

    test('平文では保存しない（ソルト付きハッシュ）', () async {
      await LockService.instance.setPasscode('9876');
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString('saved_lock_hash');
      expect(stored, isNotNull);
      expect(stored, isNot(contains('9876')));
      expect(stored!.length, 64); // sha256のhex
      expect(prefs.getString('saved_lock_salt'), isNotNull);
    });

    test('同じコードでも端末ごとにハッシュが変わる（ソルトが効いている）', () async {
      await LockService.instance.setPasscode('0000');
      final prefs = await SharedPreferences.getInstance();
      final first = prefs.getString('saved_lock_hash');
      await LockService.instance.setPasscode('0000');
      expect(prefs.getString('saved_lock_hash'), isNot(first));
    });

    test('解除するとロックも生体認証もOFFになる', () async {
      await LockService.instance.setPasscode('1111');
      await LockService.instance.setBiometricEnabled(true);
      await LockService.instance.clearPasscode();
      expect(LockService.instance.isEnabled, isFalse);
      expect(LockService.instance.biometricEnabled, isFalse);
      expect(LockService.instance.isLocked, isFalse);
    });

    test('復帰直後は猶予内なので聞かれない', () async {
      await LockService.instance.setPasscode('1234'); // 設定＝解除済み
      LockService.instance.onResume();
      expect(LockService.instance.isLocked, isFalse);
    });

    test('lockNow で即ロックできる', () async {
      await LockService.instance.setPasscode('1234');
      LockService.instance.lockNow();
      expect(LockService.instance.isLocked, isTrue);
      LockService.instance.unlock();
      expect(LockService.instance.isLocked, isFalse);
    });
  });
}
