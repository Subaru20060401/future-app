// 非Web（iOS/Androidアプリ）ではネイティブのログインを使うので何もしない。
bool get canUseRedirectAuth => false;
bool get isPopupUnfriendly => false;
String? get redirectUri => null;
String? get webClientId => null;
void startGoogleRedirect(String clientId, String redirectUri, List<String> scopes,
    {bool silent = false, String? loginHint}) {}
({String token, DateTime expiry})? consumeRedirectResult() => null;
String? consumeRedirectError() => null;
// 💡 端末アプリはリフレッシュトークンが効くので、静かな再取得はそもそも不要。
//   canUseRedirectAuth が false なので、この値は参照されない。
int? get silentAuthTriedAtMs => null;
void markSilentAuthTried() {}
void clearSilentAuthTried() {}
