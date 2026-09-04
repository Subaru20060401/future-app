import 'package:flutter/material.dart';
import '../app_state.dart';

// 給料情報（1区間）の詳細編集。参考画像3準拠。
// 期間（締日基準・読み取り）／時給／交通費／休日・深夜・残業手当（なし or 倍率）。
class WagePeriodEditScreen extends StatefulWidget {
  final WagePeriod period;
  final String periodLabel; // 表示用の期間ラベル（締日基準で算出済み）
  const WagePeriodEditScreen(
      {super.key, required this.period, required this.periodLabel});

  @override
  State<WagePeriodEditScreen> createState() => _WagePeriodEditScreenState();
}

class _WagePeriodEditScreenState extends State<WagePeriodEditScreen> {
  late TextEditingController _wageCtrl;
  late int _transportPerDay;
  late int _transportMonthlyCap;
  late double _holiday;
  late double _night;
  late double _overtime;

  @override
  void initState() {
    super.initState();
    _wageCtrl = TextEditingController(text: widget.period.hourlyWage.toString());
    _transportPerDay = widget.period.transportPerDay;
    _transportMonthlyCap = widget.period.transportMonthlyCap;
    _holiday = widget.period.holidayMultiplier;
    _night = widget.period.nightMultiplier;
    _overtime = widget.period.overtimeMultiplier;
  }

  @override
  void dispose() {
    _wageCtrl.dispose();
    super.dispose();
  }

  String _multLabel(double m) => m > 1.0 ? '$m倍' : 'なし';

  // 金額（円）の編集ダイアログ。交通費・月上限で共用。
  Future<void> _editAmount(String title, int current, ValueChanged<int> onSave) async {
    final ctrl = TextEditingController(text: current.toString());
    final v = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(suffixText: '円', labelText: '金額（0=なし）'),
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
    if (v != null) onSave(v);
  }

  // 手当（倍率）の編集ダイアログ。なし=1.0、あり=任意倍率。
  Future<void> _editMultiplier(String title, double current, double presetOn,
      ValueChanged<double> onSave) async {
    bool enabled = current > 1.0;
    final ctrl =
        TextEditingController(text: (current > 1.0 ? current : presetOn).toString());
    final v = await showDialog<double>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('この手当をつける'),
                value: enabled,
                onChanged: (b) => setLocal(() => enabled = b),
              ),
              if (enabled)
                TextField(
                  controller: ctrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                      labelText: '割増倍率', suffixText: '倍', helperText: '例: 1.25'),
                ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
            ElevatedButton(
              onPressed: () {
                if (!enabled) {
                  Navigator.pop(context, 1.0);
                } else {
                  final m = double.tryParse(ctrl.text) ?? presetOn;
                  Navigator.pop(context, m < 1.0 ? 1.0 : m);
                }
              },
              child: const Text('決定'),
            ),
          ],
        ),
      ),
    );
    if (v != null) onSave(v);
  }

  void _save() {
    final result = widget.period.copyWith(
      hourlyWage: int.tryParse(_wageCtrl.text) ?? widget.period.hourlyWage,
      transportPerDay: _transportPerDay,
      transportMonthlyCap: _transportMonthlyCap,
      holidayMultiplier: _holiday,
      nightMultiplier: _night,
      overtimeMultiplier: _overtime,
    );
    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.periodLabel)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 期間（読み取り）
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.grey[200],
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Text('期間', style: TextStyle(color: Colors.grey)),
                const SizedBox(width: 24),
                Expanded(
                    child: Text(widget.periodLabel,
                        style: const TextStyle(fontWeight: FontWeight.bold))),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('※期間は給料の締日に基づいて設定されています。',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ),
          // 時給
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  const Text('給料', style: TextStyle(color: Colors.grey)),
                  const SizedBox(width: 16),
                  const Text('時給'),
                  const SizedBox(width: 8),
                  const Text('|', style: TextStyle(color: Colors.grey)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _wageCtrl,
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.right,
                      decoration: const InputDecoration(
                          border: InputBorder.none, suffixText: '円'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                ListTile(
                  title: const Text('交通費'),
                  trailing: Text(_transportPerDay > 0 ? '一日 $_transportPerDay 円' : 'なし'),
                  onTap: () => _editAmount('交通費（一日）', _transportPerDay,
                      (v) => setState(() => _transportPerDay = v)),
                ),
                const Divider(height: 1),
                ListTile(
                  title: const Text('交通費の月上限'),
                  trailing: Text(_transportMonthlyCap > 0 ? '月 $_transportMonthlyCap 円' : 'なし'),
                  onTap: () => _editAmount('交通費の月上限', _transportMonthlyCap,
                      (v) => setState(() => _transportMonthlyCap = v)),
                ),
                const Divider(height: 1),
                ListTile(
                  title: const Text('休日給料'),
                  trailing: Text(_multLabel(_holiday)),
                  onTap: () => _editMultiplier('休日給料', _holiday, 1.35,
                      (v) => setState(() => _holiday = v)),
                ),
                const Divider(height: 1),
                ListTile(
                  title: const Text('深夜給料'),
                  trailing: Text(_multLabel(_night)),
                  onTap: () => _editMultiplier('深夜給料（22:00〜翌5:00）', _night, 1.25,
                      (v) => setState(() => _night = v)),
                ),
                const Divider(height: 1),
                ListTile(
                  title: const Text('残業手当'),
                  trailing: Text(_multLabel(_overtime)),
                  onTap: () => _editMultiplier('残業手当（1日8時間超）', _overtime, 1.25,
                      (v) => setState(() => _overtime = v)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 52,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green, foregroundColor: Colors.white),
              onPressed: _save,
              child: const Text('保存する', style: TextStyle(fontSize: 16)),
            ),
          ),
        ],
      ),
    );
  }
}
