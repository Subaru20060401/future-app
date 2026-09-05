// 💡 パスワードロックの設定（ON/OFF・変更・生体認証）。
//   Chromeなどのパスワード管理から自動生成・自動入力できるよう、
//   数字限定にせず4〜20文字の任意の文字を受け付ける。
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

  // 💡 新規パスワードと確認を「1つのフォーム」にまとめる。
  //   Chromeは new-password + 確認欄の組を見て自動生成を提案するので、
  //   ダイアログを分けると生成も保存も効かない。
  Future<void> _setPasscode() async {
    final ctrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    var show = false;
    String? error;

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setLocal) {
          bool valid(String v) =>
              v.length >= LockService.minLength && v.length <= LockService.maxLength;

          void submit() {
            if (!valid(ctrl.text)) {
              setLocal(() => error =
                  '${LockService.minLength}〜${LockService.maxLength}文字で入力してください');
              return;
            }
            if (ctrl.text != confirmCtrl.text) {
              setLocal(() => error = '2つの入力が一致しません');
              return;
            }
            // AutofillGroup が生きているうちに呼ばないと保存を聞いてくれない
            TextInput.finishAutofillContext();
            Navigator.pop(context, true);
          }

          return AlertDialog(
            title: const Text('パスワードを決める'),
            content: AutofillGroup(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: ctrl,
                    autofocus: true,
                    obscureText: !show,
                    autofillHints: const [AutofillHints.newPassword],
                    keyboardType: TextInputType.visiblePassword,
                    maxLength: LockService.maxLength,
                    decoration: InputDecoration(
                      labelText: 'パスワード',
                      helperText:
                          '${LockService.minLength}〜${LockService.maxLength}文字（英数記号OK）',
                      counterText: '',
                      suffixIcon: IconButton(
                        icon: Icon(show ? Icons.visibility_off : Icons.visibility),
                        onPressed: () => setLocal(() => show = !show),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: confirmCtrl,
                    obscureText: !show,
                    autofillHints: const [AutofillHints.newPassword],
                    keyboardType: TextInputType.visiblePassword,
                    maxLength: LockService.maxLength,
                    decoration: InputDecoration(
                      labelText: '確認のためもう一度',
                      counterText: '',
                      errorText: error,
                    ),
                    onSubmitted: (_) => submit(),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'ブラウザのパスワード管理（Chromeの自動生成など）から'
                    '入力・保存できます。',
                    style: TextStyle(fontSize: 11, color: Colors.black54),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('キャンセル')),
              ElevatedButton(onPressed: submit, child: const Text('保存')),
            ],
          );
        },
      ),
    );

    if (ok != true || !mounted) return;
    await _lock.setPasscode(ctrl.text);
    if (mounted) setState(() {});
  }

  Future<void> _turnOff() async {
    final code = await _askCode('パスワードを解除', '今のパスワードを入力してください');
    if (code == null || !mounted) return;
    if (!_lock.verify(code)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('パスワードが違います')));
      return;
    }
    await _lock.clearPasscode();
    if (mounted) setState(() {});
  }

  // 解除するときの確認入力（既存パスワードなので autocomplete=password）
  Future<String?> _askCode(String title, String hint) {
    final ctrl = TextEditingController();
    var show = false;
    bool ok(String v) =>
        v.length >= LockService.minLength && v.length <= LockService.maxLength;

    return showDialog<String>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(title),
          content: AutofillGroup(
            child: TextField(
              controller: ctrl,
              autofocus: true,
              obscureText: !show,
              autofillHints: const [AutofillHints.password],
              keyboardType: TextInputType.visiblePassword,
              maxLength: LockService.maxLength,
              decoration: InputDecoration(
                counterText: '',
                hintText: hint,
                suffixIcon: IconButton(
                  icon: Icon(show ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setLocal(() => show = !show),
                ),
              ),
              onSubmitted: (v) => Navigator.pop(context, ok(v) ? v : null),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
            ElevatedButton(
              onPressed: () =>
                  Navigator.pop(context, ok(ctrl.text) ? ctrl.text : null),
              child: const Text('OK'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.lock_outline, color: Colors.blueGrey),
          title: const Text('パスワードロック'),
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
            title: const Text('パスワードを変更'),
            onTap: _setPasscode,
          ),
          if (_canBio)
            SwitchListTile(
              secondary: const Icon(Icons.face, color: Colors.blueGrey),
              title: const Text('Face ID / Touch ID で開く'),
              subtitle: const Text('端末アプリのみ。失敗したらパスワードで開けます',
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
