import 'package:flutter/material.dart';
import 'package:device_calendar/device_calendar.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'app_state.dart';

// 💡 アプリ→Appleカレンダーの自動同期（device_calendar 実装）。
//   専用カレンダー「ポケットメイド」を作り、シフト/予定の作成・更新・削除を反映する。
//   アプリが「元」（一方向ミラー）。Apple側の編集はアプリに取り込まない。
class AppleCalendarSync implements CalendarSyncHook {
  AppleCalendarSync(this.appState) {
    _initTz();
  }
  final AppState appState;
  final DeviceCalendarPlugin _plugin = DeviceCalendarPlugin();
  String? _calendarId;
  bool _tzReady = false;

  static const _calendarName = 'ポケットメイド';

  void _initTz() {
    if (_tzReady) return;
    try {
      // すでに初期化済みなら getLocation が通る
      tz.getLocation('Asia/Tokyo');
    } catch (_) {
      tzdata.initializeTimeZones();
    }
    try {
      tz.setLocalLocation(tz.getLocation('Asia/Tokyo'));
    } catch (_) {}
    _tzReady = true;
  }

  tz.TZDateTime _tz(DateTime d) => tz.TZDateTime.from(d, tz.local);

  // 権限を確認し、専用カレンダーIDを用意する。準備できれば true。
  Future<bool> _ensure() async {
    _initTz();
    var perm = await _plugin.hasPermissions();
    if (perm.isSuccess != true || perm.data != true) {
      perm = await _plugin.requestPermissions();
      if (perm.isSuccess != true || perm.data != true) return false;
    }
    if (_calendarId != null) return true;

    final cals = await _plugin.retrieveCalendars();
    final list = cals.data;
    if (list != null) {
      for (final c in list) {
        if (c.name == _calendarName && c.isReadOnly != true) {
          _calendarId = c.id;
          break;
        }
      }
    }
    if (_calendarId == null) {
      final created =
          await _plugin.createCalendar(_calendarName, calendarColor: Colors.pink);
      if (created.isSuccess && created.data != null) {
        _calendarId = created.data;
      } else if (list != null && list.isNotEmpty) {
        // 作れない場合は書き込み可能な既定カレンダーで代替
        final writable = list.where((c) => c.isReadOnly != true).toList();
        if (writable.isNotEmpty) {
          _calendarId = writable
              .firstWhere((c) => c.isDefault == true, orElse: () => writable.first)
              .id;
        }
      }
    }
    return _calendarId != null;
  }

  // 作成 or 更新。成功時はカレンダーのイベントIDを返す。
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
    final event = Event(
      _calendarId,
      eventId: existingId,
      title: title,
      start: _tz(start),
      end: _tz(end.isAfter(start) ? end : start.add(const Duration(hours: 1))),
      location: location,
      description: description,
      allDay: allDay,
    );
    final res = await _plugin.createOrUpdateEvent(event);
    if (res != null && res.isSuccess && res.data != null) return res.data;
    return existingId;
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

  // ───── CalendarSyncHook ─────
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
    if (!await _ensure() || _calendarId == null) return;
    await _plugin.deleteEvent(_calendarId!, calendarEventId);
  }

  @override
  Future<String?> upsertSpecialEvent({
    required String existingCalId,
    required String title,
    required DateTime date,
    required String description,
  }) async {
    return await _createOrUpdate(
      existingId: existingCalId.isNotEmpty ? existingCalId : null,
      title: title,
      start: date,
      end: date.add(const Duration(hours: 1)),
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
