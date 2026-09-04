import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app_state.dart';
import '../card_styles.dart';

// カテゴリ別の月予算を設定し、今月の実績と比較する画面。
class BudgetScreen extends StatelessWidget {
  const BudgetScreen({super.key});

  Future<void> _edit(BuildContext context, AppState appState, String label) async {
    final ctrl = TextEditingController(
        text: appState.budgets[label] != null ? appState.budgets[label].toString() : '');
    final v = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('$label の月予算'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(suffixText: '円', labelText: '予算（0=未設定）'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, int.tryParse(ctrl.text) ?? 0),
            child: const Text('決定'),
          ),
        ],
      ),
    );
    if (v != null) appState.setBudget(label, v);
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final month = DateTime.now();
    final spentByLabel = {
      for (final e in appState.expenseBreakdownOf(month)) e.label: e.amount
    };
    // 予算対象＝今月の支出ラベル＋予算設定済みラベル
    final labels = {...spentByLabel.keys, ...appState.budgets.keys}.toList()..sort();

    return Scaffold(
      appBar: AppBar(title: const Text('予算の設定')),
      body: labels.isEmpty
          ? const Center(
              child: Text('今月の支出データがありません', style: TextStyle(color: Colors.grey)))
          : ListView(
              padding: const EdgeInsets.all(8),
              children: [
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Text('カテゴリをタップして月予算を設定。今月の実績と比較します。',
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                ),
                ...labels.map((label) {
                  final spent = spentByLabel[label] ?? 0;
                  final budget = appState.budgets[label] ?? 0;
                  final over = budget > 0 && spent > budget;
                  final ratio = budget > 0 ? (spent / budget).clamp(0.0, 1.0) : 0.0;
                  final color = over ? Colors.red : Colors.green;
                  return Card(
                    child: ListTile(
                      onTap: () => _edit(context, appState, label),
                      leading: Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                              color: cardColorOf(label), shape: BoxShape.circle)),
                      title: Text(label),
                      subtitle: budget > 0
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 4),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: LinearProgressIndicator(
                                    value: ratio.toDouble(),
                                    minHeight: 6,
                                    backgroundColor: Colors.grey[200],
                                    color: color,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text('¥$spent / ¥$budget${over ? '  ⚠ 超過' : ''}',
                                    style: TextStyle(fontSize: 12, color: color)),
                              ],
                            )
                          : Text('実績 ¥$spent ・予算未設定',
                              style: const TextStyle(fontSize: 12, color: Colors.grey)),
                      trailing: const Icon(Icons.edit, size: 18),
                    ),
                  );
                }),
              ],
            ),
    );
  }
}
