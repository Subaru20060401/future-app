// Gmail 取り込みの安全装置のテスト（コード点検 2026-10-22 の指摘）。
// ⚠️ 取り込みは「自動明細の作り直し方式」。取ってこなかったメールの明細は、作り直しで消える。
//   ・本文の取得に1件でも失敗したら反映しない（以前から）
//   ・件数の上限で検索を打ち切ったときも反映しない（以前は黙って成功扱いだった）
//   ・過去2年分は、作り直す範囲も2年より内側に限る（以前は全期間＝2年より前の明細が消えた）
//   ・入金のお知らせなどの取りこぼしを「確認しました」で隠さない
//   ・通常の更新中に2年分を頼んだら、通常の結果を返さず2年分を走らせる
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/app_state.dart';
import 'package:my_counter_app/gmail_service.dart';
import 'package:my_counter_app/gmail_sync.dart';

class FakeGmail implements GmailSyncSource {
  List<ParsedPayment> cards = [];
  int failures = 0;
  int truncated = 0;
  int _miss = 0;
  bool depositThrows = false;
  int depositMiss = 0;
  final cardCalls = <DateTime?>[];
  Completer<void>? gate;

  @override
  Future<GoogleAccessState> ensureAccess() async => GoogleAccessState.ready;
  @override
  Future<T> withFreshToken<T>(Future<T> Function() run) => run();
  @override
  Future<void> invalidateRejectedToken({String? used}) async {}
  @override
  Future<List<ParsedPayment>> fetchCardPayments({DateTime? since}) async {
    cardCalls.add(since);
    final g = gate;
    if (g != null) await g.future;
    return cards;
  }

  @override
  int get lastFetchFailures => failures;
  @override
  int get lastFetchTruncated => truncated;
  @override
  final Map<String, DateTime> lastMailReceivedAt = {};
  @override
  int get missTotal => _miss;
  @override
  Future<List<({String sourceId, DateTime date})>> fetchDepositNotices({DateTime? since}) async {
    if (depositThrows) throw Exception('network');
    _miss += depositMiss;
    return const [];
  }

  @override
  Future<List<PayPayTransferMail>> fetchPayPayTransfers({DateTime? since}) async => const [];
}

ParsedPayment mail(String card, int amount, DateTime d, String id) => ParsedPayment(
      cardName: card,
      amount: amount,
      date: d,
      snippet: '',
      kind: MailKind.usage,
      sourceId: id,
    );

