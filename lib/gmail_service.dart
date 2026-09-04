import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:googleapis/gmail/v1.dart' as gmail;
import 'package:shared_preferences/shared_preferences.dart';

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

// 💡 メール1通ぶんの解析結果キャッシュ。金額をそのまま持つので、
//   往復（toJson/fromJson）が壊れると明細が化ける。test/gmail_cache_test.dart で担保する。
//   payments が空でも「解析済み（何も出なかった）」という意味を持つので保存する。
class GmailCacheEntry {
  final int epochMs; // メールの受信日時（古いものを間引くときに使う）
  final List<ParsedPayment> payments;
  final AmazonFact? amazon; // Amazonの突合用の中間データ

  const GmailCacheEntry({
    required this.epochMs,
    this.payments = const [],
    this.amazon,
  });

  Map<String, dynamic> toJson() => {
        't': epochMs,
        if (payments.isNotEmpty)
          'p': [
            for (final p in payments)
              {
                'c': p.cardName,
                'm': p.amount,
                'd': p.date.millisecondsSinceEpoch,
                's': p.snippet.length > 120 ? p.snippet.substring(0, 120) : p.snippet,
                'k': p.kind.index,
                'i': p.sourceId,
                'n': p.note,
              }
          ],
        if (amazon != null) 'a': amazon!.toJson(),
      };

  static GmailCacheEntry? fromJson(Map<String, dynamic> j) {
    final t = j['t'];
    if (t is! int) return null;
    return GmailCacheEntry(
      epochMs: t,
      payments: [
        for (final e in (j['p'] as List? ?? const []))
          ParsedPayment(
            cardName: e['c'] as String? ?? '',
            amount: e['m'] as int? ?? 0,
            date: DateTime.fromMillisecondsSinceEpoch(e['d'] as int? ?? t),
            snippet: e['s'] as String? ?? '',
            kind: MailKind.values[(e['k'] as int? ?? 0).clamp(0, MailKind.values.length - 1)],
            sourceId: e['i'] as String? ?? '',
            note: e['n'] as String? ?? '',
          )
      ],
      amazon: j['a'] is Map<String, dynamic>
          ? AmazonFact.fromJson(j['a'] as Map<String, dynamic>)
          : null,
    );
  }
}

// 💡 Amazonは「注文メールの金額」と「発送メールの日付」を注文番号で突き合わせるため、
//   支払いそのものではなく、メールから読んだ材料をキャッシュする。
class AmazonFact {
  final String orderNo; // 注文番号（空＝読めなかった）
  final int amount; // 0＝このメールからは金額不明
  final int epochMs; // 発送日/注文日
  final String snippet;
  final String note;

  const AmazonFact({
    required this.orderNo,
    this.amount = 0,
    required this.epochMs,
    this.snippet = '',
    this.note = '',
  });

  Map<String, dynamic> toJson() => {
        'o': orderNo,
        'm': amount,
        't': epochMs,
        if (snippet.isNotEmpty)
          's': snippet.length > 120 ? snippet.substring(0, 120) : snippet,
        if (note.isNotEmpty) 'n': note,
      };

  static AmazonFact fromJson(Map<String, dynamic> j) => AmazonFact(
        orderNo: j['o'] as String? ?? '',
        amount: j['m'] as int? ?? 0,
        epochMs: j['t'] as int? ?? 0,
        snippet: j['s'] as String? ?? '',
        note: j['n'] as String? ?? '',
      );
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

  // 💡 一度許可が取れたら、アクセストークンが生きている間は再確認しない。
  //   確認・要求のたびにGoogleのウィンドウが一瞬開くので、更新のたびに光らせない。
  //   （アクセストークンの寿命は1時間なので、少し手前で切らす）
  DateTime? _scopeCheckedAt;
  static const Duration _scopeTtl = Duration(minutes: 45);

  // Gmailを読める状態か（Webはスコープ許可まで確認する）
  Future<bool> hasGmailAccess() async {
    if (_googleSignIn.currentUser == null) return false;
    if (!kIsWeb) return true;
    final at = _scopeCheckedAt;
    if (_scopeGranted && at != null && DateTime.now().difference(at) < _scopeTtl) {
      return true;
    }
    try {
      _scopeGranted = await _googleSignIn.canAccessScopes(_scopes);
    } catch (_) {
      _scopeGranted = false;
    }
    _scopeCheckedAt = _scopeGranted ? DateTime.now() : null;
    return _scopeGranted;
  }

