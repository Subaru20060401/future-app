import 'package:flutter/material.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:provider/provider.dart';
import '../app_state.dart';
import '../widgets/legend_dot.dart';
import '../widgets/swipe_to_delete.dart';
import 'event_edit_screen.dart';
import '../widgets/app_sheet.dart';
import '../widgets/add_entry_sheets.dart';
import '../money_format.dart';

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
            _detailRow('入金予定額', '¥${yenNum(e.amount)}', Colors.green),
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
                  Text('-¥${yenNum(summary.amount)}',
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
                      trailing: Text('-¥${yenNum(p.amount)}',
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

  void _editEvent(EventData e) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => EventEditScreen(day: e.start ?? _selectedDay ?? DateTime.now(), event: e)),
    );
  }

  // シフト編集ダイアログ（入力フォームは追加と共通）
  void _editShift(String dateKey, int idx, ShiftData s, AppState appState) {
    showShiftFormDialog(
      context,
      appState,
      DateTime.tryParse(dateKey) ?? DateTime.now(),
      title: 'シフトを編集',
      initial: s,
      onSave: (shift) => appState.updateShift(dateKey, idx, shift),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    
    // 💡 選択された日付を "yyyy-MM-dd" の文字列にして金庫から引き出す
    final selectedKey = _selectedDay != null ? dateKey(_selectedDay!) : '';
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
            // 💡 表示切替のボタンが英語（2 weeks など）だったので日本語にそろえる
            availableCalendarFormats: const {
              CalendarFormat.month: '月',
              CalendarFormat.twoWeeks: '2週間',
              CalendarFormat.week: '週',
            },
            selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
            onDaySelected: (selectedDay, focusedDay) {
              setState(() {
                _selectedDay = selectedDay;
                _focusedDay = focusedDay;
              });
            },
            // 💡 種類ごとに色を変えたポチ（ドット）を表示するため eventLoader は件数だけ返す
            eventLoader: (day) {
              final key = dateKey(day);
              final hasShift = appState.shifts.containsKey(key) && appState.shifts[key]!.isNotEmpty;
              final hasEvent = appState.events.containsKey(key) && appState.events[key]!.isNotEmpty;
              final hasPayday = appState.paydaysOnDay(day).isNotEmpty;
              final hasPayment = appState.cardPaymentSummaryOnDay(day).isNotEmpty;
              return (hasShift || hasEvent || hasPayday || hasPayment) ? [true] : [];
            },
            calendarBuilders: CalendarBuilders(
              markerBuilder: (context, day, events) {
                final key = dateKey(day);
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
                LegendDot(color: Colors.blueAccent, label: 'シフト', compact: true),
                LegendDot(color: Color(0xFF2E9E5B), label: '給料日', compact: true),
                LegendDot(color: Colors.redAccent, label: '引き落とし', compact: true),
                LegendDot(color: Colors.orange, label: '予定', compact: true),
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
                  trailing: Text('¥${yenNum(e.amount)}',
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
                      trailing: Text('+¥${yenNum(p.amount)}',
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
                      ? Text('-¥${yenNum(p.amount)}',
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
                    trailing: Text('¥${yenNum(s.earnings)}'),
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
      // 💡 空のときは、次にできることを出す
      : Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _selectedDay == null
                    ? '日付を選ぶと、その日の予定が出ます'
                    : '${_selectedDay!.month}月${_selectedDay!.day}日の予定はありません',
                style: const TextStyle(color: Colors.black54),
              ),
              if (_selectedDay != null) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => showAddEntrySheet(context, appState, _selectedDay!),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('この日に追加'),
                ),
              ],
            ],
          ),
        );
  }(),
),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'calendar_fab',
        onPressed: () {
          if (_selectedDay != null) showAddEntrySheet(context, appState, _selectedDay!);
        },
        backgroundColor: Colors.pink,
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }
}
