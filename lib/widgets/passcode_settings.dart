// 💡 パスコードロックの設定（ON/OFF・変更・生体認証）。
//   ⚠️ Web版はブラウザの中にデータがあるので、開発者ツールを開ける人には読まれる。
//     これは「端末を他人が触ったときの目隠し」であることを画面にも書いておく。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../lock_service.dart';

class PasscodeSettings extends StatefulWidget {
  const PasscodeSettings({super.key});

  @override
  State<PasscodeSettings> createState() => _PasscodeSettingsState();
}

class _PasscodeSettingsState extends State<PasscodeSettings> {
  final _lock = LockService.instance;
  bool _canBio = false;

  @override
  void initState() {
    super.initState();
    _lock.canUseBiometrics().then((v) {
      if (mounted) setState(() => _canBio = v);
    });
  }

  // 新しいパスコードを2回入力させる
  Future<void> _setPasscode() async {
    final first = await _askCode('パスコードを決める', '4〜6桁の数字');
    if (first == null || !mounted) return;
    final second = await _askCode('もう一度入力', '確認のため同じ数字を入れてください');
    if (second == null || !mounted) return;
    if (first != second) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('2回の入力が一致しません')));
      return;
    }
    await _lock.setPasscode(first);
    if (mounted) setState(() {});
  }

  Future<void> _turnOff() async {
    final code = await _askCode('パスコードを解除', '今のパスコードを入力してください');
    if (code == null || !mounted) return;
    if (!_lock.verify(code)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('パスコードが違います')));
      return;
    }
    await _lock.clearPasscode();
    if (mounted) setState(() {});
  }

  Future<String?> _askCode(String title, String hint) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          obscureText: true,
          keyboardType: TextInputType.number,
          maxLength: 6,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 22, letterSpacing: 6),
          decoration: InputDecoration(counterText: '', hintText: hint),
          onSubmitted: (v) => Navigator.pop(context, v.length >= 4 ? v : null),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
          ElevatedButton(
            onPressed: () => Navigator.pop(
                context, ctrl.text.length >= 4 ? ctrl.text : null),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.lock_outline, color: Colors.blueGrey),
          title: const Text('パスコードロック'),
          subtitle: Text(
            _lock.isEnabled
                ? '起動時と、しばらく離れて戻ったときに入力を求めます'
                : '他の人が端末を触ったときの目隠しになります',
            style: const TextStyle(fontSize: 12),
          ),
          value: _lock.isEnabled,
          onChanged: (v) => v ? _setPasscode() : _turnOff(),
        ),
        if (_lock.isEnabled) ...[
          ListTile(
            dense: true,
            leading: const Icon(Icons.password, color: Colors.blueGrey),
            title: const Text('パスコードを変更'),
            onTap: _setPasscode,
          ),
          if (_canBio)
            SwitchListTile(
              secondary: const Icon(Icons.face, color: Colors.blueGrey),
              title: const Text('Face ID / Touch ID で開く'),
              subtitle: const Text('端末アプリのみ。失敗したらパスコードで開けます',
                  style: TextStyle(fontSize: 12)),
              value: _lock.biometricEnabled,
              onChanged: (v) async {
                await _lock.setBiometricEnabled(v);
                if (mounted) setState(() {});
              },
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              '※ データはこの端末の中にあります。ブラウザの開発者ツールを使える人には'
              '中身を読まれるため、暗号化ではなく「目隠し」と考えてください。',
              style: TextStyle(fontSize: 11, color: Colors.black45),
            ),
          ),
        ],
      ],
    );
  }
}
