import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'card_styles.dart';
import 'japanese_holidays.dart';
import 'workplace_styles.dart';

// ───────────────────────── 列挙型 ─────────────────────────
enum Priority { high, middle, low }

enum RepeatType { none, daily, weekly, monthly }

// ───────────────────────── シフト ─────────────────────────
// 💡 新仕様: 開始/終了時刻 + 休憩(分)から勤務時間を自動算出
class ShiftData {
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
  });

  // 実働時間（時間）
  double get workHours {
    final total = end.difference(start).inMinutes - breakMinutes;
    return total <= 0 ? 0 : total / 60.0;
  }

  // [start, end] のうち深夜帯（22:00〜翌5:00）に重なる時間（時間）
  double get nightHours => _nightOverlapMinutes(start, end) / 60.0;

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
      return ShiftData(
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
int _nightOverlapMinutes(DateTime start, DateTime end) {
  if (!end.isAfter(start)) return 0;
  var overlap = 0;
  // 1分刻みは多めだが、シフトは最大でも数十時間なので十分軽量。
  for (var t = start; t.isBefore(end); t = t.add(const Duration(minutes: 1))) {
    final h = t.hour;
    if (h >= 22 || h < 5) overlap++;
  }
  return overlap;
}

// ───────────────────────── CSV取り込み用の補助 ─────────────────────────
// シフトCSVの1行（給与列を「答え」として持ち、設定の逆算に使う）
class _CsvShiftRow {
  final String workplace;
  final DateTime start;
  final DateTime end;
  final int breakMinutes;
  final int hourlyWage;
  final int earnings;

  _CsvShiftRow({
    required this.workplace,
    required this.start,
    required this.end,
    required this.breakMinutes,
    required this.hourlyWage,
    required this.earnings,
  });

  double get hours {
    final m = end.difference(start).inMinutes - breakMinutes;
    return m <= 0 ? 0 : m / 60.0;
  }

  double get nightHours => _nightOverlapMinutes(start, end) / 60.0;

  bool get isWeekend =>
      start.weekday == DateTime.saturday || start.weekday == DateTime.sunday;

  // ShiftData.wageEarnings と同じ計算（交通費は含めない）
  int wageWith(double nm, double om, double hm) {
    final h = hours;
    if (h <= 0) return 0;
    var total = hourlyWage * h;
    if (nm > 1.0) total += nightHours * hourlyWage * (nm - 1.0);
    if (om > 1.0 && h > 8) total += (h - 8) * hourlyWage * (om - 1.0);
    if (hm > 1.0 && isWeekend) total += h * hourlyWage * (hm - 1.0);
    return total.round();
  }
}

// 逆算で求めた勤務先の給料設定
class _WageFit {
  final int transportPerDay;
  final double nightMultiplier;
  final double overtimeMultiplier;
  final double holidayMultiplier;

  const _WageFit({
    this.transportPerDay = 0,
    this.nightMultiplier = 1.0,
    this.overtimeMultiplier = 1.0,
    this.holidayMultiplier = 1.0,
  });
}

// CSV取り込みの結果（画面に出す件数のまとめ）
class CsvImportResult {
  final int imported; // 取り込んだ件数
  final int skipped; // 同じシフトが既にあってスキップした件数
  final int failed; // 行として読めなかった件数
  final int mismatched; // 給与を再現できなかった件数

  const CsvImportResult({
    this.imported = 0,
    this.skipped = 0,
    this.failed = 0,
    this.mismatched = 0,
  });
}

// カンマ区切りを1行ぶん分解する（"" のエスケープに対応）
List<String> _splitCsvLine(String line) {
  final out = <String>[];
  final buf = StringBuffer();
  var inQuotes = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (inQuotes) {
      if (c == '"') {
        if (i + 1 < line.length && line[i + 1] == '"') {
          buf.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        buf.write(c);
      }
    } else if (c == '"') {
      inQuotes = true;
    } else if (c == ',') {
      out.add(buf.toString());
      buf.clear();
    } else {
      buf.write(c);
    }
  }
  out.add(buf.toString());
  return out;
}

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

// 支払いの出所: 手動 / 利用通知 / カード請求予定 / 銀行引落確定
enum PaymentSource { manual, usage, billing, bank }

// ───────────────────────── カード支払い ─────────────────────────
class Payment {
  String id;
  String cardName;
  int amount;
  DateTime paymentDate;
  bool paid;
  PaymentSource source;
  String sourceId; // メール由来の一意キー（自動取り込みの識別用）
  String note; // 利用先（店舗名）など
  // 💡 「記録として残すが、金額は合計に足さない」明細。
  //   同じ買い物がカード会社の通知からも入ってきたときだけ立てる。
  bool infoOnly;

  Payment({
    required this.id,
    required this.cardName,
    required this.amount,
    required this.paymentDate,
    this.paid = false,
    this.source = PaymentSource.manual,
    this.sourceId = '',
    this.note = '',
    this.infoOnly = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'cardName': cardName,
        'amount': amount,
        'paymentDate': paymentDate.toIso8601String(),
        'paid': paid,
        'source': source.index,
        'sourceId': sourceId,
        'note': note,
        'infoOnly': infoOnly,
      };

  factory Payment.fromJson(Map<String, dynamic> json) => Payment(
        id: json['id'],
        cardName: json['cardName'],
        amount: json['amount'],
        paymentDate: DateTime.parse(json['paymentDate']),
        paid: json['paid'] ?? false,
        source: PaymentSource.values[json['source'] ?? 0],
        sourceId: json['sourceId'] ?? '',
        note: json['note'] ?? '',
        infoOnly: json['infoOnly'] ?? false,
      );
}

// ───────────────────────── 分割払い ─────────────────────────
class Installment {
  final String id;
  String name;
  String cardName; // 紐づくクレカ
  int totalAmount; // 元金
  int installmentCount;
  int remainingMonths;
  int monthlyAmount; // 金利込みの月額
  double interestRate; // 年率(%)
  DateTime? startDate; // 利用日（残回数の自動計算に使用）

  Installment({
    required this.id,
    required this.name,
    this.cardName = '',
    required this.totalAmount,
    required this.installmentCount,
    required this.remainingMonths,
    required this.monthlyAmount,
    this.interestRate = 0,
    this.startDate,
  });

  // 手数料込みの総支払額
  int get totalWithInterest => monthlyAmount * installmentCount;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'cardName': cardName,
        'totalAmount': totalAmount,
        'installmentCount': installmentCount,
        'remainingMonths': remainingMonths,
        'monthlyAmount': monthlyAmount,
        'interestRate': interestRate,
        'startDate': startDate?.toIso8601String(),
      };

  factory Installment.fromJson(Map<String, dynamic> json) => Installment(
        id: json['id'],
        name: json['name'],
        cardName: json['cardName'] ?? '',
        totalAmount: json['totalAmount'],
        installmentCount: json['installmentCount'],
        remainingMonths: json['remainingMonths'],
        monthlyAmount: json['monthlyAmount'],
        interestRate: (json['interestRate'] ?? 0).toDouble(),
        startDate: json['startDate'] != null ? DateTime.parse(json['startDate']) : null,
      );
}

// 分割の月額を計算（単純な年率手数料: 元金 × 年率% × 回数/12 を上乗せ）
int computeInstallmentMonthly(int principal, int count, double annualRatePercent) {
  if (count <= 0) return principal;
  final fee = principal * (annualRatePercent / 100) * (count / 12);
  return ((principal + fee) / count).round();
}

// ───────────────────────── ローン ─────────────────────────
// 💡 分割払いとの違い: 分割はカードの請求に含まれて落ちるが、
//   ローンは口座から直接引き落とされることが多く、返済日も独立している。
//   奨学金のように「卒業してから返済開始」というものもあるので、
//   返済開始の年月を持たせて、それより前の月は何も引かない。
class Loan {
  final String id;
  String name; // 奨学金、車のローン など
  int principal; // 借入総額（元金）
  double interestRate; // 年利(%)。0＝無利息（奨学金の第一種など）
  int totalCount; // 返済回数（月）
  DateTime startMonth; // 初回返済の年月
  int payDay; // 毎月の返済日
  // 引き落とし方法。'' = 口座から直接、カード名 = そのカードの請求に含める
  String method;
  int monthlyOverride; // 0以外なら毎月の返済額をこの値で固定

  Loan({
    required this.id,
    required this.name,
    required this.principal,
    required this.totalCount,
    required this.startMonth,
    this.interestRate = 0,
    this.payDay = 27,
    this.method = '',
    this.monthlyOverride = 0,
  });

  bool get isFromAccount => method.isEmpty;
  bool get isCardPayment => method.isNotEmpty;

  // 毎月の返済額。指定があればそれを使う（金利の計算方法が違う場合に備える）
  int get monthlyAmount => monthlyOverride > 0
      ? monthlyOverride
      : computeInstallmentMonthly(principal, totalCount, interestRate);

  // その月が何回目の返済か（1始まり）。返済期間外なら0。
  int countIn(DateTime month) {
    final diff = (month.year - startMonth.year) * 12 + (month.month - startMonth.month);
    if (diff < 0 || diff >= totalCount) return 0;
    return diff + 1;
  }

  bool isActiveIn(DateTime month) => countIn(month) > 0;

  // 完済する月（最後の返済月）
  DateTime get finishMonth =>
      DateTime(startMonth.year, startMonth.month + totalCount - 1);

  // 基準日の時点で残っている回数
  int remainingCountAt(DateTime now) {
    final done = (now.year - startMonth.year) * 12 + (now.month - startMonth.month);
    if (done < 0) return totalCount; // まだ返済が始まっていない
    final left = totalCount - done;
    return left < 0 ? 0 : left;
  }

  // 残債（毎月の返済額 × 残り回数の目安）
  int remainingAmountAt(DateTime now) => monthlyAmount * remainingCountAt(now);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'principal': principal,
        'interestRate': interestRate,
        'totalCount': totalCount,
        'startMonth': startMonth.toIso8601String(),
        'payDay': payDay,
        'method': method,
        'monthlyOverride': monthlyOverride,
      };

  factory Loan.fromJson(Map<String, dynamic> json) => Loan(
        id: json['id'],
        name: json['name'] ?? '',
        principal: json['principal'] ?? 0,
        interestRate: (json['interestRate'] ?? 0).toDouble(),
        totalCount: json['totalCount'] ?? 1,
        startMonth: DateTime.parse(json['startMonth']),
        payDay: json['payDay'] ?? 27,
        method: json['method'] ?? '',
        monthlyOverride: json['monthlyOverride'] ?? 0,
      );
}

// ───────────────────────── 定期支払い ─────────────────────────
// 定期支払いの「手動」支払いを表す値（method に入る）
const String kManualPayMethod = '手動';

class Subscription {
  final String id;
  String title;
  int amount;
  int payDay;
  // 支払い方法。
  //   '' = 口座振替（口座から自動で引かれる）
  //   '手動' = 自分で払う（振込・現金など。払ったら記録して残高から引く）
  //   カード名 = そのカード払い（カードの引き落とし額に含まれるので口座からは別途引かない）
  String method;

  Subscription({
    required this.id,
    required this.title,
    required this.amount,
    required this.payDay,
    this.method = '',
  });

  // 口座振替（自動引き落とし）か
  bool get isFromAccount => method.isEmpty;
  // 自分で払うか
  bool get isManualPay => method == kManualPayMethod;
  // カード払いか（カード請求に含まれる＝口座から別途引かない）
  bool get isCardPayment => method.isNotEmpty && method != kManualPayMethod;
  // 支払い方法の表示名
  String get methodLabel => isFromAccount ? '口座振替' : method;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'amount': amount,
        'payDay': payDay,
        'method': method,
      };

  factory Subscription.fromJson(Map<String, dynamic> json) => Subscription(
        id: json['id'],
        title: json['title'],
        amount: json['amount'],
        payDay: json['payDay'],
        method: json['method'] ?? '',
      );
}

// ───────────────────────── ATM引き出し ─────────────────────────
class Withdrawal {
  final String id;
  DateTime date;
  int amount;
  String memo;

  Withdrawal({
    required this.id,
    required this.date,
    required this.amount,
    this.memo = '',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'date': date.toIso8601String(),
        'amount': amount,
        'memo': memo,
      };

  factory Withdrawal.fromJson(Map<String, dynamic> json) => Withdrawal(
        id: json['id'],
        date: DateTime.parse(json['date']),
        amount: json['amount'],
        memo: json['memo'] ?? '',
      );
}

// ───────────────────────── 口座への入金 ─────────────────────────
// 💡 銀行の「振込入金のお知らせ」メール。
//   このメールには金額が載らない（SMBCダイレクトで確認する形式）ため、
//   アプリを開いたときにポップアップで金額を入力してもらう。
class DepositNotice {
  final String sourceId; // メールID（重複表示を防ぐ一意キー）
  final DateTime date; // 入金日（メール受信日時）

  DepositNotice({required this.sourceId, required this.date});

  Map<String, dynamic> toJson() => {
        'sourceId': sourceId,
        'date': date.toIso8601String(),
      };

  factory DepositNotice.fromJson(Map<String, dynamic> json) => DepositNotice(
        sourceId: json['sourceId'] ?? '',
        date: DateTime.parse(json['date']),
      );
}

// ───────────────────── 予定入金 ─────────────────────
// 💡 これから入ってくる予定のお金（仕送り・返金・臨時収入など）。
//   給料はシフトから自動計算するので、それ以外の入金をここに登録する。
class PlannedIncome {
  final String id;
  String title;
  int amount;
  DateTime date; // 入金予定日
  bool monthly; // 毎月繰り返すか

  PlannedIncome({
    required this.id,
    required this.title,
    required this.amount,
    required this.date,
    this.monthly = false,
  });

  // 指定月の入金予定日（毎月繰り返しなら、その月の同じ日）
  DateTime? dateIn(DateTime month) {
    if (!monthly) {
      return (date.year == month.year && date.month == month.month) ? date : null;
    }
    // 繰り返しは登録日以降の月だけ
    if (DateTime(month.year, month.month).isBefore(DateTime(date.year, date.month))) {
      return null;
    }
    final lastDay = DateTime(month.year, month.month + 1, 0).day;
    return DateTime(month.year, month.month, date.day > lastDay ? lastDay : date.day);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'amount': amount,
        'date': date.toIso8601String(),
        'monthly': monthly,
      };

  factory PlannedIncome.fromJson(Map<String, dynamic> json) => PlannedIncome(
        id: json['id'] ?? '',
        title: json['title'] ?? '',
        amount: json['amount'] ?? 0,
        date: DateTime.parse(json['date']),
        monthly: json['monthly'] ?? false,
      );
}

// ───────────────────── 残高の増減履歴 ─────────────────────
// 💡 入金・引き落としを口座残高に反映したときの記録。
//   「いつ・何を・いくら反映したか」を後から確認でき、間違えたら取り消せる。
enum BalanceEntryKind { deposit, draw }

class BalanceEntry {
  final String id;
  final BalanceEntryKind kind;
  final String label; // 勤務先名・カード名・サービス名など
  final int amount; // 正の数（入金は＋、引き落としは−として扱う）
  final DateTime at; // 反映した日時
  final int balanceAfter; // 反映後の口座残高
  final String? workplaceId; // 給料入金のとき、どのバイトか
  final String? sourceKey; // 元の通知ID（取り消し時に再表示するため）

  BalanceEntry({
    required this.id,
    required this.kind,
    required this.label,
    required this.amount,
    required this.at,
    required this.balanceAfter,
    this.workplaceId,
    this.sourceKey,
  });

  // 残高への影響（入金＝＋、引き落とし＝−）
  int get signedAmount => kind == BalanceEntryKind.deposit ? amount : -amount;

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.index,
        'label': label,
        'amount': amount,
        'at': at.toIso8601String(),
        'balanceAfter': balanceAfter,
        'workplaceId': workplaceId,
        'sourceKey': sourceKey,
      };

  factory BalanceEntry.fromJson(Map<String, dynamic> json) => BalanceEntry(
        id: json['id'] ?? '',
        kind: BalanceEntryKind.values[json['kind'] ?? 0],
        label: json['label'] ?? '',
        amount: json['amount'] ?? 0,
        at: DateTime.parse(json['at']),
        balanceAfter: json['balanceAfter'] ?? 0,
        workplaceId: json['workplaceId'],
        sourceKey: json['sourceKey'],
      );
}

// 💡 Appleカレンダー連携のフック。実装は lib/calendar_sync.dart（device_calendar）。
//   AppState はプラットフォーム依存を持たないよう、この抽象だけ参照する（テストでは null）。
abstract class CalendarSyncHook {
  Future<bool> enableAndSyncAll();
  void upsertShift(DateTime date, ShiftData shift);
  void upsertEvent(EventData event);
  void deleteEvent(String calendarEventId);
  // 給料日・引き落とし日などの特殊イベント同期。keyは内部管理用(カレンダーIDを返す)。
  Future<String?> upsertSpecialEvent({
    required String existingCalId,
    required String title,
    required DateTime date,
    required String description,
  });
}

// ════════════════════════ AppState ════════════════════════
class AppState extends ChangeNotifier {
  final Map<String, List<ShiftData>> shifts = {};
  final List<Workplace> workplaces = [];
  final Map<String, List<EventData>> events = {};

  // Appleカレンダー自動連携（ON/OFF）と、その実装フック。
  bool calendarAutoSync = false;
  CalendarSyncHook? calendarSync;
  // 給料日・引き落とし日のカレンダーイベントID（key="payday_WPID_YYYYMM" or "payment_CARDNAME_YYYYMM"）
  final Map<String, String> specialCalendarIds = {};

  // 自動バックアップ
  bool autoBackupEnabled = true;
  DateTime? lastAutoBackupAt;

  // 翌々月の予想残高を表示するか（#3 非表示にできる）
  bool showMonthAfterNext = true;

  // 財布の現金機能を表示するか（設定でON/OFF）
  bool showWalletCash = true;

  // アプリの背景テーマ（グラデーションのキー）。既定はピンク。
  String backgroundTheme = 'pink';

  // 💡 カード別引き落とし日。**初期値をここに埋め込まない**。
  //   埋め込むと (1)既定のカードを二度と削除できない
  //   (2)別端末で消したカードが同期のたびに復活する、という不具合になる。
  //   代わりに、初回起動時だけ下の種をデータとして書き込む。
  Map<String, int> cardPaymentDays = {};

  // 初回起動時にだけ配る初期カード（以後はただのデータ。削除も同期もできる）
  static const Map<String, int> kSeedCardPaymentDays = {
    '三井OLIVE': 26,
    '楽天カード': 29,
    'PayPayカード': 27,
    'Amazonマスター': 26, // 三井と同じ
    'メルカード': 26, // 三井と同じ
  };

  // ───── Googleドライブ同期 ─────
  // 💡 家計データなので「新しい方で黙って上書き」はしない。
  //   dataUpdatedAt（この端末で最後に変更した時刻）と
  //   driveSyncedAt（最後にドライブとそろえた時刻）を比べて
  //   「こちらだけ変わった／向こうだけ変わった／両方変わった」を判定する。
  bool driveSyncEnabled = false;
  // 💡 起動時にGoogleログインを求めるか（ONだとログイン後にドライブから復元される）。
  //   ⚠️ 他人からデータを守る仕組みではない（データはこの端末の中にある）。
  //     端末を他人が触るのを防ぎたいときはパスコードロック（LockService）を使う。
  bool requireGoogleLogin = false;
  DateTime? dataUpdatedAt; // この端末のデータが最後に変わった時刻
  DateTime? driveSyncedAt; // 最後にドライブとそろえた時刻
  DateTime? driveKnownRemoteAt; // そのときのドライブ側の更新時刻

  // 同期の表示に使う端末名（どの端末が書いたか分かるように）
  String get deviceLabel {
    if (kIsWeb) return 'ブラウザ（Web版）';
    return Platform.isIOS ? 'iPhone/iPad' : 'この端末';
  }

