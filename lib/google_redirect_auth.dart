// プラットフォームごとの実装を切り替える。
export 'google_redirect_auth_stub.dart'
    if (dart.library.js_interop) 'google_redirect_auth_web.dart';
