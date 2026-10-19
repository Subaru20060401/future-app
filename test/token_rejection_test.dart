// Googleがトークンを拒否したとき（401 / invalid_token）の復帰のテスト
// （認証・AI・シフト計画 2026-10-19 の P0）。
// ⚠️ 以前は保存トークンを「期限内か」だけで判断していたので、Googleに拒否された
//   トークンを期限まで使い続け、同期が毎回「Access was denied」で失敗していた。
import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/gmail/v1.dart' show DetailedApiRequestError;
import 'package:googleapis_auth/googleapis_auth.dart' show AccessDeniedException;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/gmail_service.dart';
import 'package:my_counter_app/gmail_sync.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('トークン拒否の見分け', () {
    test('401・invalid_token・Access was denied は拒否', () {
      expect(isRejectedTokenError(AccessDeniedException('Access was denied')), isTrue);
      expect(isRejectedTokenError(DetailedApiRequestError(401, 'Unauthorized')), isTrue);
      expect(
        isRejectedTokenError(Exception(
            'Access was denied (www-authenticate header was: Bearer error="invalid_token")')),
        isTrue,
      );
    });

    test('403（クォータ・スコープ・API無効）と通信失敗は拒否ではない', () {
      expect(isRejectedTokenError(DetailedApiRequestError(403, 'Quota exceeded')), isFalse);
      expect(
          isRejectedTokenError(DetailedApiRequestError(403, 'Insufficient Permission')),
          isFalse);
      expect(
          isRejectedTokenError(Exception('Gmail API has not been used in project 1')),
          isFalse);
      expect(isRejectedTokenError(Exception('ClientException: Failed to fetch')), isFalse);
    });

    test('取り直し待ちの例外は拒否として拾い直さない（ループ防止）', () {
      expect(
          isRejectedTokenError(const GoogleAuthRejected(GoogleAccessState.redirecting)),
          isFalse);
      expect(
          isRejectedTokenError(
              const GoogleAuthRejected(GoogleAccessState.needsInteraction)),
          isFalse);
    });
  });

  group('拒否されたら捨てて取り直し、1回だけやり直す', () {
    test('拒否 → 捨てる → 取り直し → やり直しで成功', () async {
      final log = <String>[];
      var calls = 0;
      final r = await withTokenRecovery<String>(
        run: () async {
          calls++;
          log.add('run');
          if (calls == 1) throw AccessDeniedException('invalid_token');
          return 'ok';
        },
        invalidate: () async => log.add('invalidate'),
        recover: () async {
          log.add('recover');
          return GoogleAccessState.ready;
        },
        onUnrecovered: (_) => 'ng',
      );
      expect(r, 'ok');
      expect(log, ['run', 'invalidate', 'recover', 'run']);
    });

    test('やり直しも拒否されたら投げる（何度もやり直さない）', () async {
      var calls = 0;
      var invalidated = 0;
      await expectLater(
        withTokenRecovery<String>(
          run: () async {
            calls++;
            throw DetailedApiRequestError(401, 'invalid_token');
          },
          invalidate: () async => invalidated++,
          recover: () async => GoogleAccessState.ready,
          onUnrecovered: (_) => 'ng',
        ),
        throwsA(isA<DetailedApiRequestError>()),
      );
      expect(calls, 2);
      expect(invalidated, 1);
    });

    test('ページ移動になったら、やり直さずに状態を返す', () async {
      var calls = 0;
      final r = await withTokenRecovery<GoogleAccessState?>(
        run: () async {
          calls++;
          throw AccessDeniedException('Access was denied');
        },
        invalidate: () async {},
        recover: () async => GoogleAccessState.redirecting,
        onUnrecovered: (s) => s,
      );
      expect(r, GoogleAccessState.redirecting);
      expect(calls, 1);
    });

    test('拒否以外のエラー（403など）は捨てずにそのまま投げる', () async {
      var invalidated = 0;
      await expectLater(
        withTokenRecovery<String>(
          run: () async => throw DetailedApiRequestError(403, 'Quota exceeded'),
          invalidate: () async => invalidated++,
          recover: () async => GoogleAccessState.ready,
          onUnrecovered: (_) => 'ng',
        ),
        throwsA(isA<DetailedApiRequestError>()),
      );
      expect(invalidated, 0);
    });
  });

  test('拒否されたトークンは、期限内で保存し直されても使わない', () async {
    final expiry = DateTime.now().toUtc().add(const Duration(minutes: 50));
    final saved = {
      'saved_google_access_token': 'dummy-token-1',
      'saved_google_token_expiry': expiry.toIso8601String(),
    };
    SharedPreferences.setMockInitialValues(saved);
    final g = GmailService.instance;
    expect(await g.isUsable, isTrue);

    await g.invalidateRejectedToken();
    expect(await g.isUsable, isFalse);

    // ⚠️ プラグインなどが同じトークンを再び保存しても「使える」と判断しない
    final prefs = await SharedPreferences.getInstance();
    for (final e in saved.entries) {
      await prefs.setString(e.key, e.value);
    }
    expect(await g.isUsable, isFalse);

    // 新しいトークンなら使える
    await prefs.setString('saved_google_access_token', 'dummy-token-2');
    expect(await g.isUsable, isTrue);
  });

  test('同時に401を受けても、先に取り直した新しいトークンは捨てない', () async {
    final expiry = DateTime.now().toUtc().add(const Duration(minutes: 50));
    SharedPreferences.setMockInitialValues({
      'saved_google_access_token': 'dummy-token-new',
      'saved_google_token_expiry': expiry.toIso8601String(),
    });
    final g = GmailService.instance;
    // 古いトークンで失敗した側が、後から捨てに来た
    await g.invalidateRejectedToken(used: 'dummy-token-old');
    expect(await g.isUsable, isTrue);
  });

  test('連携の更新が必要なときは短い案内を出す', () {
    final r = GmailSyncResult(needsPermission: true);
    expect(r.shortMessage, 'Googleとの連携を更新してください');
    expect(r.ok, isFalse);
  });
}
