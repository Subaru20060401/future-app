// 起動時の「静かな再取得（prompt=none）」を試すかどうかの判定。
// ⚠️ ここを間違えると、リダイレクトの無限ループか、逆に毎回の再連携になる。
import 'package:flutter_test/flutter_test.dart';
import 'package:my_counter_app/gmail_service.dart';

// 既定は「Webで・連携済みで・トークンが切れていて・まだ試していない」状態。
bool decide({
  bool isWeb = true,
  bool canRedirect = true,
  bool signedInOnce = true,
  bool hasValidToken = false,
  bool alreadyTried = false,
}) =>
    shouldTrySilentAuth(
      isWeb: isWeb,
      canRedirect: canRedirect,
      signedInOnce: signedInOnce,
      hasValidToken: hasValidToken,
      alreadyTried: alreadyTried,
    );

void main() {
  group('静かな再取得を試すか', () {
    test('連携済みでトークンが切れていたら試す（毎回押させないため）', () {
      expect(decide(), isTrue);
    });

    test('まだ使えるトークンがあるなら飛ばない（無駄なページ移動をしない）', () {
      expect(decide(hasValidToken: true), isFalse);
    });

    test('このタブで試し済みなら繰り返さない（リダイレクトのループ防止）', () {
      expect(decide(alreadyTried: true), isFalse);
    });

    test('一度も連携していないなら飛ばない（本人に押してもらう）', () {
      expect(decide(signedInOnce: false), isFalse);
    });

    test('端末アプリでは使わない（リフレッシュトークンが効くため）', () {
      expect(decide(isWeb: false), isFalse);
    });

    test('リダイレクト方式が使えない環境では飛ばない', () {
      expect(decide(canRedirect: false), isFalse);
    });
  });
}
