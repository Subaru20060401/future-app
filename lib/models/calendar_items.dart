// 💡 予定・やることのデータ型。保存の JSON の形を変えないこと（既存データとドライブ同期の互換）。

// ───────────────────────── 列挙型 ─────────────────────────
enum Priority { high, middle, low }

enum RepeatType { none, daily, weekly, monthly }

// ───────────────────────── 予定 ─────────────────────────
class EventData {
  final String id;
  String title;
  String location;
  String url;
  String memo;
  int colorValue; // 色タグ（ARGB）
  bool allDay; // 終日
  DateTime? start; // 開始日時（allDay時は日付のみ意味を持つ）
  DateTime? end; // 終了日時
  int? notifyMinutesBefore; // 通知（開始の何分前。null=なし）
  String? calendarEventId; // Appleカレンダー連携で作成したイベントID

  EventData({
    required this.id,
    required this.title,
    this.location = '',
    this.url = '',
    this.memo = '',
    this.colorValue = 0xFFFFA726, // オレンジ
    this.allDay = false,
    this.start,
    this.end,
    this.notifyMinutesBefore,
    this.calendarEventId,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'location': location,
        'url': url,
        'memo': memo,
        'colorValue': colorValue,
        'allDay': allDay,
        'start': start?.toIso8601String(),
        'end': end?.toIso8601String(),
        'notifyMinutesBefore': notifyMinutesBefore,
        'calendarEventId': calendarEventId,
      };

  factory EventData.fromJson(Map<String, dynamic> json) => EventData(
        // 旧データ（title のみ）も吸収。id 無ければ採番。
        id: json['id'] ?? 'ev-${DateTime.now().microsecondsSinceEpoch}-${json['title']}',
        title: json['title'] ?? '',
        location: json['location'] ?? '',
        url: json['url'] ?? '',
        memo: json['memo'] ?? '',
        colorValue: json['colorValue'] ?? 0xFFFFA726,
        allDay: json['allDay'] ?? false,
        start: (json['start'] as String?) != null ? DateTime.parse(json['start']) : null,
        end: (json['end'] as String?) != null ? DateTime.parse(json['end']) : null,
        notifyMinutesBefore: json['notifyMinutesBefore'],
        calendarEventId: json['calendarEventId'],
      );
}

// ───────────────────────── Todo ─────────────────────────
class TodoData {
  final String id;
  String title;
  String description;
  DateTime deadline; // 締切（日時。時刻も通知に使う）
  bool completed;
  Priority priority;
  RepeatType repeatType;
  String label; // ラベル（学校/就活/イベント等。空=なし）
  List<int> reminderDaysBefore; // 何日前に通知するか（0=当日/締切時刻）。空=通知なし
  bool hasTime; // 締切に時刻指定があるか（false=日付のみ→通知は9:00）

  TodoData({
    required this.id,
    required this.title,
    this.description = '',
    required this.deadline,
    this.completed = false,
    this.priority = Priority.middle,
    this.repeatType = RepeatType.none,
    this.label = '',
    List<int>? reminderDaysBefore,
    this.hasTime = false,
  }) : reminderDaysBefore = reminderDaysBefore ?? const [1, 0];

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'description': description,
        'deadline': deadline.toIso8601String(),
        'completed': completed,
        'priority': priority.index,
        'repeatType': repeatType.index,
        'label': label,
        'reminderDaysBefore': reminderDaysBefore,
        'hasTime': hasTime,
      };

  factory TodoData.fromJson(Map<String, dynamic> json) => TodoData(
        id: json['id'],
        title: json['title'],
        description: json['description'] ?? '',
        deadline: DateTime.parse(json['deadline']),
        completed: json['completed'] ?? false,
        priority: Priority.values[json['priority'] ?? 1],
        repeatType: RepeatType.values[json['repeatType'] ?? 0],
        label: json['label'] ?? '',
        reminderDaysBefore: (json['reminderDaysBefore'] as List?)?.map((e) => e as int).toList(),
        hasTime: json['hasTime'] ?? false,
      );
}