Payment auto(String card, int amount, DateTime d, String id) => Payment(
      id: 'p_$id',
      cardName: card,
      amount: amount,
      paymentDate: d,
      source: PaymentSource.usage,
      sourceId: id,
      mailReceivedAt: d,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final now = DateTime.now();
  final thisMonth = DateTime(now.year, now.month, 1);

  Future<AppState> appWith(List<Payment> ps) async {
    final app = AppState();
    await app.ready;
    app.payments.addAll(ps);
    return app;
  }

  group('取り切れなかったときは明細を作り直さない', () {
    test('本文の取得に失敗したメールがあれば反映しない（既存の明細は消えない）', () async {
      final app = await appWith([auto('楽天カード', 5000, thisMonth, 'm1')]);
      final g = FakeGmail()..failures = 1; // m1 の本文が取れなかった
      final r = await syncGmail(app, source: g);
      expect(r.skipped, isTrue);
      expect(r.ok, isFalse);
      expect(app.payments.map((p) => p.sourceId), ['m1']);
    });

    test('件数の上限で検索を打ち切ったときも反映しない', () async {
      final app = await appWith([auto('楽天カード', 5000, thisMonth, 'm1')]);
      final g = FakeGmail()..truncated = 1;
      final r = await syncGmail(app, source: g, full: true);
      expect(r.truncated, isTrue);
      expect(r.skipped, isTrue);
      expect(r.message, contains('多すぎて'));
      expect(app.payments.map((p) => p.sourceId), ['m1']);
    });

    test('取り切れたときだけ作り直す（取れなかった明細は消える＝だから上の2つが要る）', () async {
      final app = await appWith([auto('楽天カード', 5000, thisMonth, 'm1')]);
      final g = FakeGmail()..cards = [mail('楽天カード', 3000, thisMonth, 'm2')];
      final r = await syncGmail(app, source: g);
      expect(r.ok, isTrue);
      expect(app.payments.map((p) => p.sourceId), ['m2']);
      expect(r.items.map((p) => p.sourceId), ['m2']);
    });
  });

  group('作り直す範囲', () {
    test('通常の更新は先月1日から。それより前の明細には触らない', () async {
      final old = DateTime(now.year, now.month - 3, 10);
      final app = await appWith([auto('楽天カード', 5000, old, 'old')]);
      final g = FakeGmail();
      await syncGmail(app, source: g);
      expect(g.cardCalls.single, DateTime(now.year, now.month - 1, 1));
      expect(app.payments.map((p) => p.sourceId), ['old']);
    });

    test('過去2年分でも、2年より前の明細は消さない', () async {
      final older = DateTime(now.year - 3, now.month, 1); // メールを取ってこない古さ
      final edge = DateTime(now.year - 2, now.month, now.day).subtract(const Duration(days: 1));
      final inside = DateTime(now.year - 1, now.month, 1); // 取り直す範囲
      final app = await appWith([
        auto('楽天カード', 1000, older, 'older'),
        auto('楽天カード', 2000, edge, 'edge'),
        auto('楽天カード', 3000, inside, 'inside'),
      ]);
      final g = FakeGmail(); // どれも見つからなかった
      final r = await syncGmail(app, source: g, full: true);
      expect(r.ok, isTrue);
      expect(g.cardCalls.single, DateTime(now.year - 2, now.month, now.day),
          reason: '検索と削除で同じ境界を使う');
      expect(app.payments.map((p) => p.sourceId).toSet(), {'older', 'edge'},
          reason: '範囲の内側だけ作り直す');
    });

    test('全取得は2年前の境目付近も追加し、再取得で二重にしない', () async {
      final app = await appWith([]);
      final d = DateTime(now.year - 2, now.month + 1, 1);
      final g = FakeGmail()..cards = [mail('楽天カード', 5000, d, 'edge')];
      g.lastMailReceivedAt['edge'] = d;
      await syncGmail(app, source: g, full: true);
      await syncGmail(app, source: g, full: true);
      expect(app.payments.single.sourceId, 'edge');
      expect(app.payments.single.mailReceivedAt, d);
    });

    test('受信日が検索範囲外なら、将来の引落日でも消さない', () async {
      final p = auto('楽天カード', 5000, thisMonth, 'older-mail')
        ..mailReceivedAt = DateTime(now.year, now.month - 3, 1);
      final app = await appWith([p]);
      await syncGmail(app, source: FakeGmail());
      expect(app.payments.single.sourceId, 'older-mail');
    });

    test('旧データは保護し、元メールを再取得したら受信日時を補完する', () async {
      final p = auto('楽天カード', 5000, thisMonth, 'legacy')..mailReceivedAt = null;
      final app = await appWith([p]);
      await syncGmail(app, source: FakeGmail());
      expect(app.payments.single.sourceId, 'legacy');
      final g = FakeGmail()..cards = [mail('楽天カード', 5000, thisMonth, 'legacy')];
      g.lastMailReceivedAt['legacy'] = thisMonth;
      await syncGmail(app, source: g);
      expect(app.payments.single.mailReceivedAt, thisMonth);
      final restored = Payment.fromJson(app.payments.single.toJson());
      expect(restored.mailReceivedAt, thisMonth);
    });

    test('元メールを解析し直して0件になった場合は、旧データも削除する', () async {
      final p = auto('楽天カード', 5000, thisMonth, 'old#0')..mailReceivedAt = null;
      final app = await appWith([p]);
      final g = FakeGmail();
      g.lastMailReceivedAt['old'] = thisMonth;
      await syncGmail(app, source: g);
      expect(app.payments, isEmpty);
    });

    test('受信日が範囲内なら、明細の日付が古くても再解析結果で置き換える', () async {
      final p = auto('楽天カード', 5000, DateTime(now.year - 3), 'old-date')
        ..mailReceivedAt = thisMonth;
      final app = await appWith([p]);
      await syncGmail(app, source: FakeGmail());
      expect(app.payments, isEmpty);
    });

    test('範囲外の銀行確定は保持し、今回届いた請求予定より優先する', () async {
      final p = auto('楽天カード', 5000, thisMonth, 'bank#0')
        ..source = PaymentSource.bank
        ..mailReceivedAt = DateTime(now.year, now.month - 3);
      final app = await appWith([p]);
      final g = FakeGmail()..cards = [ParsedPayment(
        cardName: '楽天カード', amount: 6000, date: thisMonth,
        snippet: '', kind: MailKind.billing, sourceId: 'bill')];
      await syncGmail(app, source: g);
      expect(app.payments.single.source, PaymentSource.bank);
      expect(app.payments.single.amount, 5000);
    });

    test('範囲外の請求予定も、新しく銀行確定が来れば除く', () async {
      final p = auto('楽天カード', 5000, thisMonth, 'bill')
        ..source = PaymentSource.billing
        ..mailReceivedAt = DateTime(now.year, now.month - 3);
      final app = await appWith([p]);
      final g = FakeGmail()..cards = [ParsedPayment(
        cardName: '楽天カード', amount: 6000, date: thisMonth,
        snippet: '', kind: MailKind.bank, sourceId: 'bank#0')];
      await syncGmail(app, source: g);
      expect(app.payments.single.source, PaymentSource.bank);
      expect(app.payments.single.amount, 6000);
    });
  });

  group('入金のお知らせなどの取りこぼし', () {
    test('取得に失敗したら、カードは反映しつつ「一部未確認」と出す', () async {
      final app = await appWith([]);
      final g = FakeGmail()
        ..cards = [mail('楽天カード', 3000, thisMonth, 'm2')]
        ..depositThrows = true;
      final r = await syncGmail(app, source: g);
      expect(r.ok, isTrue);
      expect(r.partial, isTrue);
      expect(r.shortMessage, contains('一部のメールは未確認'));
      expect(r.detailLines.join('\n'), contains('振込入金のお知らせを確認できませんでした'));
      expect(app.payments, hasLength(1));
    });

    test('一部のメールだけ取れなかったときも知らせる', () async {
      final app = await appWith([]);
      final g = FakeGmail()..depositMiss = 2;
      final r = await syncGmail(app, source: g);
      expect(r.partialWarnings, ['振込入金のお知らせを一部確認できませんでした']);
    });

    test('全部取れたら、ふつうの「確認しました」', () async {
      final app = await appWith([]);
      final r = await syncGmail(app, source: FakeGmail());
      expect(r.partial, isFalse);
      expect(r.shortMessage, 'メールを確認しました');
    });
  });

  group('保持した明細との照合', () {
    test('検索期間外のAmazonにも新しく届いたカード通知を照合する', () async {
      final p = auto('楽天カード', 5000, thisMonth, 'amazon#old')
        ..mailReceivedAt = DateTime(now.year, now.month - 3);
      final app = await appWith([p]);
      app.amazonCardOverrides[p.sourceId] = '楽天カード';
      final g = FakeGmail()..cards = [mail('楽天カード', 5000, thisMonth, 'real')];
      await syncGmail(app, source: g);
      expect(app.payments.firstWhere(app.isAmazonPayment).infoOnly, isTrue);
      expect(app.paymentTotalsByCardOf(thisMonth)['楽天カード'], 5000);
      expect(app.paymentTotalsByCardOf(thisMonth)['Amazonマスター'], isNull);
    });

    test('古いAmazonのキャンセル通知を確認したら該当注文だけ除く', () async {
      final app = await appWith([
        auto('Amazonマスター', 5000, thisMonth, 'amazon#cancel')..mailReceivedAt = null,
        auto('Amazonマスター', 3000, thisMonth, 'amazon#keep')..mailReceivedAt = null,
      ]);
      final g = FakeGmail();
      g.lastMailReceivedAt['amazon#cancel'] = thisMonth;
      await syncGmail(app, source: g);
      expect(app.payments.single.sourceId, 'amazon#keep');
    });

    test('境界より古い明細の再取得でも削除済みを復活させない', () async {
      final d = DateTime(now.year - 2, now.month + 1, 1);
      final app = await appWith([auto('楽天カード', 5000, d, 'deleted')]);
      app.removePayment(app.payments.single.id);
      final g = FakeGmail()..cards = [mail('楽天カード', 5000, d, 'deleted')];
      await syncGmail(app, source: g, full: true);
      expect(app.payments, isEmpty);
    });

    test('旧データを補完しても支払済みと手書きメモを引き継ぐ', () async {
      final p = auto('楽天カード', 5000, thisMonth, 'old#0')
        ..mailReceivedAt = null
        ..paid = true;
      final app = await appWith([p]);
      app.paymentNotes[p.sourceId] = '手書きのメモ';
      final g = FakeGmail()..cards = [mail('楽天カード', 5000, thisMonth, 'old#0')];
      g.lastMailReceivedAt['old'] = thisMonth;
      await syncGmail(app, source: g);
      expect(app.payments.single.mailReceivedAt, thisMonth);
      expect(app.payments.single.paid, isTrue);
      expect(app.payments.single.note, '手書きのメモ');
    });
  });

  test('通常の更新中に2年分を頼んだら、通常の結果ではなく2年分を走らせる', () async {
    final app = await appWith([]);
    final g = FakeGmail()..gate = Completer<void>();
    final normal = syncGmail(app, source: g);
    final normal2 = syncGmail(app, source: g); // 同じ種類は相乗り
    final full = syncGmail(app, source: g, full: true);
    await Future<void>.delayed(Duration.zero);
    g.gate!.complete();
    await Future.wait([normal, normal2, full]);
    expect(g.cardCalls, [DateTime(now.year, now.month - 1, 1),
      DateTime(now.year - 2, now.month, now.day)]);
  });
}
