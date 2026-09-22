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
//   「試した」を常に true にして、この経路に入らないようにする。
bool get silentAuthTried => true;
void markSilentAuthTried() {}
void clearSilentAuthTried() {}
