// 💡 予定支出（車検・旅行・家電の買い替えなど）の管理シート。
//   毎月の固定費は「定期支払い」、カードの請求は「支払い」で扱う。
//   ここは「決まった日に一度だけ出ていくお金」を登録する場所。
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import 'app_sheet.dart';
import '../money_format.dart';

Future<void> showPlannedExpenseSheet(
    BuildContext context, AppState appState) async {
  showAppSheet<void>(context, (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final all = [...appState.plannedExpenses]
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
                    const Icon(Icons.event_busy, color: Colors.deepOrange),
                    const SizedBox(width: 8),
                    const Text('予定支出',
                        style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                    const Spacer(),
                    TextButton.icon(
                      icon: const Icon(Icons.add),
                      label: const Text('追加'),
                      onPressed: () async {
                        await _edit(ctx, appState, null);
                        setLocal(() {});
                      },
                    ),
                  ],
                ),
                const Text(
                  '車検・旅行・家電の買い替えなど、決まった日に一度だけ出ていくお金。'
                  '予定日の月の残高から引かれます。',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
                const SizedBox(height: 12),
                if (all.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text('まだありません',
                          style: TextStyle(color: Colors.grey)),
                    ),
                  )
                else
                  ...all.map((e) {
                    // 💡 次に来る、まだ払っていない回。一度きりで払い済みなら null
                    final next = appState.nextUnpaidPlannedExpenseDate(e);
                    final paidOnce = !e.monthly && appState.isPlannedExpensePaid(e.id, e.date);
                    return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          e.monthly ? Icons.repeat : Icons.event,
                          color: paidOnce ? Colors.grey : Colors.deepOrange,
                        ),
                        title: Text(e.title),
                        subtitle: Text(
                          paidOnce
                              ? '払い済み（予想から外しています）'
                              : e.monthly
                                  ? '毎月${e.date.day}日'
                                      '${next != null ? '・次回 ${DateFormat('M/d').format(next)}' : ''}'
                                  : DateFormat('yyyy年M月d日').format(e.date),
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('¥${yenNum(e.amount)}',
                                style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: paidOnce ? Colors.grey : Colors.deepOrange)),
                            if (paidOnce)
                              IconButton(
                                tooltip: '払い済みを取り消す',
                                icon: const Icon(Icons.undo, color: Colors.grey),
                                onPressed: () {
                                  appState.unmarkPlannedExpensePaid(e.id, e.date);
                                  setLocal(() {});
                                },
                              )
                            else if (next != null)
                              IconButton(
                                tooltip: '払い済みにする',
                                icon: const Icon(Icons.check_circle_outline,
                                    color: Colors.green),
                                onPressed: () async {
                                  if (await _confirmPaid(ctx, e, next) != true) return;
                                  appState.markPlannedExpensePaid(e.id, next);
                                  setLocal(() {});
                                },
                              ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline,
                                  color: Colors.grey),
                              onPressed: () {
                                appState.removePlannedExpense(e.id);
                                setLocal(() {});
                              },
                            ),
                          ],
                        ),
                        onTap: () async {
                          await _edit(ctx, appState, e);
                          setLocal(() {});
                        },
                      );
                  }),
              ],
            ),
          );
        },
      ));
}

// 💡 予定日より前に払ったとき用。払ったお金は今の口座残高に入っている前提なので、
//   予想からこの回を外す（外さないと、残高と予想の両方で二重に引かれる）。
Future<bool?> _confirmPaid(BuildContext context, PlannedExpense e, DateTime date) {
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('払い済みにする'),
      content: Text(
        '「${e.title}」（${DateFormat('M/d').format(date)}・¥${yenNum(e.amount)}）を予想から外します。\n\n'
        '払ったぶんが今の口座残高に入っている（残高を書き直した）ときに使ってください。'
        'まだ残高に入れていないなら、先に残高を書き直してください。',
        style: const TextStyle(fontSize: 13),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('やめる')),
        ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('払い済みにする')),
      ],
    ),
  );
}

Future<void> _edit(
    BuildContext context, AppState appState, PlannedExpense? edit) async {
  final titleCtrl = TextEditingController(text: edit?.title ?? '');
  final amountCtrl =
      TextEditingController(text: edit == null ? '' : '${edit.amount}');
  var date = edit?.date ?? DateTime.now();
  var monthly = edit?.monthly ?? false;

  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setLocal) => AlertDialog(
        title: Text(edit == null ? '予定支出を追加' : '予定支出を編集'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: titleCtrl,
              decoration: const InputDecoration(
                  labelText: '内容', hintText: '例: 車検、旅行'),
            ),
            TextField(
              controller: amountCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '金額(円)'),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('支払予定日', style: TextStyle(fontSize: 14)),
              trailing: Text(DateFormat('yyyy/M/d').format(date)),
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: date,
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2060),
                );
                if (picked != null) setLocal(() => date = picked);
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('毎月くり返す', style: TextStyle(fontSize: 14)),
              subtitle: const Text('毎月同じ日に出ていくとき',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
              value: monthly,
              onChanged: (v) => setLocal(() => monthly = v),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル')),
          ElevatedButton(
            onPressed: () {
              final amount = int.tryParse(amountCtrl.text) ?? 0;
              if (titleCtrl.text.trim().isEmpty || amount <= 0) return;
              if (edit == null) {
                appState.addPlannedExpense(
                    title: titleCtrl.text,
                    amount: amount,
                    date: date,
                    monthly: monthly);
              } else {
                appState.updatePlannedExpense(edit.id,
                    title: titleCtrl.text,
                    amount: amount,
                    date: date,
                    monthly: monthly);
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
