// メール解析結果のキャッシュ（JSON往復）のテスト。
// 金額・日付・種別が1つでも化けると明細が狂うので、往復で完全一致することを見る。
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_counter_app/gmail_service.dart';

void main() {
  GmailCacheEntry roundTrip(GmailCacheEntry e) =>
      GmailCacheEntry.fromJson(jsonDecode(jsonEncode(e.toJson())) as Map<String, dynamic>)!;

  group('GmailCacheEntry の往復', () {
    test('支払い候補が完全に復元される', () {
      final p = ParsedPayment(
        cardName: '三井住友',
        amount: 12345,
        date: DateTime(2026, 9, 3, 14, 27, 31),
        snippet: 'ご利用のお知らせ',
        kind: MailKind.usage,
        sourceId: 'msg-1',
        note: 'セブンイレブン',
      );
      final e = roundTrip(GmailCacheEntry(epochMs: 1700000000000, payments: [p]));

      expect(e.epochMs, 1700000000000);
      expect(e.payments, hasLength(1));
      final q = e.payments.single;
      expect(q.cardName, p.cardName);
      expect(q.amount, p.amount);
      expect(q.date, p.date);
      expect(q.kind, p.kind);
      expect(q.sourceId, p.sourceId);
      expect(q.note, p.note);
    });

    test('種別ごとに復元できる', () {
      for (final kind in MailKind.values) {
        final e = roundTrip(GmailCacheEntry(
          epochMs: 1,
          payments: [
            ParsedPayment(
              cardName: 'X',
              amount: 1,
              date: DateTime(2026, 1, 1),
              snippet: '',
              kind: kind,
              sourceId: 'i',
            )
          ],
        ));
        expect(e.payments.single.kind, kind);
      }
    });

    test('抽出なし（空）も「解析済み」として保存される', () {
      final e = roundTrip(const GmailCacheEntry(epochMs: 42));
      expect(e.payments, isEmpty);
      expect(e.amazon, isNull);
      expect(e.epochMs, 42);
    });

    test('Amazonの突合材料が復元される', () {
      final e = roundTrip(const GmailCacheEntry(
        epochMs: 5,
        amazon: AmazonFact(
          orderNo: '249-1234567-1234567',
          amount: 3980,
          epochMs: 1756000000000,
          snippet: 'ご注文の発送',
          note: '書籍タイトル',
        ),
      ));
      final a = e.amazon!;
      expect(a.orderNo, '249-1234567-1234567');
      expect(a.amount, 3980);
      expect(a.epochMs, 1756000000000);
      expect(a.note, '書籍タイトル');
    });

    test('長いスニペットは切り詰めるが金額は保つ', () {
      final e = roundTrip(GmailCacheEntry(
        epochMs: 1,
        payments: [
          ParsedPayment(
            cardName: '楽天カード',
            amount: 99999,
            date: DateTime(2026, 8, 31),
            snippet: 'あ' * 500,
            kind: MailKind.billing,
            sourceId: 'i',
          )
        ],
      ));
      expect(e.payments.single.amount, 99999);
      expect(e.payments.single.snippet.length, lessThanOrEqualTo(120));
    });

    test('壊れたJSONは null を返して取り直させる', () {
      expect(GmailCacheEntry.fromJson(<String, dynamic>{}), isNull);
      expect(GmailCacheEntry.fromJson(<String, dynamic>{'t': 'こわれ'}), isNull);
    });
  });
}
