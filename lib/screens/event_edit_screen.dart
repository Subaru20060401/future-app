import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app_state.dart';
import '../workplace_styles.dart';
import '../widgets/app_sheet.dart';

// 予定の詳細編集（タイトル/色タグ/終日/開始終了/場所/URL/メモ/通知）。
// iOS純正カレンダーの新規画面を参考にしたレイアウト。
class EventEditScreen extends StatefulWidget {
  final DateTime day; // 新規時の基準日
  final EventData? event; // null = 新規
  const EventEditScreen({super.key, required this.day, this.event});

  @override
  State<EventEditScreen> createState() => _EventEditScreenState();
}

class _EventEditScreenState extends State<EventEditScreen> {
  late TextEditingController _titleCtrl;
  late TextEditingController _locationCtrl;
  late TextEditingController _urlCtrl;
  late TextEditingController _memoCtrl;
  late int _colorValue;
  late bool _allDay;
  late DateTime _start;
  late DateTime _end;
  int? _notify;

  bool get _isNew => widget.event == null;

  // 通知の選択肢（開始の何分前）
  static const _notifyOptions = <int?, String>{
    null: 'なし',
    0: '開始時',
    5: '5分前',
    10: '10分前',
    30: '30分前',
    60: '1時間前',
    1440: '1日前',
  };

  @override
  void initState() {
    super.initState();
    final e = widget.event;
    _titleCtrl = TextEditingController(text: e?.title ?? '');
    _locationCtrl = TextEditingController(text: e?.location ?? '');
    _urlCtrl = TextEditingController(text: e?.url ?? '');
    _memoCtrl = TextEditingController(text: e?.memo ?? '');
    _colorValue = e?.colorValue ?? 0xFFFFA726;
    _allDay = e?.allDay ?? false;
    final base = DateTime(widget.day.year, widget.day.month, widget.day.day, 9, 0);
    _start = e?.start ?? base;
    _end = e?.end ?? base.add(const Duration(hours: 1));
    _notify = e?.notifyMinutesBefore;
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _locationCtrl.dispose();
    _urlCtrl.dispose();
    _memoCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDateTime(bool isStart) async {
    final init = isStart ? _start : _end;
    final d = await showDatePicker(
      context: context,
      initialDate: init,
      firstDate: DateTime(2018),
      lastDate: DateTime(2035, 12, 31),
    );
    if (d == null || !mounted) return;
    TimeOfDay t = TimeOfDay.fromDateTime(init);
    if (!_allDay) {
      final picked = await showTimePicker(context: context, initialTime: t);
      if (picked != null) t = picked;
    }
    setState(() {
      final dt = DateTime(d.year, d.month, d.day, _allDay ? 0 : t.hour, _allDay ? 0 : t.minute);
      if (isStart) {
        final dur = _end.difference(_start);
        _start = dt;
        if (_end.isBefore(_start)) _end = _start.add(dur.isNegative ? const Duration(hours: 1) : dur);
      } else {
        _end = dt;
        if (_end.isBefore(_start)) _start = _end.subtract(const Duration(hours: 1));
      }
    });
  }

  Future<void> _pickColor() async {
    final v = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('色タグ'),
        children: workplaceColorOptions
            .map((o) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, o.color.toARGB32()),
                  child: Row(children: [
                    Container(
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(color: o.color, shape: BoxShape.circle)),
                    const SizedBox(width: 12),
                    Text(o.name),
                  ]),
                ))
            .toList(),
      ),
    );
    if (v != null) setState(() => _colorValue = v);
  }

  Future<void> _pickNotify() async {
    final v = await showAppSheet<Object?>(context, (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: _notifyOptions.entries
              .map((e) => ListTile(
                    title: Text(e.value),
                    trailing: _notify == e.key ? const Icon(Icons.check, color: Colors.pink) : null,
                    onTap: () => Navigator.pop(context, e.key ?? 'null'),
                  ))
              .toList(),
        ),
      ),
    );
    if (v != null) setState(() => _notify = v == 'null' ? null : v as int);
  }

  String _fmt(DateTime d) =>
      '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';
  String _fmtTime(DateTime d) =>
      '${d.hour}:${d.minute.toString().padLeft(2, '0')}';

  void _save() {
    if (_titleCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('タイトルを入力してください')));
      return;
    }
    final appState = context.read<AppState>();
    final e = EventData(
      id: widget.event?.id ?? appState.newEventId(),
      title: _titleCtrl.text.trim(),
      location: _locationCtrl.text.trim(),
      url: _urlCtrl.text.trim(),
      memo: _memoCtrl.text.trim(),
      colorValue: _colorValue,
      allDay: _allDay,
      start: _start,
      end: _end,
      notifyMinutesBefore: _notify,
    );
    appState.upsertEvent(e);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final color = Color(_colorValue);
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? '予定を追加' : '予定の編集'),
        actions: [
          IconButton(icon: const Icon(Icons.check), onPressed: _save),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextField(
                    controller: _titleCtrl,
                    decoration: const InputDecoration(hintText: 'タイトル', border: InputBorder.none),
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextField(
                    controller: _locationCtrl,
                    decoration: const InputDecoration(hintText: '場所', border: InputBorder.none),
                  ),
                ),
              ],
            ),
          ),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('終日'),
                  value: _allDay,
                  onChanged: (v) => setState(() => _allDay = v),
                ),
                const Divider(height: 1),
                ListTile(
                  title: const Text('開始'),
                  trailing: Text(_allDay ? _fmt(_start) : '${_fmt(_start)}  ${_fmtTime(_start)}'),
                  onTap: () => _pickDateTime(true),
                ),
                const Divider(height: 1),
                ListTile(
                  title: const Text('終了'),
                  trailing: Text(_allDay ? _fmt(_end) : '${_fmt(_end)}  ${_fmtTime(_end)}'),
                  onTap: () => _pickDateTime(false),
                ),
              ],
            ),
          ),
          Card(
            child: Column(
              children: [
                ListTile(
                  title: const Text('色タグ'),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(
                        width: 16,
                        height: 16,
                        decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                    const SizedBox(width: 8),
                    Text(workplaceColorName(_colorValue)),
                    const Icon(Icons.chevron_right, color: Colors.grey),
                  ]),
                  onTap: _pickColor,
                ),
                const Divider(height: 1),
                ListTile(
                  title: const Text('通知'),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(_notifyOptions[_notify] ?? 'なし'),
                    const Icon(Icons.chevron_right, color: Colors.grey),
                  ]),
                  onTap: _pickNotify,
                ),
              ],
            ),
          ),
          Card(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextField(
                    controller: _urlCtrl,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(hintText: 'URL', border: InputBorder.none),
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: TextField(
                    controller: _memoCtrl,
                    maxLines: 4,
                    decoration: const InputDecoration(hintText: 'メモ', border: InputBorder.none),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 50,
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
