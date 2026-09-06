import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../app_state.dart';
import 'app_sheet.dart';

// 💡 予定入金（仕送り・返金・臨時収入など）の管理シート。
//   給料はシフトから自動計算するので、それ以外の入ってくるお金をここに登録する。
Future<void> showPlannedIncomeSheet(BuildContext context, AppState appState) async {
  showAppSheet<void>(context, (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        final due = appState.duePlannedIncomes;
        final all = [...appState.plannedIncomes]
          ..sort((a, b) => a.date.compareTo(b.date));
        return Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text('予定入金',
                        style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('追加'),
                    onPressed: () async {
                      await _editPlanned(context, appState, null);
                      setLocal(() {});
                    },
                  ),
                ],
              ),
              const Text('給料以外に入ってくる予定のお金（仕送り・返金など）',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
              const SizedBox(height: 10),

              // 予定日が過ぎて未受け取りのもの
              if (due.isNotEmpty) ...[
                const Text('受け取り待ち',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                ...due.map((e) => Card(
                      color: Colors.green[50],
                      child: ListTile(
                        dense: true,
                        title: Text(e.income.title,
                            style: const TextStyle(fontSize: 14)),
                        subtitle: Text(DateFormat('M月d日').format(e.date),
                            style: const TextStyle(fontSize: 11)),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('+¥${e.income.amount}',
                                style: const TextStyle(
                                    color: Colors.green,
                                    fontWeight: FontWeight.bold)),
                            const SizedBox(width: 8),
                            TextButton(
                              style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact),
                              onPressed: () {
                                appState.receivePlannedIncome(
                                    e.income.id, e.income.amount, e.date);
                                setLocal(() {});
                              },
                              child: const Text('受け取った'),
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              tooltip: '今回は無し',
                              icon: const Icon(Icons.close, size: 16),
                              onPressed: () {
                                appState.skipPlannedIncome(e.income.id, e.date);
                                setLocal(() {});
                              },
                            ),
                          ],
                        ),
                      ),
                    )),
                const Divider(height: 20),
              ],

              // 登録一覧
              if (all.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text('登録された予定入金はありません',
                      style: TextStyle(fontSize: 13, color: Colors.grey)),
                )
              else
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 280),
                  child: ListView(
                    shrinkWrap: true,
                    children: all
                        .map((p) => Card(
                              child: ListTile(
                                dense: true,
                                leading: const Icon(Icons.event_available,
                                    color: Colors.green, size: 20),
                                title: Text(p.title),
                                subtitle: Text(p.monthly
                                    ? '毎月${p.date.day}日'
                                    : DateFormat('yyyy/M/d').format(p.date)),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text('+¥${p.amount}',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.bold)),
                                    IconButton(
                                      visualDensity: VisualDensity.compact,
                                      icon: const Icon(Icons.edit, size: 16),
                                      onPressed: () async {
                                        await _editPlanned(context, appState, p);
                                        setLocal(() {});
                                      },
                                    ),
                                    IconButton(
                                      visualDensity: VisualDensity.compact,
                                      icon: const Icon(Icons.delete_outline,
                                          size: 16, color: Colors.red),
                                      onPressed: () {
                                        appState.removePlannedIncome(p.id);
                                        setLocal(() {});
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            ))
                        .toList(),
                  ),
                ),
            ],
          ),
        );
      },
    ),
  );
}

// 予定入金の追加・編集
Future<void> _editPlanned(
    BuildContext context, AppState appState, PlannedIncome? existing) async {
  final titleCtrl = TextEditingController(text: existing?.title ?? '');
  final amountCtrl =
      TextEditingController(text: existing != null ? existing.amount.toString() : '');
  var date = existing?.date ?? DateTime.now();
  var monthly = existing?.monthly ?? false;

  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setLocal) => AlertDialog(
        title: Text(existing == null ? '予定入金を追加' : '予定入金を編集'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: titleCtrl,
                decoration: const InputDecoration(
                    labelText: '内容（仕送り・返金など）', isDense: true),
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
                title: const Text('入金予定日'),
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
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('毎月繰り返す', style: TextStyle(fontSize: 14)),
                subtitle: Text('毎月${date.day}日に入る予定にする',
                    style: const TextStyle(fontSize: 11)),
                value: monthly,
                onChanged: (v) => setLocal(() => monthly = v),
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
              final amount = int.tryParse(amountCtrl.text.replaceAll(',', '')) ?? 0;
              if (amount <= 0 || titleCtrl.text.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('内容と金額を入力してください')),
                );
                return;
              }
              if (existing == null) {
                appState.addPlannedIncome(
                  title: titleCtrl.text.trim(),
                  amount: amount,
                  date: date,
                  monthly: monthly,
                );
              } else {
                appState.updatePlannedIncome(
                  existing.id,
                  title: titleCtrl.text.trim(),
                  amount: amount,
                  date: date,
                  monthly: monthly,
                );
              }
              Navigator.pop(context);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  );
}
