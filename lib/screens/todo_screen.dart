import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../app_state.dart';
import '../notification_service.dart';
import '../widgets/swipe_to_delete.dart';

class TodoScreen extends StatefulWidget {
  const TodoScreen({super.key});

  @override
  State<TodoScreen> createState() => _TodoScreenState();
}

class _TodoScreenState extends State<TodoScreen> {
  String _filterLabel = ''; // '' = すべて

  // ラベルのプリセットと色
  static const List<String> _presetLabels = ['学校', '就活', 'イベント', 'バイト', 'プライベート'];
  static const List<int> _reminderOptions = [0, 1, 3, 7]; // 何日前

  Color _labelColor(String label) {
    switch (label) {
      case '学校':
        return Colors.indigo;
      case '就活':
        return Colors.teal;
      case 'イベント':
        return Colors.deepOrange;
      case 'バイト':
        return Colors.blue;
      case 'プライベート':
        return Colors.purple;
      default:
        return Colors.grey;
    }
  }

  Color _priorityColor(Priority p) {
    switch (p) {
      case Priority.high:
        return Colors.red;
      case Priority.middle:
        return Colors.orange;
      case Priority.low:
        return Colors.green;
    }
  }

  String _priorityLabel(Priority p) {
    switch (p) {
      case Priority.high:
        return '高';
      case Priority.middle:
        return '中';
      case Priority.low:
        return '低';
    }
  }

  String _reminderLabel(int d) {
    switch (d) {
      case 0:
        return '当日';
      case 1:
        return '前日';
      case 7:
        return '1週間前';
      default:
        return '$d日前';
    }
  }

