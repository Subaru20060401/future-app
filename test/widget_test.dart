// アプリのピュアなロジックの基本テスト。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/app_state.dart';
import 'package:my_counter_app/card_styles.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Amazon発送は全件表示（重複除外しない）', () {
    test('他カードのAmazon購入と同月同額でもAmazon発送は残す', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await Future<void>.delayed(Duration.zero); // loadData() を先に流す

      app.reconcilePayments([
        // 楽天で払ったAmazon購入（利用先=AMAZON）
        (cardName: '楽天カード', amount: 3699, date: DateTime(2026, 4, 6), source: PaymentSource.usage, sourceId: 'r1', note: 'AMAZON.CO.JP'),
        // 同月同額のAmazon発送 → 情報のみ(usage)なので消さず残す
        (cardName: 'Amazonマスター', amount: 3699, date: DateTime(2026, 4, 6, 16, 47), source: PaymentSource.usage, sourceId: 'amazon#503-7786126-3384652', note: ''),
        // 別のAmazon発送 → 当然残る
        (cardName: 'Amazonマスター', amount: 22544, date: DateTime(2026, 4, 1, 17, 45), source: PaymentSource.usage, sourceId: 'amazon#250-2047428-7142225', note: ''),
      ]);

      final amzn = app.payments.where((p) => p.cardName == 'Amazonマスター').toList();
      expect(amzn.length, 2); // 3699も22544も両方残る
      expect(amzn.map((p) => p.amount).toSet(), {3699, 22544});
      expect(app.payments.any((p) => p.cardName == '楽天カード' && p.amount == 3699), isTrue);
    });

    test('分割へ移動したAmazon購入と同月同額でもAmazon発送は残す', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await Future<void>.delayed(Duration.zero);

      // 楽天¥37172のAmazon購入を分割払いに移動済みの状態を作る
      app.addInstallment(
        name: '楽天カード (2026-04-04)',
        totalAmount: 37172,
        count: 5,
        cardName: '楽天カード',
        interestRate: 15,
        startDate: DateTime(2026, 4, 4),
      );

      app.reconcilePayments([
        (cardName: 'Amazonマスター', amount: 37172, date: DateTime(2026, 4, 8, 16, 49), source: PaymentSource.usage, sourceId: 'amazon#250-5900189-4785413', note: ''),
      ]);

      expect(app.payments.any((p) => p.cardName == 'Amazonマスター' && p.amount == 37172), isTrue);
      expect(app.installments.any((i) => i.totalAmount == 37172), isTrue);
    });
  });

  group('分割へ移動した明細は再取得で復活しない（二重計上防止）', () {
    test('Amazon発送の受信日時がズレても sourceId で復活を防ぐ', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await Future<void>.delayed(Duration.zero);

      // ① Amazon発送メールから ¥3000 を取り込む（日付＝発送メールの受信日時）
      app.reconcilePayments([
        (cardName: 'Amazonマスター', amount: 3000, date: DateTime(2026, 8, 2, 14, 23, 45), source: PaymentSource.usage, sourceId: 'amazon#111-2222333-4444555', note: ''),
      ]);
      final p = app.payments.firstWhere((e) => e.amount == 3000);

      // ② それを分割払いへ移動
      app.convertPaymentToInstallment(p.id, 3);
      expect(app.payments.any((e) => e.amount == 3000), isFalse);
      expect(app.installments.any((i) => i.totalAmount == 3000), isTrue);

      // ③ 再同期。発送メールの受信日時（＝時刻）がズレても復活しない
      app.reconcilePayments([
        (cardName: 'Amazonマスター', amount: 3000, date: DateTime(2026, 8, 2, 9, 5, 1), source: PaymentSource.usage, sourceId: 'amazon#111-2222333-4444555', note: ''),
      ]);
      expect(app.payments.any((e) => e.amount == 3000), isFalse); // 二重計上しない
      expect(app.installments.where((i) => i.totalAmount == 3000).length, 1);
    });

    test('同カード・同額・同じ利用日の分割払いがあれば取り込まない（自己修復）', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await Future<void>.delayed(Duration.zero);

      // 既に分割払いへ登録済み（旧バージョンで変換したためsourceIdの記録が無い状態）
      app.addInstallment(
        name: 'Amazonマスター (2026-08-02)',
        totalAmount: 3000,
        count: 3,
        cardName: 'Amazonマスター',
        interestRate: 15,
        startDate: DateTime(2026, 8, 2),
      );

      app.reconcilePayments([
        (cardName: 'Amazonマスター', amount: 3000, date: DateTime(2026, 8, 2, 14, 23), source: PaymentSource.usage, sourceId: 'amazon#999-8888777-6666555', note: ''),
      ]);

      expect(app.payments.any((e) => e.amount == 3000), isFalse); // 分割と重複しない
    });

    test('既にカード側に残っている重複は起動時の掃除で消える（自己修復）', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await Future<void>.delayed(Duration.zero);

      // 旧バージョンの取りこぼし状態を再現: 分割払いと同じ決済がカード側にも残っている
      app.addInstallment(
        name: 'Amazonマスター (2026-08-02)',
        totalAmount: 3000,
        count: 3,
        cardName: 'Amazonマスター',
        interestRate: 15,
        startDate: DateTime(2026, 8, 2),
      );
      app.payments.add(Payment(
        id: 'dup', cardName: 'Amazonマスター', amount: 3000,
        paymentDate: DateTime(2026, 8, 2, 14, 23), source: PaymentSource.usage,
        sourceId: 'amazon#111-2222333-4444555',
      ));

      final removed = app.cleanupInstallmentDuplicates();
      expect(removed, 1);
      expect(app.payments.any((e) => e.amount == 3000), isFalse);
    });

    test('手動追加はユーザーの意思なので掃除しない', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await Future<void>.delayed(Duration.zero);

      app.addInstallment(
        name: 'Amazonマスター (2026-08-02)',
        totalAmount: 3000, count: 3, cardName: 'Amazonマスター',
        interestRate: 15, startDate: DateTime(2026, 8, 2),
      );
      app.payments.add(Payment(
        id: 'man', cardName: 'Amazonマスター', amount: 3000,
        paymentDate: DateTime(2026, 8, 2), source: PaymentSource.manual,
      ));

      expect(app.cleanupInstallmentDuplicates(), 0);
      expect(app.payments.any((e) => e.id == 'man'), isTrue);
    });

    test('日付が違う同額の決済は別取引として残る', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await Future<void>.delayed(Duration.zero);

      app.addInstallment(
        name: 'Amazonマスター (2026-08-02)',
        totalAmount: 3000,
        count: 3,
        cardName: 'Amazonマスター',
        interestRate: 15,
        startDate: DateTime(2026, 8, 2),
      );

      // 別の日の同額決済は消さない
      app.reconcilePayments([
        (cardName: 'Amazonマスター', amount: 3000, date: DateTime(2026, 8, 20, 10, 0), source: PaymentSource.usage, sourceId: 'amazon#777-1111222-3333444', note: ''),
      ]);

      expect(app.payments.any((e) => e.amount == 3000), isTrue);
    });
  });
  group('分割払いの月額計算', () {
    test('金利0%は元金を回数で割る', () {
      expect(computeInstallmentMonthly(12000, 12, 0), 1000);
    });

    test('金利ありは手数料が上乗せされる', () {
      // 元金10000・12回・年率15% → 手数料 10000*0.15*1 = 1500 → 11500/12
      expect(computeInstallmentMonthly(10000, 12, 15), (11500 / 12).round());
    });
  });

  group('分割の制約', () {
    test('最低分割金額', () {
      expect(canInstallment('楽天カード', 2000), isFalse); // 楽天は3000以上
      expect(canInstallment('三井OLIVE', 1000), isTrue); // OLIVEは1000以上
    });

    test('Amazonの2・3回は手数料無料', () {
      expect(isInstallmentInterestFree('Amazonマスター', 3), isTrue);
      expect(isInstallmentInterestFree('Amazonマスター', 4), isFalse);
      expect(isInstallmentInterestFree('楽天カード', 3), isFalse);
    });
  });

  test('カード色は種別で決まる', () {
    expect(cardColorOf('三井OLIVE（デビット）'), cardColorOf('三井OLIVE'));
  });
}
