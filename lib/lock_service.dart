// 💡 アプリのパスコードロック。
//   ⚠️ 正直に書いておくと、Web版はデータがブラウザのlocalStorageにあるため、
//     開発者ツールを開ける人には中身を読まれる。これは「端末を他人が触ったときの
//     目隠し」であって、本物の暗号化ではない。
//     だからこそ、せめてパスコード自体は平文で保存しない（ソルト付きハッシュ）。
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LockService {
  LockService._();
  static final LockService instance = LockService._();

  static const _kHash = 'saved_lock_hash';
  static const _kSalt = 'saved_lock_salt';
  static const _kBio = 'saved_lock_biometric';
  static const _kGrace = Duration(seconds: 60); // 一瞬離れただけで聞かれないように

  // 💡 Chromeのパスワード自動生成（英数記号まじりの長い文字列）をそのまま
  //   使えるように、数字4桁固定ではなく 4〜20文字の任意の文字を受け付ける。
  static const int minLength = 4;
  static const int maxLength = 20;

  String? _hash;
  String? _salt;
  bool _biometric = false;
  bool _loaded = false;

  DateTime? _unlockedAt; // 最後に解除した時刻
  bool _locked = false;

  bool get isEnabled => _hash != null && _hash!.isNotEmpty;
  bool get biometricEnabled => _biometric;
  bool get isLocked => isEnabled && _locked;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    _hash = prefs.getString(_kHash);
    _salt = prefs.getString(_kSalt);
    _biometric = prefs.getBool(_kBio) ?? false;
    _locked = isEnabled; // 起動時は必ずロック
  }

  String _digest(String code, String salt) =>
      sha256.convert(utf8.encode('$salt:$code')).toString();

  Future<void> setPasscode(String code) async {
    final rnd = Random.secure();
    final salt = base64Url.encode(List<int>.generate(16, (_) => rnd.nextInt(256)));
    final prefs = await SharedPreferences.getInstance();
    _salt = salt;
    _hash = _digest(code, salt);
    await prefs.setString(_kSalt, salt);
    await prefs.setString(_kHash, _hash!);
    _locked = false;
    _unlockedAt = DateTime.now();
  }

  Future<void> clearPasscode() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kHash);
    await prefs.remove(_kSalt);
    await prefs.setBool(_kBio, false);
    _hash = null;
    _salt = null;
    _biometric = false;
    _locked = false;
  }

  bool verify(String code) {
    final salt = _salt;
    final hash = _hash;
    if (salt == null || hash == null) return true;
    return _digest(code, salt) == hash;
  }

  void unlock() {
    _locked = false;
    _unlockedAt = DateTime.now();
  }

  // 💡 バックグラウンドから戻ったとき。少しの離席で毎回聞かれると使いづらいので、
  //   猶予（60秒）を過ぎていたらロックし直す。
  void onResume() {
    if (!isEnabled) return;
    final at = _unlockedAt;
    if (at == null || DateTime.now().difference(at) > _kGrace) _locked = true;
  }

  void lockNow() {
    if (isEnabled) _locked = true;
  }

  Future<void> setBiometricEnabled(bool on) async {
    _biometric = on;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kBio, on);
  }

  // Face ID / Touch ID が使えるか（Webは常に false）
  Future<bool> canUseBiometrics() async {
    if (kIsWeb) return false;
    try {
      final auth = LocalAuthentication();
      if (!await auth.isDeviceSupported()) return false;
      return await auth.canCheckBiometrics;
    } catch (_) {
      return false;
    }
  }

  Future<bool> authenticateBiometric() async {
    if (kIsWeb || !_biometric) return false;
    try {
      final ok = await LocalAuthentication().authenticate(
        localizedReason: 'ポケットメイドを開きます',
        options: const AuthenticationOptions(stickyAuth: true, biometricOnly: true),
      );
      if (ok) unlock();
      return ok;
    } catch (_) {
      return false;
    }
  }
}
