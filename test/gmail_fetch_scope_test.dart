// 💡 偽のHTTP応答で、本番のページング・キャッシュ・受信日時の収集を通して確かめる。
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/gmail_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final service = GmailService.instance;
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'saved_google_access_token': 'test-token',
      'saved_google_token_expiry': DateTime.now().toUtc().add(const Duration(hours: 1)).toIso8601String(),
    });
    await service.clearCache();
  });
  http.Response jsonResponse(Object body) => http.Response(jsonEncode(body), 200,
      headers: {'content-type': 'application/json; charset=utf-8'});

  test('3000件で続きがあれば未完了と判定し、本文取得を始めない', () async {
    var pages = 0;
    var gets = 0;
    final client = MockClient((request) async {
      if (!request.url.path.endsWith('/messages')) {
        gets++;
        return jsonResponse({});
      }
      final query = request.url.queryParameters['q'] ?? '';
      if (!query.contains('rakuten-card')) return jsonResponse({});
      final page = int.parse(request.url.queryParameters['pageToken'] ?? '0');
      pages++;
      return jsonResponse({
        'messages': List.generate(500, (i) => {'id': 'm${page * 500 + i}'}),
        'nextPageToken': '${page + 1}',
      });
    });
    final result = await http.runWithClient(() => service.fetchCardPayments(), () => client);
    expect(result, isEmpty);
    expect(pages, 6);
    expect(service.lastFetchTruncated, 1);
    expect(gets, 0);
  });

  test('受信日時は明細の日付と別に集め、キャッシュからの再取得でも保持する', () async {
    final received = DateTime(2026, 10, 10);
    var gets = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/messages')) {
        final query = request.url.queryParameters['q'] ?? '';
        return jsonResponse(query.contains('rakuten-card')
            ? {'messages': [{'id': 'receipt'}, {'id': 'empty'}]}
            : {});
      }
      gets++;
      final id = request.url.pathSegments.last;
      final body = id == 'receipt'
          ? '■利用日: 2026/08/01\n■利用先: テスト店舗\n■利用金額: 500 円\n■支払月: 2026/09'
          : '明細のないメール';
      return jsonResponse({
        'id': id,
        'internalDate': '${received.millisecondsSinceEpoch}',
        'payload': {'mimeType': 'text/plain', 'body': {'data': base64Url.encode(utf8.encode(body))}},
      });
    });
    await http.runWithClient(() async {
      final first = await service.fetchCardPayments(since: DateTime(2026, 9));
      expect(first.single.date, DateTime(2026, 8, 1));
      expect(service.lastMailReceivedAt, {'receipt': received, 'empty': received});
      await service.fetchCardPayments(since: DateTime(2026, 9));
      expect(service.lastMailReceivedAt, {'receipt': received, 'empty': received});
      expect(gets, 2, reason: '本文は初回のみ取得する');
      expect(service.lastFetchTruncated, 0, reason: '前回の打ち切りを引き継がない');
    }, () => client);
  });
}
