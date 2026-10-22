import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../app_state.dart';
import '../gmail_service.dart';
import '../gmail_sync.dart';
import '../money_format.dart';

class GmailScreen extends StatefulWidget {
  const GmailScreen({super.key});

  @override
  State<GmailScreen> createState() => _GmailScreenState();
}

class _GmailScreenState extends State<GmailScreen> {
  final _gmail = GmailService.instance;
  bool _loading = false;
  bool _hasAccess = false; // Webはサインイン済みでもスコープ許可が別途必要
  String? _error;
  List<ParsedPayment> _results = [];

  // 種別ごとのラベル色
  (Color, Color) _kindColors(MailKind kind) {
    switch (kind) {
      case MailKind.bank:
        return (Colors.green.shade100, Colors.green.shade900);
      case MailKind.billing:
        return (Colors.red.shade100, Colors.red.shade900);
      case MailKind.usage:
        return (Colors.blue.shade100, Colors.blue.shade900);
    }
  }

  @override
  void initState() {
    super.initState();
    _gmail.signInSilently().then((_) async {
      // 保存したトークンで叩けるなら連携中とみなす（iOSはcurrentUserが立たない）
      final ok = await _gmail.isUsable;
      if (mounted) setState(() => _hasAccess = ok);
    });
  }

  Future<void> _connect() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final acc = await _gmail.signIn();
      if (acc == null) {
        setState(() => _error = 'ログインがキャンセルされました');
      } else {
        _hasAccess = await _gmail.hasGmailAccess();
      }
    } catch (e) {
      setState(() => _error = 'ログイン失敗: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  // 💡 普段の更新と同じ経路（syncGmail）で過去2年分を取り込む。
  // ⚠️ 以前はこの画面だけが自前で取得・反映していて、取りこぼし（取得失敗・件数の上限）を
  //   見ずに明細を作り直していた。取れなかったメールの明細や、2年より前の明細が消えうる。
  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _error = null;
      _results = [];
    });
    final appState = context.read<AppState>();
    try {
      var r = await syncGmail(appState, full: true);
      // 許可が無ければ、このボタン操作の中で求めてからもう一度（ポップアップは操作中のみ開ける）
      if (r.needsPermission && await _gmail.requestGmailAccess()) {
        r = await syncGmail(appState, full: true);
      }
      if (!mounted) return;
      setState(() {
        _results = r.items;
        _hasAccess = !r.needsPermission && !r.notSignedIn;
        if (!r.ok) _error = r.message;
      });
      if (r.ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(r.shortMessage)),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = '取得失敗: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Gmail連携')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 接続状態
            Card(
              child: ListTile(
                leading: Icon(_hasAccess ? Icons.check_circle : Icons.mail_outline,
                    color: _hasAccess ? Colors.green : Colors.grey),
                title: Text(_hasAccess ? '連携中' : '未連携'),
                subtitle: Text(_gmail.displayEmail ?? 'Googleアカウントでログインしてください'),
                trailing: _hasAccess
                    ? TextButton(
                        onPressed: () async {
                          await _gmail.signOut();
                          setState(() => _results = []);
                        },
                        child: const Text('解除'),
                      )
                    : null,
              ),
            ),
            const SizedBox(height: 12),

            if (!_hasAccess)
              ElevatedButton.icon(
                onPressed: _loading ? null : _connect,
                icon: const Icon(Icons.login),
                label: const Text('Googleでログイン'),
              )
            else
              ElevatedButton.icon(
                onPressed: _loading ? null : _fetch,
                icon: const Icon(Icons.refresh),
                label: const Text('カード利用メールを取得'),
              ),

            if (_loading) const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),

            const SizedBox(height: 8),
            Expanded(
              child: _results.isEmpty
                  ? const Center(child: Text('取得した支払いはここに表示されます'))
                  : ListView.builder(
                      itemCount: _results.length,
                      itemBuilder: (context, i) {
                        final p = _results[i];
                        final (bgColor, fgColor) = _kindColors(p.kind);
                        return Card(
                          child: ListTile(
                            leading: const Icon(Icons.credit_card, color: Colors.red),
                            title: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  margin: const EdgeInsets.only(right: 6),
                                  decoration: BoxDecoration(
                                    color: bgColor,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(p.kind.label,
                                      style: TextStyle(fontSize: 12, color: fgColor)),
                                ),
                                Expanded(child: Text('${p.cardName}  ¥${yenNum(p.amount)}')),
                              ],
                            ),
                            subtitle: Text('${DateFormat('M/d').format(p.date)}\n${p.snippet}',
                                maxLines: 2, overflow: TextOverflow.ellipsis),
                            isThreeLine: true,
                            trailing: const Icon(Icons.check_circle, color: Colors.green),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
