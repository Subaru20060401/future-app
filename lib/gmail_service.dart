import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:googleapis/gmail/v1.dart' as gmail;

// 💡 メールの種別: 利用通知 / カード請求予定 / 銀行引落確定
enum MailKind { usage, billing, bank }

extension MailKindLabel on MailKind {
  String get label {
    switch (this) {
      case MailKind.bank:
        return '銀行確定';
      case MailKind.billing:
        return '請求予定';
      case MailKind.usage:
        return '利用';
    }
  }
}

// 💡 メールから読み取った「支払い候補」
class ParsedPayment {
  final String cardName;
  final int amount;
  final DateTime date;
  final String snippet;
  final MailKind kind;
  final String sourceId; // メール由来の一意キー（同一メールの重複取得のみ排除）
  final String note; // 利用先（店舗名）など

  ParsedPayment({
    required this.cardName,
    required this.amount,
    required this.date,
    required this.snippet,
    required this.kind,
    required this.sourceId,
    this.note = '',
  });
}

// 💡 カードごとの検索ルール（Gmailの検索クエリ + 表示名）
class _CardRule {
  final String name;
  final String query; // Gmail検索構文
  const _CardRule(this.name, this.query);
}

class GmailService {
  GmailService._();
  static final GmailService instance = GmailService._();

  // Gmail読み取り専用スコープ
  static const List<String> _scopes = <String>[gmail.GmailApi.gmailReadonlyScope];
  final GoogleSignIn _googleSignIn = GoogleSignIn(scopes: _scopes);

  // 💡 Webは「サインイン（本人確認）」と「スコープ許可（Gmailの読み取り）」が別物。
  //   requestScopes はポップアップを開くので、ユーザーの操作の中からしか呼べない。
  //   自動同期の経路で黙って呼ぶとブロックされ、許可なしのトークンのまま
  //   API が 403 を返してしまうため、確認(hasGmailAccess)と要求(requestGmailAccess)を分ける。
  bool _scopeGranted = false;

  // Gmailを読める状態か（Webはスコープ許可まで確認する）
  Future<bool> hasGmailAccess() async {
    if (_googleSignIn.currentUser == null) return false;
    if (!kIsWeb) return true;
    try {
      _scopeGranted = await _googleSignIn.canAccessScopes(_scopes);
    } catch (_) {
      _scopeGranted = false;
    }
    return _scopeGranted;
  }

  // 💡 スコープ許可を求める。必ずボタンなどユーザー操作から呼ぶこと。
  Future<bool> requestGmailAccess() async {
    if (_googleSignIn.currentUser == null) {
      if (await _googleSignIn.signIn() == null) return false;
    }
    if (!kIsWeb) return true;
    try {
      if (await _googleSignIn.canAccessScopes(_scopes)) {
        _scopeGranted = true;
        return true;
      }
      _scopeGranted = await _googleSignIn.requestScopes(_scopes);
      return _scopeGranted;
    } catch (_) {
      _scopeGranted = false;
      return false;
    }
  }

  // 💡 APIのエラーを「次に何をすればいいか」が分かる文言に直す。
  //   403は原因が複数あるので、メッセージで切り分ける。
  Object _describeApiError(Object e) {
    final text = e.toString();
    final is403 = (e is gmail.DetailedApiRequestError && e.status == 403) ||
        text.contains('403');
    if (!is403) return e;
    final lower = text.toLowerCase();
    if (lower.contains('scope') || lower.contains('insufficient')) {
      _scopeGranted = false;
      return Exception('Gmailの読み取りが許可されていません（403）。'
          '「Gmailのアクセスを許可」を押して、Googleの画面で許可してください。');
    }
    if (lower.contains('has not been used') || lower.contains('disabled')) {
      return Exception('Gmail APIが無効になっています（403）。'
          'Google CloudでGmail APIを有効にしてください。');
    }
    return Exception('Gmailにアクセスできませんでした（403）。$text');
  }

  GoogleSignInAccount? get account => _googleSignIn.currentUser;
  bool get isSignedIn => _googleSignIn.currentUser != null;

  // 各カードの検索ルール。
  // 💡 キーワード一致だと1通が複数カードに混入するため、送信元(from:)だけで絞る
  static const List<_CardRule> _rules = [
    _CardRule('三井住友', 'from:vpass.ne.jp OR from:smbc-card.com'),
    _CardRule('楽天カード', 'from:rakuten-card.co.jp OR from:mail.rakuten-card.co.jp'),
    _CardRule('PayPayカード', 'from:paypay-card.co.jp OR from:paypay-card.com'),
    _CardRule('メルカード', 'from:mercari.com OR from:mercari.jp'),
  ];

  Future<GoogleSignInAccount?> signIn() async {
    final account = await _googleSignIn.signIn();
    if (account != null) await requestGmailAccess();
    return account;
  }

  Future<void> signOut() => _googleSignIn.signOut();

