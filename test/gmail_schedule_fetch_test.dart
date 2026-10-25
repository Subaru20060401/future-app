// 予定用のメール取得（fetchScheduleMails）を、偽のHTTP応答で本番の処理を通して確かめる。
// ⚠️ 支払いの取り込みの「取りこぼし」の数（lastFetchFailures など）を触らないこと。
// 💡 メールはすべて架空。
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/gmail_service.dart';

String b64(String s) => base64Url.encode(utf8.encode(s));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final service = GmailService.instance;
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'saved_google_access_token': 'test-token',
      'saved_google_token_expiry':
          DateTime.now().toUtc().add(const Duration(hours: 1)).toIso8601String(),
    });
  });
  http.Response json(Object body) => http.Response(jsonEncode(body), 200,
      headers: {'content-type': 'application/json; charset=utf-8'});

  Map<String, Object> message(String id, DateTime at, {String? plain, String? html}) => {
        'id': id,
        'threadId': 't-$id',
        'internalDate': '${at.millisecondsSinceEpoch}',
        'payload': {
          'mimeType': 'multipart/alternative',
          'headers': [
            {'name': 'Subject', 'value': 'ご予約が確定しました'},
            {'name': 'From', 'value': 'テスト予約 <noreply@example.com>'},
          ],
          'parts': [
            if (plain != null) {'mimeType': 'text/plain', 'body': {'data': b64(plain)}},
            if (html != null) {'mimeType': 'text/html', 'body': {'data': b64(html)}},
          ],
        },
      };

  test('テキストがあればテキスト、無ければHTMLの文字を読む。範囲より前のメールは外す', () async {
    final after = DateTime(2026, 10, 1);
    String? query;
    final client = MockClient((req) async {
      if (req.url.path.endsWith('/messages')) {
        query = req.url.queryParameters['q'];
        return json({'messages': [{'id': 'a'}, {'id': 'b'}, {'id': 'old'}]});
      }
      return switch (req.url.pathSegments.last) {
        'a' => json(message('a', DateTime(2026, 10, 5),
            plain: '日時：11月12日 14:00〜15:00', html: '<p>日時：11月12日 14:00〜15:00</p>')),
        'b' => json(message('b', DateTime(2026, 10, 6), html: '<p>日時：<b>11月13日</b></p>')),
        _ => json(message('old', DateTime(2026, 9, 30, 23), plain: '古い')),
      };
    });
    final failuresBefore = service.lastFetchFailures;
    final r = await http.runWithClient(() => service.fetchScheduleMails(after: after), () => client);
    expect(query, contains('after:${after.millisecondsSinceEpoch ~/ 1000}'));
    expect(query, contains('-in:spam'));
    expect(query, contains('subject:'));
    expect(r.mails.map((m) => m.id), ['a', 'b'], reason: '受信日時が範囲より前のものは外す');
    expect(RegExp('11月12日').allMatches(r.mails[0].body), hasLength(1), reason: 'テキストとHTMLを二重に読まない');
    expect(r.mails[1].body, contains('日時：11月13日'));
    expect(r.mails[1].body, isNot(contains('<b>')));
    expect(r.mails[0].from, contains('noreply@example.com'));
    expect(r.failed, 0);
    expect(r.truncated, isFalse);
    expect(service.lastFetchFailures, failuresBefore, reason: '支払い側の数を触らない');
  });

  test('本文が取れなかったメールは数え、件数の上限で止めたら取り切れていないと返す', () async {
    var gets = 0;
    final client = MockClient((req) async {
      if (req.url.path.endsWith('/messages')) {
        final page = int.parse(req.url.queryParameters['pageToken'] ?? '0');
        return json({
          'messages': List.generate(100, (i) => {'id': 'm${page * 100 + i}'}),
          'nextPageToken': '${page + 1}',
        });
      }
      gets++;
      // 💡 一時的なエラー（5xx）は通信の待ち合わせ側でやり直すので、消えたメール（404）で試す
      if (req.url.pathSegments.last == 'm0') return http.Response('not found', 404);
      return json(message(req.url.pathSegments.last, DateTime(2026, 10, 5), plain: 'x'));
    });
    final r = await http.runWithClient(
        () => service.fetchScheduleMails(after: DateTime(2026, 10, 1)), () => client);
    expect(r.truncated, isTrue);
    expect(r.failed, greaterThanOrEqualTo(1));
    expect(r.mails.length + r.failed, GmailService.kScheduleMailCap);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