  void _showTodoDialog(BuildContext context, AppState appState, {TodoData? existing}) {
    final titleCtrl = TextEditingController(text: existing?.title ?? '');
    final descCtrl = TextEditingController(text: existing?.description ?? '');
    final labelCtrl = TextEditingController(text: existing?.label ?? '');
    DateTime deadline = existing?.deadline ?? DateTime.now();
    bool hasTime = existing?.hasTime ?? false;
    Priority priority = existing?.priority ?? Priority.middle;
    RepeatType repeat = existing?.repeatType ?? RepeatType.none;
    final reminders = {...(existing?.reminderDaysBefore ?? const [1, 0])};

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(existing == null ? 'Todo追加' : 'Todo編集'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(controller: titleCtrl, decoration: const InputDecoration(labelText: 'タイトル')),
                TextField(controller: descCtrl, decoration: const InputDecoration(labelText: '詳細')),
                const SizedBox(height: 12),
                // 締切（日付）
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('締切日'),
                  trailing: Text(DateFormat('yyyy/M/d').format(deadline)),
                  onTap: () async {
                    final d = await showDatePicker(
                      context: context,
                      initialDate: deadline,
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2035),
                    );
                    if (d != null) {
                      setLocal(() => deadline = DateTime(d.year, d.month, d.day, deadline.hour, deadline.minute));
                    }
                  },
                ),
                // 締切（時刻・任意）
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('締切時刻'),
                  subtitle: const Text('日時を指定して通知'),
                  trailing: Text(hasTime ? TimeOfDay.fromDateTime(deadline).format(context) : '指定なし'),
                  onTap: () async {
                    final t = await showTimePicker(
                      context: context,
                      initialTime: hasTime ? TimeOfDay.fromDateTime(deadline) : const TimeOfDay(hour: 9, minute: 0),
                    );
                    if (t != null) {
                      setLocal(() {
                        deadline = DateTime(deadline.year, deadline.month, deadline.day, t.hour, t.minute);
                        hasTime = true;
                      });
                    }
                  },
                ),
                if (hasTime)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => setLocal(() => hasTime = false),
                      child: const Text('時刻をクリア', style: TextStyle(fontSize: 12)),
                    ),
                  ),
                const Divider(),
                // 通知タイミング（何日前）
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('通知（何日前）', style: TextStyle(fontSize: 12, color: Colors.grey)),
                ),
                Wrap(
                  spacing: 6,
                  children: _reminderOptions.map((d) {
                    final on = reminders.contains(d);
                    return FilterChip(
                      label: Text(_reminderLabel(d)),
                      selected: on,
                      onSelected: (_) => setLocal(() {
                        on ? reminders.remove(d) : reminders.add(d);
                      }),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 8),
                // ラベル
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('ラベル', style: TextStyle(fontSize: 12, color: Colors.grey)),
                ),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final l in _presetLabels)
                      ChoiceChip(
                        label: Text(l),
                        selected: labelCtrl.text == l,
                        selectedColor: _labelColor(l).withValues(alpha: 0.25),
                        onSelected: (_) => setLocal(() => labelCtrl.text = labelCtrl.text == l ? '' : l),
                      ),
                  ],
                ),
                TextField(
                  controller: labelCtrl,
                  decoration: const InputDecoration(labelText: 'ラベル（自由入力も可）', isDense: true),
                  onChanged: (_) => setLocal(() {}),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Text('優先度: '),
                    DropdownButton<Priority>(
                      value: priority,
                      items: Priority.values
                          .map((p) => DropdownMenuItem(value: p, child: Text(_priorityLabel(p))))
                          .toList(),
                      onChanged: (v) => setLocal(() => priority = v!),
                    ),
                    const Spacer(),
                    const Text('繰り返し: '),
                    DropdownButton<RepeatType>(
                      value: repeat,
                      items: const [
                        DropdownMenuItem(value: RepeatType.none, child: Text('なし')),
                        DropdownMenuItem(value: RepeatType.daily, child: Text('毎日')),
                        DropdownMenuItem(value: RepeatType.weekly, child: Text('毎週')),
                        DropdownMenuItem(value: RepeatType.monthly, child: Text('毎月')),
                      ],
                      onChanged: (v) => setLocal(() => repeat = v!),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
            ElevatedButton(
              onPressed: () async {
                if (titleCtrl.text.isEmpty) return;
                // 通知を使うなら権限をリクエスト
                if (reminders.isNotEmpty) {
                  await NotificationService.instance.requestPermission();
                }
                final sortedReminders = reminders.toList()..sort((a, b) => b.compareTo(a));
                if (existing == null) {
                  appState.addTodo(TodoData(
                    id: DateTime.now().microsecondsSinceEpoch.toString(),
                    title: titleCtrl.text,
                    description: descCtrl.text,
                    deadline: deadline,
                    priority: priority,
                    repeatType: repeat,
                    label: labelCtrl.text.trim(),
                    reminderDaysBefore: sortedReminders,
                    hasTime: hasTime,
                  ));
                } else {
                  final oldKey = DateFormat('yyyy-MM-dd').format(existing.deadline);
                  existing
                    ..title = titleCtrl.text
                    ..description = descCtrl.text
                    ..deadline = deadline
                    ..priority = priority
                    ..repeatType = repeat
                    ..label = labelCtrl.text.trim()
                    ..reminderDaysBefore = sortedReminders
                    ..hasTime = hasTime;
                  appState.updateTodo(oldKey, existing);
                }
                if (context.mounted) Navigator.pop(context);
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
    final allTodos = appState.allTodos;
    // 使われているラベル一覧
    final labels = <String>{for (final t in allTodos) if (t.label.isNotEmpty) t.label}.toList()..sort();
    final todos = _filterLabel.isEmpty
        ? allTodos
        : allTodos.where((t) => t.label == _filterLabel).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('やること')),
      body: Column(
        children: [
          // ラベル絞り込み
          if (labels.isNotEmpty)
            SizedBox(
              height: 46,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: const Text('すべて'),
                      selected: _filterLabel.isEmpty,
                      onSelected: (_) => setState(() => _filterLabel = ''),
                    ),
                  ),
                  ...labels.map((l) => Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text(l),
                          selected: _filterLabel == l,
                          selectedColor: _labelColor(l).withValues(alpha: 0.25),
                          onSelected: (_) => setState(() => _filterLabel = l),
                        ),
                      )),
                ],
              ),
            ),
          Expanded(
            child: todos.isEmpty
                ? const Center(child: Text('Todoはありません'))
                : ListView.builder(
                    itemCount: todos.length,
                    itemBuilder: (context, i) {
                      final t = todos[i];
                      final key = DateFormat('yyyy-MM-dd').format(t.deadline);
                      final dateText = t.hasTime
                          ? DateFormat('M/d HH:mm').format(t.deadline)
                          : DateFormat('M/d').format(t.deadline);
                      return SwipeToDelete(
                        itemKey: Key(t.id),
                        onDelete: () => appState.removeTodo(key, t.id),
                        child: Card(
                          child: ListTile(
                            leading: Checkbox(
                              value: t.completed,
                              onChanged: (_) => appState.toggleTodo(t),
                            ),
                            title: Row(
                              children: [
                                if (t.label.isNotEmpty) ...[
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: _labelColor(t.label).withValues(alpha: 0.18),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(t.label,
                                        style: TextStyle(fontSize: 11, color: _labelColor(t.label), fontWeight: FontWeight.bold)),
                                  ),
                                  const SizedBox(width: 6),
                                ],
                                Expanded(
                                  child: Text(
                                    t.title,
                                    style: TextStyle(
                                      decoration: t.completed ? TextDecoration.lineThrough : null,
                                      color: t.completed ? Colors.grey : null,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            subtitle: Row(
                              children: [
                                const Icon(Icons.schedule, size: 12, color: Colors.grey),
                                const SizedBox(width: 3),
                                Text(dateText, style: const TextStyle(fontSize: 12)),
                                if (t.reminderDaysBefore.isNotEmpty) ...[
                                  const SizedBox(width: 8),
                                  const Icon(Icons.notifications_active, size: 12, color: Colors.grey),
                                ],
                                if (t.description.isNotEmpty) ...[
                                  const SizedBox(width: 8),
                                  Expanded(child: Text(t.description, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis)),
                                ],
                              ],
                            ),
                            trailing: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: _priorityColor(t.priority).withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(_priorityLabel(t.priority),
                                  style: TextStyle(color: _priorityColor(t.priority), fontWeight: FontWeight.bold)),
                            ),
                            onTap: () => _showTodoDialog(context, appState, existing: t),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'todo_fab',
        onPressed: () => _showTodoDialog(context, appState),
        backgroundColor: Colors.pink,
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }
}
