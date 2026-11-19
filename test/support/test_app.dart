// 💡 テスト用の AppState を作る共通の入口。
//   ・「今日」を固定する（実行した日で結果が変わらないように）
//   ・保存データの読み込みが終わってから中身を入れる
//     （⚠️ 読み込みより先に項目を書くと、読み込みの続きで上書きされる）
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/app_state.dart';

/// 時刻を固定した空の AppState。[prefs] を渡すとその保存データから読み込む。
Future<AppState> fixedApp(DateTime now, {Map<String, Object>? prefs}) async {
  SharedPreferences.setMockInitialValues(prefs ?? {});
  final app = AppState(clock: () => now);
  await app.ready;
  // 💡 初回起動の種（既定のカード）を外し、テストに出てくるカードだけにする
  if (prefs == null) app.cardPaymentDays.clear();
  return app;
}

/// 同じ保存データ（モック）から、新しい AppState を作り直す（再起動の再現）。
Future<AppState> reloadApp(DateTime now) async {
  final app = AppState(clock: () => now);
  await app.ready;
  return app;
}

/// 保存の非同期処理が終わるのを待つ（saveData は呼び出し側で待たれていないため）。
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

Payment usage(String card, int amount, DateTime date, {String note = '', String? id}) =>
    Payment(
      id: id ?? 'u-$card-${date.toIso8601String()}-$amount',
      cardName: card,
      amount: amount,
      paymentDate: date,
      source: PaymentSource.usage,
      sourceId: id ?? 'mail-$card-${date.toIso8601String()}-$amount',
      note: note,
    );

Payment bank(String card, int amount, DateTime date) => Payment(
      id: 'b-$card-${date.toIso8601String()}',
      cardName: card,
      amount: amount,
      paymentDate: date,
      source: PaymentSource.bank,
      sourceId: 'bank-$card-${date.toIso8601String()}',
    );

/// 時給 [wage] で [start]〜[end] 働いたシフト（休憩なし・交通費なし）
ShiftData shiftAt(Workplace w, DateTime start, DateTime end, {int wage = 1000}) =>
    ShiftData(
      workplace: w.name,
      workplaceId: w.id,
      hourlyWage: wage,
      start: start,
      end: end,
    );

void addShift(AppState app, ShiftData s) {
  final key = dateKey(s.start);
  (app.shifts[key] ??= []).add(s);
}

/// 時計を関数で渡す版（テストの途中で時刻を進めたいとき）
Future<AppState> clockApp(DateTime Function() clock, {Map<String, Object>? prefs}) async {
  SharedPreferences.setMockInitialValues(prefs ?? {});
  final app = AppState(clock: clock);
  await app.ready;
  if (prefs == null) app.cardPaymentDays.clear();
  return app;
}

/// 書き出しの比較用（書き出した時刻の行だけ除く）
String exportWithoutStamp(AppState app) =>
    app.exportJson().replaceAll(RegExp(r'"exportedAt": "[^"]*",?\n'), '');