  // 🔧 デバッグ: 指定クエリの最新メールの「件名＋正規化本文」を返す（パーサーが見るテキスト）
  Future<String> debugRawBody(String query) async {
    final client = await _googleSignIn.authenticatedClient();
    if (client == null) return '未連携です';
    final api = gmail.GmailApi(client);
    final ids = await _listIds(api, '$query newer_than:120d');
    if (ids.isEmpty) return '該当メールなし: $query';
    final msgs = await _getByIds(api, [ids.first]);
    if (msgs.isEmpty) return '本文取得失敗';
    final m = msgs.first;
    return '［件名］${_subject(m)}\n\n［本文(正規化)］\n${_normalizeText(_extractBody(m))}';
  }

  // 🔧 デバッグ: Amazonの取得・突合状況を要約して返す
  Future<String> debugAmazonSummary() async {
    final client = await _googleSignIn.authenticatedClient();
    if (client == null) return '未連携です';
    final api = gmail.GmailApi(client);
    _window = 'newer_than:2y';
    final shipIds = await _listIds(api, 'from:shipment-tracking@amazon.co.jp $_window');
    final orderIds = await _listIds(api, 'from:auto-confirm@amazon.co.jp $_window');
    final parsed = await _fetchAmazon(api);
    final sb = StringBuffer()
      ..writeln('発送メール: ${shipIds.length}件')
      ..writeln('注文メール: ${orderIds.length}件')
      ..writeln('抽出された支払い: ${parsed.length}件')
      ..writeln('────────────');
    for (final p in parsed.take(60)) {
      sb.writeln('${p.date.toString().substring(0, 10)}  ¥${p.amount}  ${p.sourceId}');
    }
    return sb.toString();
  }

  Future<bool> signInSilently() async {
    final acc = await _googleSignIn.signInSilently();
    // 💡 ここでは許可を「要求」しない（操作外なのでポップアップが塞がれる）。確認だけ。
    if (acc != null) await hasGmailAccess();
    return acc != null;
  }

  // 銀行（三井住友銀行）の引き落とし事前お知らせ
  static const String _bankQuery = 'from:dn.smbc.co.jp 口座引き落とし';

  // 銀行（三井住友銀行）の「振込入金のお知らせ」。
  //   本文に金額が載らない（SMBCダイレクトで確認する形式）ので、日付だけ拾って
  //   アプリ側で金額をユーザーに入力してもらう。
  static const String _depositQuery = 'from:smbc.co.jp 振込入金';

  // 💡 入金通知メールを取得（メールIDと入金日だけ）。
  Future<List<({String sourceId, DateTime date})>> fetchDepositNotices({DateTime? since}) async {
    try {
      return await _fetchDepositNotices(since: since);
    } catch (e) {
      throw _describeApiError(e);
    }
  }

  Future<List<({String sourceId, DateTime date})>> _fetchDepositNotices({DateTime? since}) async {
    final from = since?.subtract(const Duration(days: 1));
    final window =
        from != null ? 'after:${from.year}/${from.month}/${from.day}' : 'newer_than:90d';
    final client = await _googleSignIn.authenticatedClient();
    if (client == null) return const [];
    final api = gmail.GmailApi(client);
    final ids = await _listIds(api, '($_depositQuery) $window');
    final out = <({String sourceId, DateTime date})>[];
    for (final full in await _getByIds(api, ids)) {
      final id = full.id;
      if (id == null) continue;
      // 宣伝メールは除外（「振込入金のお知らせ」以外を拾わないよう件名でも確認）
      final subject = _subject(full);
      if (_isPromotional(subject)) continue;
      if (!subject.contains('入金')) continue;
      out.add((sourceId: id, date: _internalDate(full) ?? DateTime.now()));
    }
    return out;
  }

  // 取得対象期間。since 指定時はその日付以降（差分更新）、未指定は過去2年
  late String _window;

  // 💡 カード関連メール＋銀行の引落確定メールを取得して支払い候補を抽出
  //   since を渡すとその日付以降だけ取得（2回目以降の差分更新用）
  Future<List<ParsedPayment>> fetchCardPayments({DateTime? since}) async {
    try {
      return await _fetchCardPayments(since: since);
    } catch (e) {
      throw _describeApiError(e);
    }
  }

