// 💡 勤務先・時給の履歴・給料日の調整。保存の JSON の形を変えないこと。
import '../japanese_holidays.dart';

// ───────────────────────── 勤務先マスタ ─────────────────────────
// 💡 給料情報（時給の変更履歴の1区間）。各区間に交通費・各種手当の倍率を持つ。
class WagePeriod {
  // この時給が有効になる開始日。null は「最古（それ以前すべて）」を表す。
  final DateTime? effectiveFrom;
  final int hourlyWage; // 時給
  final int transportPerDay; // 交通費（1勤務あたり定額。0=なし）
  final int transportMonthlyCap; // 交通費の月上限（0=上限なし）
  final double holidayMultiplier; // 休日給料の倍率（1.0=なし）
  final double nightMultiplier; // 深夜給料の倍率（1.0=なし）
  final double overtimeMultiplier; // 残業手当の倍率（1.0=なし）

  WagePeriod({
    this.effectiveFrom,
    required this.hourlyWage,
    this.transportPerDay = 0,
    this.transportMonthlyCap = 0,
    this.holidayMultiplier = 1.0,
    this.nightMultiplier = 1.0,
    this.overtimeMultiplier = 1.0,
  });

  WagePeriod copyWith({
    Object? effectiveFrom = _noChange,
    int? hourlyWage,
    int? transportPerDay,
    int? transportMonthlyCap,
    double? holidayMultiplier,
    double? nightMultiplier,
    double? overtimeMultiplier,
  }) =>
      WagePeriod(
        effectiveFrom: identical(effectiveFrom, _noChange)
            ? this.effectiveFrom
            : effectiveFrom as DateTime?,
        hourlyWage: hourlyWage ?? this.hourlyWage,
        transportPerDay: transportPerDay ?? this.transportPerDay,
        transportMonthlyCap: transportMonthlyCap ?? this.transportMonthlyCap,
        holidayMultiplier: holidayMultiplier ?? this.holidayMultiplier,
        nightMultiplier: nightMultiplier ?? this.nightMultiplier,
        overtimeMultiplier: overtimeMultiplier ?? this.overtimeMultiplier,
      );

  Map<String, dynamic> toJson() => {
        'effectiveFrom': effectiveFrom?.toIso8601String(),
        'hourlyWage': hourlyWage,
        'transportPerDay': transportPerDay,
        'transportMonthlyCap': transportMonthlyCap,
        'holidayMultiplier': holidayMultiplier,
        'nightMultiplier': nightMultiplier,
        'overtimeMultiplier': overtimeMultiplier,
      };

  factory WagePeriod.fromJson(Map<String, dynamic> json) => WagePeriod(
        effectiveFrom: (json['effectiveFrom'] as String?) != null
            ? DateTime.parse(json['effectiveFrom'])
            : null,
        hourlyWage: json['hourlyWage'] ?? 0,
        transportPerDay: json['transportPerDay'] ?? 0,
        transportMonthlyCap: json['transportMonthlyCap'] ?? 0,
        holidayMultiplier: (json['holidayMultiplier'] as num?)?.toDouble() ?? 1.0,
        nightMultiplier: (json['nightMultiplier'] as num?)?.toDouble() ?? 1.0,
        overtimeMultiplier: (json['overtimeMultiplier'] as num?)?.toDouble() ?? 1.0,
      );
}

const Object _noChange = Object();

// 💡 勤務先（バイト先）マスタ。表示色・ジャンル・場所・締日・給料日・時給履歴を持つ。
// 給料日が土日祝のときの振込タイミング
enum PaydayAdjust {
  before, // 前営業日（休みの前にもらえる。日本では一般的）
  after, // 翌営業日（休み明けにもらえる）
  none, // 調整しない（そのままの日付）
}

extension PaydayAdjustLabel on PaydayAdjust {
  String get label {
    switch (this) {
      case PaydayAdjust.before:
        return '前営業日にする';
      case PaydayAdjust.after:
        return '翌営業日にする';
      case PaydayAdjust.none:
        return '調整しない';
    }
  }

  String get shortLabel {
    switch (this) {
      case PaydayAdjust.before:
        return '前倒し';
      case PaydayAdjust.after:
        return '後ろ倒し';
      case PaydayAdjust.none:
        return 'そのまま';
    }
  }
}

