// 💡 アプリ → Googleカレンダー の一方向同期。
//   専用カレンダー「ポケットメイド」を作り、そこにだけ書く。
//   Google側で編集してもアプリには取り込まない（アプリが「元」）。
//
//   Googleカレンダーに入れておけば、iPhoneやMacの純正カレンダーには
//   端末側でGoogleアカウントを追加するだけで自動的に届く。
//   （device_calendar と違い、Web版でも動くのが利点）
import 'package:googleapis/calendar/v3.dart' as gcal;
import 'package:shared_preferences/shared_preferences.dart';

import 'app_state.dart';
import 'gmail_service.dart';

class GoogleCalendarSync implements CalendarSyncHook {
  GoogleCalendarSync(this.appState);
  final AppState appState;

  static const String _calendarName = 'ポケットメイド';
  static const String _kCalendarId = 'saved_gcal_id';

  String? _calendarId;
  String? lastError;

  // 専用カレンダーを用意する（無ければ作る）。使えるようになったら true。
  Future<bool> _ensure() async {
    if (_calendarId != null) return true;
    final api = await GmailService.instance.calendarApi();
    if (api == null) {
      lastError = 'Googleに連携されていません';
      return false;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_kCalendarId);
      if (saved != null && saved.isNotEmpty) {
        // 消されていないか確認する（消えていたら作り直す）
        try {
          await api.calendars.get(saved);
          _calendarId = saved;
          return true;
        } catch (_) {
          await prefs.remove(_kCalendarId);
        }
      }

      // 同じ名前のカレンダーが既にあれば使い回す
      final list = await api.calendarList.list();
      for (final c in list.items ?? const <gcal.CalendarListEntry>[]) {
        if (c.summary == _calendarName && c.id != null) {
          _calendarId = c.id;
          await prefs.setString(_kCalendarId, c.id!);
          return true;
        }
      }

      final created = await api.calendars.insert(
        gcal.Calendar()
          ..summary = _calendarName
          ..description = 'ポケットメイドのシフト・予定・お金の予定'
          ..timeZone = 'Asia/Tokyo',
      );
      if (created.id == null) {
        lastError = 'カレンダーを作れませんでした';
        return false;
      }
      _calendarId = created.id;
      await prefs.setString(_kCalendarId, created.id!);
      return true;
    } catch (e) {
      lastError = _describe(e);
      return false;
    }
  }

  String _describe(Object e) {
    final s = e.toString();
    if (s.contains('has not been used') || s.contains('is disabled')) {
      return 'カレンダーの利用が有効になっていません。'
          'Google CloudでGoogle Calendar APIを有効にしてください。';
    }
    if (s.contains('insufficient') || s.contains('403')) {
      return 'カレンダーへのアクセスが許可されていません。'
          '設定→Google連携で「連携し直す」を押してください。';
    }
    return s;
  }

  gcal.EventDateTime _at(DateTime d, {required bool allDay}) {
    if (allDay) {
      return gcal.EventDateTime()..date = DateTime(d.year, d.month, d.day);
    }
    return gcal.EventDateTime()
      ..dateTime = d
      ..timeZone = 'Asia/Tokyo';
  }

  // 作成または更新。成功したらイベントIDを返す。
  Future<String?> _createOrUpdate({
    String? existingId,
    required String title,
    required DateTime start,
    required DateTime end,
    bool allDay = false,
    String location = '',
    String description = '',
  }) async {
    if (!await _ensure()) return existingId;
    final api = await GmailService.instance.calendarApi();
    if (api == null) return existingId;

    final safeEnd = end.isAfter(start) ? end : start.add(const Duration(hours: 1));
    final body = gcal.Event()
      ..summary = title
      ..location = location.isEmpty ? null : location
      ..description = description.isEmpty ? null : description
      ..start = _at(start, allDay: allDay)
      // 終日予定の終了日は「翌日」を指す決まりになっている
      ..end = _at(allDay ? safeEnd.add(const Duration(days: 1)) : safeEnd,
          allDay: allDay);

    try {
      if (existingId != null && existingId.isNotEmpty) {
        final updated = await api.events.update(body, _calendarId!, existingId);
        return updated.id ?? existingId;
      }
      final created = await api.events.insert(body, _calendarId!);
      return created.id ?? existingId;
    } catch (e) {
      // 向こうで消されていたら、作り直す
      if (existingId != null && existingId.isNotEmpty) {
        try {
          final created = await api.events.insert(body, _calendarId!);
          return created.id ?? existingId;
        } catch (e2) {
          lastError = _describe(e2);
          return null;
        }
      }
      lastError = _describe(e);
      return existingId;
    }
  }

  Future<void> _syncShift(DateTime date, ShiftData s) async {
    final id = await _createOrUpdate(
      existingId: s.calendarEventId,
      title: '${s.workplace}（バイト）',
      start: s.start,
      end: s.end,
      description: '時給¥${s.hourlyWage} / 休憩${s.breakMinutes}分 / 給与¥${s.earnings}',
    );
    if (id != null && id != s.calendarEventId) {
      s.calendarEventId = id;
      appState.saveData();
    }
  }

  Future<void> _syncEvent(EventData e) async {
    final start = e.start;
    if (start == null) return;
    final id = await _createOrUpdate(
      existingId: e.calendarEventId,
      title: e.title,
      start: start,
      end: e.end ?? start.add(const Duration(hours: 1)),
      allDay: e.allDay,
      location: e.location,
      description: [e.memo, e.url].where((s) => s.isNotEmpty).join('\n'),
    );
    if (id != null && id != e.calendarEventId) {
      e.calendarEventId = id;
      appState.saveData();
    }
  }

  @override
  void upsertShift(DateTime date, ShiftData shift) {
    _syncShift(date, shift);
  }

  @override
  void upsertEvent(EventData event) {
    _syncEvent(event);
  }

  @override
  void deleteEvent(String calendarEventId) async {
    if (!await _ensure()) return;
    final api = await GmailService.instance.calendarApi();
    if (api == null) return;
    try {
      await api.events.delete(_calendarId!, calendarEventId);
    } catch (_) {
      // 既に消えている場合は何もしない
    }
  }

  @override
  Future<String?> upsertSpecialEvent({
    required String existingCalId,
    required String title,
    required DateTime date,
    required String description,
  }) async {
    return _createOrUpdate(
      existingId: existingCalId.isNotEmpty ? existingCalId : null,
      title: title,
      start: date,
      end: date,
      allDay: true,
      description: description,
    );
  }

  @override
  Future<bool> enableAndSyncAll() async {
    if (!await _ensure()) return false;
    for (final entry in appState.shifts.entries) {
      final d = DateTime.tryParse(entry.key) ?? DateTime.now();
      for (final s in entry.value) {
        await _syncShift(d, s);
      }
    }
    for (final list in appState.events.values) {
      for (final e in list) {
        await _syncEvent(e);
      }
    }
    return true;
  }
}