  Future<List<ParsedPayment>> _fetchCardPayments({DateTime? since}) async {
    // after: の境界で取りこぼさないよう1日前から検索
    final from = since?.subtract(const Duration(days: 1));
    _window = from != null
        ? 'after:${from.year}/${from.month}/${from.day}'
        : 'newer_than:2y';
    final client = await _googleSignIn.authenticatedClient();
    if (client == null) {
      throw Exception('Googleの認証に失敗しました。再ログインしてください。');
    }
    final api = gmail.GmailApi(client);
    final results = <ParsedPayment>[];
    _fetchFailures = 0; // 今回の取りこぼし件数を数え直す

    // ① 各カード：期間内の全メールIDをページングで取得（並列）
    final ruleIds =
        await Future.wait(_rules.map((r) => _listIds(api, '(${r.query}) $_window')));
    for (var ri = 0; ri < _rules.length; ri++) {
      final rule = _rules[ri];
      for (final full in await _getByIds(api, ruleIds[ri])) {
        // 💡 件名が宣伝・キャンペーンなら無条件でスキップ
        if (_isPromotional(_subject(full))) continue;

        final id = full.id ?? '';
        final subject = _subject(full);
        final text = '${full.snippet ?? ''}\n${_extractBody(full)}';

        // 💡 カードごとに専用パーサーへ分岐
        switch (rule.name) {
          case '楽天カード':
            // 利用明細（■利用日/■利用金額ブロック）から複数件抽出。
            // 請求予定（お支払金額のご案内）はブロックが無いので自然に0件になる。
            results.addAll(extractRakutenTransactions(text, id));
            break;
          case 'メルカード':
            final p = (subject.contains('ご購入') || text.contains('ご購入'))
                ? extractMercariPurchase(text, id, _internalDate(full) ?? DateTime.now())
                : extractMercardUsage(text, id);
            if (p != null) results.add(p);
            break;
          default: // 三井住友 / PayPayカード
            if (rule.name == '三井住友' && !_isTransaction(text)) continue;
            final amount = _extractAmount(text, rule.name);
            if (amount == null) continue;
            results.add(ParsedPayment(
              cardName: _resolveCardName(rule.name, text),
              amount: amount,
              date: _extractDate(text) ?? _internalDate(full) ?? DateTime.now(),
              snippet: (full.snippet ?? '').trim(),
              kind: _detectKind(text),
              sourceId: id,
              note: _extractMerchant(text),
            ));
        }
      }
    }

    // ② 銀行の引落確定メール（複数カードの明細を含む。正本）
    final bankIds = await _listIds(api, '($_bankQuery) $_window');
    for (final full in await _getByIds(api, bankIds)) {
      results.addAll(
          _parseBankMail(_extractBody(full), (full.snippet ?? '').trim(), full.id ?? ''));
    }

    // ③ Amazon（注文メールの金額 ＋ 発送メールの日付 を注文番号で突合）
    results.addAll(await _fetchAmazon(api));

    return results;
  }

  // 💡 期間内の全メッセージIDをページングで取得（漏れなく拾う）
  Future<List<String>> _listIds(gmail.GmailApi api, String query, {int cap = 3000}) async {
    final ids = <String>[];
    String? token;
    do {
      final resp =
          await api.users.messages.list('me', q: query, maxResults: 100, pageToken: token);
      ids.addAll((resp.messages ?? []).where((m) => m.id != null).map((m) => m.id!));
      token = resp.nextPageToken;
    } while (token != null && ids.length < cap);
    return ids;
  }

  // 💡 IDリストの本文を並列取得（同時実行数を制限）。
  //   1通の取得・解析で失敗しても全体を止めない（その1通だけスキップ）。
  // 💡 取得に失敗したメール数（直近の fetchCardPayments 分）。
  //   取りこぼしたまま同期すると、その明細が消えて残高がブレるため、
  //   呼び出し側はこれが 0 でないときは反映を中止する。
  int _fetchFailures = 0;
  int get lastFetchFailures => _fetchFailures;

  Future<List<gmail.Message>> _getByIds(gmail.GmailApi api, List<String> ids,
      {int concurrency = 8}) async {
    final out = <gmail.Message>[];
    final failed = <String>[];

    Future<gmail.Message?> fetch(String id) async {
      try {
        return await api.users.messages.get('me', id, format: 'full');
      } catch (_) {
        return null;
      }
    }

    // 1周目: 並列取得（同時接続を抑えてレート制限を避ける）
    for (var i = 0; i < ids.length; i += concurrency) {
      final end = (i + concurrency) > ids.length ? ids.length : i + concurrency;
      final chunk = ids.sublist(i, end);
      final res = await Future.wait(chunk.map(fetch));
      for (var k = 0; k < chunk.length; k++) {
        final m = res[k];
        if (m != null) {
          out.add(m);
        } else {
          failed.add(chunk[k]);
        }
      }
    }

    // 2周目以降: 失敗分を間隔をあけて再試行（一時的なエラー・レート制限対策）
    for (var attempt = 1; attempt <= 3 && failed.isNotEmpty; attempt++) {
      await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
      final retry = List<String>.from(failed);
      failed.clear();
      for (final id in retry) {
        final m = await fetch(id);
        if (m != null) {
          out.add(m);
        } else {
          failed.add(id);
        }
      }
    }

    _fetchFailures += failed.length; // 最後まで取れなかった件数
    return out;
  }

  // 注文番号 (例: 250-5886779-0244640 / 電子書籍 D01-1728716-8370610)
  final RegExp _amazonOrderNo = RegExp(r'([A-Z]?\d{2,3}-\d{7}-\d{7})');

