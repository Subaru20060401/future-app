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

  // 💡 「1回きり」だと、開いたままの端末（iOSのホーム画面アプリは戻っても
  //   ページを読み込み直さない）で二度と取り直せなくなる。時間で空けて繰り返す。
  group('取り直しの間隔', () {
    final now = DateTime(2026, 9, 28, 12, 0);
    int msAgo(Duration d) => now.subtract(d).millisecondsSinceEpoch;

    test('まだ一度も試していなければ、すぐ試せる', () {
      expect(silentAuthOnCooldown(null, now), isFalse);
    });

    test('さっき試したばかりなら繰り返さない（ループ防止）', () {
      expect(silentAuthOnCooldown(msAgo(const Duration(minutes: 1)), now), isTrue);
      expect(silentAuthOnCooldown(msAgo(const Duration(minutes: 9)), now), isTrue);
    });

    test('時間が空いたらまた試す（数時間後に戻ってきた場合）', () {
      expect(silentAuthOnCooldown(msAgo(const Duration(minutes: 11)), now), isFalse);
      expect(silentAuthOnCooldown(msAgo(const Duration(hours: 5)), now), isFalse);
    });

    test('時計が巻き戻っても飛び続けない', () {
      expect(silentAuthOnCooldown(now.add(const Duration(hours: 1)).millisecondsSinceEpoch, now),
          isTrue);
    });
  });
}
