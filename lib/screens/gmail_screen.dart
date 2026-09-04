import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../app_state.dart';
import '../gmail_service.dart';

class GmailScreen extends StatefulWidget {
  const GmailScreen({super.key});

  @override
  State<GmailScreen> createState() => _GmailScreenState();
}

class _GmailScreenState extends State<GmailScreen> {
  final _gmail = GmailService.instance;
  bool _loading = false;
  String? _error;
  List<ParsedPayment> _results = [];

  PaymentSource _toSource(MailKind kind) {
    switch (kind) {
      case MailKind.bank:
        return PaymentSource.bank;
      case MailKind.billing:
        return PaymentSource.billing;
      case MailKind.usage:
        return PaymentSource.usage;
    }
  }

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
    _gmail.signInSilently().then((_) => mounted ? setState(() {}) : null);
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
      }
    } catch (e) {
      setState(() => _error = 'ログイン失敗: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _error = null;
      _results = [];
    });
    // await前にAppStateを取得（context.read を非同期境界をまたいで使わない）
    final appState = context.read<AppState>();
    try {
      final list = await _gmail.fetchCardPayments();
      // 💡 銀行確定を正本として照合・自動追加（重複は除外）
      final r = appState.reconcilePayments(list.map((p) => (
            cardName: p.cardName,
            amount: p.amount,
            date: p.date,
            source: _toSource(p.kind),
            sourceId: p.sourceId,
            note: p.note,
          )));
      setState(() => _results = list);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${r.added}件追加 / ${r.removed}件削除')),
        );
      }
    } catch (e) {
      setState(() => _error = '取得失敗: $e');
    } finally {
      setState(() => _loading = false);
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
                leading: Icon(_gmail.isSignedIn ? Icons.check_circle : Icons.mail_outline,
                    color: _gmail.isSignedIn ? Colors.green : Colors.grey),
                title: Text(_gmail.isSignedIn ? '連携中' : '未連携'),
                subtitle: Text(_gmail.account?.email ?? 'Googleアカウントでログインしてください'),
                trailing: _gmail.isSignedIn
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

            if (!_gmail.isSignedIn)
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
                                Expanded(child: Text('${p.cardName}  ¥${p.amount}')),
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