  // 💡 Amazonは「注文済み」で金額（ポイント適用後の合計）、「発送済み」で
  //    支払い確定日（発送日）が分かる。注文番号で突合し1件にまとめる。
  //    キャンセルメールが届いた注文は除外（更新時に取り消し）。
  Future<List<ParsedPayment>> _fetchAmazon(gmail.GmailApi api) async {
    // 4種類のIDをページングで取得（並列）
    final idLists = await Future.wait([
      _listIds(api, 'from:amazon.co.jp (キャンセル OR cancel) $_window'),
      _listIds(api, 'from:auto-confirm@amazon.co.jp $_window'),
      _listIds(api, 'from:shipment-tracking@amazon.co.jp $_window'),
      _listIds(api, 'from:digital-no-reply@amazon.co.jp $_window'), // 電子書籍・デジタル
    ]);
    // 本文も並列取得
    final fetched = await Future.wait([
      _getByIds(api, idLists[0]),
      _getByIds(api, idLists[1]),
      _getByIds(api, idLists[2]),
      _getByIds(api, idLists[3]),
    ]);

    // キャンセルされた注文番号
    final cancelled = <String>{};
    for (final full in fetched[0]) {
      final text = '${full.snippet ?? ''}\n${_extractBody(full)}';
      final no = _amazonOrderNo.firstMatch(text)?.group(1);
      if (no != null) cancelled.add(no);
    }

    // 注文メール: 注文番号 → 金額・スニペット
    final orders = <String, ({int amount, String snippet})>{};
    for (final full in fetched[1]) {
      final text = '${full.snippet ?? ''}\n${_extractBody(full)}';
      final no = _amazonOrderNo.firstMatch(text)?.group(1);
      // Amazon注文メールは「合計」行を金額とする（取引メールなので誤爆しない）
      final amount = _extractAmount(text, 'Amazonマスター', extraKeywords: const ['合計']);
      if (no != null && amount != null && !cancelled.contains(no)) {
        orders[no] = (amount: amount, snippet: (full.snippet ?? '').trim());
      }
    }

    // 発送メール: 注文番号 → 発送日（メール受信日時）。注文と一致したら確定
    // 💡 分割発送で同じ注文番号が複数届くため、注文番号で1件にまとめる
    final out = <ParsedPayment>[];
    final addedOrders = <String>{};
    for (final full in fetched[2]) {
      final text = '${full.snippet ?? ''}\n${_extractBody(full)}';
      final no = _amazonOrderNo.firstMatch(text)?.group(1);
      if (no == null || cancelled.contains(no)) continue; // キャンセル分は除外
      if (!addedOrders.add(no)) continue; // 同じ注文は1回だけ
      // 金額は注文メール（ポイント適用後）優先。無ければ発送メールの「合計」で補完。
      final amount = orders[no]?.amount ??
          _extractAmount(text, 'Amazonマスター', extraKeywords: const ['合計']);
      if (amount == null) continue; // どちらからも金額が取れない場合のみスキップ
      out.add(ParsedPayment(
        cardName: 'Amazonマスター',
        amount: amount,
        date: _internalDate(full) ?? DateTime.now(), // 発送日＝発送メール日時
        snippet: 'Amazon 発送確定 (注文$no)',
        // 💡 支払カードが不明なため「情報のみ」。残高は各カードの請求/引落で計上
        kind: MailKind.usage,
        sourceId: 'amazon#$no', // 注文番号で一意（分割発送は1回に集約）
      ));
    }

    // 💡 電子書籍・デジタル注文（発送が無い＝注文時に課金）。金額は「総計」(ポイント適用後)。
    for (final full in fetched[3]) {
      final text = _normalizeText('${full.snippet ?? ''}\n${_extractBody(full)}');
      final no = _amazonOrderNo.firstMatch(text)?.group(1);
      if (no == null || cancelled.contains(no)) continue;
      if (!addedOrders.add(no)) continue;
      final am = RegExp(r'総計\s*[:：]?\s*[¥￥]?\s*([0-9,]+)').firstMatch(text);
      final amount = am != null ? int.tryParse(am.group(1)!.replaceAll(',', '')) : null;
      if (amount == null || amount < 1) continue;
      // 注文日 → 日付（無ければ受信日時）
      final dm = RegExp(r'注文日\s*[:：]?\s*(\d{4})年(\d{1,2})月(\d{1,2})日').firstMatch(text);
      final date = dm != null
          ? DateTime(int.parse(dm.group(1)!), int.parse(dm.group(2)!), int.parse(dm.group(3)!))
          : (_internalDate(full) ?? DateTime.now());
      // 商品名（件名「…でのご注文: タイトル」から）
      final note =
          RegExp(r'ご注文\s*[:：]\s*(.+)').firstMatch(_subject(full))?.group(1)?.trim() ?? '';
      out.add(ParsedPayment(
        cardName: 'Amazonマスター',
        amount: amount,
        date: date,
        snippet: 'Amazon(電子) $note',
        kind: MailKind.usage,
        sourceId: 'amazon#$no',
        note: note,
      ));
    }
    return out;
  }

