// 💡 メールから見つけた予定の提案を確認する画面（計画書 §4「提案詳細」）。
//   根拠と日時・場所を見て、足りないところを補い、本人が決める。
//   ・「予定として登録」「シフトとして登録」「保留」「今回は登録しない」
//   ・変更・取消は、登録済みの予定に当てる（承認前は何も変えない）
// ⚠️ 計算・登録の判断はしない。AppState.approveScheduleSuggestion などに渡すだけ。
//   AIの正確さを数値で出さない。足りない理由（終了時刻が未記載など）を出す。
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import 'app_sheet.dart';

Future<void> showSuggestionReviewSheet(
    BuildContext hostContext, AppState appState, ScheduleSuggestion sg) {
  return showAppSheet<void>(
    hostContext,
    (ctx) => _ReviewBody(appState: appState, sg: sg, hostContext: hostContext),
  );
}

class _ReviewBody extends StatefulWidget {
  const _ReviewBody({required this.appState, required this.sg, required this.hostContext});
  final AppState appState;
  final ScheduleSuggestion sg;
  final BuildContext hostContext;

  @override
  State<_ReviewBody> createState() => _ReviewBodyState();
}

class _ReviewBodyState extends State<_ReviewBody> {
  late final TextEditingController _title;
  late final TextEditingController _location;
  final _break = TextEditingController(); // ⚠️ 空から始める（休憩不明を勝手に0分にしない）
  late DateTime? _start;
  late DateTime? _end;
  late bool _allDay;
  late SuggestionKind _as;
  String? _workplaceId;
  String? _error;

