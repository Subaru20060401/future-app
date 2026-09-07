// 非Web（iOS/Androidアプリ）ではネイティブのログインを使うので何もしない。
bool get canUseRedirectAuth => false;
String? get redirectUri => null;
String? get webClientId => null;
void startGoogleRedirect(String clientId, String redirectUri, List<String> scopes) {}
({String token, DateTime expiry})? consumeRedirectResult() => null;
