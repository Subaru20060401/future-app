// 💡 シフトのデータ型と、1勤務の給与の計算。保存の JSON の形を変えないこと。

// ───────────────────────── シフト ─────────────────────────
// 💡 新仕様: 開始/終了時刻 + 休憩(分)から勤務時間を自動算出
class ShiftData {
  // 💡 シフトの固定ID。メールから来た「変更・取消」を、再起動後も同じシフトに当てるため。
  //   ⚠️ 旧データにはIDが無い。読み込み時に採番し（legacyId）、起動時の自己修復で保存する。
  //   別の端末が同じ旧データから独立に採番すると別のIDになる（同じIDになるとは仮定しない）。
  String id;
  final bool legacyId;
  final String workplace;
  final int hourlyWage;
  final DateTime start;
  final DateTime end;
  final int breakMinutes;
  // 💡 勤務先マスタ連携。入力時にその日の給料情報をスナップショットして保持するため、
  //    後から勤務先設定を変えても過去シフトの給与は変わらない。旧データは未設定（既定値）。
  final String? workplaceId;
  final int transportPerDay; // 交通費（1勤務あたり定額）
  final int transportMonthlyCap; // 交通費の月上限（0=上限なし。月集計時に適用）
  final double nightMultiplier; // 深夜割増の倍率（1.0=なし）
  final double overtimeMultiplier; // 残業割増の倍率（1.0=なし）
  final double holidayMultiplier; // 休日割増の倍率（1.0=なし）
  String? calendarEventId; // Appleカレンダー連携で作成したイベントID（更新/削除用）

  ShiftData({
    String? id,
    this.legacyId = false,
    required this.workplace,
    required this.hourlyWage,
    required this.start,
    required this.end,
    this.breakMinutes = 0,
    this.workplaceId,
    this.transportPerDay = 0,
    this.transportMonthlyCap = 0,
    this.nightMultiplier = 1.0,
    this.overtimeMultiplier = 1.0,
    this.holidayMultiplier = 1.0,
    this.calendarEventId,
  }) : id = id ?? newShiftId();

  static int _seq = 0;
  static String newShiftId() =>
      'sh-${DateTime.now().microsecondsSinceEpoch}-${_seq++}';

  // 実働時間（時間）
  double get workHours {
    final total = end.difference(start).inMinutes - breakMinutes;
    return total <= 0 ? 0 : total / 60.0;
  }

  // [start, end] のうち深夜帯（22:00〜翌5:00）に重なる時間（時間）
  double get nightHours => nightOverlapMinutes(start, end) / 60.0;

  // 交通費を除いた給与（基本給＋深夜割増＋残業割増＋休日割増）。
  // 交通費は月上限の対象なので分離し、月集計側で合算・上限適用する。
  int get wageEarnings {
    final hours = workHours;
    if (hours <= 0) return 0;
    double total = hourlyWage * hours;
    // 深夜割増（重なり時間ぶんだけ上乗せ）
    if (nightMultiplier > 1.0) {
      total += nightHours * hourlyWage * (nightMultiplier - 1.0);
    }
    // 残業割増（8時間超ぶん）
    if (overtimeMultiplier > 1.0 && hours > 8) {
      total += (hours - 8) * hourlyWage * (overtimeMultiplier - 1.0);
    }
    // 休日割増（土日のみ・実働全体）
    if (holidayMultiplier > 1.0 &&
        (start.weekday == DateTime.saturday || start.weekday == DateTime.sunday)) {
      total += hours * hourlyWage * (holidayMultiplier - 1.0);
    }
    return total.round();
  }

  // 1勤務あたりの給与（交通費込み・月上限は未適用＝単体表示用）
  int get earnings => wageEarnings + transportPerDay;

  Map<String, dynamic> toJson() => {
        'id': id,
        'workplace': workplace,
        'hourlyWage': hourlyWage,
        'start': start.toIso8601String(),
        'end': end.toIso8601String(),
        'breakMinutes': breakMinutes,
        'workplaceId': workplaceId,
        'transportPerDay': transportPerDay,
        'transportMonthlyCap': transportMonthlyCap,
        'nightMultiplier': nightMultiplier,
        'overtimeMultiplier': overtimeMultiplier,
        'holidayMultiplier': holidayMultiplier,
        'calendarEventId': calendarEventId,
      };

  factory ShiftData.fromJson(Map<String, dynamic> json) {
    // 💡 旧形式 (title / hours) からの移行も吸収
    if (json.containsKey('start')) {
      final savedId = json['id'] as String?;
      return ShiftData(
        id: savedId,
        legacyId: savedId == null,
        workplace: json['workplace'] ?? json['title'] ?? 'バイト',
        hourlyWage: json['hourlyWage'] ?? 0,
        start: DateTime.parse(json['start']),
        end: DateTime.parse(json['end']),
        breakMinutes: json['breakMinutes'] ?? 0,
        workplaceId: json['workplaceId'],
        transportPerDay: json['transportPerDay'] ?? 0,
        transportMonthlyCap: json['transportMonthlyCap'] ?? 0,
        nightMultiplier: (json['nightMultiplier'] as num?)?.toDouble() ?? 1.0,
        overtimeMultiplier: (json['overtimeMultiplier'] as num?)?.toDouble() ?? 1.0,
        holidayMultiplier: (json['holidayMultiplier'] as num?)?.toDouble() ?? 1.0,
        calendarEventId: json['calendarEventId'],
      );
    } else {
      // 旧データ: hours 形式 → 仮の時刻に変換
      final hours = (json['hours'] is int)
          ? (json['hours'] as int).toDouble()
          : (json['hours'] ?? 0.0) as double;
      final base = DateTime(2020, 1, 1, 9, 0);
      return ShiftData(
        legacyId: true,
        workplace: json['title'] ?? 'バイト',
        hourlyWage: json['hourlyWage'] ?? 0,
        start: base,
        end: base.add(Duration(minutes: (hours * 60).round())),
        breakMinutes: 0,
      );
    }
  }
}

// [start, end] のうち深夜帯（22:00〜翌05:00）に重なる分数を返す。
// 日付をまたぐシフトにも対応するため、分単位で1日ぶんを走査する。
int nightOverlapMinutes(DateTime start, DateTime end) {
  if (!end.isAfter(start)) return 0;
  var overlap = 0;
  // 1分刻みは多めだが、シフトは最大でも数十時間なので十分軽量。
  for (var t = start; t.isBefore(end); t = t.add(const Duration(minutes: 1))) {
    final h = t.hour;
    if (h >= 22 || h < 5) overlap++;
  }
  return overlap;
}