  // 💡 スコープ許可を求める。必ずボタンなどユーザー操作から呼ぶこと。
  Future<bool> requestGmailAccess() async {
    if (!kIsWeb) {
      return _googleSignIn.currentUser != null ||
          await _googleSignIn.signIn() != null;
    }
    // ⚠️ Webで signIn() を呼ぶと「Googleログイン」のポップアップが開く。
    //   ログイン済みなら即閉じるので、更新のたびに画面が一瞬光る原因になる。
    //   Webは silent サインイン → スコープ要求だけで足りるので signIn() は使わない。
    if (_googleSignIn.currentUser == null) {
      await _googleSignIn.signInSilently();
      if (_googleSignIn.currentUser == null) return false;
    }
    try {
      if (await _googleSignIn.canAccessScopes(_scopes)) {
        _scopeGranted = true;
        _scopeCheckedAt = DateTime.now();
        return true;
      }
      _scopeGranted = await _googleSignIn.requestScopes(_scopes);
      _scopeCheckedAt = _scopeGranted ? DateTime.now() : null;
      return _scopeGranted;
    } catch (_) {
      _scopeGranted = false;
      _scopeCheckedAt = null;
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
    if (lower.contains('quota') || lower.contains('rate limit')) {
      return Exception('Gmailの取得が混み合っています（403 クォータ超過）。'
          '1〜2分ほど待ってから、もう一度更新してください。');
    }
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

  Future<void> signOut() {
    _scopeGranted = false;
    _scopeCheckedAt = null;
    return _googleSignIn.signOut();
  }

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
    await _loadCache();

    // ① 各カード・銀行：期間内の全メールIDをページングで取得（並列）
    final listed = await Future.wait([
      ..._rules.map((r) => _listIds(api, '(${r.query}) $_window')),
      _listIds(api, '($_bankQuery) $_window'),
    ]);
    final ruleIds = listed.sublist(0, _rules.length);
    final bankIds = listed.last;

    // ② 未キャッシュのメールだけ本文を取って解析（ここが唯一の重い処理）
    for (var ri = 0; ri < _rules.length; ri++) {
      final rule = _rules[ri];
      await _fillCache(api, ruleIds[ri], '', (full) => GmailCacheEntry(
            epochMs: (_internalDate(full) ?? DateTime.now()).millisecondsSinceEpoch,
            payments: _parseRuleMessage(rule, full),
          ));
      results.addAll(_cachedPayments(ruleIds[ri]));
    }

    // ③ 銀行の引落確定メール（複数カードの明細を含む。正本）
    await _fillCache(api, bankIds, 'b', (full) => GmailCacheEntry(
          epochMs: (_internalDate(full) ?? DateTime.now()).millisecondsSinceEpoch,
          payments: _parseBankMail(
              _extractBody(full), (full.snippet ?? '').trim(), full.id ?? ''),
        ));
    results.addAll(_cachedPayments(bankIds, 'b'));

    // ④ Amazon（注文メールの金額 ＋ 発送メールの日付 を注文番号で突合）
    results.addAll(await _fetchAmazon(api));

    await _saveCache();
    return results;
  }


  // 💡 カードごとの専用パーサー。キャッシュに入れるため1通→支払い候補のリストにする。
  List<ParsedPayment> _parseRuleMessage(_CardRule rule, gmail.Message full) {
    final subject = _subject(full);
    // 件名が宣伝・キャンペーンなら無条件でスキップ
    if (_isPromotional(subject)) return const [];
    final id = full.id ?? '';
    final text = '${full.snippet ?? ''}\n${_extractBody(full)}';

    switch (rule.name) {
      case '楽天カード':
        // 利用明細（■利用日/■利用金額ブロック）から複数件抽出。
        // 請求予定（お支払金額のご案内）はブロックが無いので自然に0件になる。
        return extractRakutenTransactions(text, id);
      case 'メルカード':
        final p = (subject.contains('ご購入') || text.contains('ご購入'))
            ? extractMercariPurchase(text, id, _internalDate(full) ?? DateTime.now())
            : extractMercardUsage(text, id);
        return p != null ? [p] : const [];
      default: // 三井住友 / PayPayカード
        if (rule.name == '三井住友' && !_isTransaction(text)) return const [];
        final amount = _extractAmount(text, rule.name);
        if (amount == null) return const [];
        return [
          ParsedPayment(
            cardName: _resolveCardName(rule.name, text),
            amount: amount,
            date: _extractDate(text) ?? _internalDate(full) ?? DateTime.now(),
            snippet: (full.snippet ?? '').trim(),
            kind: _detectKind(text),
            sourceId: id,
            note: _extractMerchant(text),
          )
        ];
    }
  }

  // ───────── 解析結果のキャッシュ（更新を速くする本体） ─────────
  // 💡 更新のたびに同じ1〜2ヶ月分の本文を丸ごと再取得していたのが遅さの原因。
  //   メールIDごとに「解析結果」を保存しておき、2回目以降はID一覧だけ取り直して
  //   新着ぶんの本文だけ取得する。抽出できなかったメールも「空」で覚えて再取得を防ぐ。
  static const String _cacheKey = 'saved_gmail_msg_cache_v1';
  static const int _cacheMaxEntries = 4000;
  final Map<String, GmailCacheEntry> _cache = {};
  bool _cacheLoaded = false;
  bool _cacheDirty = false;

  Future<void> _loadCache() async {
    if (_cacheLoaded) return;
    _cacheLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw == null) return;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      map.forEach((k, v) {
        final e = GmailCacheEntry.fromJson(v as Map<String, dynamic>);
        if (e != null) _cache[k] = e;
      });
    } catch (_) {
      _cache.clear(); // 壊れていたら捨てて取り直す
    }
  }

  Future<void> _saveCache() async {
    if (!_cacheDirty) return;
    _cacheDirty = false;
    try {
      // 古いものから間引いて上限に収める
      if (_cache.length > _cacheMaxEntries) {
        final keys = _cache.keys.toList()
          ..sort((a, b) => _cache[a]!.epochMs.compareTo(_cache[b]!.epochMs));
        for (final k in keys.take(_cache.length - _cacheMaxEntries)) {
          _cache.remove(k);
        }
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey,
          jsonEncode({for (final e in _cache.entries) e.key: e.value.toJson()}));
    } catch (_) {}
  }

  // キャッシュを捨てて次回に取り直す（設定の「取り込み直す」用）
  Future<void> clearCache() async {
    _cache.clear();
    _cacheLoaded = true;
    _cacheDirty = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_cacheKey);
    } catch (_) {}
  }

  // 💡 未キャッシュのIDだけ本文を取得して解析し、結果をキャッシュに入れる。
  //   cacheKey は「同じメールを別の役割でも解析する」Amazon用に接頭辞を付けられる。
  Future<void> _fillCache(
    gmail.GmailApi api,
    List<String> ids,
    String prefix,
    GmailCacheEntry Function(gmail.Message full) parse,
  ) async {
    final missing = ids.where((id) => !_cache.containsKey('$prefix$id')).toList();
    if (missing.isEmpty) return;
    for (final full in await _getByIds(api, missing)) {
      final id = full.id;
      if (id == null) continue;
      _cache['$prefix$id'] = parse(full);
      _cacheDirty = true;
    }
  }

  List<ParsedPayment> _cachedPayments(List<String> ids, [String prefix = '']) => [
        for (final id in ids) ...(_cache['$prefix$id']?.payments ?? const [])
      ];

  // ───────── レート制限（403 Quota exceeded 対策） ─────────
  // 💡 Gmail APIは「1分あたり15,000ユニット/ユーザー」。messages.list も get も
  //   1回5ユニットなので 3,000リクエスト/分（=50/秒）が上限。
  //   並列で投げっぱなしにすると軽く超えて同期ごと403で落ちるため、
  //   上限の6割ほど（30回/秒＝9,000ユニット/分）に抑えて流す。
  static const int _maxRequestsPerSecond = 30;
  DateTime _nextSlot = DateTime.fromMillisecondsSinceEpoch(0);

  // 呼び出し順に一定間隔のスロットを予約してから実行する
  Future<T> _throttled<T>(Future<T> Function() op) async {
    const gap = Duration(microseconds: 1000000 ~/ _maxRequestsPerSecond);
    final now = DateTime.now();
    final slot = _nextSlot.isAfter(now) ? _nextSlot : now;
    _nextSlot = slot.add(gap);
    final wait = slot.difference(now);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
    return _withRetry(op);
  }

  // クォータ超過・一時エラーは待ってから再試行（待つ間は後続の発行も止める）
  Future<T> _withRetry<T>(Future<T> Function() op, {int attempts = 5}) async {
    var delay = const Duration(milliseconds: 800);
    for (var i = 0;; i++) {
      try {
        return await op();
      } catch (e) {
        if (i >= attempts - 1 || !_isRateLimit(e)) rethrow;
        // 混み合っているので、以降のリクエストのペースごと落とす。
        // ただし並列ぶんだけ重ねて伸ばすと止まって見えるので、既に先の予約があれば触らない。
        final until = DateTime.now().add(delay);
        if (until.isAfter(_nextSlot)) _nextSlot = until;
        await Future<void>.delayed(delay);
        if (delay < const Duration(seconds: 8)) delay *= 2;
      }
    }
  }

  bool _isRateLimit(Object e) {
    if (e is gmail.DetailedApiRequestError) {
      if (e.status == 429 || e.status == 500 || e.status == 503) return true;
      if (e.status == 403) {
        final m = (e.message ?? '').toLowerCase();
        return m.contains('quota') || m.contains('rate limit');
      }
      return false;
    }
    final s = e.toString().toLowerCase();
    return s.contains('quota exceeded') || s.contains('ratelimitexceeded');
  }

  // 💡 期間内の全メッセージIDをページングで取得（漏れなく拾う）
  Future<List<String>> _listIds(gmail.GmailApi api, String query, {int cap = 3000}) async {
    final ids = <String>[];
    String? token;
    do {
      final resp = await _throttled(() =>
          api.users.messages.list('me', q: query, maxResults: 500, pageToken: token));
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

  //   同時実行数はスロットリング(_throttled)が実質の上限になるよう少し多めにとる。
  Future<List<gmail.Message>> _getByIds(gmail.GmailApi api, List<String> ids,
      {int concurrency = 12}) async {
    final out = <gmail.Message>[];
    final failed = <String>[];

    Future<gmail.Message?> fetch(String id) async {
      try {
        return await _throttled(() => api.users.messages.get('me', id, format: 'full'));
      } catch (_) {
        return null;
      }
    }

    // 1周目: ワーカー方式で常に concurrency 本を走らせる。
    // 💡 以前は chunk ごとに Future.wait していたため、1本の遅延で毎回全員が待たされ、
    //   実効速度がスロットリングの上限まで届かなかった。
    if (ids.isEmpty) return out;
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= ids.length) return;
        final m = await fetch(ids[i]);
        if (m != null) {
          out.add(m);
        } else {
          failed.add(ids[i]);
        }
      }
    }

    final workers = concurrency < ids.length ? concurrency : ids.length;
    await Future.wait(List.generate(workers, (_) => worker()));

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

    // 💡 同じメールが複数の分類に該当しうるので、キャッシュキーは分類ごとに分ける。
    //   未キャッシュのぶんだけ本文を取って「突合の材料」に変換して覚える。
    for (var c = 0; c < idLists.length; c++) {
      await _fillCache(api, idLists[c], 'a$c',
          (full) => GmailCacheEntry(
                epochMs: (_internalDate(full) ?? DateTime.now()).millisecondsSinceEpoch,
                amazon: _parseAmazonMessage(c, full),
              ));
    }

    List<AmazonFact> factsOf(int c) => [
          for (final id in idLists[c])
            if (_cache['a$c$id']?.amazon != null) _cache['a$c$id']!.amazon!
        ];

    // キャンセルされた注文番号
    final cancelled = {
      for (final f in factsOf(0))
        if (f.orderNo.isNotEmpty) f.orderNo
    };

    // 注文メール: 注文番号 → 金額・スニペット
    final orders = <String, AmazonFact>{};
    for (final f in factsOf(1)) {
      if (f.orderNo.isEmpty || f.amount <= 0) continue;
      if (cancelled.contains(f.orderNo)) continue;
      orders[f.orderNo] = f;
    }

    // 発送メール: 注文番号 → 発送日（メール受信日時）。注文と一致したら確定
    // 💡 分割発送で同じ注文番号が複数届くため、注文番号で1件にまとめる
    final out = <ParsedPayment>[];
    final addedOrders = <String>{};
    for (final f in factsOf(2)) {
      if (f.orderNo.isEmpty || cancelled.contains(f.orderNo)) continue; // キャンセル分は除外
      if (!addedOrders.add(f.orderNo)) continue; // 同じ注文は1回だけ
      // 金額は注文メール（ポイント適用後）優先。無ければ発送メールの「合計」で補完。
      final amount = orders[f.orderNo]?.amount ?? (f.amount > 0 ? f.amount : null);
      if (amount == null) continue; // どちらからも金額が取れない場合のみスキップ
      out.add(ParsedPayment(
        cardName: 'Amazonマスター',
        amount: amount,
        date: DateTime.fromMillisecondsSinceEpoch(f.epochMs), // 発送日＝発送メール日時
        snippet: 'Amazon 発送確定 (注文${f.orderNo})',
        // 💡 支払カードが不明なため「情報のみ」。残高は各カードの請求/引落で計上
        kind: MailKind.usage,
        sourceId: 'amazon#${f.orderNo}', // 注文番号で一意（分割発送は1回に集約）
      ));
    }

    // 💡 電子書籍・デジタル注文（発送が無い＝注文時に課金）。金額は「総計」(ポイント適用後)。
    for (final f in factsOf(3)) {
      if (f.orderNo.isEmpty || cancelled.contains(f.orderNo)) continue;
      if (!addedOrders.add(f.orderNo)) continue;
      if (f.amount < 1) continue;
      out.add(ParsedPayment(
        cardName: 'Amazonマスター',
        amount: f.amount,
        date: DateTime.fromMillisecondsSinceEpoch(f.epochMs),
        snippet: 'Amazon(電子) ${f.note}',
        kind: MailKind.usage,
        sourceId: 'amazon#${f.orderNo}',
        note: f.note,
      ));
    }
    return out;
  }

  // 💡 Amazonのメール1通から「突合の材料」を読む。
  //   c: 0=キャンセル / 1=注文確認 / 2=発送 / 3=デジタル
  AmazonFact _parseAmazonMessage(int c, gmail.Message full) {
    final received = (_internalDate(full) ?? DateTime.now()).millisecondsSinceEpoch;
    final raw = '${full.snippet ?? ''}\n${_extractBody(full)}';
    final text = c == 3 ? _normalizeText(raw) : raw;
    final no = _amazonOrderNo.firstMatch(text)?.group(1) ?? '';

    switch (c) {
      case 0: // キャンセル: 注文番号だけ分かればよい
        return AmazonFact(orderNo: no, epochMs: received);
      case 1: // 注文確認: 「合計」を金額とする（取引メールなので誤爆しない）
        return AmazonFact(
          orderNo: no,
          amount: _extractAmount(text, 'Amazonマスター', extraKeywords: const ['合計']) ?? 0,
          epochMs: received,
          snippet: (full.snippet ?? '').trim(),
        );
      case 2: // 発送: 日付が本命。金額は注文メールが無いときの補完用
        return AmazonFact(
          orderNo: no,
          amount: _extractAmount(text, 'Amazonマスター', extraKeywords: const ['合計']) ?? 0,
          epochMs: received,
        );
      default: // デジタル: 「総計」(ポイント適用後) と注文日
        final am = RegExp(r'総計\s*[:：]?\s*[¥￥]?\s*([0-9,]+)').firstMatch(text);
        final dm =
            RegExp(r'注文日\s*[:：]?\s*(\d{4})年(\d{1,2})月(\d{1,2})日').firstMatch(text);
        return AmazonFact(
          orderNo: no,
          amount: am != null ? (int.tryParse(am.group(1)!.replaceAll(',', '')) ?? 0) : 0,
          epochMs: dm != null
              ? DateTime(int.parse(dm.group(1)!), int.parse(dm.group(2)!),
                      int.parse(dm.group(3)!))
                  .millisecondsSinceEpoch
              : received,
          // 商品名（件名「…でのご注文: タイトル」から）
          note: RegExp(r'ご注文\s*[:：]\s*(.+)')
                  .firstMatch(_subject(full))
                  ?.group(1)
                  ?.trim() ??
              '',
        );
    }
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
