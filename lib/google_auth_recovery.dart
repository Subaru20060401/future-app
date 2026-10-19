import 'package:googleapis/gmail/v1.dart' show DetailedApiRequestError;
import 'package:googleapis_auth/googleapis_auth.dart' show AccessDeniedException;

// 💡 API利用前の復帰を共通化する。ページ移動中は未連携として表示しない。
enum GoogleAccessState { ready, redirecting, needsInteraction }

Future<GoogleAccessState> recoverGoogleAccess({
  required Future<bool> Function() isUsable,
  required Future<bool> Function() restorePlugin,
  required Future<bool> Function() restoreRedirect,
  required bool preferRedirect,
}) async {
  if (await isUsable()) return GoogleAccessState.ready;
  if (preferRedirect) {
    if (await restoreRedirect()) return GoogleAccessState.redirecting;
  } else {
    await restorePlugin();
    if (await isUsable()) return GoogleAccessState.ready;
    if (await restoreRedirect()) return GoogleAccessState.redirecting;
  }
  return GoogleAccessState.needsInteraction;
}

// 💡 Googleがアクセストークンそのものを拒否したか（401 / invalid_token）。
//   期限内でも起きる（連携の取り消し・パスワード変更・別の場所での再ログインなど）。
// ⚠️ 403（スコープ不足・API無効・クォータ超過）と通信失敗は含めない。
//   それらはトークンを捨てても直らないので、別の案内をする。
bool isRejectedTokenError(Object e) {
  if (e is AccessDeniedException) return true;
  if (e is DetailedApiRequestError) return e.status == 401;
  final t = e.toString().toLowerCase();
  if (t.contains('invalid_token')) return true;
  if (t.contains('access was denied')) return true;
  if (RegExp(r'\b401\b').hasMatch(t) || t.contains('unauthorized')) return true;
  return false;
}

// 💡 トークンが拒否されたら、捨てて取り直し、1回だけやり直す。
//   ⚠️ 以前は「保存したトークンが期限内か」だけで使えると判断していたので、
//     Googleに拒否されたトークンを期限が切れるまで使い続け、毎回失敗していた。
//   ・拒否以外のエラーはそのまま投げる（ここでは扱わない）
//   ・やり直しは1回だけ（2回目も拒否されたら、そのまま投げる＝ループしない）
//   ・取り直しがページ移動になった／本人の操作が要るときは onUnrecovered に任せる
Future<R> withTokenRecovery<R>({
  required Future<R> Function() run,
  required Future<void> Function() invalidate,
  required Future<GoogleAccessState> Function() recover,
  required R Function(GoogleAccessState state) onUnrecovered,
}) async {
  try {
    return await run();
  } catch (e) {
    if (!isRejectedTokenError(e)) rethrow;
    await invalidate();
    final state = await recover();
    if (state != GoogleAccessState.ready) return onUnrecovered(state);
    return await run();
  }
}

// 💡 トークンを取り直そうとしたが、すぐには使えなかった（ページ移動中／本人の操作待ち）。
//   ⚠️ toString に 401 などを含めない（isRejectedTokenError に再び拾われてループしないため）。
class GoogleAuthRejected implements Exception {
  final GoogleAccessState state;
  const GoogleAuthRejected(this.state);
  @override
  String toString() => state == GoogleAccessState.redirecting
      ? 'Google連携を復帰しています'
      : 'Googleとの連携を更新してください';
}
