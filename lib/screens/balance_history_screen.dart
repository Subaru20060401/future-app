import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../app_state.dart';

// 💡 口座残高に反映した「入金・引き落とし」の履歴。
//   いつ・何を・いくら反映したかを確認でき、間違えたら取り消せる。
class BalanceHistoryScreen extends StatefulWidget {
  const BalanceHistoryScreen({super.key});

  @override
  State<BalanceHistoryScreen> createState() => _BalanceHistoryScreenState();
}

class _BalanceHistoryScreenState extends State<BalanceHistoryScreen> {
  // 0=すべて / 1=入金 / 2=引き落とし
  int _filter = 0;

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final all = appState.balanceHistory;
    final list = switch (_filter) {
      1 => all.where((e) => e.kind == BalanceEntryKind.deposit).toList(),
      2 => all.where((e) => e.kind == BalanceEntryKind.draw).toList(),
      _ => all,
    };

    final depositTotal = all
        .where((e) => e.kind == BalanceEntryKind.deposit)
        .fold<int>(0, (s, e) => s + e.amount);
    final drawTotal = all
        .where((e) => e.kind == BalanceEntryKind.draw)
        .fold<int>(0, (s, e) => s + e.amount);

    return Scaffold(
      appBar: AppBar(title: const Text('入出金の履歴')),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'add_past_entry',
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.playlist_add),
        label: const Text('記録を追加'),
        onPressed: () => _addPastEntry(context, appState),
      ),
      body: Column(
        children: [
          // 合計サマリー
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: _summaryTile('入金の合計', depositTotal, Colors.green, '+'),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _summaryTile('引き落としの合計', drawTotal, Colors.red, '-'),
                ),
              ],
            ),
          ),
          // 絞り込み
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                for (final opt in const [
                  (0, 'すべて'),
                  (1, '入金'),
                  (2, '引き落とし'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(opt.$2),
                      selected: _filter == opt.$1,
                      onSelected: (_) => setState(() => _filter = opt.$1),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: list.isEmpty
                ? const Center(
                    child: Text('履歴はまだありません',
                        style: TextStyle(color: Colors.grey)))
                : ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (context, i) {
                      final e = list[i];
                      final isDeposit = e.kind == BalanceEntryKind.deposit;
                      final color = isDeposit ? Colors.green : Colors.red;
                      return Card(
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: color.withValues(alpha: 0.15),
                            child: Icon(
                              isDeposit ? Icons.south_west : Icons.north_east,
                              color: color,
                              size: 18,
                            ),
                          ),
                          title: Text(e.label,
                              style: const TextStyle(fontWeight: FontWeight.bold)),
                          subtitle: Text(
                            '${DateFormat('M/d HH:mm').format(e.at)}  →  残高 ¥${e.balanceAfter}',
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '${isDeposit ? '+' : '-'}¥${e.amount}',
                                style: TextStyle(
                                    color: color, fontWeight: FontWeight.bold),
                              ),
                              IconButton(
                                tooltip: '取り消す',
                                visualDensity: VisualDensity.compact,
                                icon: const Icon(Icons.undo, size: 18),
                                onPressed: () => _confirmUndo(context, appState, e),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _summaryTile(String label, int amount, Color color, String sign) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 11, color: Colors.black54)),
          const SizedBox(height: 2),
          Text('$sign¥$amount',
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold, color: color)),
        ],
      ),
    );
  }

  // 💡 過去の入出金を履歴だけに書き足す（残高は変えない）
  Future<void> _addPastEntry(BuildContext context, AppState appState) async {
    var kind = BalanceEntryKind.draw;
    final labelCtrl = TextEditingController();
    final amountCtrl = TextEditingController();
    var date = DateTime.now();

    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('記録を追加'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('すでに反映済みの入出金を、記録としてだけ残します。\n残高は変わりません。',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 12),
                Row(
                  children: [
                    ChoiceChip(
                      label: const Text('入金'),
                      selected: kind == BalanceEntryKind.deposit,
                      onSelected: (_) =>
                          setLocal(() => kind = BalanceEntryKind.deposit),
                    ),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: const Text('引き落とし'),
                      selected: kind == BalanceEntryKind.draw,
                      onSelected: (_) => setLocal(() => kind = BalanceEntryKind.draw),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: labelCtrl,
                  decoration: const InputDecoration(
                      labelText: '内容（カード名・バイト名など）', isDense: true),
                ),
                TextField(
                  controller: amountCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: '金額', prefixText: '¥ ', isDense: true),
                ),
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('日付'),
                  trailing: Text(DateFormat('yyyy/M/d').format(date)),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: date,
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2035),
                    );
                    if (picked != null) setLocal(() => date = picked);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('キャンセル')),
            ElevatedButton(
              onPressed: () {
                final amount =
                    int.tryParse(amountCtrl.text.replaceAll(',', '')) ?? 0;
                if (amount <= 0 || labelCtrl.text.trim().isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('内容と金額を入力してください')),
                  );
                  return;
                }
                appState.addPastBalanceEntry(
                  kind: kind,
                  label: labelCtrl.text.trim(),
                  amount: amount,
                  at: date,
                );
                Navigator.pop(context);
              },
              child: const Text('記録する'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmUndo(
      BuildContext context, AppState appState, BalanceEntry e) async {
    final isDeposit = e.kind == BalanceEntryKind.deposit;
    final after = appState.currentBalance - e.signedAmount;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('この記録を取り消しますか？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${e.label}  ${isDeposit ? '+' : '-'}¥${e.amount}'),
            const SizedBox(height: 8),
            Text('残高が ¥$after に戻ります。',
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
            const SizedBox(height: 4),
            const Text('元の通知は未処理に戻るので、入力し直せます。',
                style: TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('やめる')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('取り消す'),
          ),
        ],
      ),
    );
    if (ok == true) {
      appState.undoBalanceEntry(e.id);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('取り消しました')),
        );
      }
    }
  }
}
