import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app_state.dart';
import '../workplace_styles.dart';
import 'wage_period_edit_screen.dart';

// 勤務先の編集／新規。参考画像2準拠。
class WorkplaceEditScreen extends StatefulWidget {
  final Workplace? workplace; // null = 新規
  const WorkplaceEditScreen({super.key, this.workplace});

  @override
  State<WorkplaceEditScreen> createState() => _WorkplaceEditScreenState();
}

class _WorkplaceEditScreenState extends State<WorkplaceEditScreen> {
  late TextEditingController _nameCtrl;
  late TextEditingController _locationCtrl;
  late int _colorValue;
  late String _genre;
  late int _closingDay; // 31 = 月末
  late int _paydayMonthOffset;
  late int _paydayDay;
  late PaydayAdjust _paydayAdjust;
  late List<WagePeriod> _periods;

  bool get _isNew => widget.workplace == null;

  @override
  void initState() {
    super.initState();
    final w = widget.workplace;
    _nameCtrl = TextEditingController(text: w?.name ?? '');
    _locationCtrl = TextEditingController(text: w?.location ?? '');
    _colorValue = w?.colorValue ?? workplaceColorOptions.first.color.toARGB32();
    _genre = w?.genre ?? '';
    _closingDay = w?.closingDay ?? 31;
    _paydayMonthOffset = w?.paydayMonthOffset ?? 1;
    _paydayDay = w?.paydayDay ?? 25;
    _paydayAdjust = w?.paydayAdjust ?? PaydayAdjust.before;
    _periods = w == null
        ? [WagePeriod(hourlyWage: 1000)]
        : w.wagePeriods.map((e) => e.copyWith()).toList();
    _sortPeriods();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _locationCtrl.dispose();
    super.dispose();
  }

  void _sortPeriods() {
    _periods.sort((a, b) {
      if (a.effectiveFrom == null) return -1;
      if (b.effectiveFrom == null) return 1;
      return a.effectiveFrom!.compareTo(b.effectiveFrom!);
    });
  }

  String _fmt(DateTime d) => '${d.year}年${d.month}月${d.day}日';

  // i番目の給料情報の表示用期間ラベル（締日基準で区切られた連続区間）
  String _periodLabel(int i) {
    final start = _periods[i].effectiveFrom;
    final end = (i + 1 < _periods.length)
        ? _periods[i + 1].effectiveFrom?.subtract(const Duration(days: 1))
        : null;
    if (start == null && end == null) return '全期間';
    if (start == null) return '〜${_fmt(end!)}';
    if (end == null) return '${_fmt(start)}〜';
    return '${_fmt(start)}〜${_fmt(end)}';
  }

  String get _closingLabel => _closingDay >= 31 ? '月末' : '$_closingDay日';

  String get _paydayLabel {
    const m = ['当月', '翌月', '翌々月'];
    final mo = (_paydayMonthOffset >= 0 && _paydayMonthOffset < m.length)
        ? m[_paydayMonthOffset]
        : '翌月';
    return '$mo $_paydayDay日（土日祝は${_paydayAdjust.shortLabel}）';
  }

