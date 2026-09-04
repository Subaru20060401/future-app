import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../app_state.dart';
import '../card_styles.dart';

// 削除した支払いのゴミ箱。復元・完全削除ができる（PCのゴミ箱と同じ）。
class TrashScreen extends StatelessWidget {
  const TrashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final trash = appState.trashedPayments;

    return Scaffold(
      appBar: AppBar(
        title: const Text('削除した金額（ゴミ箱）'),
        actions: [
          if (trash.isNotEmpty)
            TextButton(
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('ゴミ箱を空にする'),
                    content: const Text('完全に削除します。元に戻せません。よろしいですか？'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('キャンセル')),
                      TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('空にする', style: TextStyle(color: Colors.red))),
                    ],
                  ),
                );
                if (ok == true) appState.emptyTrash();
              },
              child: const Text('空にする', style: TextStyle(color: Colors.red)),
            ),
        ],
      ),
      body: trash.isEmpty
          ? const Center(
              child: Text('ゴミ箱は空です', style: TextStyle(color: Colors.grey)))
          : Column(
              children: [
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('削除した明細はここに入ります。更新（メール取得）で復活しません。\n復元すると支払い管理に戻ります。',
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                ),
                Expanded(
                  child: ListView(
                    children: trash.map((p) {
                      final style = cardStyleOf(p.cardName);
                      return Card(
                        child: ListTile(
                          leading: Icon(style.icon, color: style.color),
                          title: Text(p.cardName),
                          subtitle: Text(p.note.isNotEmpty
                              ? '${DateFormat('yyyy/M/d').format(p.paymentDate)} ・ ${p.note}'
                              : DateFormat('yyyy/M/d').format(p.paymentDate)),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('¥${p.amount}', style: const TextStyle(color: Colors.grey)),
                              IconButton(
                                tooltip: '復元',
                                icon: const Icon(Icons.restore, color: Colors.green),
                                onPressed: () => appState.restorePayment(p.id),
                              ),
                              IconButton(
                                tooltip: '完全に削除',
                                icon: const Icon(Icons.delete_forever, color: Colors.red),
                                onPressed: () => appState.deleteFromTrash(p.id),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
    );
  }
}
