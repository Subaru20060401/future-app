import 'package:flutter/material.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart'; // 💡 追加
import '../app_state.dart';
import '../widgets/swipe_to_delete.dart';
import 'event_edit_screen.dart';
import '../widgets/app_sheet.dart';

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  final CalendarFormat _calendarFormat = CalendarFormat.month;
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay = DateTime.now();

  void _showPaydayDetail(BuildContext context, ({DateTime date, Workplace workplace, int amount}) e, AppState appState) {
    showAppSheet(context, (_) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('💰 給料日 詳細', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Container(width: 14, height: 14, decoration: BoxDecoration(color: Color(e.workplace.colorValue), shape: BoxShape.circle)),
              title: Text(e.workplace.name, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text('締日: ${e.workplace.isEndOfMonthClosing ? '月末' : '${e.workplace.closingDay}日'} / 給料日: ${e.workplace.paydayDay}日'),
            ),
            const Divider(),
            _detailRow('入金予定額', '¥${e.amount}', Colors.green),
            _detailRow('給料日', '${e.date.year}年${e.date.month}月${e.date.day}日', Colors.black87),
          ],
        ),
      ),
    );
  }

  void _showCardPaymentDetail(
    BuildContext context,
    ({String cardName, int amount, bool isConfirmed}) summary,
    DateTime date,
    AppState appState,
  ) {
    // この月の明細一覧（bank確定 or 前月billing）
    final List<Payment> details;
    if (summary.isConfirmed) {
      details = appState.payments.where((p) =>
        p.cardName == summary.cardName &&
        p.source == PaymentSource.bank &&
        p.paymentDate.year == date.year &&
        p.paymentDate.month == date.month &&
        p.paymentDate.day == date.day
      ).toList();
    } else {
      final prevMonth = DateTime(date.year, date.month - 1);
      details = appState.payments.where((p) =>
        p.cardName == summary.cardName &&
        p.source == PaymentSource.billing &&
        p.paymentDate.year == prevMonth.year &&
        p.paymentDate.month == prevMonth.month
      ).toList()..sort((a, b) => a.paymentDate.compareTo(b.paymentDate));
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
        maxChildSize: 0.85,
        builder: (_, scrollCtrl) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text('💳 ${summary.cardName}',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                  Text('-¥${summary.amount}',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.red)),
                ],
              ),
              Text(summary.isConfirmed ? '銀行確定  ${date.month}/${date.day}' : '請求予定  ${date.month}/${date.day}引き落とし',
                  style: const TextStyle(color: Colors.black54, fontSize: 13)),
              const Divider(height: 16),
              Expanded(
                child: ListView.builder(
                  controller: scrollCtrl,
                  itemCount: details.length,
                  itemBuilder: (_, i) {
                    final p = details[i];
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(p.note.isNotEmpty ? p.note : p.cardName,
                          style: const TextStyle(fontSize: 13)),
                      subtitle: Text('${p.paymentDate.month}/${p.paymentDate.day}',
                          style: const TextStyle(fontSize: 11, color: Colors.black45)),
                      trailing: Text('-¥${p.amount}',
                          style: const TextStyle(color: Colors.red, fontSize: 13, fontWeight: FontWeight.bold)),
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _detailRow(String label, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(color: Colors.black54))),
          Text(value, style: TextStyle(fontWeight: FontWeight.bold, color: color)),
        ],
      ),
    );
  }

  void _showAddDialog(DateTime selectedDay, AppState appState) {
    showAppSheet(context, (context) {
        return Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('追加する項目', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 20),
              ListTile(
                leading: const Icon(Icons.work, color: Colors.blue),
                title: const Text('シフトを追加'),
                onTap: () {
                  Navigator.pop(context);
                  _addShiftWithHistory(selectedDay, appState);
                },
              ),
              ListTile(
                leading: const Icon(Icons.repeat, color: Colors.teal),
                title: const Text('繰り返しシフトを追加'),
                subtitle: const Text('毎週○曜などをまとめて登録'),
                onTap: () {
                  Navigator.pop(context);
                  _addRecurringShift(selectedDay, appState);
                },
              ),
              ListTile(
                leading: const Icon(Icons.event, color: Colors.orange),
                title: const Text('予定を追加'),
                onTap: () {
                  Navigator.pop(context);
                  _addEvent(selectedDay, appState);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  // シフト追加：まず「履歴から追加」を出し、なければ/新規は入力ダイアログへ（シフトボード風）
  void _addShiftWithHistory(DateTime selectedDay, AppState appState) {
    final templates = appState.recentShiftTemplates();
    String hm(int h, int m) => '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
    showAppSheet(context, (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${selectedDay.month}月${selectedDay.day}日 にシフト追加',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              if (templates.isNotEmpty) ...[
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('履歴から追加', style: TextStyle(fontSize: 12, color: Colors.grey)),
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 260),
                  child: ListView(
                    shrinkWrap: true,
                    children: templates.map((t) {
                      return Card(
                        child: ListTile(
                          dense: true,
                          leading: Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              color: Color(appState.workplaceById(t.workplaceId)?.colorValue ??
                                  0xFF42A5F5),
                              shape: BoxShape.circle,
                            ),
                          ),
                          title: Text('${hm(t.startHour, t.startMinute)} - ${hm(t.endHour, t.endMinute)}  ${t.workplace}'),
                          subtitle: Text('時給¥${t.hourlyWage} / 休憩${t.breakMinutes}分'),
                          trailing: const Icon(Icons.add_circle_outline, color: Colors.green),
                          onTap: () {
                            Navigator.pop(context);
                            final start = DateTime(selectedDay.year, selectedDay.month,
                                selectedDay.day, t.startHour, t.startMinute);
                            var end = DateTime(selectedDay.year, selectedDay.month,
                                selectedDay.day, t.endHour, t.endMinute);
                            if (end.isBefore(start)) end = end.add(const Duration(days: 1));
                            final w = appState.workplaceById(t.workplaceId);
                            final shift = w != null
                                ? appState.buildShiftFromWorkplace(w, selectedDay, start, end,
                                    breakMinutes: t.breakMinutes, overrideWage: t.hourlyWage)
                                : ShiftData(
                                    workplace: t.workplace,
                                    hourlyWage: t.hourlyWage,
                                    start: start,
                                    end: end,
                                    breakMinutes: t.breakMinutes,
                                  );
                            appState.addShift(selectedDay, shift);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('シフトを追加しました')),
                            );
                          },
                        ),
                      );
                    }).toList(),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green, foregroundColor: Colors.white),
                  onPressed: () {
                    Navigator.pop(context);
                    _addShift(selectedDay, appState);
                  },
                  child: const Text('新規にシフトを入力する', style: TextStyle(fontSize: 16)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _addShift(DateTime selectedDay, AppState appState) {
    final workplaces = appState.workplaces;
    // 勤務先が登録されていれば先頭を初期選択、無ければ手動入力。
    String? selectedWpId = workplaces.isNotEmpty ? workplaces.first.id : null;
    final titleCtrl = TextEditingController(text: 'バイト');
    final wageCtrl = TextEditingController(text: '1000');
    final breakCtrl = TextEditingController(text: '60');
    TimeOfDay startTime = const TimeOfDay(hour: 9, minute: 0);
    TimeOfDay endTime = const TimeOfDay(hour: 17, minute: 0);

    // 選択中の勤務先・勤務日に応じて時給欄を自動入力する。
    void applyWorkplaceWage() {
      final w = appState.workplaceById(selectedWpId);
      if (w != null) {
        final p = appState.wagePeriodFor(w, selectedDay);
        if (p != null) wageCtrl.text = p.hourlyWage.toString();
      }
    }

    applyWorkplaceWage();

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('シフト入力'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 勤務先：登録済みから選択。未登録なら手動入力欄を表示。
                if (workplaces.isNotEmpty)
                  DropdownButtonFormField<String?>(
                    initialValue: selectedWpId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '勤務先'),
                    items: [
                      ...workplaces.map((w) => DropdownMenuItem<String?>(
                            value: w.id,
                            child: Row(children: [
                              Container(
                                  width: 12,
                                  height: 12,
                                  decoration: BoxDecoration(
                                      color: Color(w.colorValue), shape: BoxShape.circle)),
                              const SizedBox(width: 8),
                              Text(w.name),
                            ]),
                          )),
                      const DropdownMenuItem<String?>(
                          value: null, child: Text('その他（手動入力）')),
                    ],
                    onChanged: (v) => setLocal(() {
                      selectedWpId = v;
                      applyWorkplaceWage();
                    }),
                  ),
                if (selectedWpId == null)
                  TextField(controller: titleCtrl, decoration: const InputDecoration(labelText: '勤務先（手動）')),
                TextField(controller: wageCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: '時給')),
                TextField(controller: breakCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: '休憩(分)')),
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('開始'),
                  trailing: Text(startTime.format(context)),
                  onTap: () async {
                    final t = await showTimePicker(context: context, initialTime: startTime);
                    if (t != null) setLocal(() => startTime = t);
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('終了'),
                  trailing: Text(endTime.format(context)),
                  onTap: () async {
                    final t = await showTimePicker(context: context, initialTime: endTime);
                    if (t != null) setLocal(() => endTime = t);
                  },
                ),
                if (selectedWpId != null)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('※交通費・休日/深夜/残業手当は勤務先の給料情報から自動で計算されます。',
                        style: TextStyle(fontSize: 11, color: Colors.grey)),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
            ElevatedButton(
              onPressed: () {
                final start = DateTime(selectedDay.year, selectedDay.month, selectedDay.day, startTime.hour, startTime.minute);
                var end = DateTime(selectedDay.year, selectedDay.month, selectedDay.day, endTime.hour, endTime.minute);
                if (end.isBefore(start)) end = end.add(const Duration(days: 1)); // 翌日跨ぎ
                final breakMin = int.tryParse(breakCtrl.text) ?? 0;
                final wage = int.tryParse(wageCtrl.text) ?? 0;
                final w = appState.workplaceById(selectedWpId);
                final shift = w != null
                    // 勤務先選択時：給料情報をスナップショット（時給は手入力を優先）
                    ? appState.buildShiftFromWorkplace(w, selectedDay, start, end,
                        breakMinutes: breakMin, overrideWage: wage)
                    : ShiftData(
                        workplace: titleCtrl.text,
                        hourlyWage: wage,
                        start: start,
                        end: end,
                        breakMinutes: breakMin,
                      );
                appState.addShift(selectedDay, shift);
                Navigator.pop(context);
              },
              child: const Text('保存'),
            )
          ],
        ),
      ),
    );
  }

  // 繰り返しシフト入力（曜日＋期間でまとめて登録）
  void _addRecurringShift(DateTime selectedDay, AppState appState) {
    final workplaces = appState.workplaces;
    String? selectedWpId = workplaces.isNotEmpty ? workplaces.first.id : null;
    final titleCtrl = TextEditingController(text: 'バイト');
    final wageCtrl = TextEditingController(text: '1000');
    final breakCtrl = TextEditingController(text: '60');
    TimeOfDay startTime = const TimeOfDay(hour: 9, minute: 0);
    TimeOfDay endTime = const TimeOfDay(hour: 17, minute: 0);
    DateTime rangeStart = selectedDay;
    DateTime rangeEnd = DateTime(selectedDay.year, selectedDay.month + 1, selectedDay.day);
    final selectedWeekdays = <int>{selectedDay.weekday}; // DateTime.weekday (月=1..日=7)

    void applyWage() {
      final w = appState.workplaceById(selectedWpId);
      if (w != null) {
        final p = appState.wagePeriodFor(w, rangeStart);
        if (p != null) wageCtrl.text = p.hourlyWage.toString();
      }
    }

    applyWage();
    const weekdayLabels = {7: '日', 1: '月', 2: '火', 3: '水', 4: '木', 5: '金', 6: '土'};
    String fmtDate(DateTime d) => '${d.year}/${d.month}/${d.day}';

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('繰り返しシフト'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (workplaces.isNotEmpty)
                  DropdownButtonFormField<String?>(
                    initialValue: selectedWpId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '勤務先'),
                    items: [
                      ...workplaces.map((w) => DropdownMenuItem<String?>(
                            value: w.id,
                            child: Text(w.name),
                          )),
                      const DropdownMenuItem<String?>(value: null, child: Text('その他（手動入力）')),
                    ],
                    onChanged: (v) => setLocal(() {
                      selectedWpId = v;
                      applyWage();
                    }),
                  ),
                if (selectedWpId == null)
                  TextField(controller: titleCtrl, decoration: const InputDecoration(labelText: '勤務先（手動）')),
                TextField(controller: wageCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: '時給')),
                TextField(controller: breakCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: '休憩(分)')),
                const SizedBox(height: 12),
                const Text('曜日', style: TextStyle(fontSize: 12, color: Colors.grey)),
                Wrap(
                  spacing: 4,
                  children: [7, 1, 2, 3, 4, 5, 6].map((wd) {
                    final on = selectedWeekdays.contains(wd);
                    return FilterChip(
                      label: Text(weekdayLabels[wd]!),
                      selected: on,
                      onSelected: (_) => setLocal(() {
                        on ? selectedWeekdays.remove(wd) : selectedWeekdays.add(wd);
                      }),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Text('開始'),
                    const Spacer(),
                    Text(startTime.format(context)),
                    IconButton(
                      icon: const Icon(Icons.schedule, size: 18),
                      onPressed: () async {
                        final t = await showTimePicker(context: context, initialTime: startTime);
                        if (t != null) setLocal(() => startTime = t);
                      },
                    ),
                    const Text('終了'),
                    const Spacer(),
                    Text(endTime.format(context)),
                    IconButton(
                      icon: const Icon(Icons.schedule, size: 18),
                      onPressed: () async {
                        final t = await showTimePicker(context: context, initialTime: endTime);
                        if (t != null) setLocal(() => endTime = t);
                      },
                    ),
                  ],
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('期間'),
                  subtitle: Text('${fmtDate(rangeStart)} 〜 ${fmtDate(rangeEnd)}'),
                  onTap: () async {
                    final picked = await showDateRangePicker(
                      context: context,
                      firstDate: DateTime(2020, 1, 1),
                      lastDate: DateTime(2032, 12, 31),
                      initialDateRange: DateTimeRange(start: rangeStart, end: rangeEnd),
                    );
                    if (picked != null) {
                      setLocal(() {
                        rangeStart = picked.start;
                        rangeEnd = picked.end;
                        applyWage();
                      });
                    }
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
            ElevatedButton(
              onPressed: () {
                if (selectedWeekdays.isEmpty) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(const SnackBar(content: Text('曜日を選んでください')));
                  return;
                }
                final breakMin = int.tryParse(breakCtrl.text) ?? 0;
                final wage = int.tryParse(wageCtrl.text) ?? 0;
                final w = appState.workplaceById(selectedWpId);
                final entries = <({DateTime date, ShiftData shift})>[];
                for (var d = DateTime(rangeStart.year, rangeStart.month, rangeStart.day);
                    !d.isAfter(rangeEnd);
                    d = d.add(const Duration(days: 1))) {
                  if (!selectedWeekdays.contains(d.weekday)) continue;
                  final start = DateTime(d.year, d.month, d.day, startTime.hour, startTime.minute);
                  var end = DateTime(d.year, d.month, d.day, endTime.hour, endTime.minute);
                  if (end.isBefore(start)) end = end.add(const Duration(days: 1));
                  final shift = w != null
                      ? appState.buildShiftFromWorkplace(w, d, start, end,
                          breakMinutes: breakMin, overrideWage: wage)
                      : ShiftData(
                          workplace: titleCtrl.text,
                          hourlyWage: wage,
                          start: start,
                          end: end,
                          breakMinutes: breakMin,
                        );
                  entries.add((date: d, shift: shift));
                }
                appState.addShiftsBulk(entries);
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('${entries.length}件のシフトを追加しました')),
                );
              },
              child: const Text('まとめて追加'),
            ),
          ],
        ),
      ),
    );
  }

  void _addEvent(DateTime selectedDay, AppState appState) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => EventEditScreen(day: selectedDay)),
    );
  }

  void _editEvent(EventData e) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => EventEditScreen(day: e.start ?? _selectedDay ?? DateTime.now(), event: e)),
    );
  }

  // シフト編集ダイアログ
  void _editShift(String dateKey, int idx, ShiftData s, AppState appState) {
    final selectedDay = DateTime.tryParse(dateKey) ?? DateTime.now();
    final workplaces = appState.workplaces;
    String? selectedWpId = s.workplaceId ?? (workplaces.isNotEmpty ? workplaces.first.id : null);
    final titleCtrl = TextEditingController(text: s.workplace);
    final wageCtrl = TextEditingController(text: s.hourlyWage.toString());
    final breakCtrl = TextEditingController(text: s.breakMinutes.toString());
    TimeOfDay startTime = TimeOfDay.fromDateTime(s.start);
    TimeOfDay endTime = TimeOfDay.fromDateTime(s.end);

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('シフトを編集'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (workplaces.isNotEmpty)
                  DropdownButtonFormField<String?>(
                    initialValue: selectedWpId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '勤務先'),
                    items: [
                      ...workplaces.map((w) => DropdownMenuItem<String?>(
                            value: w.id,
                            child: Row(children: [
                              Container(
                                  width: 12, height: 12,
                                  decoration: BoxDecoration(color: Color(w.colorValue), shape: BoxShape.circle)),
                              const SizedBox(width: 8),
                              Text(w.name),
                            ]),
                          )),
                      const DropdownMenuItem<String?>(value: null, child: Text('その他（手動入力）')),
                    ],
                    onChanged: (v) => setLocal(() => selectedWpId = v),
                  ),
                if (selectedWpId == null)
                  TextField(controller: titleCtrl, decoration: const InputDecoration(labelText: '勤務先（手動）')),
                TextField(controller: wageCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: '時給')),
                TextField(controller: breakCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: '休憩(分)')),
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('開始'),
                  trailing: Text(startTime.format(context)),
                  onTap: () async {
                    final t = await showTimePicker(context: context, initialTime: startTime);
                    if (t != null) setLocal(() => startTime = t);
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('終了'),
                  trailing: Text(endTime.format(context)),
                  onTap: () async {
                    final t = await showTimePicker(context: context, initialTime: endTime);
                    if (t != null) setLocal(() => endTime = t);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
            ElevatedButton(
              onPressed: () {
                final start = DateTime(selectedDay.year, selectedDay.month, selectedDay.day, startTime.hour, startTime.minute);
                var end = DateTime(selectedDay.year, selectedDay.month, selectedDay.day, endTime.hour, endTime.minute);
                if (end.isBefore(start)) end = end.add(const Duration(days: 1));
                final breakMin = int.tryParse(breakCtrl.text) ?? 0;
                final wage = int.tryParse(wageCtrl.text) ?? 0;
                final w = appState.workplaceById(selectedWpId);
                final newShift = w != null
                    ? appState.buildShiftFromWorkplace(w, selectedDay, start, end,
                        breakMinutes: breakMin, overrideWage: wage)
                    : ShiftData(
                        workplace: titleCtrl.text,
                        hourlyWage: wage,
                        start: start,
                        end: end,
                        breakMinutes: breakMin,
                      );
                appState.updateShift(dateKey, idx, newShift);
                Navigator.pop(context);
              },
              child: const Text('保存'),
            )
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    
    // 💡 選択された日付を "yyyy-MM-dd" の文字列にして金庫から引き出す
    final selectedKey = _selectedDay != null ? DateFormat('yyyy-MM-dd').format(_selectedDay!) : '';
    final dayShifts = appState.shifts[selectedKey] ?? [];
    final dayEvents = appState.events[selectedKey] ?? [];

    return Scaffold(
      appBar: AppBar(title: const Text('カレンダー')),
      body: Column(
        children: [
          TableCalendar(
            locale: 'ja_JP',
            firstDay: DateTime.utc(2020, 1, 1),
            lastDay: DateTime.utc(2030, 12, 31),
            focusedDay: _focusedDay,
            calendarFormat: _calendarFormat,
            selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
            onDaySelected: (selectedDay, focusedDay) {
              setState(() {
                _selectedDay = selectedDay;
                _focusedDay = focusedDay;
              });
            },
            // 💡 種類ごとに色を変えたポチ（ドット）を表示するため eventLoader は件数だけ返す
            eventLoader: (day) {
              final key = DateFormat('yyyy-MM-dd').format(day);
              final hasShift = appState.shifts.containsKey(key) && appState.shifts[key]!.isNotEmpty;
              final hasEvent = appState.events.containsKey(key) && appState.events[key]!.isNotEmpty;
              final hasPayday = appState.paydaysOnDay(day).isNotEmpty;
              final hasPayment = appState.cardPaymentSummaryOnDay(day).isNotEmpty;
              return (hasShift || hasEvent || hasPayday || hasPayment) ? [true] : [];
            },
            calendarBuilders: CalendarBuilders(
              markerBuilder: (context, day, events) {
                final key = DateFormat('yyyy-MM-dd').format(day);
                final hasShift = appState.shifts.containsKey(key) && appState.shifts[key]!.isNotEmpty;
                final hasEvent = appState.events.containsKey(key) && appState.events[key]!.isNotEmpty;
                final hasPayday = appState.paydaysOnDay(day).isNotEmpty;
                final hasPayment = appState.cardPaymentSummaryOnDay(day).isNotEmpty;
                final hasPlanned = appState.plannedIncomesOnDay(day).isNotEmpty;
                final dots = <Color>[
                  if (hasShift) Colors.blueAccent,      // シフト＝青
                  if (hasPayday || hasPlanned) const Color(0xFF2E9E5B), // 給料日・予定入金＝緑
                  if (hasPayment) Colors.redAccent,     // 引き落とし＝赤
                  if (hasEvent) Colors.orange,          // 予定＝オレンジ
                ];
                if (dots.isEmpty) return null;
                return Positioned(
                  bottom: 1,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: dots
                        .map((c) => Container(
                              width: 6,
                              height: 6,
                              margin: const EdgeInsets.symmetric(horizontal: 0.8),
                              decoration: BoxDecoration(color: c, shape: BoxShape.circle),
                            ))
                        .toList(),
                  ),
                );
              },
            ),
            calendarStyle: const CalendarStyle(
              selectedDecoration: BoxDecoration(color: Colors.pink, shape: BoxShape.circle),
              todayDecoration: BoxDecoration(color: Colors.pinkAccent, shape: BoxShape.circle),
            ),
          ),
          // ドットの凡例
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Wrap(
              spacing: 12,
              runSpacing: 2,
              alignment: WrapAlignment.center,
              children: const [
                _LegendDot(color: Colors.blueAccent, label: 'シフト'),
                _LegendDot(color: Color(0xFF2E9E5B), label: '給料日'),
                _LegendDot(color: Colors.redAccent, label: '引き落とし'),
                _LegendDot(color: Colors.orange, label: '予定'),
              ],
            ),
          ),
          const Divider(),
          // カレンダー画面の Expanded の中身を以下のように差し替え

Expanded(
  child: () {
    final dayPaydays = _selectedDay != null ? appState.paydaysOnDay(_selectedDay!) : <({DateTime date, Workplace workplace, int amount})>[];
    final dayPayments = _selectedDay != null ? appState.cardPaymentSummaryOnDay(_selectedDay!) : <({String cardName, int amount, bool isConfirmed})>[];
    final dayPlanned = _selectedDay != null ? appState.plannedIncomesOnDay(_selectedDay!) : <PlannedIncome>[];
    final hasAny = dayShifts.isNotEmpty || dayEvents.isNotEmpty || dayPaydays.isNotEmpty ||
        dayPayments.isNotEmpty || dayPlanned.isNotEmpty;
    return hasAny
      ? ListView(
          padding: const EdgeInsets.all(10),
          children: [
            // ── 給料日 ──
            if (dayPaydays.isNotEmpty) ...[
              const Text('💰 給料日', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.green)),
              ...dayPaydays.map((e) => Card(
                color: Colors.green[50],
                child: ListTile(
                  leading: Container(
                    width: 12, height: 12,
                    decoration: BoxDecoration(color: Color(e.workplace.colorValue), shape: BoxShape.circle),
                  ),
                  title: Text(e.workplace.name),
                  subtitle: const Text('給料日'),
                  trailing: Text('¥${e.amount}',
                      style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
                  onTap: () => _showPaydayDetail(context, e, appState),
                ),
              )),
              const SizedBox(height: 6),
            ],
            // ── 予定入金 ──
            if (dayPlanned.isNotEmpty) ...[
              const Text('📥 予定入金',
                  style: TextStyle(fontWeight: FontWeight.bold, color: Colors.green)),
              ...dayPlanned.map((p) => Card(
                    color: Colors.green[50],
                    child: ListTile(
                      leading: const Icon(Icons.event_available,
                          color: Colors.green, size: 18),
                      title: Text(p.title),
                      subtitle: Text(p.monthly ? '毎月${p.date.day}日' : '入金予定'),
                      trailing: Text('+¥${p.amount}',
                          style: const TextStyle(
                              color: Colors.green, fontWeight: FontWeight.bold)),
                    ),
                  )),
              const SizedBox(height: 6),
            ],
            // ── 引き落とし日（カード別集約） ──
            if (dayPayments.isNotEmpty) ...[
              const Text('💳 引き落とし', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red)),
              ...dayPayments.map((p) => Card(
                color: Colors.red[50],
                child: ListTile(
                  leading: const Icon(Icons.credit_card, color: Colors.red, size: 18),
                  title: Text(p.cardName),
                  subtitle: Text(p.isConfirmed
                      ? '銀行確定'
                      : p.amount > 0
                          ? '請求予定'
                          : '引き落とし日（金額はまだ未確定）'),
                  trailing: p.amount > 0
                      ? Text('-¥${p.amount}',
                          style: const TextStyle(
                              color: Colors.red, fontWeight: FontWeight.bold))
                      : const Text('—',
                          style: TextStyle(color: Colors.black38)),
                  onTap: () => _showCardPaymentDetail(context, p, _selectedDay!, appState),
                ),
              )),
              const SizedBox(height: 6),
            ],
            if (dayShifts.isNotEmpty) const Text('💼 シフト', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue)),
            ...dayShifts.asMap().entries.map((entry) {
              int idx = entry.key;
              ShiftData s = entry.value;
              return SwipeToDelete(
                itemKey: Key('shift_${selectedKey}_$idx'),
                onDelete: () => appState.removeShift(selectedKey, idx),
                child: Card(
                  child: ListTile(
                    leading: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: Color(appState.workplaceById(s.workplaceId)?.colorValue ??
                            0xFF42A5F5),
                        shape: BoxShape.circle,
                      ),
                    ),
                    title: Text(s.workplace),
                    subtitle: Text(
                        '${TimeOfDay.fromDateTime(s.start).format(context)}〜${TimeOfDay.fromDateTime(s.end).format(context)}  (${s.workHours.toStringAsFixed(1)}h / 休憩${s.breakMinutes}分)'),
                    trailing: Text('¥${s.earnings}'),
                    onTap: () => _editShift(selectedKey, idx, s, appState),
                  ),
                ),
              );
            }),
            const SizedBox(height: 10),
            if (dayEvents.isNotEmpty) const Text('📅 予定', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.orange)),
            ...dayEvents.asMap().entries.map((entry) {
              int idx = entry.key;
              EventData e = entry.value;
              final timeText = e.allDay
                  ? '終日'
                  : (e.start != null
                      ? '${TimeOfDay.fromDateTime(e.start!).format(context)}'
                          '〜${e.end != null ? TimeOfDay.fromDateTime(e.end!).format(context) : ''}'
                      : '');
              final sub = [
                if (timeText.isNotEmpty) timeText,
                if (e.location.isNotEmpty) e.location,
              ].join('  ');
              return SwipeToDelete(
                itemKey: Key('event_${selectedKey}_$idx'),
                onDelete: () => appState.removeEvent(selectedKey, idx),
                child: Card(
                  child: ListTile(
                    leading: Container(
                      width: 12,
                      height: 12,
                      decoration:
                          BoxDecoration(color: Color(e.colorValue), shape: BoxShape.circle),
                    ),
                    title: Text(e.title),
                    subtitle: sub.isNotEmpty ? Text(sub) : null,
                    trailing: e.notifyMinutesBefore != null
                        ? const Icon(Icons.notifications_active, size: 16, color: Colors.grey)
                        : null,
                    onTap: () => _editEvent(e),
                  ),
                ),
              );
            }),
          ],
        )
      : const Center(child: Text('予定はありません'));
  }(),
),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'calendar_fab',
        onPressed: () {
          if (_selectedDay != null) _showAddDialog(_selectedDay!, appState);
        },
        backgroundColor: Colors.pink,
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }
}
// カレンダー下部のドット凡例
class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.black54)),
      ],
    );
  }
}