  // ───── 銀行メールの明細を解析（複数カード分）─────
  // 口座引落予定日：YYYY年MM月DD日 を全明細の日付に使い、
  // ◆明細ごとに「引落金額」と「内容(カード名)」を取り出す。
  List<ParsedPayment> _parseBankMail(String text, String snippet, String msgId) {
    // 全角数字（１０，０００円）も拾えるよう正規化してから解析
    final t = _normalizeText(text);
    final out = <ParsedPayment>[];

    // 引落予定日
    final dm = RegExp(r'口座引落予定日[:：\s]*(\d{4})年(\d{1,2})月(\d{1,2})日').firstMatch(t);
    final date = dm != null
        ? DateTime(int.parse(dm.group(1)!), int.parse(dm.group(2)!), int.parse(dm.group(3)!))
        : DateTime.now();

    // 各明細: 引落金額 ... 内容
    final item = RegExp(
        r'引落金額[:：\s]*([0-9,]+)\s*円[\s\S]{0,40}?内容[:：\s]*([^\n（(]+)');
    var idx = 0;
    for (final m in item.allMatches(t)) {
      final amount = int.tryParse(m.group(1)!.replaceAll(',', ''));
      if (amount == null) continue;
      final card = _mapCardName(m.group(2)!.trim());
      out.add(ParsedPayment(
        cardName: card,
        amount: amount,
        date: date,
        snippet: '銀行引落確定: $snippet',
        kind: MailKind.bank,
        sourceId: '$msgId#${idx++}', // 明細ごとに一意
      ));
    }
    return out;
  }

  // 銀行メールの「内容」表記をアプリのカード名に正規化
  String _mapCardName(String content) {
    final c = _toHalf(content).replaceAll(' ', '');
    final u = c.toUpperCase();
    if (u.contains('PAYPAY') || c.contains('ペイペイ')) return 'PayPayカード';
    if (c.contains('ラクテン') || c.contains('楽天')) return '楽天カード';
    if (u.contains('AMAZON') || c.contains('アマゾン')) return 'Amazonマスター';
    if (c.contains('メル')) return 'メルカード';
    if (c.contains('ミツイスミトモ') || c.contains('三井住友') || u.contains('OLIVE') || c.contains('オリーブ')) {
      return '三井OLIVE';
    }
    return content; // 不明はそのまま
  }

  // vpass/smbc-card は1つの送信元から クレジット/デビット/Vポイントペイ/Amazon が届くため本文で判別
  String _resolveCardName(String ruleName, String text) {
    if (ruleName != '三井住友') return ruleName;
    final t = _toHalf(text);
    final u = t.toUpperCase();
    final compact = t.replaceAll(' ', '');
    if (u.contains('AMAZON') || text.contains('アマゾン')) return 'Amazonマスター';
    if (compact.contains('プリペイド') || compact.contains('VポイントPay')) {
      return '三井OLIVE（Vポイントペイ）';
    }
    if (text.contains('デビット')) return '三井OLIVE（デビット）';
    return '三井OLIVE'; // クレジット/Olive
  }

  // 全角英数字を半角へ（Ｏｌｉｖｅ → Olive など）
  String _toHalf(String s) {
    final buf = StringBuffer();
    for (final r in s.runes) {
      if (r >= 0xFF01 && r <= 0xFF5E) {
        buf.writeCharCode(r - 0xFEE0);
      } else if (r == 0x3000) {
        buf.write(' ');
      } else {
        buf.writeCharCode(r);
      }
    }
    return buf.toString();
  }

  // 💡 解析用に正規化：全角→半角、￥統一、改行・空白を1つにまとめる。
  //   テーブル/HTML由来の余分な空白でラベルと数値が離れる問題を解消し、
  //   全角数字（１０，０００）も拾えるようにする。
  String _normalizeText(String text) => _toHalf(text)
      .replaceAll('￥', '¥')
      .replaceAll(RegExp(r'[\s　]+'), ' ');

  // 取引/請求を示す明確なキーワード（宣伝メールには通常含まれない）
  static const List<String> _txnMarkers = [
    'ご利用のお知らせ', 'ご利用日時', 'ご利用内容', 'ご利用金額',
    'カード利用お知らせ', 'カード利用のお知らせ',
    'お支払金額', 'お支払い金額', 'お支払い金額のご案内', '支払い金額',
    '請求金額', 'ご請求金額', '請求予定金額', '請求額',
    '取引内容', '取引金額合計', 'ご購入', '決済でお支払い', '口座引落',
  ];

  bool _isTransaction(String text) {
    final t = _toHalf(text);
    return _txnMarkers.any(t.contains);
  }

  // 件名(Subject)を取得
  String _subject(gmail.Message m) {
    for (final h in m.payload?.headers ?? const <gmail.MessagePartHeader>[]) {
      if ((h.name ?? '').toLowerCase() == 'subject') return h.value ?? '';
    }
    return '';
  }

  // 💡 宣伝・キャンペーンメールの件名キーワード（決済メールの件名には通常入らない）。
  //   本文ではなく「件名」で判定して、正規メールのフッター文での誤除外を防ぐ。
  static const List<String> _promoMarkers = [
    'キャンペーン', 'エントリー', '抽選', '当選', '当たる', 'プレゼント', '招待',
    'クーポン', 'OFF', '進呈', '還元', '損かも', 'お得', '最大', '名さま',
    '入会', 'セール', '受付中', 'おすすめ', '無料', '％', '%',
  ];

