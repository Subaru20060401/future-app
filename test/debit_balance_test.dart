// デビット（即時引き落とし）と残高の関係のテスト。
// 💡 デビットは残高そのものを書き換えず、基準日(balanceUpdatedAt)より後のぶんを
//   表示・予想のときに差し引く方式。
// ⚠️ 入金や引き落としを反映すると基準日が進む。進む前に残高へ畳み込まないと、
//   それ以前のデビットが「反映済み」扱いになって消え、残高が増えて見える。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // 残高を入力した後にGmailから入ってきたデビット（＝まだ残高に入っていないぶん）
  Payment debit(int amount) => Payment(
        id: 'd$amount',
        cardName: '三井OLIVE（デビット）',
        amount: amount,
        paymentDate: DateTime.now().subtract(const Duration(hours: 1)),
        source: PaymentSource.usage,
      );

  AppState withDebit() {
    final app = AppState();
    app.updateBalance(100000); // ここが基準日になる
    app.payments.add(debit(3000));
    return app;
  }

  group('デビットは使った時点で引く', () {
    test('残高の表示はデビットを引いた額になる', () {
      final app = withDebit();
      expect(app.currentBalance, 100000); // 入力した値そのもの
      expect(app.debitsAfterSnapshot(), 3000);
      expect(app.effectiveBalance, 97000); // 画面に出るのはこちら
    });

    test('入金を反映してもデビットぶんは消えない', () {
      final app = withDebit();
      app.addDeposit(80000);
      // 10万 − デビット3000 ＋ 入金8万 ＝ 177000
      expect(app.currentBalance, 177000);
      expect(app.effectiveBalance, 177000); // 畳み込み済みなので二重には引かない
    });

    test('引き落としを反映してもデビットぶんは消えない', () {
      final app = withDebit();
      app.subtractFromBalance(20000, label: '家賃');
      expect(app.currentBalance, 77000); // 10万 −3000 −2万
      expect(app.effectiveBalance, 77000);
    });

    test('履歴に残る「反映後の残高」もデビットを引いた額になる', () {
      final app = withDebit();
      app.addDeposit(80000);
      final entry = app.balanceHistory.first;
      expect(entry.balanceAfter, 177000);
    });

    test('残高を手で書き直したときは畳み込まない（通帳の値は既に引かれている）', () {
      final app = withDebit();
      app.updateBalance(97000); // 通帳を見て入力し直した
      expect(app.currentBalance, 97000);
      // 入力より後のデビットは無いので、二重には引かれない
      expect(app.effectiveBalance, 97000);
    });

    test('開き直しても二重に引かれない（畳み込み済みが保たれる）', () {
      final app = withDebit();
      app.addDeposit(80000); // ここでデビットを残高へ畳み込む
      final restored = AppState()..importJson(app.exportJson());
      expect(restored.currentBalance, 177000);
      expect(restored.debitsAfterSnapshot(), 0); // もう引かない
      expect(restored.effectiveBalance, 177000);
    });

    test('畳み込んだ後に新しく使ったデビットは、ちゃんと引かれる', () {
      final app = withDebit();
      app.addDeposit(80000); // 3000は畳み込み済み
      app.payments.add(Payment(
        id: 'd2',
        cardName: '三井OLIVE（デビット）',
        amount: 500,
        paymentDate: DateTime.now(),
        source: PaymentSource.usage,
      ));
      expect(app.debitsAfterSnapshot(), 500);
      expect(app.effectiveBalance, 176500);
    });

    test('予想残高もデビットを引いた額から始まる', () {
      final app = withDebit();
      // 給料もカードも無いので、今月末＝いまの実効残高
      expect(app.thisMonthBalance, 97000);
    });
  });
}