  void markDriveSynced({required DateTime localAt, required DateTime remoteAt}) {
    driveSyncedAt = localAt;
    driveKnownRemoteAt = remoteAt;
    _saveDriveSyncState();
    notifyListeners();
  }

  Future<void> setRequireGoogleLogin(bool on) async {
    requireGoogleLogin = on;
    await _saveDriveSyncState();
    notifyListeners();
  }

  Future<void> setDriveSyncEnabled(bool on) async {
    driveSyncEnabled = on;
    await _saveDriveSyncState();
    notifyListeners();
  }

  Future<void> _saveDriveSyncState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('saved_drive_sync_enabled', driveSyncEnabled);
    await prefs.setBool('saved_require_google_login', requireGoogleLogin);
    await prefs.setString('saved_data_updated_at', dataUpdatedAt?.toIso8601String() ?? '');
    await prefs.setString('saved_drive_synced_at', driveSyncedAt?.toIso8601String() ?? '');
    await prefs.setString(
        'saved_drive_remote_at', driveKnownRemoteAt?.toIso8601String() ?? '');
  }

  // 💡 カード別の締め日（1〜28、31＝月末締め）。未設定＝31（従来どおり暦月で集計）。
  //   締め日を月末以外にすると、その月の引き落としは
  //   「前々月の締め日の翌日 〜 前月の締め日」の利用ぶんになる。
  Map<String, int> cardClosingDays = {};

  final Map<String, List<TodoData>> todos = {};
  List<Payment> payments = [];
  List<Installment> installments = [];
  List<Subscription> subscriptions = [];
  List<Loan> loans = [];
  List<Withdrawal> withdrawals = [];

  int currentBalance = 0;
  // 財布の中の現金（手動編集）。口座残高とは別に保持し、予想残高の起点に加える。
  int walletCash = 0;
  // #6 残高を最後に編集した日時。これより後のイベント（デビット/引き落とし/給料）だけ
  //    予測に反映する（編集時点の残高には過去分が既に含まれているため二重計上を防ぐ）。
  DateTime? balanceUpdatedAt;

  // カードごとの分割金利（年率%）
  final Map<String, double> cardInterestRates = {};
  double interestRateOf(String card) => cardInterestRates[card] ?? 15.0;
  void setInterestRate(String card, double rate) {
    cardInterestRates[card] = rate;
    saveData();
    notifyListeners();
  }

  // 初回の全期間取得が済んだか（2回目以降は先月+今月だけ取得）
  bool gmailFirstSyncDone = false;
  void markGmailSynced() {
    if (!gmailFirstSyncDone) {
      gmailFirstSyncDone = true;
      saveData();
    }
  }

  // 分割へ変換済みの明細（再取得で復活させないため）。
  //   dupKey（カード|金額|日時|種別）は日時・金額が変わると外れるので、
  //   メール由来の一意キー(sourceId)でも照合する（削除の墓石と同じ二重構え）。
  final Set<String> convertedPaymentKeys = {};
  final Set<String> convertedSourceIds = {};

  // ───── ゴミ箱（削除した支払い）と墓石（更新で復活させない）─────
  // 削除した支払いを退避するフォルダ（PCのゴミ箱と同じ。復元可能）。
  List<Payment> trashedPayments = [];
  // 更新(Gmail取込)で再追加させないための墓石。
  //   sourceId（メール由来の一意キー）と dupKey（カード|金額|日時|種別）の両方で照合。
  final Set<String> deletedSourceIds = {};
  final Set<String> deletedDupKeys = {};

  AppState() {
    loadData();
  }

  String _formatDate(DateTime date) => DateFormat('yyyy-MM-dd').format(date);

  // 💡 一括追加でも衝突しないユニークID（マイクロ秒＋連番）
  int _idCounter = 0;
  String _id() => '${DateTime.now().microsecondsSinceEpoch}-${_idCounter++}';

  // Appleカレンダー自動連携のON/OFF。ON時は権限取得＋既存を全同期。
  Future<bool> setCalendarAutoSync(bool on) async {
    calendarAutoSync = on;
    saveData();
    notifyListeners();
    if (on && calendarSync != null) {
      final ok = await calendarSync!.enableAndSyncAll();
      if (!ok) {
        // 権限が得られなければOFFへ戻す
        calendarAutoSync = false;
        saveData();
        notifyListeners();
      }
      return ok;
    }
    return true;
  }

  // 給料日・引き落とし日をAppleカレンダーに同期（calendarAutoSyncがONの場合）
  Future<void> syncSpecialEventsToCalendar() async {
    if (!calendarAutoSync || calendarSync == null) return;
    final now = DateTime.now();
    // 前後3か月の給料日
    for (var dm = -1; dm <= 3; dm++) {
      final m = DateTime(now.year, now.month + dm);
      for (final entry in paydaysInMonth(m)) {
        final key = 'payday_${entry.workplace.id}_${DateFormat('yyyyMM').format(m)}';
        final existingId = specialCalendarIds[key] ?? '';
        final title = '💰 給料日（${entry.workplace.name}）';
        final desc = '${m.month}月分 ¥${entry.amount}';
        final calId = await calendarSync!.upsertSpecialEvent(
          existingCalId: existingId,
          title: title,
          date: entry.date,
          description: desc,
        );
        if (calId != null) specialCalendarIds[key] = calId;
      }
    }
    // 直近の引き落とし日（銀行確定・今後の予定）
    final upcoming = payments.where((p) =>
      p.paymentDate.isAfter(DateTime(now.year, now.month - 1))
    );
    final grouped = <String, List<Payment>>{};
    for (final p in upcoming) {
      final k = DateFormat('yyyyMMdd').format(p.paymentDate);
      grouped.putIfAbsent(k, () => []).add(p);
    }
    for (final entry in grouped.entries) {
      final date = DateTime.parse(entry.key.substring(0, 4) + '-' +
          entry.key.substring(4, 6) + '-' + entry.key.substring(6, 8));
      final total = entry.value.fold<int>(0, (s, p) => s + p.amount);
      final cards = entry.value.map((p) => p.cardName).toSet().join('・');
      final key = 'payment_${entry.key}';
      final existingId = specialCalendarIds[key] ?? '';
      final calId = await calendarSync!.upsertSpecialEvent(
        existingCalId: existingId,
        title: '💳 引き落とし（$cards）',
        date: date,
        description: '合計 ¥$total',
      );
      if (calId != null) specialCalendarIds[key] = calId;
    }
    saveData();
  }

  // ───── シフト ─────
  void addShift(DateTime date, ShiftData shift) {
    shifts.putIfAbsent(_formatDate(date), () => []).add(shift);
    saveData();
    notifyListeners();
    if (calendarAutoSync) calendarSync?.upsertShift(date, shift);
  }

  void removeShift(String dateKey, int index) {
    final list = shifts[dateKey];
    final calId = (list != null && index < list.length) ? list[index].calendarEventId : null;
    list?.removeAt(index);
    if (shifts[dateKey]?.isEmpty ?? true) shifts.remove(dateKey);
    saveData();
    notifyListeners();
    if (calendarAutoSync && calId != null) calendarSync?.deleteEvent(calId);
  }

  void updateShift(String dateKey, int index, ShiftData newShift) {
    final list = shifts[dateKey];
    if (list == null || index < 0 || index >= list.length) return;
    final old = list[index];
    newShift.calendarEventId = old.calendarEventId;
    list[index] = newShift;
    saveData();
    notifyListeners();
    if (calendarAutoSync) {
      final date = DateTime.tryParse(dateKey) ?? DateTime.now();
      calendarSync?.upsertShift(date, newShift);
    }
  }

  // 💡 過去のシフトから定型（勤務先＋時刻＋休憩）を新しい順に重複なく抽出。
  //   「履歴から追加」でワンタップ再入力するために使う。
  List<({String? workplaceId, String workplace, int hourlyWage, int startHour, int startMinute, int endHour, int endMinute, int breakMinutes})>
      recentShiftTemplates({int limit = 8}) {
    // 日付キー新しい順に走査
    final keys = shifts.keys.toList()..sort((a, b) => b.compareTo(a));
    final seen = <String>{};
    final out = <({String? workplaceId, String workplace, int hourlyWage, int startHour, int startMinute, int endHour, int endMinute, int breakMinutes})>[];
    for (final k in keys) {
      for (final s in shifts[k]!) {
        final sig = '${s.workplaceId ?? s.workplace}|${s.start.hour}:${s.start.minute}'
            '|${s.end.hour}:${s.end.minute}|${s.breakMinutes}';
        if (!seen.add(sig)) continue;
        out.add((
          workplaceId: s.workplaceId,
          workplace: s.workplace,
          hourlyWage: s.hourlyWage,
          startHour: s.start.hour,
          startMinute: s.start.minute,
          endHour: s.end.hour,
          endMinute: s.end.minute,
          breakMinutes: s.breakMinutes,
        ));
        if (out.length >= limit) return out;
      }
    }
    return out;
  }

  // 💡 複数日のシフトをまとめて追加（繰り返し入力用。保存・通知は1回だけ）
  void addShiftsBulk(Iterable<({DateTime date, ShiftData shift})> entries) {
    for (final e in entries) {
      shifts.putIfAbsent(_formatDate(e.date), () => []).add(e.shift);
    }
    saveData();
    notifyListeners();
    if (calendarAutoSync) {
      for (final e in entries) {
        calendarSync?.upsertShift(e.date, e.shift);
      }
    }
  }

  // ───── 勤務先マスタ ─────
  String newWorkplaceId() => 'wp-${_id()}';

  Workplace? workplaceById(String? id) {
    if (id == null) return null;
    for (final w in workplaces) {
      if (w.id == id) return w;
    }
    return null;
  }

  void addWorkplace(Workplace w) {
    w.sortWagePeriods();
    workplaces.add(w);
    saveData();
    notifyListeners();
  }

  // 既存の勤務先を丸ごと差し替え（編集画面の「保存する」用）
  void updateWorkplace(Workplace w) {
    final i = workplaces.indexWhere((e) => e.id == w.id);
    if (i < 0) return;
    w.sortWagePeriods();
    workplaces[i] = w;
    saveData();
    notifyListeners();
  }

  void removeWorkplace(String id) {
    workplaces.removeWhere((e) => e.id == id);
    // 削除した勤務先に紐づくデータも掃除（入金の選択肢や集計に残らないように）
    actualSalariesByWp.removeWhere((k, _) => k.endsWith('|$id'));
    paidSalaryKeys.removeWhere((k) => k.startsWith('$id|'));
    saveData();
    notifyListeners();
  }

  // 指定日に適用される給料情報（effectiveFrom <= date で最大のもの。null=最古）
  WagePeriod? wagePeriodFor(Workplace w, DateTime date) {
    if (w.wagePeriods.isEmpty) return null;
    final sorted = [...w.wagePeriods]..sort((a, b) {
        if (a.effectiveFrom == null) return -1;
        if (b.effectiveFrom == null) return 1;
        return a.effectiveFrom!.compareTo(b.effectiveFrom!);
      });
    WagePeriod? result;
    for (final p in sorted) {
      final from = p.effectiveFrom;
      if (from == null || !date.isBefore(from)) {
        result = p; // この区間は date 以前に開始 → 候補
      } else {
        break; // 以降は未来の区間
      }
    }
    return result ?? sorted.first;
  }

  // 勤務先＋勤務日＋時刻から、給料情報をスナップショットした ShiftData を生成。
  // 後から勤務先設定を変えても過去のシフト給与は変わらない。
  ShiftData buildShiftFromWorkplace(
    Workplace w,
    DateTime date,
    DateTime start,
    DateTime end, {
    int breakMinutes = 0,
    int? overrideWage,
  }) {
    final period = wagePeriodFor(w, date);
    return ShiftData(
      workplace: w.name,
      workplaceId: w.id,
      hourlyWage: overrideWage ?? period?.hourlyWage ?? 0,
      start: start,
      end: end,
      breakMinutes: breakMinutes,
      transportPerDay: period?.transportPerDay ?? 0,
      transportMonthlyCap: period?.transportMonthlyCap ?? 0,
      nightMultiplier: period?.nightMultiplier ?? 1.0,
      overtimeMultiplier: period?.overtimeMultiplier ?? 1.0,
      holidayMultiplier: period?.holidayMultiplier ?? 1.0,
    );
  }

  // ───── 予定 ─────
  String newEventId() => 'ev-${_id()}';

  void addEvent(DateTime date, EventData event) {
    events.putIfAbsent(_formatDate(date), () => []).add(event);
    saveData();
    notifyListeners();
  }

  // 予定の追加/更新（idで照合）。開始日が変わってもバケットを移動する。
  void upsertEvent(EventData event) {
    // 既存idを全バケットから除去
    events.forEach((k, list) => list.removeWhere((x) => x.id == event.id));
    events.removeWhere((k, list) => list.isEmpty);
    final d = event.start ?? DateTime.now();
    events.putIfAbsent(_formatDate(d), () => []).add(event);
    saveData();
    notifyListeners();
    if (calendarAutoSync) calendarSync?.upsertEvent(event);
  }

  void removeEvent(String dateKey, int index) {
    final list = events[dateKey];
    final calId = (list != null && index < list.length) ? list[index].calendarEventId : null;
    list?.removeAt(index);
    if (events[dateKey]?.isEmpty ?? true) events.remove(dateKey);
    saveData();
    notifyListeners();
    if (calendarAutoSync && calId != null) calendarSync?.deleteEvent(calId);
  }

  // ───── Todo ─────
  void addTodo(TodoData todo) {
    final key = _formatDate(todo.deadline);
    todos.putIfAbsent(key, () => []).add(todo);
    saveData();
    notifyListeners();
  }

  void toggleTodo(TodoData todo) {
    todo.completed = !todo.completed;
    saveData();
    notifyListeners();
  }

  void updateTodo(String oldKey, TodoData todo) {
    todos[oldKey]?.removeWhere((t) => t.id == todo.id);
    if (todos[oldKey]?.isEmpty ?? false) todos.remove(oldKey);
    addTodo(todo);
  }

  void removeTodo(String dateKey, String id) {
    todos[dateKey]?.removeWhere((t) => t.id == id);
    if (todos[dateKey]?.isEmpty ?? true) todos.remove(dateKey);
    saveData();
    notifyListeners();
  }

  List<TodoData> get allTodos =>
      todos.values.expand((list) => list).toList()
        ..sort((a, b) => a.deadline.compareTo(b.deadline));

  // ───── カード支払い ─────
  void addPayment({
    required String cardName,
    required int amount,
    required DateTime date,
    PaymentSource source = PaymentSource.manual,
    String note = '', // 利用先（例: Amazonで購入）
  }) {
    payments.add(Payment(
        id: _id(),
        cardName: cardName,
        amount: amount,
        paymentDate: date,
        source: source,
        note: note.trim()));
    saveData();
    notifyListeners();
  }

  // 💡 メール由来の明細に書いたメモは、次の取り込みで自動データが作り直されると
  //   消えてしまう。sourceId をキーに別で覚えておき、reconcile 後に貼り直す。
  final Map<String, String> paymentNotes = {};

  // ───── Amazonの明細（支払いカードが分からない問題）─────
  // 💡 Amazonの注文・発送メールには「どのカードで払ったか」が書いていない。
  //   既定では Amazonマスター の支出として計上し、
  //   別のカードで払ったと分かったときだけ手で付け替える。
  //   同じカード・同じ日・同じ金額の本物の明細が来たときだけ、
  //   同じ買い物の二重計上になるので infoOnly（記録するが足さない）に落とす。
  // ───── カード名の別名 ─────
  // 💡 銀行の引落確定メールは、カード名を銀行の請求元表記でよこす
  //   （例: 「ミツビシUFJニコス」）。自分が設定で付けた名前（例: 「三菱UFJカード」）
  //   とは一致しないため、同じカードが2つに割れてしまう。
  //   取り込んだ名前 → まとめ先の名前 を覚えて突き合わせる。
  final Map<String, String> cardAliases = {};

  String resolveCardName(String name) => cardAliases[name] ?? name;

  // 💡 設定に登録されていないカード名で入っている明細（＝割れている候補）。
  List<({String name, int count})> get unregisteredCardNames {
    final counts = <String, int>{};
    for (final p in payments) {
      final n = p.cardName.trim();
      if (n.isEmpty || n == kOtherCard) continue;
      if (cardPaymentDays.containsKey(n)) continue;
      counts[n] = (counts[n] ?? 0) + 1;
    }
    final out = [for (final e in counts.entries) (name: e.key, count: e.value)];
    out.sort((a, b) => b.count.compareTo(a.count));
    return out;
  }

  // 💡 割れているカード名を1つにまとめる。既存の明細もその場で付け替える。
  void mergeCardName(String from, String to) {
    if (from == to || from.trim().isEmpty) return;
    cardAliases[from] = to;
    for (final p in payments) {
      if (p.cardName == from) p.cardName = to;
    }
    for (final i in installments) {
      if (i.cardName == from) i.cardName = to;
    }
    for (final s in subscriptions) {
      if (s.method == from) s.method = to;
    }
    // 設定側にも残っていたら消す（まとめ先へ寄せる）
    cardPaymentDays.remove(from);
    cardClosingDays.remove(from);
    saveData();
    _saveCardPaymentDays();
    notifyListeners();
  }

  void unmergeCardName(String from) {
    cardAliases.remove(from);
    saveData();
    notifyListeners();
  }

  static const String kAmazonSourcePrefix = 'amazon#';

  bool isAmazonPayment(Payment p) => p.sourceId.startsWith(kAmazonSourcePrefix);

  // sourceId → 付け替え先のカード名
  final Map<String, String> amazonCardOverrides = {};

  // 💡 同じカード・同じ日・同じ金額の「本物の明細」が既にあるか。
  //   あるならカード会社の通知が来たということなので、手の付け替えは不要になる。
  bool _hasRealChargeLike(String card, DateTime date, int amount,
      {String? exceptId}) {
    final day = _formatDate(date);
    return payments.any((p) =>
        p.id != exceptId &&
        !isAmazonPayment(p) &&
        p.cardName == card &&
        p.amount == amount &&
        _formatDate(p.paymentDate) == day);
  }

  // 💡 Amazonの明細を「実際に使ったカード」へ付け替える。
  //   すでに同じ日・同じ金額の明細がそのカードにあるなら、二重になるので付け替えない。
  //   戻り値: 付け替えたら true、重複していて見送ったら false。
  bool moveAmazonPaymentTo(String paymentId, String cardName) {
    final i = payments.indexWhere((e) => e.id == paymentId);
    if (i < 0) return false;
    final p = payments[i];
    if (!isAmazonPayment(p)) return false;

    if (_hasRealChargeLike(cardName, p.paymentDate, p.amount, exceptId: p.id)) {
      // カード会社の通知で既に計上済み。付け替えを取り消して情報のみに戻す。
      amazonCardOverrides.remove(p.sourceId);
      p.cardName = 'Amazonマスター';
      p.infoOnly = true;
      saveData();
      notifyListeners();
      return false;
    }

    amazonCardOverrides[p.sourceId] = cardName;
    p.cardName = cardName;
    p.infoOnly = false;
    saveData();
    notifyListeners();
    return true;
  }


  void setPaymentNote(String paymentId, String note) {
    final i = payments.indexWhere((p) => p.id == paymentId);
    if (i < 0) return;
    final p = payments[i];
    p.note = note.trim();
    if (p.sourceId.isNotEmpty) {
      if (p.note.isEmpty) {
        paymentNotes.remove(p.sourceId);
      } else {
        paymentNotes[p.sourceId] = p.note;
      }
    }
    saveData();
    notifyListeners();
  }

  // 同じカード名・金額・日付の支払いが既にあるか
  bool hasPayment(String cardName, int amount, DateTime date) {
    return payments.any((p) =>
        p.cardName == cardName &&
        p.amount == amount &&
        _formatDate(p.paymentDate) == _formatDate(date));
  }

  String _ym(DateTime d) => '${d.year}-${d.month}';

  // 重複判定キー: カード＋金額＋利用日時＋種別。
  //   利用日時の「時刻」まで含むので、同額・同日でも時刻が違えば別取引として残る。
  //   時刻が無い（00:00）同内容は1件に統合される。
  String _dupKey(String card, int amount, DateTime date, PaymentSource source) =>
      '$card|$amount|${date.toIso8601String()}|${source.index}';

  // 💡 すでに分割払いへ登録済みの決済と一致するか（カード・金額・利用日が同じ）。
  //   分割に移した明細がGmail再取得で復活して二重計上になるのを防ぐ。
  //   ＝分割払いは元の決済そのものなので、カード側にも残ると同じ買い物を2回計上してしまう。
  bool _matchesInstallment(String card, int amount, DateTime date) {
    return installments.any((i) =>
        i.cardName == card &&
        i.totalAmount == amount &&
        i.startDate != null &&
        _formatDate(i.startDate!) == _formatDate(date));
  }

  // 💡 分割払いへ移したはずの決済がカード側にも残っていたら取り除く（二重計上の自己修復）。
  //   旧バージョンで変換した明細は sourceId の記録が無く復活しうるため、
  //   起動時と取り込み時に既存の分割払いと突き合わせて掃除する。手動追加は対象外。
  int cleanupInstallmentDuplicates() {
    if (installments.isEmpty) return 0;
    final before = payments.length;
    payments.removeWhere((p) =>
        p.source != PaymentSource.manual &&
        _matchesInstallment(p.cardName, p.amount, p.paymentDate));
    return before - payments.length;
  }


  // 💡 Gmail取り込みの完全同期。
  //   取得結果(items)を「正本」とし、自動取り込み分(非manual)を丸ごと作り直す。
  //   ・重複は「カード＋金額＋利用日時」で1件に統合
  //   ・銀行確定(bank)が同カード・同月の請求予定(billing)を上書き
  //   ・同月・同額で他カードとAmazonマスターが重複したらAmazon側を削除
  //   ・支払済み(paid)は引き継ぎ、手動追加(manual)・変換済みは保持
  //   戻り値は (追加, 削除)。
  ({int added, int removed}) reconcilePayments(
      Iterable<({String cardName, int amount, DateTime date, PaymentSource source, String sourceId, String note})> rawItems,
      {DateTime? since}) {
    bool inWindow(DateTime d) => since == null || !d.isBefore(since);

    // 💡 銀行表記などの別名を、自分が付けたカード名に寄せてから照合する
    final items = rawItems.map((it) => (
          cardName: resolveCardName(it.cardName),
          amount: it.amount,
          date: it.date,
          source: it.source,
          sourceId: it.sourceId,
          note: it.note,
        ));

    // 銀行確定があるカード月（請求予定を抑制）
    final bankKeys = <String>{};
    for (final it in items.where((e) => e.source == PaymentSource.bank)) {
      bankKeys.add('${it.cardName}|${_ym(it.date)}');
    }

    // 望ましい自動集合を構築（重複・変換済み・銀行に上書きされた予測を除外）
    final desired = <({String cardName, int amount, DateTime date, PaymentSource source, String sourceId, String note})>[];
    final seen = <String>{};
    for (final it in items) {
      if (!inWindow(it.date)) continue;
      final key = _dupKey(it.cardName, it.amount, it.date, it.source);
      // 💡 分割へ移動済みは復活させない。dupKey（日時・金額が変われば外れる）に加え、
      //   sourceId と「既存の分割払いと一致するか」でも照合して取りこぼしを防ぐ。
      if (convertedPaymentKeys.contains(key)) continue;
      if (it.sourceId.isNotEmpty && convertedSourceIds.contains(it.sourceId)) continue;
      if (_matchesInstallment(it.cardName, it.amount, it.date)) continue;
      // 💡 ユーザーが削除した明細は更新で復活させない（墓石照合）。
      if (deletedDupKeys.contains(key)) continue;
      if (it.sourceId.isNotEmpty && deletedSourceIds.contains(it.sourceId)) continue;
      if (it.source == PaymentSource.billing &&
          bankKeys.contains('${it.cardName}|${_ym(it.date)}')) {
        continue; // 銀行確定が優先
      }
      if (!seen.add(key)) continue; // 同内容（同時刻）は1件に統合
      desired.add(it);
    }

    // 💡 手動追加と「同じカード・同じ年月日・同じ金額」の正式取り込み(メール確認)が来たら、
    //   重複しないよう手動の方を削除し、正式の明細に置き換える（メール受信が遅いカード対策）。
    String dayKey(String card, int amount, DateTime d) =>
        '$card|${_formatDate(d)}|$amount';
    final officialDayKeys = <String>{
      for (final it in desired) dayKey(it.cardName, it.amount, it.date),
    };
    payments.removeWhere((p) =>
        p.source == PaymentSource.manual &&
        officialDayKeys.contains(dayKey(p.cardName, p.amount, p.paymentDate)));

    // 既存の自動データ（取得期間内のみ）: paid を引き継ぐ
    final paidByKey = <String, bool>{};
    final beforeKeys = <String>{};
    for (final p in payments
        .where((p) => p.source != PaymentSource.manual && inWindow(p.paymentDate))) {
      final k = _dupKey(p.cardName, p.amount, p.paymentDate, p.source);
      paidByKey[k] = p.paid;
      beforeKeys.add(k);
    }

    // 自動データを総入れ替え（取得期間内のみ。期間外の過去データは保持）
    payments.removeWhere((p) => p.source != PaymentSource.manual && inWindow(p.paymentDate));
    final desiredKeys = <String>{};
    for (final it in desired) {
      final k = _dupKey(it.cardName, it.amount, it.date, it.source);
      desiredKeys.add(k);
      // 💡 Amazonは既定どおり Amazonマスター として計上する。
      //   手で付け替えてあればそのカードへ。
      //   ただし同じカード・同じ日・同じ金額の本物の明細が既にあるときだけは、
      //   同じ買い物を二度数えることになるので「記録のみ」に落とす。
      var card = it.cardName;
      var infoOnly = false;
      if (it.sourceId.startsWith(kAmazonSourcePrefix)) {
        card = amazonCardOverrides[it.sourceId] ?? it.cardName;
        final duplicated = desired.any((o) =>
            !o.sourceId.startsWith(kAmazonSourcePrefix) &&
            o.cardName == card &&
            o.amount == it.amount &&
            _formatDate(o.date) == _formatDate(it.date));
        if (duplicated) {
          infoOnly = true;
          amazonCardOverrides.remove(it.sourceId);
          card = it.cardName; // Amazonマスターの記録として残す
        }
      }
      payments.add(Payment(
        id: _id(),
        cardName: card,
        amount: it.amount,
        paymentDate: it.date,
        source: it.source,
        paid: paidByKey[k] ?? false,
        sourceId: it.sourceId,
        // 手で書いたメモがあれば、メール由来の利用先より優先して残す
        note: paymentNotes[it.sourceId] ?? it.note,
        infoOnly: infoOnly,
      ));
    }

    // 💡 Amazon発送(kind=usage・情報のみ)は他カードのAmazon利用と重複しても削除しない。
    //   残高は各カードの請求/引落で計上するため二重計上は起きず、全件をそのまま表示する。
    cleanupInstallmentDuplicates(); // 分割へ移した決済が残っていれば取り除く
    final added = desiredKeys.difference(beforeKeys).length;
    final removed = beforeKeys.difference(desiredKeys).length;
    saveData();
    notifyListeners();
    return (added: added, removed: removed);
  }


  void togglePaid(String id) {
    final p = payments.firstWhere((e) => e.id == id);
    p.paid = !p.paid;
    saveData();
    notifyListeners();
  }

  // 削除＝ゴミ箱へ退避＋墓石を記録（更新で復活しない）。
  void removePayment(String id) {
    final idx = payments.indexWhere((e) => e.id == id);
    if (idx < 0) return;
    final p = payments[idx];
    trashedPayments.insert(0, p); // 新しい削除を先頭に
    if (p.sourceId.isNotEmpty) deletedSourceIds.add(p.sourceId);
    deletedDupKeys.add(_dupKey(p.cardName, p.amount, p.paymentDate, p.source));
    payments.removeAt(idx);
    saveData();
    notifyListeners();
  }

  // ゴミ箱から復元（墓石も解除し、再び更新対象に戻す）。
  void restorePayment(String id) {
    final idx = trashedPayments.indexWhere((e) => e.id == id);
    if (idx < 0) return;
    final p = trashedPayments.removeAt(idx);
    deletedSourceIds.remove(p.sourceId);
    deletedDupKeys.remove(_dupKey(p.cardName, p.amount, p.paymentDate, p.source));
    payments.add(p);
    saveData();
    notifyListeners();
  }

  // ゴミ箱から完全削除（墓石は残す＝更新でも復活させない）。
  void deleteFromTrash(String id) {
    trashedPayments.removeWhere((e) => e.id == id);
    saveData();
    notifyListeners();
  }

  // ゴミ箱を空にする（墓石は残す）。
  void emptyTrash() {
    trashedPayments.clear();
    saveData();
    notifyListeners();
  }

  // ───── 分割払い ─────
  void addInstallment({
    required String name,
    required int totalAmount,
    required int count,
    String cardName = '',
    double interestRate = 0,
    DateTime? startDate,
  }) {
    final start = startDate ?? DateTime.now();
    // 💡 同一取引の二重登録を防止（カード・総額・回数・利用日が同じものは追加しない）。
    final dup = installments.any((i) =>
        i.cardName == cardName &&
        i.totalAmount == totalAmount &&
        i.installmentCount == count &&
        i.startDate != null &&
        _formatDate(i.startDate!) == _formatDate(start));
    if (dup) return;
    installments.add(Installment(
      id: _id(),
      name: name,
      cardName: cardName,
      totalAmount: totalAmount,
      installmentCount: count,
      remainingMonths: count,
      monthlyAmount: computeInstallmentMonthly(totalAmount, count, interestRate),
      interestRate: interestRate,
      startDate: start,
    ));
    saveData();
    notifyListeners();
  }

  // カード規則を考慮した実効金利（Amazonの2・3回は無料）
  double effectiveRateFor(String cardName, int count) =>
      isInstallmentInterestFree(cardName, count) ? 0.0 : interestRateOf(cardName);

  // 💡 経過した引落回数から「残り回数」を動的に算出。
  //   利用日(startDate)から引落日ルールで各回の引落日を出し、今日までに過ぎた回数を引く。
  int remainingMonthsOf(Installment i) {
    final start = i.startDate;
    if (start == null) return i.remainingMonths; // 旧データは保存値を使用
    final now = DateTime.now();
    var paid = 0;
    for (var k = 0; k < i.installmentCount; k++) {
      // 各回の引落日を正確に算出（土日調整も各回ごと）。過ぎた回数を「支払済み」に。
      final d = debitDateForNth(i.cardName, start, k);
      if (!d.isAfter(now)) paid++;
    }
    return (i.installmentCount - paid).clamp(0, i.installmentCount);
  }

  // 回数を編集して月額を再計算（金利はカード規則で自動判定）
  void editInstallment(String id, {required int count, String? cardName}) {
    final inst = installments.firstWhere((e) => e.id == id);
    if (cardName != null) inst.cardName = cardName;
    inst.installmentCount = count;
    inst.remainingMonths = count;
    inst.interestRate = effectiveRateFor(inst.cardName, count);
    inst.monthlyAmount =
        computeInstallmentMonthly(inst.totalAmount, count, inst.interestRate);
    saveData();
    notifyListeners();
  }

  void removeInstallment(String id) {
    installments.removeWhere((e) => e.id == id);
    saveData();
    notifyListeners();
  }

  // 💡 カード請求を分割払いへ変換（カードからは外す）。金利はそのカードの設定値。
  void convertPaymentToInstallment(String paymentId, int count) {
    final idx = payments.indexWhere((e) => e.id == paymentId);
    if (idx < 0) return;
    final p = payments[idx];
    if (!canInstallment(p.cardName, p.amount)) return; // 最低金額未満は不可
    final rate = effectiveRateFor(p.cardName, count);
    // 再取得で復活しないよう変換済みとして記録。
    //   dupKey は日時・金額が変わると外れるため、sourceId でも記録する。
    //   （例: Amazonは発送メールの受信日時が日付になるので、再同期で時刻がズレうる）
    convertedPaymentKeys.add(_dupKey(p.cardName, p.amount, p.paymentDate, p.source));
    if (p.sourceId.isNotEmpty) convertedSourceIds.add(p.sourceId);
    addInstallment(
      name: '${p.cardName} (${_formatDate(p.paymentDate)})',
      totalAmount: p.amount,
      count: count,
      cardName: p.cardName,
      interestRate: rate,
      startDate: p.paymentDate,
    );
    payments.removeAt(idx);
    saveData();
    notifyListeners();
  }

  // ───── 定期支払い ─────
  void addSubscription({
    required String title,
    required int amount,
    required int payDay,
    String method = '',
  }) {
    subscriptions.add(Subscription(
        id: _id(), title: title, amount: amount, payDay: payDay, method: method));
    saveData();
    notifyListeners();
  }

  // 定期支払いの支払い方法を変更（口座振替 / カード名）
  void setSubscriptionMethod(String id, String method) {
    final i = subscriptions.indexWhere((e) => e.id == id);
    if (i < 0) return;
    subscriptions[i].method = method;
    saveData();
    notifyListeners();
  }

  void removeSubscription(String id) {
    subscriptions.removeWhere((e) => e.id == id);
    saveData();
    notifyListeners();
  }

  // ───── ATM引き出し ─────
  void addWithdrawal({required DateTime date, required int amount, String memo = ''}) {
    withdrawals.add(Withdrawal(id: _id(), date: date, amount: amount, memo: memo));
    saveData();
    notifyListeners();
  }

  void removeWithdrawal(String id) {
    withdrawals.removeWhere((e) => e.id == id);
    saveData();
    notifyListeners();
  }

  void updateBalance(int balance) {
    currentBalance = balance;
    balanceUpdatedAt = DateTime.now(); // #6 編集日時を記録
    saveData();
    notifyListeners();
  }

  void updateWalletCash(int amount) {
    walletCash = amount;
    saveData();
    notifyListeners();
  }

  // ════════════ 予定入金 ════════════
  List<PlannedIncome> plannedIncomes = [];
  // 受け取り済みの予定入金（キー: "id|yyyy-MM"）
  final Set<String> receivedPlannedKeys = {};

  String _plannedKey(String id, DateTime date) =>
      '$id|${DateFormat('yyyy-MM').format(date)}';

  void addPlannedIncome(
      {required String title, required int amount, required DateTime date, bool monthly = false}) {
    plannedIncomes.add(PlannedIncome(
        id: _id(), title: title, amount: amount, date: date, monthly: monthly));
    saveData();
    notifyListeners();
  }

  void updatePlannedIncome(String id,
      {String? title, int? amount, DateTime? date, bool? monthly}) {
    final i = plannedIncomes.indexWhere((e) => e.id == id);
    if (i < 0) return;
    final p = plannedIncomes[i];
    if (title != null) p.title = title;
    if (amount != null) p.amount = amount;
    if (date != null) p.date = date;
    if (monthly != null) p.monthly = monthly;
    saveData();
    notifyListeners();
  }

  void removePlannedIncome(String id) {
    plannedIncomes.removeWhere((e) => e.id == id);
    receivedPlannedKeys.removeWhere((k) => k.startsWith('$id|'));
    saveData();
    notifyListeners();
  }

  // 指定月に入る予定の入金（まだ受け取っていないもの）
  List<({PlannedIncome income, DateTime date})> plannedIncomesIn(DateTime month) {
    final out = <({PlannedIncome income, DateTime date})>[];
    for (final p in plannedIncomes) {
      final d = p.dateIn(month);
      if (d == null) continue;
      if (receivedPlannedKeys.contains(_plannedKey(p.id, d))) continue;
      out.add((income: p, date: d));
    }
    out.sort((a, b) => a.date.compareTo(b.date));
    return out;
  }

  // 指定日の予定入金（カレンダー表示用・受け取り済みも含む）
  List<PlannedIncome> plannedIncomesOnDay(DateTime date) {
    final day = DateTime(date.year, date.month, date.day);
    return plannedIncomes.where((p) => p.dateIn(day) == day).toList();
  }

  // 予測に足す予定入金（残高編集日より後のものだけ）
  int plannedIncomeForecastIn(DateTime month) => plannedIncomesIn(month)
      .where((e) => _forecastInclude(e.date))
      .fold(0, (s, e) => s + e.income.amount);

  // 予定日が過ぎて、まだ受け取っていない入金
  List<({PlannedIncome income, DateTime date})> get duePlannedIncomes {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final oldest = today.subtract(const Duration(days: 62));
    final out = <({PlannedIncome income, DateTime date})>[];
    for (var back = 0; back < 3; back++) {
      for (final e in plannedIncomesIn(DateTime(now.year, now.month - back))) {
        if (e.date.isAfter(today) || e.date.isBefore(oldest)) continue;
        out.add(e);
      }
    }
    out.sort((a, b) => a.date.compareTo(b.date));
    return out;
  }

  // 予定入金を受け取った → 残高に加算して履歴に残す
  void receivePlannedIncome(String id, int amount, DateTime date) {
    final p = plannedIncomes.firstWhere((e) => e.id == id,
        orElse: () => PlannedIncome(id: '', title: '入金', amount: 0, date: date));
    receivedPlannedKeys.add(_plannedKey(id, date));
    if (amount > 0) {
      currentBalance += amount;
      balanceUpdatedAt = DateTime.now();
      _recordBalanceEntry(
        kind: BalanceEntryKind.deposit,
        label: p.title.isEmpty ? '予定入金' : p.title,
        amount: amount,
      );
    }
    saveData();
    notifyListeners();
  }

  // 予定入金を「受け取らなかった」ことにする（残高は変えない）
  void skipPlannedIncome(String id, DateTime date) {
    receivedPlannedKeys.add(_plannedKey(id, date));
    saveData();
    notifyListeners();
  }

  // ════════════ 残高の増減履歴 ════════════
  List<BalanceEntry> balanceHistory = [];

  // 💡 給料を受け取り済みの「勤務先×支払月」（キー: "wpId|yyyy-MM"）。
  //   入金の選択肢から、もう入金済みのバイトを外すために使う。
  final Set<String> paidSalaryKeys = {};
  // この月までの給料はすべて受け取り済みとみなす（初期移行用）。
  DateTime? salaryPaidThroughMonth;

  String _paidKey(String wpId, DateTime payDate) =>
      '$wpId|${DateFormat('yyyy-MM').format(payDate)}';

  // その勤務先の、その支払月の給料をもう受け取っているか
  bool isSalaryPaid(String wpId, DateTime payDate) {
    final through = salaryPaidThroughMonth;
    if (through != null) {
      final m = DateTime(payDate.year, payDate.month);
      if (!m.isAfter(DateTime(through.year, through.month))) return true;
    }
    return paidSalaryKeys.contains(_paidKey(wpId, payDate));
  }

  // 入金の選択肢に出す勤務先（もう受け取った分は除く）
  List<Workplace> workplacesAwaitingSalary(DateTime payDate) =>
      workplaces.where((w) => !isSalaryPaid(w.id, payDate)).toList();

  void _recordBalanceEntry({
    required BalanceEntryKind kind,
    required String label,
    required int amount,
    String? workplaceId,
    String? sourceKey,
  }) {
    balanceHistory.insert(
      0,
      BalanceEntry(
        id: _id(),
        kind: kind,
        label: label,
        amount: amount,
        at: DateTime.now(),
        balanceAfter: currentBalance,
        workplaceId: workplaceId,
        sourceKey: sourceKey,
      ),
    );
    // 履歴が増えすぎないよう直近300件まで
    if (balanceHistory.length > 300) {
      balanceHistory = balanceHistory.sublist(0, 300);
    }
  }

  // 💡 過去の入金・引き落としを履歴だけに書き足す（残高は変えない）。
  //   履歴機能を付ける前に反映した分を、後から記録として残すために使う。
  void addPastBalanceEntry({
    required BalanceEntryKind kind,
    required String label,
    required int amount,
    required DateTime at,
    String? workplaceId,
  }) {
    if (amount <= 0) return;
    balanceHistory.add(BalanceEntry(
      id: _id(),
      kind: kind,
      label: label,
      amount: amount,
      at: at,
      balanceAfter: currentBalance, // 残高は動かさない（記録のみ）
      workplaceId: workplaceId,
    ));
    balanceHistory.sort((a, b) => b.at.compareTo(a.at)); // 新しい順
    saveData();
    notifyListeners();
  }

  // 💡 履歴を取り消して残高を元に戻す（入力ミスの修正用）。
  //   元の通知も未処理に戻すので、もう一度入力し直せる。
  void undoBalanceEntry(String entryId) {
    final i = balanceHistory.indexWhere((e) => e.id == entryId);
    if (i < 0) return;
    final e = balanceHistory[i];
    currentBalance -= e.signedAmount; // 反映を打ち消す
    balanceUpdatedAt = DateTime.now();
    balanceHistory.removeAt(i);
    final key = e.sourceKey;
    if (key != null && key.isNotEmpty) {
      handledDrawIds.remove(key);
      handledDepositIds.remove(key);
      pendingDeposits.removeWhere((d) => d.sourceId == key);
    }
    // 給料入金の取り消しなら「受け取り済み」も解除
    final wp = e.workplaceId;
    if (wp != null) {
      paidSalaryKeys.remove(_paidKey(wp, e.at));
      paidSalaryKeys.removeWhere((k) => k.startsWith('$wp|'));
    }
    saveData();
    notifyListeners();
  }

  // ════════════ 口座への入金 ════════════
  // 未処理の入金通知（アプリ起動時にポップアップで金額を聞く）
  List<DepositNotice> pendingDeposits = [];
  // 入力済み/スキップ済みのメールID（同じ通知を何度も出さない）
  final Set<String> handledDepositIds = {};

  // 💡 入金を口座残高へ加算する（手入力・通知どちらも共通）。
  //   残高の編集日時も更新するので、この入金が予想残高で二重計上されない。
  void addDeposit(int amount, {String? workplaceId, DateTime? date, String? sourceKey}) {
    if (amount == 0) return;
    currentBalance += amount;
    balanceUpdatedAt = DateTime.now();
    final d = date ?? DateTime.now();
    // バイトの給料として入力された場合は、その労働月の実給料にも反映する
    final w = workplaceById(workplaceId);
    if (w != null) {
      setActualSalaryOfWorkplace(workMonthForPayday(w, d), w.id, amount);
      paidSalaryKeys.add(_paidKey(w.id, d)); // この月はもう受け取った
    }
    _recordBalanceEntry(
      kind: BalanceEntryKind.deposit,
      label: w?.name ?? 'その他の入金',
      amount: amount,
      workplaceId: w?.id,
      sourceKey: sourceKey,
    );
    saveData();
    notifyListeners();
  }

  // 給料日(payDate)に受け取る給料は、どの月の労働分か
  DateTime workMonthForPayday(Workplace w, DateTime payDate) =>
      DateTime(payDate.year, payDate.month - w.paydayMonthOffset);

  // 💡 その日が給料日にあたる勤務先（土日ズレを見込んで前後 tolerance 日まで許容）。
  //   入金通知のポップアップで「どのバイトの給料か」を推測するために使う。
  List<Workplace> workplacesWithPaydayNear(DateTime date, {int tolerance = 3}) {
    final matched = <({Workplace w, int diff})>[];
    final target = DateTime(date.year, date.month, date.day);
    for (final w in workplaces) {
      // 土日祝の調整を反映した「実際の給料日」と比べる
      final payday = w.paydayIn(DateTime(date.year, date.month));
      final diff = target.difference(payday).inDays.abs();
      if (diff <= tolerance) matched.add((w: w, diff: diff));
    }
    matched.sort((a, b) => a.diff.compareTo(b.diff)); // 近い順
    return matched.map((e) => e.w).toList();
  }

  // メールから見つけた入金通知を取り込む（処理済み・既存は無視）
  int addDepositNotices(Iterable<({String sourceId, DateTime date})> notices) {
    var added = 0;
    for (final n in notices) {
      if (n.sourceId.isEmpty) continue;
      if (handledDepositIds.contains(n.sourceId)) continue;
      if (pendingDeposits.any((e) => e.sourceId == n.sourceId)) continue;
      pendingDeposits.add(DepositNotice(sourceId: n.sourceId, date: n.date));
      added++;
    }
    if (added > 0) {
      pendingDeposits.sort((a, b) => a.date.compareTo(b.date));
      saveData();
      notifyListeners();
    }
    return added;
  }

  // 入金通知に金額を入力して残高へ反映
  void applyDepositNotice(String sourceId, int amount, {String? workplaceId}) {
    final idx = pendingDeposits.indexWhere((e) => e.sourceId == sourceId);
    final date = idx >= 0 ? pendingDeposits[idx].date : DateTime.now();
    if (idx >= 0) pendingDeposits.removeAt(idx);
    handledDepositIds.add(sourceId);
    addDeposit(amount, workplaceId: workplaceId, date: date, sourceKey: sourceId);
  }

  // ════════════ 口座からの引き落とし ════════════
  // 反映済み/スキップ済みの引き落としID（同じものを何度も聞かない）
  final Set<String> handledDrawIds = {};

  // 💡 まだ口座残高に反映していない引き落とし。
  //   ・銀行の引き落とし事前お知らせ（金額つき）で、引き落とし日が過ぎたもの
  //   ・口座振替の定期支払いで、支払日が過ぎたもの
  //   残高を編集した日より後のものだけが対象（それ以前は残高に反映済みとみなす）。
  List<({String id, String label, int amount, DateTime date})> get pendingDraws {
    final out = <({String id, String label, int amount, DateTime date})>[];
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    // 💡 対象は「直近2か月以内に引き落とし日が過ぎたもの」。
    //   残高の編集日では絞らない（入金を反映すると編集日が今日になり、
    //   それ以前の引き落としが消えてしまうため）。重複は handledDrawIds で防ぐ。
    final oldest = today.subtract(const Duration(days: 62));
    bool inWindow(DateTime d) => !d.isAfter(today) && !d.isBefore(oldest);

    // ① 銀行確定の引き落とし（カードごと・金額はメールに載っている）
    final bankDone = <String>{}; // 「カード|yyyy-MM」= 事前お知らせが来ている
    for (final p in payments) {
      if (p.source != PaymentSource.bank) continue;
      bankDone.add('${p.cardName}|${DateFormat('yyyy-MM').format(p.paymentDate)}');
      if (!inWindow(p.paymentDate)) continue;
      final id = 'bank:${p.sourceId.isNotEmpty ? p.sourceId : _dupKey(p.cardName, p.amount, p.paymentDate, p.source)}';
      if (handledDrawIds.contains(id)) continue;
      out.add((id: id, label: p.cardName, amount: p.amount, date: p.paymentDate));
    }

    // ①' 事前お知らせメールが来ていないカードは、設定した引き落とし日で知らせる。
    //   金額は前月の利用合計から見込みで出す（ダイアログで直せる）。
    for (final e in cardPaymentDays.entries) {
      final card = e.key;
      for (var back = 0; back < 3; back++) {
        final m = DateTime(now.year, now.month - back);
        final date = cardDrawDateOf(card, m); // 土日祝は翌営業日
        if (!inWindow(date)) continue;
        final ym = DateFormat('yyyy-MM').format(date);
        if (bankDone.contains('$card|$ym')) continue; // 事前お知らせ優先
        // 引き落とし額＝前月の利用分
        final amount = paymentTotalsByCardOf(DateTime(m.year, m.month - 1))[card] ?? 0;
        if (amount <= 0) continue;
        final id = 'card:$card:$ym';
        if (handledDrawIds.contains(id)) continue;
        out.add((id: id, label: '$card（予定）', amount: amount, date: date));
      }
    }

    // ② 口座振替＋手動払いの定期支払い（直近3か月ぶんを確認）。
    //   カード払いはカード請求に含まれるので対象外。
    //   一度「引く」か「スキップ」した月は handledDrawIds に入り、二度と出ない。
    for (final sub in subscriptions.where((e) => !e.isCardPayment)) {
      for (var back = 0; back < 3; back++) {
        final m = DateTime(now.year, now.month - back);
        final lastDay = DateTime(m.year, m.month + 1, 0).day;
        final day = sub.payDay > lastDay ? lastDay : sub.payDay;
        final date = DateTime(m.year, m.month, day);
        if (!inWindow(date)) continue;
        final id = 'sub:${sub.id}:${DateFormat('yyyy-MM').format(m)}';
        if (handledDrawIds.contains(id)) continue;
        final label = sub.isManualPay ? '${sub.title}（手動）' : sub.title;
        out.add((id: id, label: label, amount: sub.amount, date: date));
      }
    }

    out.sort((a, b) => a.date.compareTo(b.date)); // 古い順
    return out;
  }

  // 💡 引き落としを口座残高から引く（残高の編集日時も更新するので二重計上しない）
  void applyDraw(String id, int amount, {String? label}) {
    if (amount != 0) {
      currentBalance -= amount;
      balanceUpdatedAt = DateTime.now();
      _recordBalanceEntry(
        kind: BalanceEntryKind.draw,
        label: label ?? '引き落とし',
        amount: amount,
        sourceKey: id,
      );
    }
    handledDrawIds.add(id);
    saveData();
    notifyListeners();
  }

  // 引き落としをスキップ（残高は変えない。同じものは二度と出さない）
  void skipDraw(String id) {
    handledDrawIds.add(id);
    saveData();
    notifyListeners();
  }

  // 未反映の引き落としをまとめてスキップ（過去分の一括整理用）
  void skipAllDraws() {
    for (final d in pendingDraws) {
      handledDrawIds.add(d.id);
    }
    saveData();
    notifyListeners();
  }

  // 口座からの支払いを手入力で引く（引き落とし・現金払いなど）
  void subtractFromBalance(int amount, {String label = '手入力'}) {
    if (amount == 0) return;
    currentBalance -= amount;
    balanceUpdatedAt = DateTime.now();
    _recordBalanceEntry(
      kind: BalanceEntryKind.draw,
      label: label,
      amount: amount,
    );
    saveData();
    notifyListeners();
  }

  // 入金通知をスキップ（残高は変えない。同じ通知は二度と出さない）
  void skipDepositNotice(String sourceId) {
    pendingDeposits.removeWhere((e) => e.sourceId == sourceId);
    handledDepositIds.add(sourceId);
    saveData();
    notifyListeners();
  }

  // ════════════════ 集計・残高予測 ════════════════

  // 指定月のシフト一覧を集める
  List<ShiftData> _shiftsInMonth(DateTime month) {
    final prefix = DateFormat('yyyy-MM').format(month);
    final out = <ShiftData>[];
    shifts.forEach((dateStr, list) {
      if (dateStr.startsWith(prefix)) out.addAll(list);
    });
    return out;
  }

  // 勤務先キー（workplaceId 優先、無ければ名前）
  String _shiftKey(ShiftData s) => s.workplaceId ?? 'name:${s.workplace}';

  // シフト群を勤務先ごとに集計し、交通費の月上限を適用した金額を返す。
  // 返り値: 勤務先キー → 給与合計（賃金＋上限適用後の交通費）
  Map<String, int> _aggregateByWorkplace(Iterable<ShiftData> list) {
    final wage = <String, int>{};
    final transport = <String, int>{};
    final cap = <String, int>{};
    for (final s in list) {
      final k = _shiftKey(s);
      wage[k] = (wage[k] ?? 0) + s.wageEarnings;
      transport[k] = (transport[k] ?? 0) + s.transportPerDay;
      if (s.transportMonthlyCap > 0 && s.transportMonthlyCap > (cap[k] ?? 0)) {
        cap[k] = s.transportMonthlyCap;
      }
    }
    final result = <String, int>{};
    for (final k in {...wage.keys, ...transport.keys}) {
      var t = transport[k] ?? 0;
      final c = cap[k] ?? 0;
      if (c > 0 && t > c) t = c; // 月上限を適用
      result[k] = (wage[k] ?? 0) + t;
    }
    return result;
  }

  // 指定月のシフト給与合計（交通費の月上限を適用）。＝給料見込み。
  int salaryOf(DateTime month) =>
      _aggregateByWorkplace(_shiftsInMonth(month)).values.fold(0, (s, v) => s + v);

  // 指定月の総労働時間（実働の合計・休憩除く）
  double workHoursOf(DateTime month) =>
      _shiftsInMonth(month).fold(0.0, (s, e) => s + e.workHours);

  // 指定月・勤務先名ごとの総労働時間（収入内訳の凡例用。ラベル＝勤務先名）
  double workHoursOfWorkplace(DateTime month, String workplaceName) =>
      _shiftsInMonth(month)
          .where((s) => (workplaceById(s.workplaceId)?.name ?? s.workplace) == workplaceName)
          .fold(0.0, (sum, s) => sum + s.workHours);

  // #3 指定月の勤務先ごとの収入詳細（キー・名前・色・見込み・実給料・労働時間）。
  List<({String key, String name, int colorValue, int estimated, int? actual, double hours})>
      incomeByWorkplaceOf(DateTime month) {
    final monthShifts = _shiftsInMonth(month);
    final est = _aggregateByWorkplace(monthShifts);
    final hoursByKey = <String, double>{};
    final nameByKey = <String, String>{};
    final colorByKey = <String, int>{};
    for (final s in monthShifts) {
      final k = _shiftKey(s);
      hoursByKey[k] = (hoursByKey[k] ?? 0) + s.workHours;
      final w = workplaceById(s.workplaceId);
      nameByKey[k] = w?.name ?? s.workplace;
      colorByKey[k] = w?.colorValue ?? 0xFF9E9E9E;
    }
    final out = <({String key, String name, int colorValue, int estimated, int? actual, double hours})>[];
    est.forEach((k, amount) {
      out.add((
        key: k,
        name: nameByKey[k] ?? k.replaceFirst('name:', ''),
        colorValue: colorByKey[k] ?? 0xFF9E9E9E,
        estimated: amount,
        actual: actualSalaryOfWorkplace(month, k),
        hours: hoursByKey[k] ?? 0,
      ));
    });
    // シフトが無い登録勤務先も「実給料を手入力」できるよう含める（4月以前など）
    for (final w in workplaces) {
      if (out.any((e) => e.key == w.id)) continue;
      out.add((
        key: w.id,
        name: w.name,
        colorValue: w.colorValue,
        estimated: 0,
        actual: actualSalaryOfWorkplace(month, w.id),
        hours: 0,
      ));
    }
    out.sort((a, b) {
      final c = b.estimated.compareTo(a.estimated);
      return c != 0 ? c : a.name.compareTo(b.name);
    });
    return out;
  }

  // ───── 予算（カテゴリ別の月上限。カテゴリ名＝支出内訳のラベル）─────
  final Map<String, int> budgets = {};
  void setBudget(String category, int amount) {
    if (amount <= 0) {
      budgets.remove(category);
    } else {
      budgets[category] = amount;
    }
    saveData();
    notifyListeners();
  }

  // 予算が設定されたカテゴリの、指定月の予算と実績。over=超過。
  List<({String label, int budget, int spent, bool over})> budgetStatus(DateTime month) {
    final spentByLabel = {for (final e in expenseBreakdownOf(month)) e.label: e.amount};
    final out = <({String label, int budget, int spent, bool over})>[];
    budgets.forEach((label, budget) {
      final spent = spentByLabel[label] ?? 0;
      out.add((label: label, budget: budget, spent: spent, over: spent > budget));
    });
    out.sort((a, b) => (b.spent / b.budget).compareTo(a.spent / a.budget));
    return out;
  }

  // 今月に予算超過しているカテゴリ
  List<({String label, int budget, int spent, bool over})> get overBudgetThisMonth =>
      budgetStatus(DateTime.now()).where((e) => e.over).toList();

  // ───── 目標貯金（目標額＋目標年月）─────
  int goalAmount = 0; // 0 = 未設定
  DateTime? goalDate; // 目標年月（その月末までに達成したい）
  void setGoal(int amount, DateTime? date) {
    goalAmount = amount;
    goalDate = date;
    saveData();
    notifyListeners();
  }

  // 月あたりの純増ペース（来月末 − 今月末）。収入(給料日入金)−支出の見込み。
  int get monthlyNetPace => nextMonthBalance - thisMonthBalance;

  // 目標到達の予測。目標未設定なら null。
  ({int goal, DateTime date, int monthsLeft, int pace, int projected, bool achievable, int requiredMonthly})?
      savingsForecast() {
    if (goalAmount <= 0 || goalDate == null) return null;
    final now = DateTime.now();
    final monthsLeft =
        ((goalDate!.year - now.year) * 12 + (goalDate!.month - now.month)).clamp(0, 600);
    final pace = monthlyNetPace;
    final projected = currentBalance + pace * monthsLeft;
    final required = monthsLeft > 0
        ? ((goalAmount - currentBalance) / monthsLeft).ceil()
        : (goalAmount - currentBalance);
    return (
      goal: goalAmount,
      date: goalDate!,
      monthsLeft: monthsLeft,
      pace: pace,
      projected: projected,
      achievable: projected >= goalAmount,
      requiredMonthly: required,
    );
  }

  // ───── 実給料（手入力）─────
  // 旧: 月合計（yyyy-MM → 金額）。後方互換のため残す。
  final Map<String, int> actualSalaries = {};
  // 新: 勤務先別（"yyyy-MM|wpKey" → 金額）。#3
  final Map<String, int> actualSalariesByWp = {};

  String _ymKey(DateTime m) => DateFormat('yyyy-MM').format(m);
  String _wpSalKey(DateTime m, String wpKey) => '${_ymKey(m)}|$wpKey';

  // 月合計の実給料（勤務先別が入っていればその合計、無ければ旧・月合計）
  int? actualSalaryOf(DateTime month) {
    final byWp = _actualByWpTotal(month);
    if (byWp != null) return byWp;
    return actualSalaries[_ymKey(month)];
  }

  // その月に勤務先別の実給料が1件でも入力されていれば合計を返す（なければ null）
  int? _actualByWpTotal(DateTime month) {
    final keys = _aggregateByWorkplace(_shiftsInMonth(month)).keys;
    int total = 0;
    bool any = false;
    for (final k in keys) {
      final v = actualSalariesByWp[_wpSalKey(month, k)];
      if (v != null) {
        any = true;
        total += v;
      } else {
        // 実給料が未入力の勤務先は見込みで補完
        total += _salaryByWorkplaceOf(month)[k] ?? 0;
      }
    }
    return any ? total : null;
  }

  // 旧API: 月合計をまとめて設定（後方互換）
  void setActualSalary(DateTime month, int? amount) {
    final key = _ymKey(month);
    if (amount == null || amount <= 0) {
      actualSalaries.remove(key);
    } else {
      actualSalaries[key] = amount;
    }
    saveData();
    notifyListeners();
  }

  // #3 勤務先別の実給料を設定
  int? actualSalaryOfWorkplace(DateTime month, String wpKey) =>
      actualSalariesByWp[_wpSalKey(month, wpKey)];
  void setActualSalaryOfWorkplace(DateTime month, String wpKey, int? amount) {
    final key = _wpSalKey(month, wpKey);
    if (amount == null || amount <= 0) {
      actualSalariesByWp.remove(key);
    } else {
      actualSalariesByWp[key] = amount;
    }
    saveData();
    notifyListeners();
  }

  // 勤務先別の見込み給与（その月）
  Map<String, int> _salaryByWorkplaceOf(DateTime month) =>
      _aggregateByWorkplace(_shiftsInMonth(month));
  int estimatedSalaryOfWorkplace(DateTime month, String wpKey) =>
      _salaryByWorkplaceOf(month)[wpKey] ?? 0;
  // 勤務先別の手取り（実給料があればそれ、無ければ見込み）
  int takeHomeOfWorkplace(DateTime month, String wpKey) =>
      actualSalaryOfWorkplace(month, wpKey) ??
      estimatedSalaryOfWorkplace(month, wpKey);

  // 指定月の収入内訳（勤務先ごと。円グラフ用）。金額>0のみ・降順。
  List<({String label, int amount, int colorValue})> incomeBreakdownOf(DateTime month) {
    final monthShifts = _shiftsInMonth(month);
    final agg = _aggregateByWorkplace(monthShifts);
    // 勤務先マスタが見つからない場合はシフトの勤務先名を表示名に使う。
    final nameByKey = <String, String>{};
    final colorByKey = <String, int>{};
    for (final s in monthShifts) {
      final k = _shiftKey(s);
      final w = workplaceById(s.workplaceId);
      nameByKey[k] = w?.name ?? s.workplace;
      colorByKey[k] = w?.colorValue ?? 0xFF9E9E9E;
    }
    final out = <({String label, int amount, int colorValue})>[];
    agg.forEach((key, amount) {
      if (amount <= 0) return;
      out.add((
        label: nameByKey[key] ?? key.replaceFirst('name:', ''),
        amount: amount,
        colorValue: colorByKey[key] ?? 0xFF9E9E9E,
      ));
    });
    out.sort((a, b) => b.amount.compareTo(a.amount));
    return out;
  }

  // 指定月の支出内訳（カード別＋定期＋分割＋ATM。円グラフ用）。金額>0のみ・降順。
  // 💡 月ごとの支出（利用月ベース）のカード分のソース。
  //   三井住友銀行の「口座引き落とし事前お知らせ」は引落日＝利用月の翌月。
  //   よって 月Mの支出 ＝ 翌月(M+1)に引き落とされる銀行確定額（1ヶ月戻して計上）。
  //   銀行確定がまだ無い先月・今月は、その月の支払い管理（利用通知/請求予定/手動）で代替。
  //   いずれも手修正した金額がそのまま反映される。
  // その月の支出が銀行確定（事前お知らせ）で確定しているか。
  //   ＝翌月(M+1)に引き落とされる bank 明細が存在するか。
  bool isExpenseConfirmedByBank(DateTime month) {
    final nextMonth = DateTime(month.year, month.month + 1);
    return payments.any((p) =>
        p.source == PaymentSource.bank &&
        p.paymentDate.year == nextMonth.year &&
        p.paymentDate.month == nextMonth.month);
  }

  // 💡 Amazonマスターは三井住友(OLIVE)発行で、引き落としはOLIVEの請求に含まれる。
  //   OLIVEの銀行確定があるときはAmazon分を別計上しない（二重計上防止）。
  //   デビット/Vポイントペイは即時・プリペイドなので対象外（別枠のまま残す）。
  bool _coveredByOliveBank(String cardName, Map<String, int> bank) {
    if (!cardName.contains('Amazon')) return false;
    return bank.keys.any((k) =>
        !k.contains('デビット') &&
        !k.contains('ポイントペイ') &&
        (k.contains('OLIVE') || k.contains('三井')));
  }

  Map<String, int> paymentTotalsByCardOf(DateTime month) {
    bool sameYm(DateTime d, DateTime m) => d.year == m.year && d.month == m.month;
    final nextMonth = DateTime(month.year, month.month + 1);
    final result = <String, int>{};

    // ① 翌月に引き落とされる銀行確定（＝この月の利用分）
    final bank = <String, int>{};
    for (final p in payments) {
      if (p.source == PaymentSource.bank && sameYm(p.paymentDate, nextMonth)) {
        bank[p.cardName] = (bank[p.cardName] ?? 0) + p.amount;
      }
    }

    if (bank.isNotEmpty) {
      // 💡 銀行確定があるカードは、その確定額を正本にする（手動・利用通知も含んだ総額）。
      result.addAll(bank);
      // 💡 まだ確定していないカード（メルカード等）は消さず、その月の非bank明細
      //   （利用通知/請求予定/手動）で計上を続ける。確定したら上の確定額に置き換わる。
      for (final p in payments) {
        if (p.source == PaymentSource.bank) continue;
        if (p.infoOnly) continue; // 記録だけの明細は合計に足さない
        if (!sameYm(p.paymentDate, month)) continue;
        if (bank.containsKey(p.cardName)) continue; // 確定済み＝確定額が正本
        if (_coveredByOliveBank(p.cardName, bank)) continue; // Amazonは三井OLIVEの確定に含まれる
        result[p.cardName] = (result[p.cardName] ?? 0) + p.amount;
      }
      return result;
    }

    // ② 銀行確定が無い月（先月・今月）：その月の支払い管理（銀行確定以外）で代替
    // 💡 ここに infoOnly の除外が無かったため、確定メールが届くまでの期間だけ
    //   Amazonの買い物が二重計上されていた。
    for (final p in payments) {
      if (p.infoOnly) continue;
      if (p.source != PaymentSource.bank && sameYm(p.paymentDate, month)) {
        result[p.cardName] = (result[p.cardName] ?? 0) + p.amount;
      }
    }
    return result;
  }

  // 指定月の分割払いの月額合計（分割後の月額・金利込み）。
  // 💡 利用月ベース: 利用開始月(startDateの月)を1回目として、その月から installmentCount か月ぶん計上。
  //   （引き落とし月ではなく利用月で集計。例: 4月利用→4月の支出に表示）
  int installmentTotalOf(DateTime month) {
    int total = 0;
    final now = DateTime.now();
    for (final i in installments) {
      final start = i.startDate;
      if (start == null) {
        // 期間不明な旧データはアクティブなら当月のみ計上
        if (i.remainingMonths > 0 && month.year == now.year && month.month == now.month) {
          total += i.monthlyAmount;
        }
        continue;
      }
      // 1回目＝利用開始月。そこから installmentCount か月ぶんアクティブ。
      final diff = (month.year - start.year) * 12 + (month.month - start.month);
      if (diff >= 0 && diff < i.installmentCount) total += i.monthlyAmount;
    }
    return total;
  }

  // 💡 分割払いの月額を、組んだカードごとに分ける。
  //   実際の引き落としは「分割払い」という独立した請求ではなく、
  //   それぞれのカードの請求に含まれて、そのカードの引き落とし日に落ちるため。
  Map<String, int> installmentTotalByCardOf(DateTime month) {
    final out = <String, int>{};
    final now = DateTime.now();
    for (final i in installments) {
      final card = i.cardName.trim();
      if (card.isEmpty) continue; // カード未設定は割り当てられない
      final start = i.startDate;
      if (start == null) {
        if (i.remainingMonths > 0 && month.year == now.year && month.month == now.month) {
          out[card] = (out[card] ?? 0) + i.monthlyAmount;
        }
        continue;
      }
      final diff = (month.year - start.year) * 12 + (month.month - start.month);
      if (diff >= 0 && diff < i.installmentCount) {
        out[card] = (out[card] ?? 0) + i.monthlyAmount;
      }
    }
    return out;
  }

  // 💡 その月にカードへ合算した分割払いの合計（「※うち分割払い」の参考表示用）。
  //   銀行確定済みの月は確定額に既に含まれているので0。
  int installmentFoldedInto(DateTime month) {
    if (isExpenseConfirmedByBank(month)) return 0;
    return installmentTotalByCardOf(month).values.fold(0, (s, v) => s + v);
  }

  // 💡 カードが設定されていない分割払い（古いデータ）。
  //   どのカードにも足せないため、そのままだと予想から消えてしまう。
  //   別枠で残して、カードを設定するよう促す。
  int unassignedInstallmentTotalOf(DateTime month) {
    var total = 0;
    final now = DateTime.now();
    for (final i in installments) {
      if (i.cardName.trim().isNotEmpty) continue;
      final start = i.startDate;
      if (start == null) {
        if (i.remainingMonths > 0 && month.year == now.year && month.month == now.month) {
          total += i.monthlyAmount;
        }
        continue;
      }
      final diff = (month.year - start.year) * 12 + (month.month - start.month);
      if (diff >= 0 && diff < i.installmentCount) total += i.monthlyAmount;
    }
    return total;
  }

  // カード未設定のまま残っている分割払い（設定を促すために一覧で使う）
  List<Installment> get installmentsWithoutCard =>
      installments.where((i) => i.cardName.trim().isEmpty).toList();

  List<({String label, int amount, int colorValue})> expenseBreakdownOf(DateTime month) {
    final out = <({String label, int amount, int colorValue})>[];
    final totals = Map<String, int>.from(paymentTotalsByCardOf(month));

    // 💡 分割払いはカードの請求に含めて落ちるので、カードの金額に足し込む。
    //   銀行確定済みの月は確定額に既に含まれているため足さない（二重計上になる）。
    if (!isExpenseConfirmedByBank(month)) {
      installmentTotalByCardOf(month).forEach((card, amount) {
        totals[card] = (totals[card] ?? 0) + amount;
      });
    }

    // 💡 カード払いのローンも、分割払いと同じくカードの請求に含めて落ちる
    if (!isExpenseConfirmedByBank(month)) {
      loanTotalByCardOf(month).forEach((card, amount) {
        totals[card] = (totals[card] ?? 0) + amount;
      });
    }

    totals.forEach((card, amount) {
      if (amount > 0) {
        out.add((label: card, amount: amount, colorValue: cardColorOf(card).toARGB32()));
      }
    });

    // カードが決まっていない分割は足せないので、消さずに別枠で残す
    if (!isExpenseConfirmedByBank(month)) {
      final unassigned = unassignedInstallmentTotalOf(month);
      if (unassigned > 0) {
        out.add((
          label: '分割払い（カード未設定）',
          amount: unassigned,
          colorValue: Colors.deepOrange.toARGB32(),
        ));
      }
    }
    // 💡 口座から直接引かれるローンは、返済日が個別なので1本ずつ出す
    for (final l in activeLoansIn(month)) {
      if (!l.isFromAccount) continue;
      out.add((
        label: l.name,
        amount: l.monthlyAmount,
        colorValue: Colors.indigo.toARGB32(),
      ));
    }
    final subTotal = subscriptionTotalOf(month);
    if (subTotal > 0) {
      out.add((label: '定期支払い', amount: subTotal, colorValue: Colors.purple.toARGB32()));
    }
    final atm = withdrawalsOf(month);
    if (atm > 0) {
      out.add((label: 'ATM', amount: atm, colorValue: Colors.brown.toARGB32()));
    }
    out.sort((a, b) => b.amount.compareTo(a.amount));
    return out;
  }

  // 支払い種別の表示名（明細詳細のサブ情報用）
  String sourceLabelOf(PaymentSource s) {
    switch (s) {
      case PaymentSource.manual:
        return '手動';
      case PaymentSource.usage:
        return '利用';
      case PaymentSource.billing:
        return '請求予定';
      case PaymentSource.bank:
        return '銀行確定';
    }
  }

  // 💡 指定月・指定カテゴリ（支出内訳のラベル）の個々の明細。合計は expenseBreakdownOf と一致。
  List<({String title, String subtitle, int amount})> expenseDetailOf(DateTime month, String label) {
    final out = <({String title, String subtitle, int amount})>[];
    bool sameYm(DateTime d, DateTime m) => d.year == m.year && d.month == m.month;

    if (label == '定期支払い') {
      for (final s in subscriptions) {
        out.add((title: s.title, subtitle: '毎月${s.payDay}日', amount: s.amount));
      }
    } else if (label == '分割払い') {
      for (final i in installments) {
        final start = i.startDate;
        if (start == null) continue;
        final diff = (month.year - start.year) * 12 + (month.month - start.month);
        if (diff >= 0 && diff < i.installmentCount) {
          out.add((title: i.name, subtitle: '${diff + 1}/${i.installmentCount}回目', amount: i.monthlyAmount));
        }
      }
    } else if (loans.any((l) => l.isFromAccount && l.name == label)) {
      for (final l in loans.where((e) => e.isFromAccount && e.name == label)) {
        final n = l.countIn(month);
        if (n == 0) continue;
        out.add((
          title: l.name,
          subtitle: '$n/${l.totalCount}回目 ・ 毎月${l.payDay}日',
          amount: l.monthlyAmount,
        ));
      }
    } else if (label == 'ATM') {
      for (final w in withdrawals) {
        if (sameYm(w.date, month)) {
          out.add((
            title: 'ATM引き出し',
            subtitle: '${DateFormat('M/d').format(w.date)}${w.memo.isNotEmpty ? ' ・ ${w.memo}' : ''}',
            amount: w.amount,
          ));
        }
      }
    } else {
      // カード：paymentTotalsByCardOf と同じ抽出ロジックで、そのカードの明細を返す。
      final nextMonth = DateTime(month.year, month.month + 1);
      // 💡 集計 paymentTotalsByCardOf と同じルール（合計と明細を一致させる）:
      //   ・このカードに銀行確定がある → 確定明細だけ（手動/利用通知は確定額に含まれる）
      //   ・まだ確定していない       → その月の非bank明細（利用通知/請求予定/手動）
      final cardHasBank = payments.any((p) =>
          p.cardName == label &&
          p.source == PaymentSource.bank &&
          sameYm(p.paymentDate, nextMonth));
      for (final p in payments) {
        if (p.cardName != label) continue;
        final belongs = cardHasBank
            ? (p.source == PaymentSource.bank && sameYm(p.paymentDate, nextMonth))
            : (p.source != PaymentSource.bank && sameYm(p.paymentDate, month));
        if (!belongs) continue;
        if (p.infoOnly) continue; // 記録のみ（他カードで計上済み）は合計に入っていない
        out.add((
          title: p.note.isNotEmpty ? p.note : sourceLabelOf(p.source),
          subtitle: '${sourceLabelOf(p.source)} ・ ${DateFormat('M/d').format(p.paymentDate)}',
          amount: p.amount,
        ));
      }
      // 💡 このカードで組んだ分割払いの当月ぶん。カードの請求に含めて落ちるので、
      //   合計にも足してあり、明細にも出す（銀行確定済みなら確定額に含まれるので出さない）。
      if (!cardHasBank) {
        for (final inst in installments.where((e) => e.cardName == label)) {
          final start = inst.startDate;
          if (start == null) continue;
          final diff = (month.year - start.year) * 12 + (month.month - start.month);
          if (diff >= 0 && diff < inst.installmentCount) {
            out.add((
              title: '分割: ${inst.name}',
              subtitle: '分割 ${diff + 1}/${inst.installmentCount}回目',
              amount: inst.monthlyAmount,
            ));
          }
        }
      }
    }
    out.sort((a, b) => b.amount.compareTo(a.amount));
    return out;
  }

  // 💡 指定月・指定勤務先の収入明細（円グラフの収入詳細用）。シフト1件ごと。
  List<({String title, String subtitle, int amount})> incomeDetailOf(DateTime month, String label) {
    final out = <({String title, String subtitle, int amount})>[];
    for (final s in _shiftsInMonth(month)) {
      final name = workplaceById(s.workplaceId)?.name ?? s.workplace;
      if (name != label) continue;
      final d = s.start;
      out.add((
        title: '${d.month}/${d.day}（${s.workHours.toStringAsFixed(1)}h）',
        subtitle:
            '${TimeOfDay.fromDateTime(s.start).hour}:${s.start.minute.toString().padLeft(2, '0')}'
            '〜${TimeOfDay.fromDateTime(s.end).hour}:${s.end.minute.toString().padLeft(2, '0')}',
        amount: s.earnings,
      ));
    }
    out.sort((a, b) {
      // 日付順（古い→新しい）
      return a.title.compareTo(b.title);
    });
    return out;
  }

  // ───── 年間集計（過去データの振り返り・年収計算用）─────
  // データが存在する年の一覧（新しい順）
  List<int> get dataYears {
    final years = <int>{};
    for (final k in shifts.keys) {
      final y = int.tryParse(k.split('-').first);
      if (y != null) years.add(y);
    }
    for (final p in payments) {
      years.add(p.paymentDate.year);
    }
    final list = years.toList()..sort((a, b) => b.compareTo(a));
    return list;
  }

  // 💡 扶養・社保の「壁」。学生/主婦バイトの働き方の目安。
  static const List<({int amount, String label})> incomeWalls = [
    (amount: 1030000, label: '103万（所得税）'),
    (amount: 1060000, label: '106万（社保・大企業）'),
    (amount: 1300000, label: '130万（社保扶養）'),
    (amount: 1500000, label: '150万（配偶者特別控除）'),
  ];

  // 指定年の年収に対する「次の壁」と残り金額。全部超えていれば nextWall=null。
  ({int income, ({int amount, String label})? nextWall, int remaining}) incomeWallStatus(int year) {
    final income = salaryOfYear(year);
    for (final w in incomeWalls) {
      if (income < w.amount) {
        return (income: income, nextWall: w, remaining: w.amount - income);
      }
    }
    return (income: income, nextWall: null, remaining: 0);
  }

  // 指定年の給与合計（年収・見込み）。交通費の月上限は月ごとに適用するため月単位で合算。
  int salaryOfYear(int year) {
    int total = 0;
    for (var m = 1; m <= 12; m++) {
      total += salaryOf(DateTime(year, m));
    }
    return total;
  }

  // #2 見込み年収（＝salaryOfYear のエイリアス）
  int estimatedSalaryOfYear(int year) => salaryOfYear(year);

  // #2 実年収（実給料を入力した月だけ合計。未入力の月は計上しない）
  int actualSalaryOfYear(int year) {
    int total = 0;
    for (var m = 1; m <= 12; m++) {
      final month = DateTime(year, m);
      // 勤務先別の実入力分のみ合計
      final keys = _salaryByWorkplaceOf(month).keys;
      for (final k in keys) {
        final v = actualSalariesByWp[_wpSalKey(month, k)];
        if (v != null) total += v;
      }
      // 旧・月合計の実給料も加算（勤務先別が無い場合）
      if (keys.every((k) => actualSalariesByWp[_wpSalKey(month, k)] == null)) {
        final old = actualSalaries[_ymKey(month)];
        if (old != null) total += old;
      }
    }
    return total;
  }

  // #2 実給料が1件でも入力されている年か
  bool hasActualSalaryInYear(int year) {
    for (var m = 1; m <= 12; m++) {
      final month = DateTime(year, m);
      if (actualSalaries[_ymKey(month)] != null) return true;
      for (final k in _salaryByWorkplaceOf(month).keys) {
        if (actualSalariesByWp[_wpSalKey(month, k)] != null) return true;
      }
    }
    return false;
  }

  // 指定年のカード支出合計（利用通知・確定を含む実支出）
  int cardSpendingOfYear(int year) {
    return payments
        .where((p) => p.paymentDate.year == year)
        .fold(0, (sum, p) => sum + p.amount);
  }

  // 指定月の総支出（カード＋定期＋ATM＋分割）
  int monthlyExpenseOf(DateTime month) =>
      cardPaymentsOf(month) + subscriptionTotal + withdrawalsOf(month) + installmentTotal;

  // 直近 months か月の月次推移（収入＝給料見込み・支出＝支出内訳合計）。古い順。
  List<({DateTime month, int income, int expense})> monthlyTrend(int months) {
    final now = DateTime.now();
    final out = <({DateTime month, int income, int expense})>[];
    for (var i = months - 1; i >= 0; i--) {
      final m = DateTime(now.year, now.month - i);
      final income = salaryOf(m);
      final expense = expenseBreakdownOf(m).fold(0, (s, e) => s + e.amount);
      out.add((month: m, income: income, expense: expense));
    }
    return out;
  }

  // 指定年の総支出（各月の支出内訳合計を12か月ぶん。円グラフ中央の年支出用）
  int expenseOfYear(int year) {
    int total = 0;
    for (var m = 1; m <= 12; m++) {
      total += expenseBreakdownOf(DateTime(year, m)).fold(0, (s, e) => s + e.amount);
    }
    return total;
  }

  // 💡 引き落とし日ルール（締め＝末日）
  //   楽天        : 利用月の翌月27日（月末締め・翌月27日払い）
  //   三井OLIVE/Amazonマスター : 利用月の翌月26日
  //   その他       : 利用月の翌月27日
  //   土日は翌営業日へ（祝日は未対応）
  ({int monthsAhead, int day}) _cardDrawRule(String cardName) {
    if (cardName.contains('楽天')) return (monthsAhead: 1, day: 27);
    if (cardName.contains('OLIVE') ||
        cardName.contains('Amazon') ||
        cardName.contains('メル') ||
        cardName.contains('三井')) {
      return (monthsAhead: 1, day: 26);
    }
    return (monthsAhead: 1, day: 27);
  }

  // 土日祝は翌営業日へ（カードの引き落としは後ろ倒し）
  DateTime _businessDay(DateTime d) => nextBusinessDay(d);

  // 利用日から1回目の引き落とし日。
  DateTime debitDateFor(String cardName, DateTime purchaseDate) =>
      debitDateForNth(cardName, purchaseDate, 0);

  // 利用日からk回目(0始まり)の引き落とし日。分割の各回の引落日を正確に出す。
  //   ※各回ごとに土日調整するので、1回目の土日ズレを後続へ持ち越さない。
  DateTime debitDateForNth(String cardName, DateTime purchaseDate, int k) {
    final r = _cardDrawRule(cardName);
    return _businessDay(
        DateTime(purchaseDate.year, purchaseDate.month + r.monthsAhead + k, r.day));
  }

  // 💡 指定月に引き落とされるカード請求を「カード別」に集計。
  //   ・請求予定/銀行確定/手動 … paymentDate がその月のものを採用
  //   ・利用通知(usage) … 引落日ルールで引落月を推定。ただし同カードに
  //     確定/予測(explicit)があればそちらを優先（二重計上を防ぐ）
  Map<String, int> cardChargesOf(DateTime month) {
    bool sameYm(DateTime d) => d.year == month.year && d.month == month.month;
    final result = <String, int>{};

    for (final p in payments) {
      if (p.paid || p.source == PaymentSource.usage) continue;
      if (sameYm(p.paymentDate)) {
        result[p.cardName] = (result[p.cardName] ?? 0) + p.amount;
      }
    }

    // 利用通知 → 引落月を推定して、確定/予測が無いカードだけ予測計上。
    // 💡 以下は将来の引落ではないため残高予測に含めない（情報のみ）:
    //   ・Amazon発送由来(amazon#) … 支払カード不明
    //   ・デビット … 即時に口座から引落済み
    //   ・Vポイントペイ … プリペイド残高から支払済み
    final usageByCard = <String, int>{};
    for (final p in payments) {
      if (p.paid || p.source != PaymentSource.usage) continue;
      if (p.sourceId.startsWith('amazon#')) continue;
      if (p.cardName.contains('デビット') || p.cardName.contains('ポイントペイ')) continue;
      if (sameYm(debitDateFor(p.cardName, p.paymentDate))) {
        usageByCard[p.cardName] = (usageByCard[p.cardName] ?? 0) + p.amount;
      }
    }
    usageByCard.forEach((card, amt) {
      result.putIfAbsent(card, () => amt);
    });

    return result;
  }

  // 指定月の未払いカード請求合計
  int cardPaymentsOf(DateTime month) =>
      cardChargesOf(month).values.fold(0, (sum, v) => sum + v);

  // 定期支払い（毎月固定）合計
  int get subscriptionTotal =>
      subscriptions.fold(0, (sum, s) => sum + s.amount);

  // 口座から引かれる定期支払いの合計（カード払いを除く＝口座振替＋手動）
  int get subscriptionFromAccountTotal =>
      subscriptions.where((s) => !s.isCardPayment).fold(0, (sum, s) => sum + s.amount);

  // 💡 指定月の支出に載せる定期支払いの合計。
  //   カード払いの定期は、その月が銀行確定していればカードの引き落とし額に既に含まれるので除く
  //   （分割払いと同じ二重計上対策）。口座振替の定期は常に計上する。
  int subscriptionTotalOf(DateTime month) {
    final confirmed = isExpenseConfirmedByBank(month);
    return subscriptions
        .where((s) => !s.isCardPayment || !confirmed)
        .fold(0, (sum, s) => sum + s.amount);
  }

  // ───── ローン ─────
  // 💡 口座から直接引かれるローンは、返済日が個別なので1本ずつのスライスにする。
  //   （まとめて1つにすると、分割払いで起きたのと同じ「引き落とし日のズレ」が出る）
  List<Loan> activeLoansIn(DateTime month) =>
      loans.where((l) => l.isActiveIn(month)).toList();

  // カード払いのローンは、そのカードの請求に含めて落ちる
  Map<String, int> loanTotalByCardOf(DateTime month) {
    final out = <String, int>{};
    for (final l in loans) {
      if (!l.isCardPayment || !l.isActiveIn(month)) continue;
      out[l.method] = (out[l.method] ?? 0) + l.monthlyAmount;
    }
    return out;
  }

  // 口座から直接引かれるローンの合計（参考表示用）
  int loanTotalFromAccountOf(DateTime month) => loans
      .where((l) => l.isFromAccount && l.isActiveIn(month))
      .fold(0, (s, l) => s + l.monthlyAmount);

  void addLoan({
    required String name,
    required int principal,
    required int totalCount,
    required DateTime startMonth,
    double interestRate = 0,
    int payDay = 27,
    String method = '',
    int monthlyOverride = 0,
  }) {
    loans.add(Loan(
      id: _id(),
      name: name.trim(),
      principal: principal,
      totalCount: totalCount < 1 ? 1 : totalCount,
      startMonth: DateTime(startMonth.year, startMonth.month),
      interestRate: interestRate,
      payDay: payDay.clamp(1, 31),
      method: method,
      monthlyOverride: monthlyOverride,
    ));
    saveData();
    notifyListeners();
  }

  void updateLoan(Loan loan) {
    saveData();
    notifyListeners();
  }

  void removeLoan(String id) {
    loans.removeWhere((l) => l.id == id);
    saveData();
    notifyListeners();
  }

  // 指定月のATM引き出し合計
  int withdrawalsOf(DateTime month) {
    final prefix = DateFormat('yyyy-MM').format(month);
    return withdrawals
        .where((w) => DateFormat('yyyy-MM').format(w.date) == prefix)
        .fold(0, (sum, w) => sum + w.amount);
  }

  // 分割払い（残回数があるもの）の今月分合計。残回数は経過に応じて動的算出。
  int get installmentTotal => installments
      .where((i) => remainingMonthsOf(i) > 0)
      .fold(0, (sum, i) => sum + i.monthlyAmount);

  // 💡 給料日までのズレ（月）。勤務先の paydayMonthOffset の最頻値（無ければ翌月=1）。
  //   締日締め→給料日に入金、を予測へ反映するために使う。
  int get paydayOffsetMonths {
    if (workplaces.isEmpty) return 1;
    final counts = <int, int>{};
    for (final w in workplaces) {
      counts[w.paydayMonthOffset] = (counts[w.paydayMonthOffset] ?? 0) + 1;
    }
    return counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  }

  // その月の手取り（実給料があればそれ、無ければ給料見込み）
  int takeHomeOf(DateTime month) => actualSalaryOf(month) ?? salaryOf(month);

  // 指定月に「給料日として入金される」見込み額。＝給料日offsetぶん前の労働月の手取り。
  int incomeArrivingIn(DateTime payMonth) {
    final wm = DateTime(payMonth.year, payMonth.month - paydayOffsetMonths);
    return takeHomeOf(wm);
  }

  // ────── #5 #6 デビット即時引き落とし ──────
  bool _isDebit(String card) => card.contains('デビット');

  // #6 スナップショット日より「後」のイベントだけ予測へ反映するための判定。
  //   基準日が無い（未編集）なら過去全部を引くと誤るので false（反映しない）。
  bool _afterSnapshot(DateTime d) {
    final since = balanceUpdatedAt;
    if (since == null) return false;
    return d.isAfter(DateTime(since.year, since.month, since.day));
  }

  // #5 #6 残高編集後に使ったデビット（即時口座引落）の合計。
  int debitsAfterSnapshot() => payments
      .where((p) => _isDebit(p.cardName) && _afterSnapshot(p.paymentDate))
      .fold(0, (s, p) => s + p.amount);

  // #5 #6 実効的な現在残高＝編集時の残高 − 編集後に使ったデビット。
  int get effectiveBalance => currentBalance - debitsAfterSnapshot();

  String _wpKeyOf(Workplace w) => w.id;

  // 💡 予想残高の引き落としソース判定：口座から実際に引き落とされないものは除外。
  bool _excludedFromDraw(String label) =>
      label.contains('デビット') ||
      label.contains('ポイントペイ') ||
      label == 'ATM';

  // 二重計上防止ゲート：日付が「残高を編集した日」より後なら予想へ反映（true）。
  //   基準日が無ければ従来どおり全部反映（true）。
  bool _forecastInclude(DateTime d) {
    final since = balanceUpdatedAt;
    if (since == null) return true;
    return d.isAfter(DateTime(since.year, since.month, since.day));
  }

  // 引き落とし項目の「引き落とし日(日)」を推定（ゲート判定用）。
  // 💡 そのカードの、その月の実際の引き落とし日。
  //   設定した日が土日祝なら翌営業日にずれる（カードの引き落としは後ろ倒しが一般的）。
  DateTime cardDrawDateOf(String cardName, DateTime month) {
    final day = cardPaymentDays[cardName] ?? 27;
    final lastDay = DateTime(month.year, month.month + 1, 0).day;
    final base = DateTime(month.year, month.month, day > lastDay ? lastDay : day);
    return nextBusinessDay(base);
  }

  int _drawDayOf(String label) {
    final card = cardPaymentDays[label];
    if (card != null) return card;
    // ローンは名前がそのままラベルになる。自分の返済日で落ちる。
    for (final l in loans) {
      if (l.isFromAccount && l.name == label) return l.payDay;
    }
    if (label == '定期支払い' && subscriptions.isNotEmpty) {
      return subscriptions.map((s) => s.payDay).reduce((a, b) => a < b ? a : b);
    }
    return 27; // 分割など、日付が無いものは月末寄りの27日とみなす
  }

  // n月に口座から引き落とされる支出の内訳。＝ n-1月の「月ごとの支出詳細」から
  //   デビット/Vポイント/ATMを除き、編集日より後の引き落としだけを残す。
  List<({String label, int amount, int colorValue})> drawBreakdownOf(DateTime payMonth) {
    final useMonth = DateTime(payMonth.year, payMonth.month - 1);
    final lastDay = DateTime(payMonth.year, payMonth.month + 1, 0).day;

    // 二重計上ゲート（引き落とし日が残高の編集日より後か）
    bool afterEdit(String label) {
      final day = _drawDayOf(label).clamp(1, lastDay);
      // 土日祝なら翌営業日にずれる
      return _forecastInclude(
          nextBusinessDay(DateTime(payMonth.year, payMonth.month, day)));
    }

    final out = <({String label, int amount, int colorValue})>[];

    // 💡 締め日を月末以外にしたカードは、暦月ではなく締め期間で集計する。
    //   （月末締めのカードと定期/分割は従来どおり「前月の支出詳細」を使う）
    final byPeriod = <String>{};
    for (final card in cardPaymentDays.keys) {
      if (isMonthEndClosing(card) || _excludedFromDraw(card)) continue;
      byPeriod.add(card);
      if (!afterEdit(card)) continue;
      final amount = cardUsageInClosingPeriod(card, payMonth);
      if (amount <= 0) continue;
      out.add((label: card, amount: amount, colorValue: cardColorOf(card).toARGB32()));
    }

    for (final e in expenseBreakdownOf(useMonth)) {
      if (byPeriod.contains(e.label)) continue; // 締め期間で集計済み
      if (_excludedFromDraw(e.label)) continue;
      if (!afterEdit(e.label)) continue;
      out.add(e);
    }

    out.sort((a, b) => b.amount.compareTo(a.amount));
    return out;
  }

  // n月に引き落とされる合計（＝ n-1月の支出詳細・除外分とゲート済みを除く）。
  int drawnInMonth(DateTime payMonth) =>
      drawBreakdownOf(payMonth).fold(0, (s, e) => s + e.amount);

  // 💡 n月の引き落としのうち、分割払いぶんはいくらか（参考表示用）。
  //   各カードの金額に既に含まれているので、合計には足さないこと。
  int installmentPartOfDraw(DateTime payMonth) =>
      installmentFoldedInto(DateTime(payMonth.year, payMonth.month - 1));

  // 予想用：n月に入金される給料のうち、給料日が編集日より後の勤務先分のみ。
  //   （既に受け取って残高に反映済みの給料を二重に足さない）
  int incomeForecastIn(DateTime payMonth) {
    if (balanceUpdatedAt == null || workplaces.isEmpty) {
      // 基準日なし→従来どおり（予定入金は足す）
      return incomeArrivingIn(payMonth) + plannedIncomeForecastIn(payMonth);
    }
    int total = 0;
    for (final w in workplaces) {
      final wm = DateTime(payMonth.year, payMonth.month - w.paydayMonthOffset);
      final payDate = w.paydayIn(payMonth); // 土日祝の調整を反映
      if (_forecastInclude(payDate)) total += takeHomeOfWorkplace(wm, w.id);
    }
    total += plannedIncomeForecastIn(payMonth); // 予定入金も足す
    return total;
  }

  // 財布の現金（機能ONのときだけ有効）
  int get effectiveWalletCash => showWalletCash ? walletCash : 0;

  // 今月末残高。起点＝デビット調整済み残高＋財布の現金、給料・引き落としは編集日より後の分のみ。
  int get thisMonthBalance {
    final now = DateTime.now();
    return effectiveBalance + effectiveWalletCash + incomeForecastIn(now) - drawnInMonth(now);
  }

  // 来月末残高
  int get nextMonthBalance {
    final next = DateTime(DateTime.now().year, DateTime.now().month + 1, 1);
    return thisMonthBalance + incomeForecastIn(next) - drawnInMonth(next);
  }

  // 翌々月末残高（#2）
  int get monthAfterNextBalance {
    final m2 = DateTime(DateTime.now().year, DateTime.now().month + 2, 1);
    return nextMonthBalance + incomeForecastIn(m2) - drawnInMonth(m2);
  }

  Future<void> setShowMonthAfterNext(bool on) async {
    showMonthAfterNext = on;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('saved_show_month_after_next', on);
    notifyListeners();
  }

  Future<void> setShowWalletCash(bool on) async {
    showWalletCash = on;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('saved_show_wallet_cash', on);
    notifyListeners();
  }

  Future<void> setBackgroundTheme(String key) async {
    backgroundTheme = key;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_background_theme', key);
    notifyListeners();
  }

  // ────── 給料日ヘルパー ──────
  // 指定月(workMonth)の給料日を全勤務先分返す。#4 金額は勤務先ごとの手取り。
  List<({DateTime date, Workplace workplace, int amount})> paydaysInMonth(DateTime month) {
    final result = <({DateTime date, Workplace workplace, int amount})>[];
    for (final w in workplaces) {
      final payMonth = DateTime(month.year, month.month + w.paydayMonthOffset);
      final payDate = w.paydayIn(payMonth); // 土日祝は設定に応じて前後にズラす
      // #4 その勤務先・その労働月の手取りのみ（月総額ではない）
      final amount = takeHomeOfWorkplace(month, _wpKeyOf(w));
      if (amount > 0) result.add((date: payDate, workplace: w, amount: amount));
    }
    return result;
  }

  // 表示範囲（前後N月）の全給料日を返す。
  List<({DateTime date, Workplace workplace, int amount})> paydaysNear(DateTime center, {int before = 2, int ahead = 3}) {
    final result = <({DateTime date, Workplace workplace, int amount})>[];
    for (var dm = -before; dm <= ahead; dm++) {
      result.addAll(paydaysInMonth(DateTime(center.year, center.month + dm)));
    }
    return result;
  }

  // 指定日付の給料日エントリを返す（カレンダー表示用）。
  List<({Workplace workplace, int amount, DateTime date})> paydaysOnDay(DateTime date) {
    return paydaysNear(date).where((e) =>
      e.date.year == date.year && e.date.month == date.month && e.date.day == date.day
    ).toList();
  }

  // 指定日に表示するカード別集約引き落とし情報。
  // 銀行確定(bank)はその日付優先、未確定はcardPaymentDaysの日に前月billing合計を表示。
  List<({String cardName, int amount, bool isConfirmed})> cardPaymentSummaryOnDay(DateTime date) {
    final result = <({String cardName, int amount, bool isConfirmed})>[];

    // 銀行確定: この日のbank支払いをカード別集計
    final bankByCard = <String, int>{};
    for (final p in payments) {
      if (p.source == PaymentSource.bank &&
          p.paymentDate.year == date.year &&
          p.paymentDate.month == date.month &&
          p.paymentDate.day == date.day) {
        bankByCard[p.cardName] = (bankByCard[p.cardName] ?? 0) + p.amount;
      }
    }
    for (final e in bankByCard.entries) {
      result.add((cardName: e.key, amount: e.value, isConfirmed: true));
    }

    // 予定: cardPaymentDaysに登録済みカードで、この日が引き落とし日なら前月billing合計を表示
    final confirmedCards = bankByCard.keys.toSet();
    final prevMonth = DateTime(date.year, date.month - 1);
    for (final e in cardPaymentDays.entries) {
      if (confirmedCards.contains(e.key)) continue;
      // 土日祝は翌営業日にずれた日で判定
      if (cardDrawDateOf(e.key, DateTime(date.year, date.month)) !=
          DateTime(date.year, date.month, date.day)) {
        continue;
      }
      // 前月の利用ぶん（まだ無ければ0＝「引き落とし日」だけ表示する）
      final total = paymentTotalsByCardOf(prevMonth)[e.key] ?? 0;
      result.add((cardName: e.key, amount: total, isConfirmed: false));
    }

    return result;
  }

  void setCardPaymentDay(String cardName, int day) {
    cardPaymentDays[cardName] = day;
    _saveCardPaymentDays();
    notifyListeners();
  }

  Future<void> _saveCardPaymentDays() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_card_payment_days', jsonEncode(cardPaymentDays));
    await prefs.setString('saved_card_closing_days', jsonEncode(cardClosingDays));
  }

  // 💡 カード選択に出す一覧。設定で登録したカードに加え、
  //   既存の明細・分割・定期に出てくるカード名も拾う。
  //   （設定で追加したのに選べない／過去データのカードが選べない、を防ぐ）
  static const String kOtherCard = 'その他';

  List<String> get cardChoices {
    final out = <String>[];
    void add(String? name) {
      final n = (name ?? '').trim();
      if (n.isEmpty || n == kOtherCard) return;
      if (!out.contains(n)) out.add(n);
    }

    for (final k in cardPaymentDays.keys) {
      add(k);
    }
    for (final p in payments) {
      add(p.cardName);
    }
    for (final i in installments) {
      add(i.cardName);
    }
    for (final s in subscriptions) {
      if (s.isCardPayment) add(s.method);
    }
    out.add(kOtherCard); // 「その他」は必ず最後
    return out;
  }

  // カードの締め日（未設定＝31＝月末締め）
  int closingDayOf(String cardName) => cardClosingDays[cardName] ?? 31;

  bool isMonthEndClosing(String cardName) => closingDayOf(cardName) >= 31;

  // 💡 カードを設定から外す。明細は消さない（過去の記録は残す）。
  //   cardChoices は明細に出てくるカード名も拾うので、過去データの表示は壊れない。
  void removeCard(String cardName) {
    cardPaymentDays.remove(cardName);
    cardClosingDays.remove(cardName);
    _saveCardPaymentDays();
    notifyListeners();
  }

  void setCardClosingDay(String cardName, int day) {
    cardClosingDays[cardName] = day.clamp(1, 31);
    _saveCardPaymentDays();
    notifyListeners();
  }

  // 締め日の表示用ラベル
  String closingLabelOf(String cardName) =>
      isMonthEndClosing(cardName) ? '月末締め' : '${closingDayOf(cardName)}日締め';

  // 💡 内訳に出す表示名。締め日が月末以外のカードは対象期間も添える
  //   （「なぜこの金額なのか」が分からなくなるため）。
  String drawLabelOf(String label, DateTime payMonth) {
    if (!cardPaymentDays.containsKey(label) || isMonthEndClosing(label)) return label;
    final r = cardClosingPeriodOf(label, payMonth);
    return '$label（${r.start.month}/${r.start.day}〜${r.end.month}/${r.end.day}利用）';
  }

  // 💡 payMonth に引き落とされる利用の対象期間。
  //   締め日 C なら「前々月C日の翌日 〜 前月C日」。
  //   月末締め(31)ならちょうど前月1日〜前月末日になり、従来の暦月集計と一致する。
  ({DateTime start, DateTime end}) cardClosingPeriodOf(String cardName, DateTime payMonth) {
    final c = closingDayOf(cardName);
    DateTime closingIn(DateTime m) {
      final last = DateTime(m.year, m.month + 1, 0).day;
      return DateTime(m.year, m.month, c > last ? last : c);
    }

    final endMonth = DateTime(payMonth.year, payMonth.month - 1);
    final end = closingIn(endMonth);
    final start = closingIn(DateTime(endMonth.year, endMonth.month - 1))
        .add(const Duration(days: 1));
    return (start: start, end: end);
  }

  // 💡 締め期間で集計したカード利用額。
  //   銀行の引落確定メールが来ている月は、その確定額を正本にする（従来と同じ扱い）。
  int cardUsageInClosingPeriod(String cardName, DateTime payMonth) {
    var bank = 0;
    for (final p in payments) {
      if (p.source != PaymentSource.bank) continue;
      if (p.cardName != cardName) continue;
      if (p.paymentDate.year == payMonth.year && p.paymentDate.month == payMonth.month) {
        bank += p.amount;
      }
    }
    if (bank > 0) return bank;

    final r = cardClosingPeriodOf(cardName, payMonth);
    var total = 0;
    for (final p in payments) {
      if (p.source == PaymentSource.bank) continue;
      if (p.infoOnly) continue; // 記録だけの明細は合計に足さない
      if (p.cardName != cardName) continue;
      final d = DateTime(p.paymentDate.year, p.paymentDate.month, p.paymentDate.day);
      if (d.isBefore(r.start) || d.isAfter(r.end)) continue;
      total += p.amount;
    }
    return total;
  }

  // 指定月の引き落とし日セット（ドット表示用）
  Set<int> paymentDaysInMonth(DateTime month) {
    final days = <int>{};
    // 銀行確定のbank支払い日
    for (final p in payments) {
      if (p.source == PaymentSource.bank &&
          p.paymentDate.year == month.year &&
          p.paymentDate.month == month.month) {
        days.add(p.paymentDate.day);
      }
    }
    // 設定済みカードの引き落とし予定日。引き落とし日は毎月同じなので、
    //   まだ利用データが無い翌月以降も日付だけは表示する（土日祝は翌営業日）。
    for (final e in cardPaymentDays.entries) {
      days.add(cardDrawDateOf(e.key, month).day);
    }
    return days;
  }

  // 指定月の給料日（Set<int> day）。
  Set<int> paydayDaysInMonth(DateTime month) {
    return paydaysNear(month).where((e) =>
      e.date.year == month.year && e.date.month == month.month
    ).map((e) => e.date.day).toSet();
  }

  // 今月末残高の内訳（タップ詳細用）。現在の残高→デビット調整(#5#6)→給料入金→引き落とし。
  Map<String, int> get thisMonthBreakdown {
    final now = DateTime.now();
    final out = <String, int>{'現在の残高': currentBalance};
    if (showWalletCash && walletCash != 0) out['財布の現金'] = walletCash;
    final debit = debitsAfterSnapshot();
    if (debit > 0) out['デビット利用（編集後・即時引落）'] = -debit;
    final income = incomeForecastIn(now);
    if (income != 0) out['給料入金（編集後）'] = income;
    for (final e in drawBreakdownOf(now)) {
      out[drawLabelOf(e.label, now)] = -e.amount;
    }
    return out;
  }

  // 来月末残高の内訳。
  Map<String, int> get nextMonthBreakdown {
    final next = DateTime(DateTime.now().year, DateTime.now().month + 1, 1);
    final out = <String, int>{'今月末残高': thisMonthBalance};
    final income = incomeForecastIn(next);
    if (income != 0) out['給料入金'] = income;
    for (final e in drawBreakdownOf(next)) {
      out[drawLabelOf(e.label, next)] = -e.amount;
    }
    return out;
  }

  // 翌々月末残高の内訳。
  Map<String, int> get monthAfterNextBreakdown {
    final m2 = DateTime(DateTime.now().year, DateTime.now().month + 2, 1);
    final out = <String, int>{'来月末残高': nextMonthBalance};
    final income = incomeForecastIn(m2);
    if (income != 0) out['給料入金'] = income;
    for (final e in drawBreakdownOf(m2)) {
      out[drawLabelOf(e.label, m2)] = -e.amount;
    }
    return out;
  }

  // 残高不足アラート（マイナスになる支払い予定）
  List<Payment> get shortagePayments {
    final balance = thisMonthBalance;
    return balance < 0
        ? (payments.where((p) => !p.paid).toList()
          ..sort((a, b) => a.paymentDate.compareTo(b.paymentDate)))
        : [];
  }

  // ════════════════ バックアップ（エクスポート/インポート）════════════════
  // 全データを1つのJSON文字列に書き出す（機種変・バックアップ用）。
  String exportJson() {
    final map = {
      'version': 1,
      'exportedAt': DateTime.now().toIso8601String(),
      'shifts': shifts.map((k, v) => MapEntry(k, v.map((e) => e.toJson()).toList())),
      'workplaces': workplaces.map((e) => e.toJson()).toList(),
      'actualSalaries': actualSalaries,
      'actualSalariesByWp': actualSalariesByWp,
      'balanceUpdatedAt': balanceUpdatedAt?.toIso8601String(),
      'paymentNotes': paymentNotes,
      'amazonCardOverrides': amazonCardOverrides,
      'cardAliases': cardAliases,
      'cardPaymentDays': cardPaymentDays,
      'cardClosingDays': cardClosingDays,
      'events': events.map((k, v) => MapEntry(k, v.map((e) => e.toJson()).toList())),
      'todos': todos.map((k, v) => MapEntry(k, v.map((e) => e.toJson()).toList())),
      'payments': payments.map((e) => e.toJson()).toList(),
      'installments': installments.map((e) => e.toJson()).toList(),
      'subscriptions': subscriptions.map((e) => e.toJson()).toList(),
      'loans': loans.map((e) => e.toJson()).toList(),
      'withdrawals': withdrawals.map((e) => e.toJson()).toList(),
      'currentBalance': currentBalance,
      'walletCash': walletCash,
      'pendingDeposits': pendingDeposits.map((e) => e.toJson()).toList(),
      'handledDepositIds': handledDepositIds.toList(),
      'handledDrawIds': handledDrawIds.toList(),
      'balanceHistory': balanceHistory.map((e) => e.toJson()).toList(),
      'paidSalaryKeys': paidSalaryKeys.toList(),
      'plannedIncomes': plannedIncomes.map((e) => e.toJson()).toList(),
      'receivedPlannedKeys': receivedPlannedKeys.toList(),
      'salaryPaidThroughMonth': salaryPaidThroughMonth?.toIso8601String(),
      'cardInterestRates': cardInterestRates,
      'convertedPaymentKeys': convertedPaymentKeys.toList(),
      'convertedSourceIds': convertedSourceIds.toList(),
      'trashedPayments': trashedPayments.map((e) => e.toJson()).toList(),
      'deletedSourceIds': deletedSourceIds.toList(),
      'deletedDupKeys': deletedDupKeys.toList(),
      'gmailFirstSyncDone': gmailFirstSyncDone,
      'goalAmount': goalAmount,
      'goalDate': goalDate?.toIso8601String(),
      'budgets': budgets,
    };
    return const JsonEncoder.withIndent('  ').convert(map);
  }

  // CSV（シフトの実績一覧）を書き出す。表計算で見たい人向けの簡易版。
  String exportShiftsCsv() {
    final rows = <String>['日付,勤務先,開始,終了,休憩(分),時給,給与'];
    final keys = shifts.keys.toList()..sort();
    for (final k in keys) {
      for (final s in shifts[k]!) {
        rows.add('$k,${s.workplace},${s.start.toIso8601String()},'
            '${s.end.toIso8601String()},${s.breakMinutes},${s.hourlyWage},${s.earnings}');
      }
    }
    return rows.join('\n');
  }

  // ────── CSVインポート ──────
  // exportShiftsCsv() が書き出した形式のシフトCSVを取り込む。
  // 💡 CSVには交通費・深夜/残業/休日の割増が載らないので、「給与」列から逆算して
  //    復元する（そうしないと取り込んだ月の収入がズレる）。
  CsvImportResult importShiftsCsv(String text, {bool replace = false}) {
    final lines = const LineSplitter()
        .convert(text.replaceAll('﻿', ''))
        .where((l) => l.trim().isNotEmpty)
        .toList();
    if (lines.isEmpty) return const CsvImportResult();

    // ヘッダー列名 → 位置。未知のヘッダーなら書き出し順の固定位置にフォールバック。
    const names = ['日付', '勤務先', '開始', '終了', '休憩(分)', '時給', '給与'];
    final header = _splitCsvLine(lines.first).map((e) => e.trim()).toList();
    final idx = <String, int>{};
    for (var i = 0; i < header.length; i++) {
      idx[header[i]] = i;
    }
    final hasHeader = idx.containsKey('日付') && idx.containsKey('開始');
    for (var i = 0; i < names.length; i++) {
      idx.putIfAbsent(names[i], () => i);
    }

    var failed = 0;
    final parsed = <_CsvShiftRow>[];
    for (final line in lines.skip(hasHeader ? 1 : 0)) {
      final f = _splitCsvLine(line);
      String cell(String name) {
        final i = idx[name]!;
        return i < f.length ? f[i].trim() : '';
      }

      final start = DateTime.tryParse(cell('開始'));
      final end = DateTime.tryParse(cell('終了'));
      final wp = cell('勤務先');
      if (start == null || end == null || wp.isEmpty || !end.isAfter(start)) {
        failed++;
        continue;
      }
      parsed.add(_CsvShiftRow(
        workplace: wp,
        start: start,
        end: end,
        breakMinutes: int.tryParse(cell('休憩(分)')) ?? 0,
        hourlyWage: int.tryParse(cell('時給')) ?? 0,
        earnings: int.tryParse(cell('給与')) ?? 0,
      ));
    }
    if (parsed.isEmpty) return CsvImportResult(failed: failed);

    // 勤務先ごとに交通費・割増を推定
    final byWorkplace = <String, List<_CsvShiftRow>>{};
    for (final r in parsed) {
      byWorkplace.putIfAbsent(r.workplace, () => []).add(r);
    }
    final fits = {
      for (final e in byWorkplace.entries) e.key: _fitWageSettings(e.value)
    };

    if (replace) shifts.clear();

    // 既存シフトの重複判定キー（日付+勤務先+開始+終了）
    String keyOf(String dateKey, ShiftData s) =>
        '$dateKey|${s.workplace}|${s.start.toIso8601String()}|${s.end.toIso8601String()}';
    final existing = <String>{};
    shifts.forEach((k, list) {
      for (final s in list) {
        existing.add(keyOf(k, s));
      }
    });

    var imported = 0, skipped = 0, mismatched = 0;
    for (final r in parsed) {
      final fit = fits[r.workplace]!;
      final s = ShiftData(
        workplace: r.workplace,
        hourlyWage: r.hourlyWage,
        start: r.start,
        end: r.end,
        breakMinutes: r.breakMinutes,
        transportPerDay: fit.transportPerDay,
        nightMultiplier: fit.nightMultiplier,
        overtimeMultiplier: fit.overtimeMultiplier,
        holidayMultiplier: fit.holidayMultiplier,
      );
      final dateKey = DateFormat('yyyy-MM-dd').format(r.start);
      final k = keyOf(dateKey, s);
      if (existing.contains(k)) {
        skipped++;
        continue;
      }
      existing.add(k);
      shifts.putIfAbsent(dateKey, () => []).add(s);
      imported++;
      if (r.earnings > 0 && s.earnings != r.earnings) mismatched++;
    }

    // 新しい勤務先は推定した給料情報つきで作る（以後の手入力にも効く）
    for (final entry in byWorkplace.entries) {
      if (workplaces.any((w) => w.name == entry.key)) continue;
      final fit = fits[entry.key]!;
      final latest = entry.value.reduce((a, b) => a.start.isAfter(b.start) ? a : b);
      workplaces.add(Workplace(
        id: newWorkplaceId(),
        name: entry.key,
        colorValue:
            workplaceColorPalette[workplaces.length % workplaceColorPalette.length]
                .toARGB32(),
        wagePeriods: [
          WagePeriod(
            hourlyWage: latest.hourlyWage,
            transportPerDay: fit.transportPerDay,
            nightMultiplier: fit.nightMultiplier,
            overtimeMultiplier: fit.overtimeMultiplier,
            holidayMultiplier: fit.holidayMultiplier,
          ),
        ],
      ));
    }

    _migrateWorkplaces(); // workplaceId の紐付け
    saveData();
    notifyListeners();
    return CsvImportResult(
      imported: imported,
      skipped: skipped,
      failed: failed,
      mismatched: mismatched,
    );
  }

  // 💡 給与列に一致するように交通費と各割増を総当たりで推定する。
  //    倍率は 1.00〜2.00 の 0.05 刻み。該当行が無い項目はループごと省くので軽い。
  _WageFit _fitWageSettings(List<_CsvShiftRow> rows) {
    final hasNight = rows.any((r) => r.nightHours > 0);
    final hasOvertime = rows.any((r) => r.hours > 8);
    final hasHoliday = rows.any((r) => r.isWeekend);
    const steps = 21; // 1.00, 1.05, ... 2.00

    _WageFit? best;
    var bestHits = -1, bestSimple = 99, bestTransport = 1 << 30;
    for (var a = 0; a < (hasNight ? steps : 1); a++) {
      final nm = 1.0 + a * 0.05;
      for (var b = 0; b < (hasOvertime ? steps : 1); b++) {
        final om = 1.0 + b * 0.05;
        for (var c = 0; c < (hasHoliday ? steps : 1); c++) {
          final hm = 1.0 + c * 0.05;
          // 残差（= 交通費の候補）の最頻値をとる
          final counts = <int, int>{};
          for (final r in rows) {
            final diff = r.earnings - r.wageWith(nm, om, hm);
            if (diff < 0) continue;
            counts[diff] = (counts[diff] ?? 0) + 1;
          }
          if (counts.isEmpty) continue;
          var tp = 0, hits = 0;
          counts.forEach((k, v) {
            if (v > hits || (v == hits && k < tp)) {
              tp = k;
              hits = v;
            }
          });
          final simple = (nm > 1.0001 ? 1 : 0) +
              (om > 1.0001 ? 1 : 0) +
              (hm > 1.0001 ? 1 : 0);
          // 一致数が多い → 設定が単純 → 交通費が小さい、の順に良いとみなす
          final better = hits > bestHits ||
              (hits == bestHits &&
                  (simple < bestSimple ||
                      (simple == bestSimple && tp < bestTransport)));
          if (!better) continue;
          bestHits = hits;
          bestSimple = simple;
          bestTransport = tp;
          best = _WageFit(
            transportPerDay: tp,
            nightMultiplier: nm,
            overtimeMultiplier: om,
            holidayMultiplier: hm,
          );
        }
      }
    }
    return best ?? const _WageFit();
  }

  // ────── 自動バックアップ ──────
  // 1日1回、アプリのDocumentsディレクトリにJSONを保存。直近7件を保持。
  Future<void> doAutoBackup() async {
    if (kIsWeb) return; // Webはファイル保存できない（設定→書き出しで手動保存）
    if (!autoBackupEnabled) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final backupDir = Directory('${dir.path}/backups');
      if (!await backupDir.exists()) await backupDir.create(recursive: true);
      final ts = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final file = File('${backupDir.path}/pocket_maid_$ts.json');
      await file.writeAsString(exportJson());
      lastAutoBackupAt = DateTime.now();
      // 古い7件超えのバックアップを削除
      final files = (await backupDir.list().toList())
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path));
      for (var i = 7; i < files.length; i++) {
        await files[i].delete();
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('saved_last_backup_at', lastAutoBackupAt!.toIso8601String());
    } catch (_) {}
  }

  // バックアップファイルの一覧を返す（新しい順）。
  Future<List<File>> listBackupFiles() async {
    if (kIsWeb) return [];
    try {
      final dir = await getApplicationDocumentsDirectory();
      final backupDir = Directory('${dir.path}/backups');
      if (!await backupDir.exists()) return [];
      final files = (await backupDir.list().toList())
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path));
      return files;
    } catch (_) {
      return [];
    }
  }

  // バックアップファイルからリストア。
  Future<void> restoreFromBackup(File file) async {
    final text = await file.readAsString();
    importJson(text);
  }

  Future<void> setAutoBackupEnabled(bool on) async {
    autoBackupEnabled = on;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('saved_auto_backup_enabled', on);
    notifyListeners();
    if (on) doAutoBackup();
  }

  // エクスポートしたJSONを取り込んで全データを置き換える。
  void importJson(String text) {
    // 取り込みは「この端末での変更」ではないので、更新時刻を刻まない。
    // （刻むと、取り込んだ直後に「こちらの方が新しい」と誤判定して押し戻してしまう）
    _importing = true;
    try {
      _importJson(text);
    } finally {
      _importing = false;
    }
  }

  void _importJson(String text) {
    final map = jsonDecode(text) as Map<String, dynamic>;

    shifts.clear();
    (map['shifts'] as Map?)?.forEach((k, v) =>
        shifts[k] = (v as List).map((e) => ShiftData.fromJson(e)).toList());

    workplaces
      ..clear()
      ..addAll((map['workplaces'] as List? ?? []).map((e) => Workplace.fromJson(e)));

    actualSalaries.clear();
    (map['actualSalaries'] as Map?)?.forEach((k, v) {
      if (v is int) actualSalaries[k] = v;
    });
    actualSalariesByWp.clear();
    (map['actualSalariesByWp'] as Map?)?.forEach((k, v) {
      if (v is int) actualSalariesByWp[k] = v;
    });
    final buaStr = map['balanceUpdatedAt'] as String?;
    balanceUpdatedAt = (buaStr != null && buaStr.isNotEmpty) ? DateTime.tryParse(buaStr) : null;
    paymentNotes.clear();
    (map['paymentNotes'] as Map?)?.forEach((k, v) {
      if (v is String) paymentNotes['$k'] = v;
    });
    amazonCardOverrides.clear();
    (map['amazonCardOverrides'] as Map?)?.forEach((k, v) {
      if (v is String) amazonCardOverrides['$k'] = v;
    });
    cardAliases.clear();
    (map['cardAliases'] as Map?)?.forEach((k, v) {
      if (v is String) cardAliases['$k'] = v;
    });
    // 💡 マージだと、別端末で削除したカードが取り込みのたびに復活する。置き換える。
    final cpd = map['cardPaymentDays'] as Map?;
    if (cpd != null) {
      cardPaymentDays.clear();
      cpd.forEach((k, v) {
        if (v is int) cardPaymentDays['$k'] = v;
      });
    }
    cardClosingDays.clear();
    (map['cardClosingDays'] as Map?)?.forEach((k, v) {
      if (v is int) cardClosingDays[k] = v;
    });

    events.clear();
    (map['events'] as Map?)?.forEach((k, v) =>
        events[k] = (v as List).map((e) => EventData.fromJson(e)).toList());

    todos.clear();
    (map['todos'] as Map?)?.forEach((k, v) =>
        todos[k] = (v as List).map((e) => TodoData.fromJson(e)).toList());

    payments = (map['payments'] as List? ?? []).map((e) => Payment.fromJson(e)).toList();
    installments =
        (map['installments'] as List? ?? []).map((e) => Installment.fromJson(e)).toList();
    subscriptions =
        (map['subscriptions'] as List? ?? []).map((e) => Subscription.fromJson(e)).toList();
    loans = (map['loans'] as List? ?? []).map((e) => Loan.fromJson(e)).toList();
    withdrawals =
        (map['withdrawals'] as List? ?? []).map((e) => Withdrawal.fromJson(e)).toList();

    currentBalance = map['currentBalance'] ?? currentBalance;
    walletCash = map['walletCash'] ?? walletCash;
    pendingDeposits = (map['pendingDeposits'] as List? ?? [])
        .map((e) => DepositNotice.fromJson(e))
        .toList();
    handledDepositIds
      ..clear()
      ..addAll((map['handledDepositIds'] as List? ?? []).map((e) => e.toString()));
    handledDrawIds
      ..clear()
      ..addAll((map['handledDrawIds'] as List? ?? []).map((e) => e.toString()));
    balanceHistory = (map['balanceHistory'] as List? ?? [])
        .map((e) => BalanceEntry.fromJson(e))
        .toList();
    paidSalaryKeys
      ..clear()
      ..addAll((map['paidSalaryKeys'] as List? ?? []).map((e) => e.toString()));
    plannedIncomes = (map['plannedIncomes'] as List? ?? [])
        .map((e) => PlannedIncome.fromJson(e))
        .toList();
    receivedPlannedKeys
      ..clear()
      ..addAll((map['receivedPlannedKeys'] as List? ?? []).map((e) => e.toString()));
    final sptStr = map['salaryPaidThroughMonth'] as String?;
    salaryPaidThroughMonth =
        (sptStr != null && sptStr.isNotEmpty) ? DateTime.tryParse(sptStr) : null;

    cardInterestRates.clear();
    (map['cardInterestRates'] as Map?)?.forEach((k, v) {
      cardInterestRates[k] = (v as num).toDouble();
    });

    convertedPaymentKeys
      ..clear()
      ..addAll((map['convertedPaymentKeys'] as List? ?? []).map((e) => e.toString()));
    convertedSourceIds
      ..clear()
      ..addAll((map['convertedSourceIds'] as List? ?? []).map((e) => e.toString()));

    trashedPayments =
        (map['trashedPayments'] as List? ?? []).map((e) => Payment.fromJson(e)).toList();
    deletedSourceIds
      ..clear()
      ..addAll((map['deletedSourceIds'] as List? ?? []).map((e) => e.toString()));
    deletedDupKeys
      ..clear()
      ..addAll((map['deletedDupKeys'] as List? ?? []).map((e) => e.toString()));

    gmailFirstSyncDone = map['gmailFirstSyncDone'] ?? gmailFirstSyncDone;
    goalAmount = map['goalAmount'] ?? 0;
    final gd = map['goalDate'] as String?;
    goalDate = (gd != null && gd.isNotEmpty) ? DateTime.tryParse(gd) : null;

    budgets.clear();
    (map['budgets'] as Map?)?.forEach((k, v) {
      if (v is int) budgets[k] = v;
    });

    saveData();
    notifyListeners();
  }

  // ════════════════ 保存・読込 ════════════════
  bool _importing = false; // インポート中は「この端末で変更した」と数えない

  Future<void> saveData() async {
    final prefs = await SharedPreferences.getInstance();
    if (!_importing) {
      dataUpdatedAt = DateTime.now();
      await prefs.setString('saved_data_updated_at', dataUpdatedAt!.toIso8601String());
    }
    await prefs.setString('saved_shifts', jsonEncode(shifts));
    await prefs.setString('saved_payment_notes', jsonEncode(paymentNotes));
    await prefs.setString('saved_amazon_overrides', jsonEncode(amazonCardOverrides));
    await prefs.setString('saved_card_aliases', jsonEncode(cardAliases));
    await prefs.setString('saved_actual_salaries', jsonEncode(actualSalaries));
    await prefs.setString('saved_actual_salaries_by_wp', jsonEncode(actualSalariesByWp));
    await prefs.setString('saved_balance_updated_at', balanceUpdatedAt?.toIso8601String() ?? '');
    await prefs.setInt('saved_goal_amount', goalAmount);
    await prefs.setString('saved_goal_date', goalDate?.toIso8601String() ?? '');
    await prefs.setString('saved_budgets', jsonEncode(budgets));
    await prefs.setString('saved_workplaces',
        jsonEncode(workplaces.map((e) => e.toJson()).toList()));
    await prefs.setString('saved_events', jsonEncode(events));
    await prefs.setString(
        'saved_todos',
        jsonEncode(todos.map(
            (k, v) => MapEntry(k, v.map((t) => t.toJson()).toList()))));
    await prefs.setString(
        'saved_payments', jsonEncode(payments.map((e) => e.toJson()).toList()));
    await prefs.setString('saved_installments',
        jsonEncode(installments.map((e) => e.toJson()).toList()));
    await prefs.setString('saved_subscriptions',
        jsonEncode(subscriptions.map((e) => e.toJson()).toList()));
    await prefs.setString(
        'saved_loans', jsonEncode(loans.map((e) => e.toJson()).toList()));
    await prefs.setString('saved_withdrawals',
        jsonEncode(withdrawals.map((e) => e.toJson()).toList()));
    await prefs.setInt('saved_balance', currentBalance);
    await prefs.setInt('saved_wallet_cash', walletCash);
    await prefs.setString(
        'saved_pending_deposits', jsonEncode(pendingDeposits.map((e) => e.toJson()).toList()));
    await prefs.setStringList('saved_handled_deposit_ids', handledDepositIds.toList());
    await prefs.setStringList('saved_handled_draw_ids', handledDrawIds.toList());
    await prefs.setString(
        'saved_balance_history', jsonEncode(balanceHistory.map((e) => e.toJson()).toList()));
    await prefs.setStringList('saved_paid_salary_keys', paidSalaryKeys.toList());
    await prefs.setString(
        'saved_planned_incomes', jsonEncode(plannedIncomes.map((e) => e.toJson()).toList()));
    await prefs.setStringList('saved_received_planned_keys', receivedPlannedKeys.toList());
    await prefs.setString(
        'saved_salary_paid_through', salaryPaidThroughMonth?.toIso8601String() ?? '');
    await prefs.setString('saved_card_rates', jsonEncode(cardInterestRates));
    await prefs.setStringList('saved_converted_keys', convertedPaymentKeys.toList());
    await prefs.setStringList('saved_converted_source_ids', convertedSourceIds.toList());
    await prefs.setString(
        'saved_trashed_payments', jsonEncode(trashedPayments.map((e) => e.toJson()).toList()));
    await prefs.setStringList('saved_deleted_source_ids', deletedSourceIds.toList());
    await prefs.setStringList('saved_deleted_dup_keys', deletedDupKeys.toList());
    await prefs.setBool('saved_calendar_autosync', calendarAutoSync);
    await prefs.setBool('saved_first_sync', gmailFirstSyncDone);
    // 自動バックアップ（1日1回）
    final now = DateTime.now();
    if (autoBackupEnabled &&
        (lastAutoBackupAt == null ||
            lastAutoBackupAt!.year != now.year ||
            lastAutoBackupAt!.month != now.month ||
            lastAutoBackupAt!.day != now.day)) {
      doAutoBackup();
    }
  }

  Future<void> loadData() async {
    final prefs = await SharedPreferences.getInstance();

    final shiftsStr = prefs.getString('saved_shifts');
    if (shiftsStr != null) {
      (jsonDecode(shiftsStr) as Map<String, dynamic>).forEach((k, v) {
        shifts[k] = (v as List).map((e) => ShiftData.fromJson(e)).toList();
      });
    }

    final actualSalStr = prefs.getString('saved_actual_salaries');
    if (actualSalStr != null) {
      (jsonDecode(actualSalStr) as Map<String, dynamic>).forEach((k, v) {
        if (v is int) actualSalaries[k] = v;
      });
    }
    final actualSalWpStr = prefs.getString('saved_actual_salaries_by_wp');
    if (actualSalWpStr != null) {
      (jsonDecode(actualSalWpStr) as Map<String, dynamic>).forEach((k, v) {
        if (v is int) actualSalariesByWp[k] = v;
      });
    }
    final buaStr = prefs.getString('saved_balance_updated_at');
    balanceUpdatedAt = (buaStr != null && buaStr.isNotEmpty) ? DateTime.tryParse(buaStr) : null;
    goalAmount = prefs.getInt('saved_goal_amount') ?? 0;
    final goalStr = prefs.getString('saved_goal_date');
    goalDate = (goalStr != null && goalStr.isNotEmpty) ? DateTime.tryParse(goalStr) : null;
    final budgetsStr = prefs.getString('saved_budgets');
    if (budgetsStr != null) {
      (jsonDecode(budgetsStr) as Map<String, dynamic>).forEach((k, v) {
        if (v is int) budgets[k] = v;
      });
    }

    final workplacesStr = prefs.getString('saved_workplaces');
    if (workplacesStr != null) {
      workplaces
        ..clear()
        ..addAll((jsonDecode(workplacesStr) as List)
            .map((e) => Workplace.fromJson(e)));
    }

    final eventsStr = prefs.getString('saved_events');
    if (eventsStr != null) {
      (jsonDecode(eventsStr) as Map<String, dynamic>).forEach((k, v) {
        events[k] = (v as List).map((e) => EventData.fromJson(e)).toList();
      });
    }

    final todosStr = prefs.getString('saved_todos');
    if (todosStr != null) {
      (jsonDecode(todosStr) as Map<String, dynamic>).forEach((k, v) {
        todos[k] = (v as List).map((e) => TodoData.fromJson(e)).toList();
      });
    }

    final paymentsStr = prefs.getString('saved_payments');
    if (paymentsStr != null) {
      payments = (jsonDecode(paymentsStr) as List)
          .map((e) => Payment.fromJson(e))
          .toList();
      // 旧データの重複IDを振り直し（Keyの衝突・巻き込み削除を防ぐ）
      final seen = <String>{};
      var dedupped = false;
      for (final p in payments) {
        if (!seen.add(p.id)) {
          p.id = _id();
          dedupped = true;
        }
      }
      if (dedupped) saveData();
    }

    final installStr = prefs.getString('saved_installments');
    if (installStr != null) {
      installments = (jsonDecode(installStr) as List)
          .map((e) => Installment.fromJson(e))
          .toList();
    }

    final subsStr = prefs.getString('saved_subscriptions');
    if (subsStr != null) {
      subscriptions = (jsonDecode(subsStr) as List)
          .map((e) => Subscription.fromJson(e))
          .toList();
    }

    final loanStr = prefs.getString('saved_loans');
    if (loanStr != null) {
      loans = (jsonDecode(loanStr) as List).map((e) => Loan.fromJson(e)).toList();
    }

    final wdStr = prefs.getString('saved_withdrawals');
    if (wdStr != null) {
      withdrawals = (jsonDecode(wdStr) as List)
          .map((e) => Withdrawal.fromJson(e))
          .toList();
    }

    currentBalance = prefs.getInt('saved_balance') ?? 0;
    walletCash = prefs.getInt('saved_wallet_cash') ?? 0;
    final pdStr = prefs.getString('saved_pending_deposits');
    if (pdStr != null) {
      pendingDeposits =
          (jsonDecode(pdStr) as List).map((e) => DepositNotice.fromJson(e)).toList();
    }
    handledDepositIds
      ..clear()
      ..addAll(prefs.getStringList('saved_handled_deposit_ids') ?? const []);
    handledDrawIds
      ..clear()
      ..addAll(prefs.getStringList('saved_handled_draw_ids') ?? const []);
    final histStr = prefs.getString('saved_balance_history');
    if (histStr != null) {
      balanceHistory =
          (jsonDecode(histStr) as List).map((e) => BalanceEntry.fromJson(e)).toList();
    }
    paidSalaryKeys
      ..clear()
      ..addAll(prefs.getStringList('saved_paid_salary_keys') ?? const []);
    final planStr = prefs.getString('saved_planned_incomes');
    if (planStr != null) {
      plannedIncomes =
          (jsonDecode(planStr) as List).map((e) => PlannedIncome.fromJson(e)).toList();
    }
    receivedPlannedKeys
      ..clear()
      ..addAll(prefs.getStringList('saved_received_planned_keys') ?? const []);
    final sptStr = prefs.getString('saved_salary_paid_through');
    salaryPaidThroughMonth =
        (sptStr != null && sptStr.isNotEmpty) ? DateTime.tryParse(sptStr) : null;
    // 💡 一度だけの移行: 2026年8月までの給料は受け取り済みとして扱う
    //   （既存ユーザーは8月分まで入金済みのため、9月分から選択肢に出す）
    if (!(prefs.getBool('migrated_salary_paid_through_202608') ?? false)) {
      salaryPaidThroughMonth ??= DateTime(2026, 8);
      await prefs.setString(
          'saved_salary_paid_through', salaryPaidThroughMonth!.toIso8601String());
      await prefs.setBool('migrated_salary_paid_through_202608', true);
    }

    final ratesStr = prefs.getString('saved_card_rates');
    if (ratesStr != null) {
      (jsonDecode(ratesStr) as Map<String, dynamic>).forEach((k, v) {
        cardInterestRates[k] = (v as num).toDouble();
      });
    }
    convertedPaymentKeys
      ..clear()
      ..addAll(prefs.getStringList('saved_converted_keys') ?? const []);
    convertedSourceIds
      ..clear()
      ..addAll(prefs.getStringList('saved_converted_source_ids') ?? const []);

    final trashStr = prefs.getString('saved_trashed_payments');
    if (trashStr != null) {
      trashedPayments =
          (jsonDecode(trashStr) as List).map((e) => Payment.fromJson(e)).toList();
    }
    deletedSourceIds
      ..clear()
      ..addAll(prefs.getStringList('saved_deleted_source_ids') ?? const []);
    deletedDupKeys
      ..clear()
      ..addAll(prefs.getStringList('saved_deleted_dup_keys') ?? const []);
    calendarAutoSync = prefs.getBool('saved_calendar_autosync') ?? false;
    autoBackupEnabled = prefs.getBool('saved_auto_backup_enabled') ?? true;
    showMonthAfterNext = prefs.getBool('saved_show_month_after_next') ?? true;
    showWalletCash = prefs.getBool('saved_show_wallet_cash') ?? true;
    backgroundTheme = prefs.getString('saved_background_theme') ?? 'pink';
    final cpdStr = prefs.getString('saved_card_payment_days');
    if (cpdStr == null) {
      // 初回起動：種をデータとして書き込む（以後はここを通らない）
      cardPaymentDays = Map<String, int>.from(kSeedCardPaymentDays);
      await prefs.setString('saved_card_payment_days', jsonEncode(cardPaymentDays));
    } else {
      // 保存済みの内容で「置き換える」。消したカードが復活しないように。
      cardPaymentDays
        ..clear()
        ..addAll({
          for (final e in (jsonDecode(cpdStr) as Map<String, dynamic>).entries)
            if (e.value is int) e.key: e.value as int
        });
    }
    final caStr = prefs.getString('saved_card_aliases');
    if (caStr != null) {
      (jsonDecode(caStr) as Map<String, dynamic>).forEach((k, v) {
        if (v is String) cardAliases[k] = v;
      });
    }
    final aoStr = prefs.getString('saved_amazon_overrides');
    if (aoStr != null) {
      (jsonDecode(aoStr) as Map<String, dynamic>).forEach((k, v) {
        if (v is String) amazonCardOverrides[k] = v;
      });
    }
    final pnStr = prefs.getString('saved_payment_notes');
    if (pnStr != null) {
      (jsonDecode(pnStr) as Map<String, dynamic>).forEach((k, v) {
        if (v is String) paymentNotes[k] = v;
      });
    }
    final ccdStr = prefs.getString('saved_card_closing_days');
    if (ccdStr != null) {
      (jsonDecode(ccdStr) as Map<String, dynamic>).forEach((k, v) {
        if (v is int) cardClosingDays[k] = v;
      });
    }
    final lbaStr = prefs.getString('saved_last_backup_at');
    if (lbaStr != null && lbaStr.isNotEmpty) lastAutoBackupAt = DateTime.tryParse(lbaStr);

    gmailFirstSyncDone = prefs.getBool('saved_first_sync') ?? false;

    driveSyncEnabled = prefs.getBool('saved_drive_sync_enabled') ?? false;
    requireGoogleLogin = prefs.getBool('saved_require_google_login') ?? false;
    DateTime? readAt(String key) {
      final s = prefs.getString(key);
      return (s == null || s.isEmpty) ? null : DateTime.tryParse(s);
    }

    dataUpdatedAt = readAt('saved_data_updated_at');
    driveSyncedAt = readAt('saved_drive_synced_at');
    driveKnownRemoteAt = readAt('saved_drive_remote_at');

    // 💡 「三井住友」は「三井OLIVE」に統合
    var migrated = false;
    for (final p in payments) {
      if (p.cardName == '三井住友') {
        p.cardName = '三井OLIVE';
        migrated = true;
      }
    }
    for (final i in installments) {
      if (i.cardName == '三井住友') {
        i.cardName = '三井OLIVE';
        migrated = true;
      }
      // 旧データ: startDate が無ければ名前内の日付 "(2026-03-11)" から復元
      if (i.startDate == null) {
        final m = RegExp(r'(\d{4})-(\d{1,2})-(\d{1,2})').firstMatch(i.name);
        if (m != null) {
          i.startDate =
              DateTime(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
          migrated = true;
        }
      }
    }
    if (_migrateWorkplaces()) migrated = true;
    // 分割へ移した決済がカード側に残っていたら掃除（旧バージョンの取りこぼしを自己修復）
    if (cleanupInstallmentDuplicates() > 0) migrated = true;
    if (migrated) saveData();

    notifyListeners();
  }

  // 💡 既存の手入力シフト（workplace文字列）から勤務先マスタを自動生成し、
  //    各シフトに workplaceId を紐付ける。戻り値: 変更があれば true。
  bool _migrateWorkplaces() {
    var changed = false;
    // 既存の勤務先名→id
    final byName = <String, Workplace>{for (final w in workplaces) w.name: w};

    // シフトに登場する勤務先名と「最新シフトの時給」を集める
    final latestWageByName = <String, ({DateTime date, int wage})>{};
    shifts.forEach((dateKey, list) {
      final d = DateTime.tryParse(dateKey);
      for (final s in list) {
        final name = s.workplace.trim();
        if (name.isEmpty) continue;
        if (d != null) {
          final cur = latestWageByName[name];
          if (cur == null || d.isAfter(cur.date)) {
            latestWageByName[name] = (date: d, wage: s.hourlyWage);
          }
        }
        latestWageByName.putIfAbsent(name, () => (date: DateTime(2000), wage: s.hourlyWage));
      }
    });

    // 未登録の勤務先を生成
    for (final entry in latestWageByName.entries) {
      if (byName.containsKey(entry.key)) continue;
      final color = workplaceColorPalette[
          workplaces.length % workplaceColorPalette.length];
      final w = Workplace(
        id: newWorkplaceId(),
        name: entry.key,
        colorValue: color.toARGB32(),
        wagePeriods: [WagePeriod(hourlyWage: entry.value.wage)],
      );
      workplaces.add(w);
      byName[entry.key] = w;
      changed = true;
    }

    // シフトに workplaceId を紐付け（未設定のものだけ）
    shifts.forEach((dateKey, list) {
      for (var i = 0; i < list.length; i++) {
        final s = list[i];
        if (s.workplaceId != null) continue;
        final w = byName[s.workplace.trim()];
        if (w == null) continue;
        list[i] = ShiftData(
          workplace: s.workplace,
          workplaceId: w.id,
          hourlyWage: s.hourlyWage,
          start: s.start,
          end: s.end,
          breakMinutes: s.breakMinutes,
          transportPerDay: s.transportPerDay,
          transportMonthlyCap: s.transportMonthlyCap,
          nightMultiplier: s.nightMultiplier,
          overtimeMultiplier: s.overtimeMultiplier,
          holidayMultiplier: s.holidayMultiplier,
        );
        changed = true;
      }
    });

    return changed;
  }
}
