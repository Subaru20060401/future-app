import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/app_state.dart';
import 'package:my_counter_app/mail_schedule_rules.dart';

ScheduleMail m(String subject, String body) => ScheduleMail(
  id: 'test',
  subject: subject,
  from: '予約窓口 <booking@example.com>',
  receivedAt: DateTime(2026, 10, 25),
  body: body,
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final rejected = <(String, String)>[
    ('明日まで！公式チケットトレード(抽選)', '公演日10月29日。抽選受付は10月26日11:59まで'),
    ('次の滞在を15%OFFで予約しませんか？', '2027年1月7日9:59までに予約が完了した宿泊予約が対象です。'),
    ('追加日程のご案内', 'ご予約いただいた方、ありがとうございます。日時：10月30日 10:00〜11:00'),
    ('ご予約受付を開始しました', '予約いただいた時点で参加確定となります。'),
    ('説明会参加確定', '詳細は添付PDFをご覧ください。'),
    ('ご予約完了', '開催日：2026年10月30日\n電話受付時間：9:00〜18:00'),
    ('面接日程調整', 'ご都合のよい候補日を回答してください。日時：10月30日 10:00'),
    ('抽選受付完了', '公演日：2026年10月30日 10:00〜11:00'),
    ('リマインド：明日開催', '日時：2026年10月30日 10:00〜11:00\nぜひご予約ください。'),
    ('スカイマーク予約完了【未購入】', 'ご予約が完了しました。搭乗日：2026年10月30日 10:00〜11:00'),
  ];
  for (final (subject, body) in rejected) {
    test('対象外：$subject', () {
      final r = readScheduleMail(m(subject, body), accountKey: 'acct');
      expect(r.suggestions, isEmpty);
      expect(r.skipReason, isNotEmpty);
    });
  }
  test('決済の返金説明を含む取消も拾う', () {
    final r = readScheduleMail(
      m(
        'キャンセルを受け付けました',
        '予約番号：R-100\n日時：2026年10月30日 10:00〜11:00\n決済金額は後日返金されます。',
      ),
      accountKey: 'acct',
    );
    expect(r.suggestions.single.action, SuggestionAction.cancel);
  });
  test('キャンセル完了に句読点があっても追加にしない', () {
    final r = readScheduleMail(
      m(
        'ご予約のご連絡',
        '日時：2026年10月30日 10:00〜11:00\n'
            '上記日時の予約キャンセルが、完了いたしましたのでご連絡いたします。',
      ),
      accountKey: 'acct',
    );
    expect(r.suggestions.single.action, SuggestionAction.cancel);
  });
  test('予約の注意書きにあるキャンセル案内は取消にしない', () {
    final r = readScheduleMail(
      m(
        '予約確定',
        'ご予約が確定しました。\n日時：2026年10月30日 10:00〜11:00\n'
            '都合が悪くなった場合はキャンセルしてください。',
      ),
      accountKey: 'acct',
    );
    expect(r.suggestions.single.action, SuggestionAction.add);
  });
  test('別の日付に属する締切時刻を借りない', () {
    final r = readScheduleMail(
      m('ご予約が確定しました', '開催日：2026年10月30日 申込締切10月28日 11:59'),
      accountKey: 'acct',
    );
    expect(r.suggestions, isEmpty);
  });
  test('数値文字参照とHTMLを復号して日時を読む', () {
    final r = readScheduleMail(
      m('予約確定', '<html><p>日時：2026年10月30日 10&#58;00〜11&#58;00</p></html>'),
      accountKey: 'acct',
    );
    expect(r.suggestions.single.start, DateTime(2026, 10, 30, 10));
  });

  test('旧版の未操作候補だけ整理し、登録済み・保留・却下・見本は保つ', () async {
    SharedPreferences.setMockInitialValues({});
    final app = AppState();
    await app.ready;
    ScheduleSuggestion sg(
      String id,
      SuggestionStatus status, {
      bool sample = false,
    }) => ScheduleSuggestion(
      id: id,
      accountKey: 'acct',
      messageId: id,
      entityKey: id,
      rulesVersion: 2,
      kind: SuggestionKind.event,
      title: '架空の予定',
      receivedAt: DateTime(2026, 10, 25),
      status: status,
      sample: sample,
    );
    app.scheduleSuggestions = [
      sg('old', SuggestionStatus.pending),
      sg('held', SuggestionStatus.held),
      sg('approved', SuggestionStatus.approved),
      sg('rejected', SuggestionStatus.rejected),
      sg('sample', SuggestionStatus.pending, sample: true),
    ];
    expect(app.retireOldScheduleSuggestions(), 1);
    expect(app.scheduleSuggestions[0].status, SuggestionStatus.superseded);
    expect(app.scheduleSuggestions[1].status, SuggestionStatus.held);
    expect(app.scheduleSuggestions[2].status, SuggestionStatus.approved);
    expect(app.scheduleSuggestions[3].status, SuggestionStatus.rejected);
    expect(app.scheduleSuggestions[4].status, SuggestionStatus.pending);
    app.dispose();
  });

  test('新しい取消を先に取得しても古い追加が復活しない', () async {
    SharedPreferences.setMockInitialValues({});
    final app = AppState();
    await app.ready;
    final add = readScheduleMail(
      ScheduleMail(
        id: 'add',
        subject: '予約確定',
        from: '予約 <booking@example.com>',
        receivedAt: DateTime(2026, 10, 24),
        body: '日時：2026年10月30日 10:00〜11:00\n予約番号：R-100',
      ),
      accountKey: 'acct',
    ).suggestions;
    final cancel = readScheduleMail(
      ScheduleMail(
        id: 'cancel',
        subject: 'キャンセル完了',
        from: '予約 <booking@example.com>',
        receivedAt: DateTime(2026, 10, 25),
        body: '日時：2026年10月30日 10:00〜11:00\n予約番号：R-100',
      ),
      accountKey: 'acct',
    ).suggestions;
    app.addScheduleSuggestions([...cancel, ...add]);
    expect(app.pendingScheduleSuggestions, isEmpty);
    app.addScheduleSuggestions(add);
    expect(app.pendingScheduleSuggestions, isEmpty);
    app.dispose();
  });
}
