import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../app_state.dart';

// 💡 「振込入金のお知らせ」メールを受けて、金額を入力してもらうポップアップ。
//   メールに金額が載らないため、ユーザーに入力してもらって口座残高へ加算する。
//   給料日が一致する勤務先は自動で選ばれ、見込み額が金額欄に入る。
Future<void> showDepositDialog(
  BuildContext context,
  AppState appState,
  DepositNotice notice,
) async {
  // 💡 まだ受け取っていない勤務先だけを選択肢に出す（入金済みは消す）
  final awaiting = appState.workplacesAwaitingSalary(notice.date);
  // 入金日が給料日に近い勤務先（近い順）。未入金のものだけ推奨にする。
  final candidates = appState
      .workplacesWithPaydayNear(notice.date)
      .where((w) => awaiting.any((a) => a.id == w.id))
      .toList();
  String? selectedWpId = candidates.isNotEmpty ? candidates.first.id : null;
  final amountCtrl = TextEditingController();

  // 選んだ勤務先の見込み手取りを金額欄に入れる
  void fillEstimate() {
    final w = appState.workplaceById(selectedWpId);
    if (w == null) return;
    final wm = appState.workMonthForPayday(w, notice.date);
    final est = appState.takeHomeOfWorkplace(wm, w.id);
    if (est > 0) amountCtrl.text = est.toString();
  }

  fillEstimate();

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => StatefulBuilder(
      builder: (context, setLocal) => AlertDialog(
        title: const Row(
          children: [
            Text('💰 ', style: TextStyle(fontSize: 22)),
            Expanded(child: Text('入金がありました', style: TextStyle(fontSize: 18))),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${DateFormat('M月d日').format(notice.date)} に振込入金のお知らせが届いています。',
                style: const TextStyle(fontSize: 13, color: Colors.black87),
              ),
              const SizedBox(height: 2),
              const Text(
                'メールに金額が無いため、入金額を入力してください。',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: amountCtrl,
                keyboardType: TextInputType.number,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '入金額',
                  prefixText: '¥ ',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              if (awaiting.isNotEmpty) ...[
                const SizedBox(height: 14),
                const Text('どの入金ですか？',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    ...awaiting.map((w) {
                      // 給料日が入金日と近い勤務先には「推奨」マークを出す
                      final isPayday = candidates.any((c) => c.id == w.id);
                      return ChoiceChip(
                        avatar: CircleAvatar(
                          backgroundColor: Color(w.colorValue),
                          radius: 6,
                        ),
                        label: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('${w.name}の給料', style: const TextStyle(fontSize: 12)),
                            if (isPayday) ...[
                              const SizedBox(width: 4),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                decoration: BoxDecoration(
                                  color: Colors.amber.shade700,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.star, size: 9, color: Colors.white),
                                    SizedBox(width: 2),
                                    Text('推奨',
                                        style: TextStyle(
                                            fontSize: 9,
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold)),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                        selected: selectedWpId == w.id,
                        onSelected: (_) => setLocal(() {
                          selectedWpId = selectedWpId == w.id ? null : w.id;
                          fillEstimate();
                        }),
                      );
                    }),
                    ChoiceChip(
                      label: const Text('その他の入金', style: TextStyle(fontSize: 12)),
                      selected: selectedWpId == null,
                      onSelected: (_) => setLocal(() => selectedWpId = null),
                    ),
                  ],
                ),
                if (selectedWpId != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '※ ${_workMonthLabel(appState, selectedWpId!, notice.date)}の実給料としても記録します',
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              appState.skipDepositNotice(notice.sourceId);
              Navigator.pop(context);
            },
            child: const Text('スキップ'),
          ),
          ElevatedButton(
            onPressed: () {
              final amount = int.tryParse(amountCtrl.text.replaceAll(',', '')) ?? 0;
              if (amount <= 0) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('入金額を入力してください')),
                );
                return;
              }
              appState.applyDepositNotice(notice.sourceId, amount, workplaceId: selectedWpId);
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('¥$amount を口座残高に追加しました')),
              );
            },
            child: const Text('残高に追加'),
          ),
        ],
      ),
    ),
  );
}

String _workMonthLabel(AppState appState, String wpId, DateTime date) {
  final w = appState.workplaceById(wpId);
  if (w == null) return '';
  final wm = appState.workMonthForPayday(w, date);
  return '${wm.month}月分';
}

// 💡 手入力で口座に入金する（メール通知が無いときや現金入金用）
Future<void> showManualDepositDialog(BuildContext context, AppState appState) async {
  final amountCtrl = TextEditingController();
  String? selectedWpId;

  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setLocal) => AlertDialog(
        title: const Text('口座に入金'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('現在の口座残高に加算します。',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 10),
              TextField(
                controller: amountCtrl,
                keyboardType: TextInputType.number,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '入金額',
                  prefixText: '¥ ',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              if (appState.workplacesAwaitingSalary(DateTime.now()).isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('給料の場合はバイトを選択',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    ...appState.workplacesAwaitingSalary(DateTime.now()).map((w) => ChoiceChip(
                          avatar: CircleAvatar(
                              backgroundColor: Color(w.colorValue), radius: 6),
                          label: Text(w.name, style: const TextStyle(fontSize: 12)),
                          selected: selectedWpId == w.id,
                          onSelected: (_) => setLocal(
                              () => selectedWpId = selectedWpId == w.id ? null : w.id),
                        )),
                    ChoiceChip(
                      label: const Text('その他', style: TextStyle(fontSize: 12)),
                      selected: selectedWpId == null,
                      onSelected: (_) => setLocal(() => selectedWpId = null),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
          ElevatedButton(
            onPressed: () {
              final amount = int.tryParse(amountCtrl.text.replaceAll(',', '')) ?? 0;
              if (amount <= 0) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('入金額を入力してください')),
                );
                return;
              }
              appState.addDeposit(amount, workplaceId: selectedWpId);
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('¥$amount を口座残高に追加しました')),
              );
            },
            child: const Text('入金する'),
          ),
        ],
      ),
    ),
  );
}

