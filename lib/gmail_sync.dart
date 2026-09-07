import 'app_state.dart';
import 'gmail_service.dart';

// 取得結果
class GmailSyncResult {
  final int added;
  final int removed;
  final int fetched;
  final String? error;
  final bool notSignedIn;
  final int missed; // 取得できなかったメール数（>0なら反映を中止している）
  // 💡 Web用。サインイン済みだがGmail読み取りの許可が無い（403の原因）。
  final bool needsPermission;

  GmailSyncResult({
    this.added = 0,
    this.removed = 0,
    this.fetched = 0,
    this.error,
    this.notSignedIn = false,
    this.missed = 0,
    this.needsPermission = false,
  });

  // 取りこぼしがあり、データを守るため反映を見送ったか
  bool get skipped => missed > 0;

  String get message {
    if (notSignedIn) return 'Gmail未連携です（設定から連携してください）';
    if (needsPermission) {
      return 'Gmailの読み取りが許可されていません。設定→Gmail連携で'
          '「Gmailのアクセスを許可」を押してください';
    }
    if (error != null) return '取得失敗: $error';
    if (skipped) {
      return 'メールを$missed件取得できなかったため、今回は反映を見送りました（電波の良い場所でもう一度お試しください）';
    }
    return '$added件追加 / $removed件削除';
  }
}

MailKind _kindOf(ParsedPayment p) => p.kind;

PaymentSource _toSource(MailKind kind) {
  switch (kind) {
    case MailKind.bank:
      return PaymentSource.bank;
    case MailKind.billing:
      return PaymentSource.billing;
    case MailKind.usage:
      return PaymentSource.usage;
  }
}

// 💡 どの画面からでも呼べる共通のGmail取得＆照合処理。
//   未連携なら silent サインインを試み、それでもダメなら notSignedIn を返す。
//   通常は「先月＋今月」だけ取得する（数秒で終わる）。
//   過去分がほしいときだけ 設定→「過去2年分をすべて取り込み直す」= full:true。
//   ⚠️ 初回だけ自動で2年分…にすると数千通ぶんのリクエストで
//      クォータ超過(403)＆数分待ちになるため、自動フル取得はしない。
// 💡 起動時の自動同期とユーザーの更新ボタンが重なると、同じ取得を2回走らせて
//   スロットリングの順番待ちが倍になる（＝くるくるが倍長くなる）。実行中は相乗りさせる。
Future<GmailSyncResult>? _inFlight;

Future<GmailSyncResult> syncGmail(AppState appState, {bool full = false}) {
  final running = _inFlight;
  if (running != null) return running;
  final f = _syncGmail(appState, full: full);
  _inFlight = f;
  f.whenComplete(() {
    if (identical(_inFlight, f)) _inFlight = null;
  });
  return f;
}

Future<GmailSyncResult> _syncGmail(AppState appState, {bool full = false}) async {
  final gmail = GmailService.instance;
  if (!gmail.isSignedIn) {
    final ok = await gmail.signInSilently();
    if (!ok) return GmailSyncResult(notSignedIn: true);
  }
  // 💡 許可が無いまま取得すると403になるので、先に確認して案内を返す。
  //   （許可要求はポップアップを開くのでボタン操作からしか呼べない）
  if (!await gmail.isUsable) {
    return GmailSyncResult(needsPermission: true);
  }
  final now = DateTime.now();
  // 通常更新は先月1日から（＝直近1〜2ヶ月）。full のときだけ全期間。
  final since = full ? null : DateTime(now.year, now.month - 1, 1);
  try {
    final list = await gmail.fetchCardPayments(since: since);
    // 💡 取りこぼしがあるまま反映すると、その明細が消えて残高がブレる。
    //   （reconcile は取得結果を正本として自動明細を作り直すため）
    //   1件でも取れなかったら今回は反映しない＝データを壊さない。
    if (gmail.lastFetchFailures > 0) {
      return GmailSyncResult(
          fetched: list.length, missed: gmail.lastFetchFailures);
    }
    final r = appState.reconcilePayments(
      list.map((p) => (
            cardName: p.cardName,
            amount: p.amount,
            date: p.date,
            source: _toSource(_kindOf(p)),
            sourceId: p.sourceId,
            note: p.note,
          )),
      since: since,
    );
    // 💡 「振込入金のお知らせ」も取得。金額はメールに無いので、
    //   起動時にポップアップで入力してもらうためキューに積む。
    try {
      appState.addDepositNotices(await gmail.fetchDepositNotices(since: since));
    } catch (_) {
      // 入金通知の取得に失敗しても、カードの取り込み結果は返す
    }
    appState.markGmailSynced();
    return GmailSyncResult(added: r.added, removed: r.removed, fetched: list.length);
  } catch (e) {
    return GmailSyncResult(error: e.toString());
  }
}
