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
