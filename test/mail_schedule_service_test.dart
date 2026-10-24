// 「メールから予定を探す」の実行のテスト（Gmailにはつながない。偽の取得元を使う）。
// ⚠️ 守ること:
//   ・初回は過去30日、次からは前回確認したところ（24時間重ねる）から
//   ・取りこぼしたら「どこまで確認したか」を進めない（次回もう一度その期間を確認する）
//   ・アカウントが分からないまま始めない
//   ・同じメールを何度読んでも提案は増えない。終わった予定の追加は出さない
//   ・処理済みの履歴は予定の終わりから90日で消す（確認待ちは消さない）
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/app_state.dart';
import 'package:my_counter_app/gmail_service.dart';
import 'package:my_counter_app/mail_schedule_rules.dart';
import 'package:my_counter_app/mail_schedule_service.dart';

class FakeSource implements ScheduleMailSource {
  List<ScheduleMail> mails = [];
  int failed = 0;
  bool truncated = false;
  String? account = 'acct';
  final calls = <DateTime>[];

  @override
  Future<GoogleAccessState> ensureAccess() async => GoogleAccessState.ready;
  @override
  String? get scheduleAccountKey => account;
  @override
  Future<({List<ScheduleMail> mails, int failed, bool truncated})> fetchScheduleMails(
      {required DateTime after}) async {
    calls.add(after);
    return (mails: mails, failed: failed, truncated: truncated);
  }
}

final now = DateTime(2026, 11, 1, 10);

ScheduleMail confirmMail(String id, String date) => ScheduleMail(
      id: id,
      subject: 'ご予約が確定しました',
      from: 'テスト <noreply@example.com>',
      receivedAt: now.subtract(const Duration(days: 1)),
      body: 'ご予約が確定しました。\n日時：$date 14:00〜15:00\n',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AppState> app() async {
    final a = AppState();
    await a.ready;
    return a;
  }

  test('初回は過去30日。全部取れたら、次は前回の確認から24時間重ねて取る', () async {
    final a = await app();
    final src = FakeSource()..mails = [confirmMail('m1', '2026年11月12日(木)')];
    final r1 = await scanScheduleMails(a, source: src, now: now);
    expect(r1.complete, isTrue);
    expect(r1.added, 1);
    expect(src.calls.single, now.subtract(const Duration(days: 30)));

    final later = now.add(const Duration(days: 3));
    await scanScheduleMails(a, source: src, now: later);
    expect(src.calls.last, now.subtract(const Duration(hours: 24)));
    expect(a.scheduleSuggestions, hasLength(1), reason: '同じメールを読み直しても増えない');
  });

  test('取りこぼしたら「どこまで確認したか」を進めない（見つかった提案は出す）', () async {
    final a = await app();
    final src = FakeSource()
      ..mails = [confirmMail('m1', '2026年11月12日(木)')]
      ..failed = 2;
    final r = await scanScheduleMails(a, source: src, now: now);
    expect(r.complete, isFalse);
    expect(r.message, contains('最後まで確認できていません'));
    expect(a.scheduleSuggestions, hasLength(1));
    expect(await lastScheduleScanAt('acct'), isNull);

    // 次もまた過去30日から
    src.failed = 0;
    await scanScheduleMails(a, source: src, now: now.add(const Duration(hours: 1)));
    expect(src.calls.last, now.add(const Duration(hours: 1)).subtract(const Duration(days: 30)));
  });

  test('件数の上限で取り切れなかったときも進めない', () async {
    final a = await app();
    final src = FakeSource()..truncated = true;
    final r = await scanScheduleMails(a, source: src, now: now);
    expect(r.complete, isFalse);
    expect(r.message, contains('メールが多くて'));
    expect(await lastScheduleScanAt('acct'), isNull);
  });

  test('アカウントが分からなければ始めない', () async {
    final a = await app();
    final src = FakeSource()..account = null;
    final r = await scanScheduleMails(a, source: src, now: now);
    expect(r.error, contains('アカウント'));
    expect(src.calls, isEmpty);
  });

  test('終わった予定の追加は出さない', () async {
    final a = await app();
    final src = FakeSource()..mails = [confirmMail('old', '2026年10月20日(火)')];
    final r = await scanScheduleMails(a, source: src, now: now);
    expect(r.added, 0);
    expect(a.scheduleSuggestions, isEmpty);
  });

  test('登録しなかった提案は、同じメールを読み直しても再提案しない', () async {
    final a = await app();
    final src = FakeSource()..mails = [confirmMail('m1', '2026年11月12日(木)')];
    await scanScheduleMails(a, source: src, now: now);
    a.rejectScheduleSuggestion(a.scheduleSuggestions.single.id);
    await scanScheduleMails(a, source: src, now: now.add(const Duration(days: 1)));
    expect(a.pendingScheduleSuggestions, isEmpty);
  });

  test('処理済みの履歴は予定の終わりから90日で消す。確認待ちは消さない', () async {
    final a = await app();
    a.addScheduleSuggestions([
      ScheduleSuggestion(id: 'done', accountKey: 'acct', messageId: 'x', entityKey: 'E1',
          kind: SuggestionKind.event, title: '終わった予定',
          start: DateTime(2026, 7, 1, 10), end: DateTime(2026, 7, 1, 11),
          receivedAt: DateTime(2026, 6, 20), status: SuggestionStatus.rejected),
      ScheduleSuggestion(id: 'open', accountKey: 'acct', messageId: 'y', entityKey: 'E2',
          kind: SuggestionKind.event, title: '確認待ち',
          start: DateTime(2026, 7, 1, 10), end: DateTime(2026, 7, 1, 11),
          receivedAt: DateTime(2026, 6, 20)),
    ]);
    expect(a.pruneScheduleSuggestions(DateTime(2026, 9, 1)), 0, reason: 'まだ90日たっていない');
    expect(a.pruneScheduleSuggestions(DateTime(2026, 10, 1)), 1);
    expect(a.scheduleSuggestions.map((s) => s.id), ['open']);
  });
}
