// 💡 iOS（WebKit）向けのGoogleログイン。
//   GoogleのJSライブラリ(GIS)はポップアップとFedCMに依存していて、
//   iOSのChrome/Safariでは弾かれることがある（Macでは通るのに繋がらない原因）。
//   そこで、ポップアップを使わずページ自体を移動させる方式に切り替える。
//   戻ってきたURLの # にアクセストークンが入っているので、それを取り出して使う。
import 'package:web/web.dart' as web;

bool get canUseRedirectAuth => true;

// 💡 iOSはポップアップとFedCMが塞がれるため、GoogleのJSライブラリでは連携できない。
//   その場合は最初からページ移動方式にする（無駄なポップアップを出さない）。
//   iPadOSはUAがMacintoshになるので、タッチ対応かどうかも見る。
bool get isPopupUnfriendly {
  final ua = web.window.navigator.userAgent;
  if (ua.contains('iPhone') || ua.contains('iPad') || ua.contains('iPod')) {
    return true;
  }
  return ua.contains('Macintosh') && web.window.navigator.maxTouchPoints > 1;
}

// index.html の meta タグに入れてあるクライアントIDを読む（二重管理しない）
String? get webClientId {
  final meta = web.document.querySelector('meta[name="google-signin-client_id"]');
  final id = (meta as web.HTMLMetaElement?)?.content;
  return (id == null || id.isEmpty) ? null : id;
}

// Googleに登録する「承認済みのリダイレクトURI」と完全に一致させる必要がある
String? get redirectUri {
  final loc = web.window.location;
  return '${loc.origin}${loc.pathname}';
}

void startGoogleRedirect(String clientId, String redirect, List<String> scopes) {
  final url = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
    'client_id': clientId,
    'redirect_uri': redirect,
    'response_type': 'token', // ブラウザだけで完結する方式
    'scope': scopes.join(' '),
    'include_granted_scopes': 'true',
    // prompt は付けない。許可済みなら確認画面を挟まずすぐ戻ってくる。
  });
  web.window.location.href = url.toString();
}

// 戻ってきたURLの # からトークンを取り出し、URLからは消す（履歴に残さない）
({String token, DateTime expiry})? consumeRedirectResult() {
  final hash = web.window.location.hash;
  if (!hash.contains('access_token=')) return null;
  final params = Uri.splitQueryString(hash.startsWith('#') ? hash.substring(1) : hash);
  final token = params['access_token'];
  if (token == null || token.isEmpty) return null;
  final seconds = int.tryParse(params['expires_in'] ?? '') ?? 3600;
  final expiry = DateTime.now().toUtc().add(Duration(seconds: seconds));

  // アドレスバーからトークンを消す
  final loc = web.window.location;
  web.window.history.replaceState(
      null, '', '${loc.origin}${loc.pathname}${loc.search}');
  return (token: token, expiry: expiry);
}