  bool _isPromotional(String subject) {
    final s = _toHalf(subject);
    return _promoMarkers.any(s.contains);
  }

  // 💡 利用先（店舗名）を抽出。「スカイマーク（買物）」等の括弧パターンを優先。
  String _extractMerchant(String text) {
    final t = _normalizeText(text);
    final paren =
        RegExp(r'([^\s（）():：]{2,40})\s*[（(](?:買物|ご利用|利用|物販|サービス|電子マネー)[）)]')
            .firstMatch(t);
    if (paren != null) return paren.group(1)!.trim();
    // 「ご利用先：◯◯」「ご利用店舗：◯◯」
    final label = RegExp(r'ご利用(?:先|店舗|加盟店)[:：]?\s*([^\s0-9¥円]{2,40})').firstMatch(t);
    if (label != null) return label.group(1)!.trim();
    return '';
  }

  // ───── 種別判定（請求確定 or 利用通知）─────
  // 「ご請求を確定するものではございません」等の免責文に引っかからないよう、
  // 具体的な請求ラベル句だけで判定する。
  static const List<String> _billingMarkers = [
    'お支払金額', 'お支払い金額', '月度のお支払', 'ご請求金額', 'ご請求額',
    'お支払い予定金額', 'お支払い金額のご案内', 'ご請求予定金額', '確定のお知らせ',
    '請求予定金額', '請求予定', '請求確定',
  ];

  MailKind _detectKind(String text) {
    for (final marker in _billingMarkers) {
      if (text.contains(marker)) return MailKind.billing;
    }
    return MailKind.usage;
  }

  // ───── 本文の取り出し（base64url）─────
  String _extractBody(gmail.Message msg) {
    final payload = msg.payload;
    if (payload == null) return '';
    final buffer = StringBuffer();
    _walkParts(payload, buffer);
    return buffer.toString();
  }

  void _walkParts(gmail.MessagePart part, StringBuffer buffer) {
    final data = part.body?.data;
    if (data != null && (part.mimeType?.startsWith('text/') ?? false)) {
      try {
        buffer.writeln(utf8.decode(base64Url.decode(_normalize(data))));
      } catch (_) {}
    }
    for (final p in part.parts ?? <gmail.MessagePart>[]) {
      _walkParts(p, buffer);
    }
  }

  String _normalize(String b64) {
    var s = b64.replaceAll('-', '+').replaceAll('_', '/');
    while (s.length % 4 != 0) {
      s += '=';
    }
    return base64.normalize(s);
  }

  // ───── 金額抽出 ─────
  // 会員番号などの長い数字を誤検出しないよう、
  // ①「ご利用/ご請求/お支払金額」等のキーワード近くの金額を最優先
  // ②なければカンマ区切り(1,234)の金額を採用（ID等のカンマ無し数字は除外）
  static const int _maxAmount = 100000000; // 1億円を上限に異常値を除外

  // 金額ラベル（この近くの金額を最優先）。具体的なものを先に並べる
  // 💡「合計」は単独だと宣伝文「合計5,000円以上ご利用で」に誤爆するため共通からは外し、
  //   Amazon取得時のみ extraKeywords で限定的に使う。
  static const List<String> _amountKeywords = [
    'ご利用金額', 'ご請求金額', 'ご請求額', 'お支払金額', 'お支払い金額',
    '請求金額', '請求額', '利用金額', '合計金額', 'お支払い予定金額',
    'ご利用内容', 'ご利用日時', 'ご利用先', // 利用通知メール用
  ];

  // 💡「¥」付き、または「円 / JPY」付きの数字だけを金額とみなす（番号やIDを除外）。
  //   685円 / 3,280円 / ¥685 / ¥3,280 / 1,300.00 JPY にマッチ。
  //   小数部(.00)は非キャプチャで読み飛ばし、整数部だけを採用。
  final RegExp _moneyRegex = RegExp(
      r'¥\s*([0-9]{1,3}(?:,[0-9]{3})+|[0-9]{1,7})(?:\.[0-9]+)?'
      r'|([0-9]{1,3}(?:,[0-9]{3})+|[0-9]{1,7})(?:\.[0-9]+)?\s*(?:円|JPY)',
      caseSensitive: false);

  int? _moneyValue(RegExpMatch m) {
    final s = (m.group(1) ?? m.group(2))!.replaceAll(',', '');
    final n = int.tryParse(s);
    if (n == null || n < 1 || n > _maxAmount) return null;
    return n;
  }

  // パターン群を順に試し、最初に一致した金額（group(1)）を返す
  int? _firstAmount(String t, List<RegExp> patterns) {
    for (final re in patterns) {
      for (final m in re.allMatches(t)) {
        final n = int.tryParse(m.group(1)!.replaceAll(',', ''));
        if (n != null && n >= 1 && n <= _maxAmount) return n;
      }
    }
    return null;
  }

