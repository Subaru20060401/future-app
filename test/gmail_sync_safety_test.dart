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
      final edge = DateTime(now.year - 2, now.month, 15); // 境目（2か月の余裕の内側）
      final inside = DateTime(now.year - 1, now.month, 1); // 取り直す範囲
      final app = await appWith([
        auto('楽天カード', 1000, older, 'older'),
        auto('楽天カード', 2000, edge, 'edge'),
        auto('楽天カード', 3000, inside, 'inside'),
      ]);
      final g = FakeGmail(); // どれも見つからなかった
      final r = await syncGmail(app, source: g, full: true);
      expect(r.ok, isTrue);
      expect(g.cardCalls.single, isNull, reason: 'メールは2年分を取る');
      expect(app.payments.map((p) => p.sourceId).toSet(), {'older', 'edge'},
          reason: '範囲の内側だけ作り直す');
    });

    test('作り直しの始まりは、2年前の2か月内側', () {
      expect(fullSyncReconcileSince(DateTime(2026, 10, 22)), DateTime(2024, 12, 22));
      expect(fullSyncReconcileSince(DateTime(2026, 11, 30)), DateTime(2025, 1, 30));
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

  test('通常の更新中に2年分を頼んだら、通常の結果ではなく2年分を走らせる', () async {
    final app = await appWith([]);
    final g = FakeGmail()..gate = Completer<void>();
    final normal = syncGmail(app, source: g);
    final normal2 = syncGmail(app, source: g); // 同じ種類は相乗り
    final full = syncGmail(app, source: g, full: true);
    await Future<void>.delayed(Duration.zero);
    g.gate!.complete();
    await Future.wait([normal, normal2, full]);
    expect(g.cardCalls, [DateTime(now.year, now.month - 1, 1), null]);
  });
}
