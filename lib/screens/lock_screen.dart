// 💡 パスコード入力画面。ロック中はこれだけを表示する（データは一切見せない）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../lock_service.dart';

class LockScreen extends StatefulWidget {
  const LockScreen({super.key, required this.onUnlocked});

  final VoidCallback onUnlocked;

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final _ctrl = TextEditingController();
  String? _error;
  int _failures = 0;

  @override
  void initState() {
    super.initState();
    // 生体認証が使えるなら先に試す（成功すれば入力不要）
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryBiometric());
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _tryBiometric() async {
    if (!LockService.instance.biometricEnabled) return;
    if (await LockService.instance.authenticateBiometric()) widget.onUnlocked();
  }

  void _submit() {
    if (LockService.instance.verify(_ctrl.text)) {
      LockService.instance.unlock();
      widget.onUnlocked();
      return;
    }
    setState(() {
      _failures++;
      _error = 'パスコードが違います';
      _ctrl.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock, size: 48, color: Colors.pink),
                const SizedBox(height: 12),
                const Text('ポケットメイド',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                const Text('パスコードを入力してください',
                    style: TextStyle(fontSize: 13, color: Colors.grey)),
                const SizedBox(height: 20),
                TextField(
                  controller: _ctrl,
                  autofocus: true,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  maxLength: 6,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  style: const TextStyle(fontSize: 24, letterSpacing: 8),
                  decoration: InputDecoration(
                    counterText: '',
                    errorText: _error,
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _submit,
                    child: const Text('開く'),
                  ),
                ),
                if (LockService.instance.biometricEnabled)
                  TextButton.icon(
                    onPressed: _tryBiometric,
                    icon: const Icon(Icons.face),
                    label: const Text('Face ID / Touch ID で開く'),
                  ),
                if (_failures >= 3)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text(
                      'パスコードを忘れた場合は、ブラウザのサイトデータを消すと'
                      'ロックは外れますが、この端末のデータも消えます。'
                      'ドライブ同期がONなら別の端末から復元できます。',
                      style: TextStyle(fontSize: 11, color: Colors.grey),
                      textAlign: TextAlign.center,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