  // 💡 カード別の厳密な金額抽出。
  //   メル/PayPay/楽天は「指定パターンに一致した時のみ」抽出し、それ以外の数字は拾わない。
  //   三井OLIVE系・Amazon等はキーワード近傍方式（誤抽出しにくい）。
  int? _extractAmount(String text, String cardName, {List<String> extraKeywords = const []}) {
    final t = _normalizeText(text);

    // ── PayPayカード ──
    //  A(速報): 「利用速報」が目印。時刻直後の金額（13:28 3,000円）
    //  B(通常): ご利用金額/利用金額/お支払金額 の後の「[金額] 円」
    if (cardName.contains('PayPay') || cardName.contains('ペイペイ')) {
      if (t.contains('利用速報')) {
        final a = _firstAmount(t, [RegExp(r'\d{1,2}:\d{2}\s*([0-9,]+)\s*円')]);
        if (a != null) return a;
      }
      return _firstAmount(
          t, [RegExp(r'(?:ご利用金額|利用金額|お支払金額)\s*[:：]?\s*([0-9,]+)\s*円')]);
    }

    // ── それ以外（三井OLIVE系・Amazon等）: キーワード近傍方式 ──
    // （楽天・メルはカード別の専用パーサーで処理するためここには来ない）
    // ラベル直後（空白圧縮後120文字以内）の金額のみ採用。無ければ拾わない。
    for (final kw in [..._amountKeywords, ...extraKeywords]) {
      var from = 0;
      while (true) {
        final idx = t.indexOf(kw, from);
        if (idx < 0) break;
        final end = (idx + kw.length + 120).clamp(0, t.length);
        for (final m in _moneyRegex.allMatches(t.substring(idx, end))) {
          final n = _moneyValue(m);
          if (n != null) return n;
        }
        from = idx + kw.length;
      }
    }
    return null;
  }

  // ════════════ カード専用パーサー ════════════

  // 💡 楽天カード利用明細を解析（1メール→複数件、合計は除外）。
  //   ①プレーンテキストの「■利用日 / ■利用先 / ■利用金額」ラベル
  //   ②HTML表の「<td>日付</td><td>店名</td><td>金額 円</td>」行
  //   の両方から拾い、(日付+金額) で重複を除外する（本文省略で①が欠けても②で補完）。
  @visibleForTesting
  List<ParsedPayment> extractRakutenTransactions(String text, String msgId) {
    final t = _normalizeText(text);
    final out = <ParsedPayment>[];
    final seen = <String>{};
    var i = 0;

    void add(int y, int mo, int d, String merchant, int amount) {
      if (amount < 1 || amount > _maxAmount) return;
      final key = '$y-$mo-$d|$amount';
      if (!seen.add(key)) return; // 同一メール内の重複（■とHTMLの二重）を除外
      out.add(ParsedPayment(
        cardName: '楽天カード',
        amount: amount,
        date: DateTime(y, mo, d),
        snippet: '楽天利用',
        kind: MailKind.usage,
        sourceId: '$msgId#${i++}',
        note: merchant.trim(),
      ));
    }

    // ① ■ラベル形式
    final block = RegExp(
      r'■\s*利用日\s*[:：]?\s*(\d{4})/(\d{1,2})/(\d{1,2})'
      r'.*?■\s*利用先\s*[:：]?\s*(.+?)\s*■'
      r'.*?利用金額\s*[:：]?\s*([0-9,]+)\s*円',
      dotAll: true,
    );
    for (final m in block.allMatches(t)) {
      final amount = int.tryParse(m.group(5)!.replaceAll(',', ''));
      if (amount == null) continue;
      add(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!),
          m.group(4)!, amount);
    }

