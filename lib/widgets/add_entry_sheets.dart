// 💡 シフト・予定を追加する画面。カレンダーとホームの両方から開く。
//   （カレンダーの中にだけあったものを、そのまま外に出した）
// ⚠️ シートやダイアログのビルダーは context を引数で受け取り直していて、外の context を隠す。
//   続きの画面を開くときは、閉じたシートの context ではなく、呼び出し元の hostContext を渡すこと。
//   （外側の引数をわざと hostContext という別名にして、取り違えるとコンパイルで気づけるようにしている）
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../screens/event_edit_screen.dart';
import 'app_sheet.dart';

void showAddEntrySheet(BuildContext hostContext, AppState appState, DateTime selectedDay) {
  showAppSheet(hostContext, (context) {
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
                showAddShiftSheet(hostContext, appState, selectedDay);
              },
            ),
            ListTile(
              leading: const Icon(Icons.repeat, color: Colors.teal),
              title: const Text('繰り返しシフトを追加'),
              subtitle: const Text('毎週○曜などをまとめて登録'),
              onTap: () {
                Navigator.pop(context);
                showRecurringShiftDialog(hostContext, appState, selectedDay);
              },
            ),
            ListTile(
              leading: const Icon(Icons.event, color: Colors.orange),
              title: const Text('予定を追加'),
              onTap: () {
                Navigator.pop(context);
                openAddEvent(hostContext, appState, selectedDay);
              },
            ),
          ],
        ),
      );
    },
  );
}

// シフト追加：まず「履歴から追加」を出し、なければ/新規は入力ダイアログへ（シフトボード風）
void showAddShiftSheet(BuildContext hostContext, AppState appState, DateTime selectedDay) {
  final templates = appState.recentShiftTemplates();
  String hm(int h, int m) => '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  showAppSheet(hostContext, (context) => SafeArea(
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
                  showShiftInputDialog(hostContext, appState, selectedDay);
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

void showShiftInputDialog(BuildContext hostContext, AppState appState, DateTime selectedDay) {
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
    context: hostContext,
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
void showRecurringShiftDialog(BuildContext hostContext, AppState appState, DateTime selectedDay) {
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
    context: hostContext,
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

void openAddEvent(BuildContext hostContext, AppState appState, DateTime selectedDay) {
  Navigator.push(
    hostContext,
    MaterialPageRoute(builder: (_) => EventEditScreen(day: selectedDay)),
  );
}