// 💡 「引き落としがありました」ポップアップ。
//   銀行の事前お知らせには金額が載っているので、そのまま口座から引ける。
//   （入金と違って金額が分かるので、確認してボタンを押すだけ）
Future<void> showDrawDialog(
  BuildContext context,
  AppState appState,
  ({String id, String label, int amount, DateTime date}) draw,
) async {
  final amountCtrl = TextEditingController(text: draw.amount.toString());

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: const Row(
        children: [
          Text('💳 ', style: TextStyle(fontSize: 22)),
          Expanded(child: Text('引き落としがありました', style: TextStyle(fontSize: 18))),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${DateFormat('M月d日').format(draw.date)}  ${draw.label}',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            Text(
              draw.label.contains('（手動）')
                  ? '支払い済みなら、この金額を口座残高から引きます'
                  : draw.label.contains('（予定）')
                      ? '見込みの金額です。実際の引き落とし額に直してから引いてください'
                      : 'この金額を口座残高から引きますか？',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: amountCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '引き落とし額',
                prefixText: '¥ ',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Text('引いた後の残高', style: TextStyle(fontSize: 12)),
                  const Spacer(),
                  Text(
                    '¥${appState.currentBalance - (int.tryParse(amountCtrl.text) ?? draw.amount)}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            appState.skipDraw(draw.id);
            Navigator.pop(context);
          },
          child: const Text('スキップ'),
        ),
        ElevatedButton(
          onPressed: () {
            final amount = int.tryParse(amountCtrl.text.replaceAll(',', '')) ?? draw.amount;
            appState.applyDraw(draw.id, amount, label: draw.label);
            Navigator.pop(context);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('¥$amount を口座残高から引きました')),
            );
          },
          child: const Text('口座から引く'),
        ),
      ],
    ),
  );
}

// 💡 引き落としの一覧＋手入力。未反映の引き落としをまとめて処理できる。
Future<void> showDrawSheet(BuildContext context, AppState appState) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        final pending = appState.pendingDraws;
        return Padding(
          padding: EdgeInsets.only(
            left: 20, right: 20, top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('口座から引き落とし',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              Text('現在の残高 ¥${appState.currentBalance}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 12),
              if (pending.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('未反映の引き落としはありません',
                      style: TextStyle(fontSize: 13, color: Colors.grey)),
                )
              else ...[
                const Text('未反映の引き落とし',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 260),
                  child: ListView(
                    shrinkWrap: true,
                    children: pending
                        .map((d) => Card(
                              color: Colors.red[50],
                              child: ListTile(
                                dense: true,
                                title: Text(d.label, style: const TextStyle(fontSize: 14)),
                                subtitle: Text(DateFormat('M月d日').format(d.date),
                                    style: const TextStyle(fontSize: 11)),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text('-¥${d.amount}',
                                        style: const TextStyle(
                                            color: Colors.red, fontWeight: FontWeight.bold)),
                                    const SizedBox(width: 8),
                                    TextButton(
                                      style: TextButton.styleFrom(
                                          visualDensity: VisualDensity.compact),
                                      onPressed: () {
                                        appState.applyDraw(d.id, d.amount, label: d.label);
                                        setLocal(() {});
                                      },
                                      child: const Text('引く'),
                                    ),
                                    IconButton(
                                      visualDensity: VisualDensity.compact,
                                      tooltip: 'スキップ',
                                      icon: const Icon(Icons.close, size: 16),
                                      onPressed: () {
                                        appState.skipDraw(d.id);
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
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red, foregroundColor: Colors.white),
                        icon: const Icon(Icons.done_all, size: 18),
                        label: Text('すべて引く（-¥${pending.fold<int>(0, (s, d) => s + d.amount)}）'),
                        onPressed: () {
                          for (final d in List.of(pending)) {
                            appState.applyDraw(d.id, d.amount, label: d.label);
                          }
                          setLocal(() {});
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () {
                        appState.skipAllDraws();
                        setLocal(() {});
                      },
                      child: const Text('すべてスキップ'),
                    ),
                  ],
                ),
              ],
              const Divider(height: 24),
              // 手入力（通知に無い引き落とし・現金払いなど）
              const Text('手入力で引く', style: TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 6),
              _ManualSubtractRow(appState: appState),
            ],
          ),
        );
      },
    ),
  );
}

class _ManualSubtractRow extends StatefulWidget {
  final AppState appState;
  const _ManualSubtractRow({required this.appState});

  @override
  State<_ManualSubtractRow> createState() => _ManualSubtractRowState();
}

class _ManualSubtractRowState extends State<_ManualSubtractRow> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _ctrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '金額',
              prefixText: '¥ ',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        const SizedBox(width: 8),
        ElevatedButton(
          onPressed: () {
            final amount = int.tryParse(_ctrl.text.replaceAll(',', '')) ?? 0;
            if (amount <= 0) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('金額を入力してください')),
              );
              return;
            }
            widget.appState.subtractFromBalance(amount);
            _ctrl.clear();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('¥$amount を口座残高から引きました')),
            );
          },
          child: const Text('引く'),
        ),
      ],
    );
  }
}
