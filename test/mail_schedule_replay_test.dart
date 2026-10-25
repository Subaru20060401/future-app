// 💡 実メールはGit管理外に置き、スマホと同じサービス・AppStateで再生する。
//   Gmailへの接続やカレンダーへの書き込みは行わない。
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/app_state.dart';
import 'package:my_counter_app/gmail_service.dart';
import 'package:my_counter_app/mail_schedule_rules.dart';
import 'package:my_counter_app/mail_schedule_service.dart';

class ReplaySource implements ScheduleMailSource {
  ReplaySource(this.mails);
  final List<ScheduleMail> mails;
  @override
  String get scheduleAccountKey => 'evaluation';
  @override
  Future<GoogleAccessState> ensureAccess() async => GoogleAccessState.ready;
  @override
  Future<({List<ScheduleMail> mails, int failed, bool truncated})>
  fetchScheduleMails({required DateTime after}) async => (
    mails: mails.where((m) => !m.receivedAt.isBefore(after)).toList(),
    failed: 0,
    truncated: false,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const root = String.fromEnvironment(
    'MAIL_EVAL_DIR',
    defaultValue: '.dart_tool/mail_schedule_eval',
  );
  test(
    '取得済みメールを本番と同じ予定取り込みで評価する',
    () async {
      final report =
          jsonDecode(File('$root/after.json').readAsStringSync()) as Map;
      final app = AppState();
      await app.ready;
      final source = ReplaySource([
        for (final row in report['mails'] as List)
          ScheduleMail(
            id: row['id'],
            subject: row['subject'],
            from: row['from'],
            receivedAt: DateTime.parse(row['receivedAt']),
            body: row['body'],
          ),
      ]);
      final now = DateTime.parse(report['now']);
      final result = await scanScheduleMails(app, source: source, now: now);
      expect(result.complete, isTrue);
      final first = app.pendingScheduleSuggestions.map((s) => s.id).toList();
      await scanScheduleMails(app, source: source, now: now);
      expect(app.pendingScheduleSuggestions.map((s) => s.id), first);
      expect(app.events, isEmpty);
      expect(app.shifts, isEmpty);
      File('$root/app-result.json').writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'checked': result.checked,
          'scannedMessageIds': source.mails
              .where(
                (m) => !m.receivedAt.isBefore(now.subtract(kFirstScanWindow)),
              )
              .map((m) => m.id)
              .toList(),
          'added': result.added,
          'pending': app.pendingScheduleSuggestions
              .map((s) => s.toJson())
              .toList(),
          'history': app.scheduleSuggestions
              .where((s) => !s.isOpen)
              .map((s) => s.toJson())
              .toList(),
        }),
      );
      app.dispose();
    },
    skip: !File('$root/after.json').existsSync()
        ? '実メール評価データがある端末でのみ実行'
        : false,
  );
  setUp(() => SharedPreferences.setMockInitialValues({}));
}