class Workplace {
  final String id;
  String name; // 勤務先名（必須）
  int colorValue; // 表示色（ARGB）
  String genre; // ジャンル（情報用）
  String location; // 場所（情報用）
  int closingDay; // 締日（1〜28、31=月末）
  int paydayMonthOffset; // 給料日：当月0/翌月1/翌々月2
  int paydayDay; // 給料日（日）
  PaydayAdjust paydayAdjust; // 給料日が土日祝のときの扱い
  List<WagePeriod> wagePeriods; // 給料情報（effectiveFrom昇順）

  Workplace({
    required this.id,
    required this.name,
    this.colorValue = 0xFF42A5F5,
    this.genre = '',
    this.location = '',
    this.closingDay = 31,
    this.paydayMonthOffset = 1,
    this.paydayDay = 25,
    this.paydayAdjust = PaydayAdjust.before,
    List<WagePeriod>? wagePeriods,
  }) : wagePeriods = wagePeriods ?? [];

  // 💡 指定月の実際の給料日（土日祝を設定に応じて前後にズラす）
  DateTime paydayIn(DateTime payMonth) {
    final lastDay = DateTime(payMonth.year, payMonth.month + 1, 0).day;
    final day = paydayDay > lastDay ? lastDay : paydayDay;
    final base = DateTime(payMonth.year, payMonth.month, day);
    switch (paydayAdjust) {
      case PaydayAdjust.before:
        return previousBusinessDay(base);
      case PaydayAdjust.after:
        return nextBusinessDay(base);
      case PaydayAdjust.none:
        return base;
    }
  }

  bool get isEndOfMonthClosing => closingDay >= 31;

  // 指定月の締日（実日付）。月末締めや短い月にも対応。
  DateTime _closingDateOf(int year, int month) {
    final lastDay = DateTime(year, month + 1, 0).day;
    final day = isEndOfMonthClosing ? lastDay : (closingDay > lastDay ? lastDay : closingDay);
    return DateTime(year, month, day);
  }

  // 💡 date が属する給与期間の「開始日」。締日に基づいてスナップする。
  //   月末締め → その月の1日。N日締め → 直前の締日の翌日。
  DateTime payPeriodStartFor(DateTime date) {
    final d = DateTime(date.year, date.month, date.day);
    if (isEndOfMonthClosing) return DateTime(d.year, d.month, 1);
    final thisClosing = _closingDateOf(d.year, d.month);
    if (!d.isAfter(thisClosing)) {
      // 当月の締日以前 → 前月の締日の翌日が開始
      final prev = _closingDateOf(
          d.month == 1 ? d.year - 1 : d.year, d.month == 1 ? 12 : d.month - 1);
      return prev.add(const Duration(days: 1));
    } else {
      // 当月の締日より後 → 当月の締日の翌日が開始
      return thisClosing.add(const Duration(days: 1));
    }
  }

  // effectiveFrom 昇順に並べ替える（null＝最古を先頭）
  void sortWagePeriods() {
    wagePeriods.sort((a, b) {
      if (a.effectiveFrom == null) return -1;
      if (b.effectiveFrom == null) return 1;
      return a.effectiveFrom!.compareTo(b.effectiveFrom!);
    });
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'colorValue': colorValue,
        'genre': genre,
        'location': location,
        'closingDay': closingDay,
        'paydayMonthOffset': paydayMonthOffset,
        'paydayDay': paydayDay,
        'paydayAdjust': paydayAdjust.index,
        'wagePeriods': wagePeriods.map((e) => e.toJson()).toList(),
      };

  factory Workplace.fromJson(Map<String, dynamic> json) => Workplace(
        id: json['id'],
        name: json['name'] ?? '勤務先',
        colorValue: json['colorValue'] ?? 0xFF42A5F5,
        genre: json['genre'] ?? '',
        location: json['location'] ?? '',
        closingDay: json['closingDay'] ?? 31,
        paydayMonthOffset: json['paydayMonthOffset'] ?? 1,
        paydayDay: json['paydayDay'] ?? 25,
        paydayAdjust: PaydayAdjust.values[json['paydayAdjust'] ?? 0],
        wagePeriods: (json['wagePeriods'] as List?)
                ?.map((e) => WagePeriod.fromJson(e))
                .toList() ??
            [],
      );
}