  Future<void> _pickColor() async {
    final v = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('表示色'),
        children: workplaceColorOptions
            .map((o) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, o.color.toARGB32()),
                  child: Row(
                    children: [
                      Container(
                          width: 20,
                          height: 20,
                          decoration:
                              BoxDecoration(color: o.color, shape: BoxShape.circle)),
                      const SizedBox(width: 12),
                      Text(o.name),
                    ],
                  ),
                ))
            .toList(),
      ),
    );
    if (v != null) setState(() => _colorValue = v);
  }

  Future<void> _pickGenre() async {
    final v = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('ジャンル'),
        children: workplaceGenres
            .map((g) => SimpleDialogOption(
                onPressed: () => Navigator.pop(context, g), child: Text(g)))
            .toList(),
      ),
    );
    if (v != null) setState(() => _genre = v);
  }

  Future<void> _pickClosingDay() async {
    final v = await showModalBottomSheet<int>(
      context: context,
      builder: (context) => ListView(
        children: [
          ListTile(title: const Text('月末'), onTap: () => Navigator.pop(context, 31)),
          for (var d = 1; d <= 28; d++)
            ListTile(title: Text('$d日'), onTap: () => Navigator.pop(context, d)),
        ],
      ),
    );
    if (v != null) setState(() => _closingDay = v);
  }

  Future<void> _pickPayday() async {
    int offset = _paydayMonthOffset;
    int day = _paydayDay;
    PaydayAdjust adjust = _paydayAdjust;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('給料日'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButton<int>(
                  value: offset,
                  isExpanded: true,
                  items: const [
                    DropdownMenuItem(value: 0, child: Text('当月')),
                    DropdownMenuItem(value: 1, child: Text('翌月')),
                    DropdownMenuItem(value: 2, child: Text('翌々月')),
                  ],
                  onChanged: (v) => setLocal(() => offset = v ?? 1),
                ),
                DropdownButton<int>(
                  value: day,
                  isExpanded: true,
                  items: [
                    for (var d = 1; d <= 31; d++)
                      DropdownMenuItem(value: d, child: Text('$d日')),
                  ],
                  onChanged: (v) => setLocal(() => day = v ?? 25),
                ),
                const SizedBox(height: 12),
                const Text('給料日が土日祝のとき',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                ...PaydayAdjust.values.map((a) => RadioListTile<PaydayAdjust>(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: a,
                      groupValue: adjust,
                      title: Text(a.label, style: const TextStyle(fontSize: 14)),
                      onChanged: (v) => setLocal(() => adjust = v ?? PaydayAdjust.before),
                    )),
                const Text('例: 25日が土曜 → 前営業日=24日(金) / 翌営業日=27日(月)',
                    style: TextStyle(fontSize: 11, color: Colors.grey)),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('キャンセル')),
            ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('決定')),
          ],
        ),
      ),
    );
    if (ok == true) {
      setState(() {
        _paydayMonthOffset = offset;
        _paydayDay = day;
        _paydayAdjust = adjust;
      });
    }
  }

  // 給料情報の編集（既存をタップ）
  Future<void> _editPeriod(int i) async {
    final edited = await Navigator.push<WagePeriod>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            WagePeriodEditScreen(period: _periods[i], periodLabel: _periodLabel(i)),
      ),
    );
    if (edited != null) {
      setState(() => _periods[i] = edited.copyWith(effectiveFrom: _periods[i].effectiveFrom));
    }
  }

  // 給料情報を追加（変更の有効日を選び、締日基準でスナップ）
  Future<void> _addPeriod() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(2018, 1, 1),
      lastDate: DateTime(2035, 12, 31),
      helpText: '給料が変わる日を選択',
    );
    if (picked == null) return;
    // 締日基準で期間の開始日へスナップ
    final tmp = Workplace(id: 'tmp', name: '', closingDay: _closingDay);
    final from = tmp.payPeriodStartFor(picked);
    // 直近の時給を引き継ぐ
    final base = _periods.isNotEmpty ? _periods.last : WagePeriod(hourlyWage: 1000);
    setState(() {
      // 同じ開始日が既にあれば置き換え扱いにせず追加を避ける
      _periods.removeWhere((p) => p.effectiveFrom == from);
      _periods.add(base.copyWith(effectiveFrom: from));
      _sortPeriods();
    });
  }

  void _save() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('勤務先名を入力してください')));
      return;
    }
    final appState = context.read<AppState>();
    final w = Workplace(
      id: widget.workplace?.id ?? appState.newWorkplaceId(),
      name: name,
      colorValue: _colorValue,
      genre: _genre,
      location: _locationCtrl.text.trim(),
      closingDay: _closingDay,
      paydayMonthOffset: _paydayMonthOffset,
      paydayDay: _paydayDay,
      paydayAdjust: _paydayAdjust,
      wagePeriods: _periods,
    );
    if (_isNew) {
      appState.addWorkplace(w);
    } else {
      appState.updateWorkplace(w);
    }
    Navigator.pop(context);
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('削除の確認'),
        content: Text('「${_nameCtrl.text}」を削除しますか？\n（登録済みのシフトは残ります）'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('キャンセル')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('削除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok == true && widget.workplace != null && mounted) {
      context.read<AppState>().removeWorkplace(widget.workplace!.id);
      Navigator.pop(context);
    }
  }

  Widget _row(String label, Widget value, {VoidCallback? onTap, bool required = false}) {
    return ListTile(
      onTap: onTap,
      title: Row(
        children: [
          Text(label, style: const TextStyle(color: Colors.black54)),
          if (required) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                  color: Colors.red, borderRadius: BorderRadius.circular(4)),
              child: const Text('必須',
                  style: TextStyle(color: Colors.white, fontSize: 11)),
            ),
          ],
        ],
      ),
      trailing: onTap != null
          ? Row(mainAxisSize: MainAxisSize.min, children: [
              value,
              const Icon(Icons.chevron_right, color: Colors.grey)
            ])
          : value,
    );
  }

  @override
  Widget build(BuildContext context) {
    final color = Color(_colorValue);
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? '勤務先の追加' : '${widget.workplace!.name}の編集'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: Column(
              children: [
                ListTile(
                  title: Row(children: [
                    const Text('勤務先', style: TextStyle(color: Colors.black54)),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                          color: Colors.red, borderRadius: BorderRadius.circular(4)),
                      child: const Text('必須',
                          style: TextStyle(color: Colors.white, fontSize: 11)),
                    ),
                  ]),
                  subtitle: TextField(
                    controller: _nameCtrl,
                    decoration: const InputDecoration(
                        border: InputBorder.none, hintText: '例: コンビニバイト'),
                  ),
                ),
                const Divider(height: 1),
                _row(
                  '表示色',
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(
                        width: 16,
                        height: 16,
                        decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                    const SizedBox(width: 8),
                    Text(workplaceColorName(_colorValue)),
                  ]),
                  onTap: _pickColor,
                ),
              ],
            ),
          ),
          Card(
            child: Column(
              children: [
                _row('ジャンル', Text(_genre.isEmpty ? '未設定' : _genre), onTap: _pickGenre),
                const Divider(height: 1),
                ListTile(
                  title: const Text('場所', style: TextStyle(color: Colors.black54)),
                  subtitle: TextField(
                    controller: _locationCtrl,
                    decoration: const InputDecoration(
                        border: InputBorder.none, hintText: '例: 東京都新宿区'),
                  ),
                ),
              ],
            ),
          ),
          Card(
            child: Column(
              children: [
                _row('締日', Text(_closingLabel), onTap: _pickClosingDay),
                const Divider(height: 1),
                _row('給料日', Text(_paydayLabel), onTap: _pickPayday),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(8, 12, 8, 4),
            child: Text('給料情報  ※給料に変更があった場合にここから追加することができます。',
                style: TextStyle(fontSize: 12, color: Colors.black54)),
          ),
          Card(
            child: Column(
              children: [
                for (var i = 0; i < _periods.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  ListTile(
                    title: Text(_periodLabel(i), style: const TextStyle(fontSize: 13)),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text('時給 ${_periods[i].hourlyWage}円'),
                      const Icon(Icons.chevron_right, color: Colors.grey),
                    ]),
                    onTap: () => _editPeriod(i),
                  ),
                ],
                const Divider(height: 1),
                TextButton.icon(
                  onPressed: _addPeriod,
                  icon: const Icon(Icons.add, color: Colors.green),
                  label: const Text('給料情報を追加', style: TextStyle(color: Colors.green)),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('※給料計算で算出された金額は実際の給料金額と差が生じます。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ),
          SizedBox(
            height: 52,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green, foregroundColor: Colors.white),
              onPressed: _save,
              child: const Text('保存する', style: TextStyle(fontSize: 16)),
            ),
          ),
          if (!_isNew) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 52,
              child: OutlinedButton(
                onPressed: _delete,
                child: const Text('この勤務先を削除する', style: TextStyle(color: Colors.black54)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
