// Googleドライブ同期の「どちらが新しいか」判定のテスト。
// 誤ると片方の変更が黙って消えるので、境界を細かく固める。
import 'package:flutter_test/flutter_test.dart';
import 'package:my_counter_app/drive_sync.dart';

void main() {
  final t0 = DateTime(2026, 9, 6, 10, 0);
  final t1 = DateTime(2026, 9, 6, 11, 0);
  final t2 = DateTime(2026, 9, 6, 12, 0);

  DriveSyncState decide({
    required DateTime remote,
    DateTime? known,
    DateTime? local,
    DateTime? synced,
  }) =>
      decideSyncState(
        remoteUpdatedAt: remote,
        knownRemoteAt: known,
        dataUpdatedAt: local,
        syncedAt: synced,
      );

  group('decideSyncState', () {
    test('どちらも変わっていなければ最新のまま', () {
      expect(
        decide(remote: t0, known: t0, local: t0, synced: t0),
        DriveSyncState.upToDate,
      );
    });

    test('この端末だけ変わったらアップロード', () {
      expect(
        decide(remote: t0, known: t0, local: t1, synced: t0),
        DriveSyncState.localNewer,
      );
    });

    test('別の端末だけ変わったら取り込み', () {
      expect(
        decide(remote: t1, known: t0, local: t0, synced: t0),
        DriveSyncState.remoteNewer,
      );
    });

    test('両方変わっていたら競合（勝手に消さない）', () {
      expect(
        decide(remote: t1, known: t0, local: t2, synced: t0),
        DriveSyncState.conflict,
      );
    });

    test('この端末が新しくても、向こうも変わっていれば競合', () {
      // 「新しい方を採用」だと古い方の変更が消えるので、時刻の大小では決めない
      expect(
        decide(remote: t1, known: t0, local: t2, synced: t0),
        DriveSyncState.conflict,
      );
      expect(
        decide(remote: t2, known: t0, local: t1, synced: t0),
        DriveSyncState.conflict,
      );
    });

    test('初回（ドライブを見たことがない）で変更なしなら取り込み', () {
      expect(
        decide(remote: t0, known: null, local: null, synced: null),
        DriveSyncState.remoteNewer,
      );
    });

    test('初回で、この端末にもデータがあれば競合', () {
      expect(
        decide(remote: t0, known: null, local: t1, synced: null),
        DriveSyncState.conflict,
      );
    });

    test('同期直後に同じ時刻が来ても変更扱いにしない（境界）', () {
      // isAfter なので「ちょうど同じ時刻」は変更なし
      expect(
        decide(remote: t1, known: t1, local: t1, synced: t1),
        DriveSyncState.upToDate,
      );
    });

    test('取り込み後は、向こうの更新時刻を覚えていれば再取り込みしない', () {
      // pullNow 相当: known=向こうの時刻, synced=いまの時刻, local=取り込み前のまま
      expect(
        decide(remote: t1, known: t1, local: t0, synced: t2),
        DriveSyncState.upToDate,
      );
    });
  });
}
