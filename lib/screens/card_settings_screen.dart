import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app_state.dart';
import '../card_styles.dart';

// 💡 各クレカの分割金利（年率%）を設定。分割変換時にこの値を使う。
class CardSettingsScreen extends StatelessWidget {
  const CardSettingsScreen({super.key});

  void _edit(BuildContext context, AppState appState, String card) {
    final ctrl = TextEditingController(text: appState.interestRateOf(card).toStringAsFixed(1));
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('$card の分割金利'),
        content: TextField(
          controller: ctrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: '年率(%)', hintText: '例: 15.0'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
          ElevatedButton(
            onPressed: () {
              appState.setInterestRate(card, double.tryParse(ctrl.text) ?? 15.0);
              Navigator.pop(context);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(title: const Text('カードの金利設定')),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('分割払いに変換するときの手数料計算に使う年率です。',
                style: TextStyle(color: Colors.grey)),
          ),
          // 💡 設定で追加したカードも金利を設定できるように AppState から取る
          ...appState.cardChoices
              .where((c) => c != AppState.kOtherCard)
              .map((c) {
            final style = cardStyleOf(c);
            return Card(
              child: ListTile(
                leading: Icon(style.icon, color: style.color),
                title: Text(c),
                subtitle: Text(
                    '分割は¥${minInstallmentAmount(c)}以上'
                    '${(c.contains('Amazon')) ? ' / 2・3回は手数料無料' : ''}',
                    style: const TextStyle(fontSize: 12)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('${appState.interestRateOf(c).toStringAsFixed(1)} %',
                        style: const TextStyle(fontSize: 16)),
                    const Icon(Icons.edit, size: 18),
                  ],
                ),
                onTap: () => _edit(context, appState, c),
              ),
            );
          }),
        ],
      ),
    );
  }
}
