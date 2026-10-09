import 'package:flutter_test/flutter_test.dart';
import 'package:my_counter_app/google_auth_recovery.dart';
import 'package:my_counter_app/gmail_sync.dart';
import 'package:my_counter_app/drive_sync.dart';

void main() {
  test('有効な保存トークンでは再認証しない', () async {
    final state = await recoverGoogleAccess(
      isUsable: () async => true,
      restorePlugin: () async => throw StateError('不要なプラグイン認証'),
      restoreRedirect: () async => throw StateError('不要な画面移動'),
      preferRedirect: true,
    );
    expect(state, GoogleAccessState.ready);
  });

  test('スマホの期限切れはPC用のプラグインを使わず復帰する', () async {
    var redirects = 0;
    final state = await recoverGoogleAccess(
      isUsable: () async => false,
      restorePlugin: () async => throw StateError('スマホでプラグイン認証'),
      restoreRedirect: () async {
        redirects++;
        return true;
      },
      preferRedirect: true,
    );
    expect(state, GoogleAccessState.redirecting);
    expect(redirects, 1);
  });

  test('PCはプラグインの復帰で使えるなら画面移動しない', () async {
    var usable = false;
    final state = await recoverGoogleAccess(
      isUsable: () async => usable,
      restorePlugin: () async {
        usable = true;
        return true;
      },
      restoreRedirect: () async => throw StateError('不要な画面移動'),
      preferRedirect: false,
    );
    expect(state, GoogleAccessState.ready);
  });

  test('PCのプラグインで復帰できない場合はリダイレクトへ進む', () async {
    final state = await recoverGoogleAccess(
      isUsable: () async => false,
      restorePlugin: () async => false,
      restoreRedirect: () async => true,
      preferRedirect: false,
    );
    expect(state, GoogleAccessState.redirecting);
  });

  test('自動復帰が断られたら手動連携が必要とする', () async {
    final state = await recoverGoogleAccess(
      isUsable: () async => false,
      restorePlugin: () async => false,
      restoreRedirect: () async => false,
      preferRedirect: true,
    );
    expect(state, GoogleAccessState.needsInteraction);
  });

  test('画面移動中はGmailとDriveで未連携や期限切れの警告を出さない', () {
    final gmail = GmailSyncResult(restoringAuth: true);
    const drive = DriveSyncResult(DriveSyncState.restoringAuth);
    expect(gmail.needsPermission, false);
    expect(gmail.message, 'Google連携を復帰しています…');
    expect(drive.message, gmail.message);
  });
}
