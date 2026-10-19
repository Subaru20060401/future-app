import 'package:flutter/foundation.dart' show ValueNotifier;

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
  final bool restoringAuth;

  GmailSyncResult({
    this.added = 0,
    this.removed = 0,
    this.fetched = 0,
    this.error,
    this.notSignedIn = false,
    this.missed = 0,
    this.needsPermission = false,
    this.restoringAuth = false,
  });

  // 取りこぼしがあり、データを守るため反映を見送ったか
  bool get skipped => missed > 0;

  // 問題なく最後まで確認できたか
  bool get ok =>
      error == null && !notSignedIn && !needsPermission && !restoringAuth && !skipped;

  // 💡 画面に常に出しておく短い一言（詳細は detailLines で開いて見る）
  String get shortMessage {
    if (ok) return 'メールを確認しました';
    if (restoringAuth) return 'Google連携を復帰しています…';
    if (notSignedIn) return 'Googleに連携されていません';
    if (needsPermission) return 'Googleとの連携を更新してください';
    if (skipped) return '一部のメールが取れず、反映を見送りました';
    return 'メールを確認できませんでした';
  }

  // 💡 詳細で見せる内訳。
  //   ⚠️ removed は「メールの取り込み直しで入れ替わって外れた自動明細」の数で、
  //     自分で削除した明細の数ではない。混同しないよう言葉を分ける。
  List<String> get detailLines => [
        if (ok) ...[
          '確認したメール: $fetched件',
          '新しく入った明細: $added件',
          '取り込み直しで外れた明細: $removed件（自分で削除したものは含みません）',
        ] else
          message,
      ];

  String get message {
    if (restoringAuth) return 'Google連携を復帰しています…';
    if (notSignedIn) return 'Googleに連携されていません（設定→Google連携）';
    if (needsPermission) {
      return 'Googleの有効期限が切れています。設定→Google連携で「連携し直す」を押してください';
    }
    if (error != null) return '取得失敗: $error';
    if (skipped) {
      return 'メールを$missed件取得できなかったため、今回は反映を見送りました（電波の良い場所でもう一度お試しください）';
    }
    return '$added件追加 / $removed件削除';
  }
}

// 💡 最後に確認した結果（起動時の自動更新と更新ボタンの両方で記録する）。
//   画面は大きな通知で覆わず、ホームの上に一言で出す。保存はしない（開いている間だけ）。
final ValueNotifier<({DateTime at, GmailSyncResult result})?> lastGmailSync =
    ValueNotifier(null);

// 💡 最後に成功した時刻。失敗が出ていても「いつまでのデータか」が分かるようにする。
DateTime? lastGmailSuccessAt;

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
  final f = _syncGmail(appState, full: full).then((r) {
    // 連携の復帰中（ページ移動中）は結果ではないので残さない
    final at = DateTime.now();
    if (r.ok) lastGmailSuccessAt = at;
    if (!r.restoringAuth) lastGmailSync.value = (at: at, result: r);
    return r;
  });
  _inFlight = f;
  f.whenComplete(() {
    if (identical(_inFlight, f)) _inFlight = null;
  });
  return f;
}

Future<GmailSyncResult> _syncGmail(
  AppState appState, {
  bool full = false,
}) async {
  final gmail = GmailService.instance;
  // ⚠️ ここで isSignedIn（GoogleのJSライブラリのログイン状態）を見てはいけない。
  //   リダイレクト認証ではそれが成立しないため、保存したトークンがあっても
  //   必ず「未連携」で止まってしまう。
  //   実際にAPIを叩けるか（isUsable）で判定する。
  final access = await gmail.ensureAccess();
  if (access == GoogleAccessState.redirecting) {
    return GmailSyncResult(restoringAuth: true);
  }
  if (access == GoogleAccessState.needsInteraction) {
    return GmailSyncResult(needsPermission: true);
  }
  final now = DateTime.now();
  // 通常更新は先月1日から（＝直近1〜2ヶ月）。full のときだけ全期間。
  final since = full ? null : DateTime(now.year, now.month - 1, 1);
  try {
    // 💡 Googleがトークンを拒否（401）したら、捨てて取り直して1回だけやり直す
    final list = await gmail.withFreshToken(
      () => gmail.fetchCardPayments(since: since),
    );
    // 💡 取りこぼしがあるまま反映すると、その明細が消えて残高がブレる。
    //   （reconcile は取得結果を正本として自動明細を作り直すため）
    //   1件でも取れなかったら今回は反映しない＝データを壊さない。
    if (gmail.lastFetchFailures > 0) {
      return GmailSyncResult(
        fetched: list.length,
        missed: gmail.lastFetchFailures,
      );
    }
    final r = appState.reconcilePayments(
      list.map(
        (p) => (
          cardName: p.cardName,
          amount: p.amount,
          date: p.date,
          source: _toSource(_kindOf(p)),
          sourceId: p.sourceId,
          note: p.note,
        ),
      ),
      since: since,
    );
    // 💡 「振込入金のお知らせ」も取得。金額はメールに無いので、
    //   起動時にポップアップで入力してもらうためキューに積む。
    try {
      appState.addDepositNotices(await gmail.fetchDepositNotices(since: since));
    } catch (_) {
      // 入金通知の取得に失敗しても、カードの取り込み結果は返す
    }
    // 💡 PayPay残高から銀行への出金（金額と振込予定日が分かる＝予想に入れられる）。
    //   足すだけなので、取りこぼしても既にあるものは消えない。
    try {
      final transfers = await gmail.fetchPayPayTransfers(since: since);
      appState.addPayPayTransfers(transfers.map((t) => PayPayTransfer(
            id: t.id,
            amount: t.amount,
            acceptedAt: t.acceptedAt,
            scheduledDate: t.scheduledDate,
            bank: t.bank,
          )));
    } catch (_) {
      // 出金メールの取得に失敗しても、カードの取り込み結果は返す
    }
    appState.markGmailSynced();
    return GmailSyncResult(
      added: r.added,
      removed: r.removed,
      fetched: list.length,
    );
  } on GoogleAuthRejected catch (e) {
    // 取り直しがページ移動になった＝失敗ではない。本人の操作が要るなら連携し直しを案内。
    if (e.state == GoogleAccessState.redirecting) {
      return GmailSyncResult(restoringAuth: true);
    }
    return GmailSyncResult(needsPermission: true);
  } catch (e) {
    // ⚠️ 取り直したトークンまで拒否された。次の起動で同じトークンを使わないよう捨て、
    //   ここで止める（自動で何度もやり直さない）。保存済みの明細には触れない。
    if (isRejectedTokenError(e)) {
      await gmail.invalidateRejectedToken();
      return GmailSyncResult(needsPermission: true);
    }
    return GmailSyncResult(error: e.toString());
  }
}