  ScheduleSuggestion get sg => widget.sg;
  AppState get app => widget.appState;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: sg.title);
    _location = TextEditingController(text: sg.location);
    _start = sg.start;
    _end = sg.end;
    _allDay = sg.allDay;
    _as = sg.kind;
    if (app.workplaces.isNotEmpty) _workplaceId = app.workplaces.first.id;
  }

  @override
  void dispose() {
    _title.dispose();
    _location.dispose();
    _break.dispose();
    super.dispose();
  }

  bool get _isAdd => sg.action == SuggestionAction.add;

  // 💡 http/https 以外のURLは出さない（AIが返した値をそのまま信じない）
  String? get _safeUrl {
    final u = Uri.tryParse(sg.url.trim());
    if (u == null || !(u.scheme == 'https' || u.scheme == 'http') || u.host.isEmpty) return null;
    return u.toString();
  }

  Future<void> _pickDate() async {
    final base = _start ?? DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: base,
      firstDate: DateTime(base.year - 1),
      lastDate: DateTime(base.year + 2),
    );
    if (d == null) return;
    setState(() {
      DateTime move(DateTime t) => DateTime(d.year, d.month, d.day, t.hour, t.minute);
      final oldStart = _start;
      _start = oldStart == null ? DateTime(d.year, d.month, d.day, 9) : move(oldStart);
      if (_end != null && oldStart != null) {
        // 長さを保ったまま動かす（日をまたぐ勤務も崩さない）
        _end = _start!.add(_end!.difference(oldStart));
      }
    });
  }

  Future<void> _pickTime({required bool start}) async {
    final cur = start ? _start : (_end ?? _start);
    final t = await showTimePicker(
      context: context,
      initialTime: cur != null ? TimeOfDay.fromDateTime(cur) : const TimeOfDay(hour: 9, minute: 0),
    );
    if (t == null) return;
    setState(() {
      final day = _start ?? DateTime.now();
      final v = DateTime(day.year, day.month, day.day, t.hour, t.minute);
      if (start) {
        final len = (_start != null && _end != null) ? _end!.difference(_start!) : null;
        _start = v;
        if (len != null) _end = v.add(len);
      } else {
        // 終わりが始まり以前なら翌日（夜勤など）
        _end = v.isAfter(_start ?? v) ? v : v.add(const Duration(days: 1));
      }
    });
  }

  void _saveEdits() {
    app.editScheduleSuggestion(
      sg.id,
      title: _title.text,
      start: _start,
      end: _end,
      allDay: _allDay,
      location: _location.text,
    );
  }

  void _approve() {
    _saveEdits();
    final err = app.approveScheduleSuggestion(
      sg.id,
      as: _as,
      workplaceId: _workplaceId,
      breakMinutes: int.tryParse(_break.text.trim()),
    );
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    final messenger = ScaffoldMessenger.of(widget.hostContext);
    Navigator.pop(context);
    messenger.showSnackBar(SnackBar(
      content: Text(switch (sg.action) {
        SuggestionAction.add => _as == SuggestionKind.shift ? 'シフトに登録しました' : '予定に登録しました',
        SuggestionAction.change => '予定を変更しました',
        SuggestionAction.cancel => '予定を取り消しました',
      }),
    ));
  }

  void _close(void Function(String id) action, String message) {
    _saveEdits();
    action(sg.id);
    final messenger = ScaffoldMessenger.of(widget.hostContext);
    Navigator.pop(context);
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final fmtDay = DateFormat('M月d日(E)', 'ja_JP');
    final fmtTime = DateFormat('H:mm');
    final url = _safeUrl;
    final headline = switch (sg.action) {
      SuggestionAction.add => sg.kind == SuggestionKind.shift ? '勤務の確定が見つかりました' : '予定が見つかりました',
      SuggestionAction.change => '予定の変更が届きました',
      SuggestionAction.cancel => '予定の取消が届きました',
    };
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Expanded(
              child: Text(headline,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            ),
            if (sg.sample)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text('見本', style: TextStyle(fontSize: 11)),
              ),
          ]),
          const SizedBox(height: 6),
          // 根拠（どのメールの、どの一文から見つけたか）
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.blueGrey[50],
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (sg.evidence.isNotEmpty)
                  Text('根拠：${sg.evidence}', style: const TextStyle(fontSize: 13)),
                Text(
                  '${sg.sender.isEmpty ? '送信元不明' : sg.sender}・'
                  '${DateFormat('M/d HH:mm').format(sg.receivedAt)} 受信',
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ],
            ),
          ),
          if (sg.missing.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final m in sg.missing)
              Text('・確認：$m', style: TextStyle(fontSize: 12, color: Colors.orange[900])),
          ],
          if (sg.action == SuggestionAction.cancel) ...[
            const SizedBox(height: 12),
            Text('「${sg.title}」を予定から取り消します。登録済みの予定（またはシフト）が消えます。',
                style: const TextStyle(fontSize: 13)),
          ] else ...[
            const SizedBox(height: 12),
            if (_isAdd)
              SegmentedButton<SuggestionKind>(
                segments: const [
                  ButtonSegment(value: SuggestionKind.event, label: Text('予定'), icon: Icon(Icons.event)),
                  ButtonSegment(value: SuggestionKind.shift, label: Text('シフト'), icon: Icon(Icons.work)),
                ],
                selected: {_as},
                onSelectionChanged: (v) => setState(() {
                  _as = v.first;
                  if (_as == SuggestionKind.shift) _allDay = false; // 勤務は時刻が必要
                }),
              ),
            const SizedBox(height: 8),
            TextField(
              controller: _title,
              decoration: const InputDecoration(labelText: 'タイトル', isDense: true),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('日付'),
              trailing: Text(_start == null ? '未定（選ぶ）' : fmtDay.format(_start!)),
              onTap: _pickDate,
            ),
            if (_as == SuggestionKind.event)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('終日'),
                value: _allDay,
                onChanged: (v) => setState(() => _allDay = v),
              ),
            if (!_allDay || _as == SuggestionKind.shift)
              Row(children: [
                Expanded(
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('開始'),
                    trailing: Text(_start == null ? '—' : fmtTime.format(_start!)),
                    onTap: () => _pickTime(start: true),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('終了'),
                    trailing: Text(
                      _end == null
                          ? '未定（入れる）'
                          : '${_start != null && _end!.day != _start!.day ? '翌' : ''}${fmtTime.format(_end!)}',
                      style: TextStyle(color: _end == null ? Colors.red : null),
                    ),
                    onTap: () => _pickTime(start: false),
                  ),
                ),
              ]),
            TextField(
              controller: _location,
              decoration: const InputDecoration(labelText: '場所', isDense: true),
            ),
            if (url != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: SelectableText('参加URL：$url', style: const TextStyle(fontSize: 12)),
              ),
            if (_isAdd && _as == SuggestionKind.shift) ...[
              const SizedBox(height: 8),
              if (app.workplaces.isEmpty)
                const Text('シフトにするには、先に 設定→勤務先の管理 で勤務先を登録してください',
                    style: TextStyle(fontSize: 12, color: Colors.red))
              else
                DropdownButtonFormField<String>(
                  initialValue: _workplaceId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '勤務先（給与はこの設定で計算）', isDense: true),
                  items: [
                    for (final w in app.workplaces) DropdownMenuItem(value: w.id, child: Text(w.name)),
                  ],
                  onChanged: (v) => setState(() => _workplaceId = v),
                ),
              TextField(
                controller: _break,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '休憩（分）',
                  helperText: 'メールに書かれていなければ、自分で入れてください',
                  isDense: true,
                ),
              ),
            ],
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
          ],
          const SizedBox(height: 14),
          if (sg.isOpen) ...[
            FilledButton(
              onPressed: _approve,
              child: Text(switch (sg.action) {
                SuggestionAction.add => _as == SuggestionKind.shift ? 'シフトとして登録' : '予定として登録',
                SuggestionAction.change => '変更を反映',
                SuggestionAction.cancel => '予定を取り消す',
              }),
            ),
            Row(children: [
              if (sg.status == SuggestionStatus.pending)
                Expanded(
                  child: TextButton(
                    onPressed: () => _close(app.holdScheduleSuggestion, '保留にしました'),
                    child: const Text('保留'),
                  ),
                ),
              Expanded(
                child: TextButton(
                  onPressed: () => _close(app.rejectScheduleSuggestion, '登録しませんでした'),
                  child: const Text('今回は登録しない'),
                ),
              ),
            ]),
          ] else
            Text('この提案は処理済みです（${_statusLabel(sg.status)}）',
                style: const TextStyle(color: Colors.black54)),
        ],
      ),
    );
  }
}

String _statusLabel(SuggestionStatus s) => switch (s) {
      SuggestionStatus.pending => '確認待ち',
      SuggestionStatus.held => '保留',
      SuggestionStatus.approved => '登録済み',
      SuggestionStatus.rejected => '登録しない',
      SuggestionStatus.expired => '期限切れ',
      SuggestionStatus.superseded => '新しい提案に置き換え',
    };

String suggestionStatusLabel(SuggestionStatus s) => _statusLabel(s);