    // ② HTML表形式（<td>日付</td><td>店名</td><td>金額 円</td>）
    final htmlRow = RegExp(
      r'<td[^>]*>\s*(\d{4})/(\d{1,2})/(\d{1,2})\s*</td>\s*'
      r'<td[^>]*>\s*([^<]*?)\s*</td>\s*'
      r'<td[^>]*>\s*([0-9,]+)\s*円',
    );
    for (final m in htmlRow.allMatches(t)) {
      final amount = int.tryParse(m.group(5)!.replaceAll(',', ''));
      if (amount == null) continue;
      add(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!),
          m.group(4)!, amount);
    }

    // ③ 【速報版】カード利用のお知らせ（利用先が無く「ご利用日/利用者/ご利用金額」の3列）。
    //   セル内が <span> 等で包まれると②のHTML表パターンが効かないので、
    //   タグを除去した素のテキストから「日付…金額 円」を1件だけ拾う。
    if (out.isEmpty) {
      final plain = _stripTags(t);
      final m = RegExp(
        r'ご利用日[\s\S]{0,60}?(\d{4})/(\d{1,2})/(\d{1,2})[\s\S]{0,60}?([0-9,]+)\s*円',
      ).firstMatch(plain);
      if (m != null) {
        final amount = int.tryParse(m.group(4)!.replaceAll(',', ''));
        if (amount != null) {
          add(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!), '', amount);
        }
      }
    }

    return out;
  }

  // HTMLタグを取り除いて素のテキストにする（構造に依存しない解析用）
  String _stripTags(String html) => html
      .replaceAll(RegExp(r'<(script|style)[^>]*>[\s\S]*?</\1>', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll(RegExp(r'\s+'), ' ');

  // 💡 メルカリ「ご購入ありがとうございます」→ 商品代金 と 商品名 を取得（受信日時を日付に）。
  @visibleForTesting
  ParsedPayment? extractMercariPurchase(String text, String msgId, DateTime received) {
    final t = _normalizeText(text);
    final am = RegExp(r'(?:支払い金額|商品代金)\s*[:：]?\s*¥\s*([0-9,]+)').firstMatch(t);
    if (am == null) return null;
    final amount = int.tryParse(am.group(1)!.replaceAll(',', ''));
    if (amount == null || amount < 1) return null;
    // 商品名（「= 英語名」やラベルの前で切る）
    var note = RegExp(r'商品名\s*[:：]\s*(.+?)\s*(?:出品者|■|支払|クーポン|$)')
            .firstMatch(t)
            ?.group(1)
            ?.trim() ??
        '';
    if (note.contains('=')) note = note.split('=').first.trim();
    return ParsedPayment(
      cardName: 'メルカード',
      amount: amount,
      date: received,
      snippet: 'メルカリ購入: $note',
      kind: MailKind.usage,
      sourceId: '$msgId#0',
      note: note,
    );
  }

  // 💡 メルカード「ご利用がありました」→ 決済金額・決済日時・店舗名 を取得。
  @visibleForTesting
  ParsedPayment? extractMercardUsage(String text, String msgId) {
    final t = _normalizeText(text);
    final am = RegExp(r'決済金額\s*¥\s*([0-9,]+)').firstMatch(t);
    if (am == null) return null;
    final amount = int.tryParse(am.group(1)!.replaceAll(',', ''));
    if (amount == null || amount < 1) return null;
    final dtStr =
        RegExp(r'決済日時\s*(\d{4}/\d{1,2}/\d{1,2}\s*\d{1,2}:\d{2})').firstMatch(t)?.group(1);
    final date = (dtStr != null ? _parseDate(dtStr) : null) ?? DateTime.now();
    final store =
        RegExp(r'店舗名\s*(.+?)\s*決済金額').firstMatch(t)?.group(1)?.trim() ?? '';
    return ParsedPayment(
      cardName: 'メルカード',
      amount: amount,
      date: date,
      snippet: 'メルカード利用: $store',
      kind: MailKind.usage,
      sourceId: '$msgId#0',
      note: store,
    );
  }

  // ───── 日付抽出 ─────
  // 「利用日時 / 支払い日 / 口座引落予定日」近くの日付を優先。利用日時は時刻も取得。
  static const List<String> _dateKeywords = [
    'ご利用日時', 'ご利用日', '決済日時', '取引日時', '支払い日', '支払日', '口座引落予定日', 'お支払い日'
  ];

  DateTime? _extractDate(String text) {
    final t = _normalizeText(text);
    // 日付ラベル近く（空白圧縮後40文字以内）の日付のみ採用。
    // 本文全体の最初の日付を拾うと広告日付や前月分を誤認識するため行わない。
    // （ラベルが無い場合は呼び出し側がメール受信日時で補完する）
    for (final kw in _dateKeywords) {
      final idx = t.indexOf(kw);
      if (idx < 0) continue;
      final end = (idx + kw.length + 40).clamp(0, t.length);
      final d = _parseDate(t.substring(idx, end));
      if (d != null) return d;
    }
    return null;
  }

  DateTime? _parseDate(String text) {
    final now = DateTime.now();

    // 年月日（＋任意で時:分）。時刻があれば取引の識別に使う
    final ymd = RegExp(
            r'(\d{4})[/年.-](\d{1,2})[/月.-](\d{1,2})(?:[\sT]+(\d{1,2}):(\d{2}))?')
        .firstMatch(text);
    if (ymd != null) {
      return DateTime(
        int.parse(ymd.group(1)!),
        int.parse(ymd.group(2)!),
        int.parse(ymd.group(3)!),
        int.tryParse(ymd.group(4) ?? '') ?? 0,
        int.tryParse(ymd.group(5) ?? '') ?? 0,
      );
    }

    final md = RegExp(r'(\d{1,2})月(\d{1,2})日').firstMatch(text);
    if (md != null) {
      final month = int.parse(md.group(1)!);
      final day = int.parse(md.group(2)!);
      var year = now.year;
      if (month < now.month - 1) year += 1; // 過去の月なら翌年扱い
      return DateTime(year, month, day);
    }
    return null;
  }

  DateTime? _internalDate(gmail.Message msg) {
    final ms = msg.internalDate;
    if (ms == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(int.tryParse(ms) ?? 0);
  }
}
