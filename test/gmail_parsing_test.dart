import 'package:flutter_test/flutter_test.dart';
import 'package:my_counter_app/gmail_service.dart';

void main() {
  final svc = GmailService.instance;

  group('楽天カード（■ラベル形式・実メール）解析', () {
    // 実際の楽天メール（プレーンテキスト部）と同じラベル形式
    const single = '''
<カードご利用情報> 《ショッピングご利用分》
■利用日: 2026/06/05
■利用先: ﾐｾｽｸﾞﾘ-ﾝｱﾂﾌﾟﾙｴﾌｼ-
■利用者: 本人
■支払方法: 1回
■利用金額: 550 円
■支払月: 2026/07
合計 550 円
''';

    test('1取引を正しく抽出（店名・金額・日付）', () {
      final list = svc.extractRakutenTransactions(single, 'm1');
      expect(list.length, 1);
      expect(list[0].cardName, '楽天カード');
      expect(list[0].amount, 550);
      expect(list[0].note, 'ﾐｾｽｸﾞﾘ-ﾝｱﾂﾌﾟﾙｴﾌｼ-');
      expect(list[0].date, DateTime(2026, 6, 5));
      // 合計(550)を二重に拾わない
      expect(list.length, 1);
    });

    const multi = '''
■利用日: 2026/04/10
■利用先: ドラッグイレブン
■利用者: 本人
■利用金額: 1,331 円
■支払月: 2026/05
■利用日: 2026/04/10
■利用先: AMAZON.CO.JP
■利用者: 本人
■利用金額: 1,089 円
■支払月: 2026/05
合計 2,420 円
''';

    test('複数取引を取得し、合計は除外', () {
      final list = svc.extractRakutenTransactions(multi, 'm2');
      expect(list.length, 2);
      expect(list[0].amount, 1331);
      expect(list[0].note, 'ドラッグイレブン');
      expect(list[1].amount, 1089);
      expect(list[1].note, 'AMAZON.CO.JP');
      expect(list.any((p) => p.amount == 2420), isFalse);
      expect(list[0].sourceId, 'm2#0');
      expect(list[1].sourceId, 'm2#1');
    });

    test('全角金額も取得', () {
      const t = '■利用日: 2026/04/10 ■利用先: コンビニ ■利用金額: １，２００ 円';
      final list = svc.extractRakutenTransactions(t, 'm3');
      expect(list.length, 1);
      expect(list[0].amount, 1200);
      expect(list[0].note, 'コンビニ');
    });

    test('【速報版】: セルが<span>で包まれていても抽出できる（利用先なし）', () {
      // 実メール相当: ご利用日/利用者/ご利用金額 の3列。セル内がタグで包まれている。
      const t = '''
【速報版】カード利用のお知らせ(本人ご利用分)
<table><tr><td align="center"><span style="color:#fff">ご利用日</span></td>
<td align="center"><span>利用者</span></td><td align="center"><span>ご利用金額</span></td></tr>
<tr><td align="center"><span style="font-size:14px">2026/08/05</span></td>
<td align="center"><span>本人</span></td><td align="center"><span>550 円</span></td></tr></table>
''';
      final list = svc.extractRakutenTransactions(t, 'sokuho1');
      expect(list.length, 1);
      expect(list[0].amount, 550);
      expect(list[0].date, DateTime(2026, 8, 5));
      expect(list[0].cardName, '楽天カード');
    });

    test('【速報版】の後に詳細メールが来ても二重にならない（同日同額）', () {
      const sokuho = '''
【速報版】カード利用のお知らせ
<tr><td><span>ご利用日</span></td></tr><tr><td><span>2026/08/05</span></td>
<td><span>本人</span></td><td><span>550 円</span></td></tr>
''';
      const detail = '■利用日: 2026/08/05 ■利用先: ｺﾝﾋﾞﾆ ■利用金額: 550 円';
      final a = svc.extractRakutenTransactions(sokuho, 'x1');
      final b = svc.extractRakutenTransactions(detail, 'x2');
      expect(a.length, 1);
      expect(b.length, 1);
      // 同じ カード|金額|日付 なので reconcile 側の重複判定で1件に統合される
      expect(a[0].date, b[0].date);
      expect(a[0].amount, b[0].amount);
    });

    test('■とHTMLが両方あっても二重にならない', () {
      const t = '''
■利用日: 2026/06/05 ■利用先: ﾐｾｽ ■利用者: 本人 ■利用金額: 550 円
<tr><td>2026/06/05</td><td class='p'>ﾐｾｽ</td><td class='a'>550 円</td></tr>
合計 550 円
''';
      final list = svc.extractRakutenTransactions(t, 'm4');
      expect(list.length, 1); // (日付+金額)で重複除外
      expect(list[0].amount, 550);
    });

    test('HTML表のみ（プレーン本文が省略）でも取得', () {
      const t = "<tr><td>2026/04/15</td><td class='p'>ABCストア</td>"
          "<td class='a'>1,485 円</td></tr> 合計 1,485 円";
      final list = svc.extractRakutenTransactions(t, 'm5');
      expect(list.length, 1);
      expect(list[0].amount, 1485);
      expect(list[0].note, 'ABCストア');
    });
  });

  group('メルカリ 購入完了メール', () {
    const purchase = '''
【メルカリ】ご購入ありがとうございます

■商品情報
商品名：ディジタル画像処理 = Digital image processing
出品者：ミランジョ
■支払い金額
商品代金 ¥1,800
クーポン：利用なし
支払い金額：¥1,800
支払い方法：メルペイのクレジット
''';

    test('商品代金と商品名を取得（受信日時を日付に）', () {
      final received = DateTime(2026, 5, 8, 7, 26);
      final p = svc.extractMercariPurchase(purchase, 'm2', received);
      expect(p, isNotNull);
      expect(p!.cardName, 'メルカード');
      expect(p.amount, 1800);
      expect(p.note, 'ディジタル画像処理');
      expect(p.date, received);
    });
  });

  group('メルカード 利用通知', () {
    const usage = '''
メルカードのご利用がありました

決済内容
店舗名      業務スーパー 泡瀬店
決済金額    ¥338
メルカード還元   P3（付与予定）
決済方法    メルカード
決済日時    2026/03/09 15:06
取引番号    019970674222
''';

    test('決済金額・店舗名・決済日時を取得', () {
      final p = svc.extractMercardUsage(usage, 'm3');
      expect(p, isNotNull);
      expect(p!.cardName, 'メルカード');
      expect(p.amount, 338);
      expect(p.note, '業務スーパー 泡瀬店');
      expect(p.date, DateTime(2026, 3, 9, 15, 6));
    });

    test('決済金額が無いメールは null', () {
      final p = svc.extractMercardUsage('キャンペーンのお知らせ ポイント還元', 'm4');
      expect(p, isNull);
    });
  });
}
