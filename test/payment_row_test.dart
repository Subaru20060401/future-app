// 支払い明細の1行（PaymentRow）の表示テスト（UI改善計画 2026-10-14 の段階1）。
// ⚠️ 以前は右側に金額と最大3つのボタンが並び、カード名や日時が1〜2文字幅の
//   縦書き状態になっていた。どの幅・文字倍率でも、
//   ・はみ出しのエラーが出ない
//   ・カード名に十分な幅がある
//   ・金額が全桁読める（省略・改行しない）
//   を固定する。データは架空。
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_counter_app/app_state.dart';
import 'package:my_counter_app/widgets/payment_row.dart';

void main() {
  const longName = 'とても長い名前のテスト用クレジットカード（デビット）';
  Payment payment({
    String card = longName,
    int amount = 1234567,
    String note = '長い利用先のメモ。駅前のお店でまとめて買ったもの。あとで分割にするかもしれない',
    bool paid = false,
    bool infoOnly = false,
  }) =>
      Payment(
        id: 'p1',
        cardName: card,
        amount: amount,
        paymentDate: DateTime(2026, 10, 14, 16, 46),
        source: PaymentSource.usage,
        note: note,
        paid: paid,
        infoOnly: infoOnly,
      );

  final actions = PaymentActions(
    onEditNote: () {},
    onTogglePaid: () {},
    onDelete: () {},
    onMoveCard: () {},
    onInstallment: () {},
  );

  Future<void> pumpRow(WidgetTester t, Payment p, {required double width, double scale = 1.0}) async {
    t.view.physicalSize = Size(width, 900);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: Size(width, 900), textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          body: ListView(children: [PaymentRow(payment: p, actions: actions, onTap: () {})]),
        ),
      ),
    ));
  }

  for (final width in [320.0, 360.0, 390.0, 430.0, 1280.0]) {
    for (final scale in [1.0, 1.3, 1.5, 2.0]) {
      testWidgets('幅$width・文字倍率$scale でも崩れない', (t) async {
        await pumpRow(t, payment(), width: width, scale: scale);
        expect(t.takeException(), isNull, reason: 'はみ出し（overflow）が無いこと');

        // 金額は全桁が出ている（省略記号なし・1行）
        final amount = find.text('¥1,234,567');
        expect(amount, findsOneWidget);
        final amountPara = t.renderObject<RenderParagraph>(amount);
        expect(amountPara.didExceedMaxLines, isFalse);

        // カード名が縦書き状態になっていない（行の幅の半分以上を使える）
        final nameWidth = t.getSize(find.text(longName)).width;
        expect(nameWidth, greaterThan(width * 0.45),
            reason: 'カード名が1〜2文字幅の列に押し込まれていないこと');
      });
    }
  }

  testWidgets('広い幅では金額を1行目の右、狭い幅では下段に置く', (t) async {
    await pumpRow(t, payment(card: '楽天カード', amount: 1280), width: 430);
    final wideName = t.getTopLeft(find.text('楽天カード')).dy;
    final wideAmount = t.getTopLeft(find.text('¥1,280')).dy;
    expect((wideAmount - wideName).abs(), lessThan(8), reason: '同じ行');

    await pumpRow(t, payment(card: '楽天カード', amount: 1280), width: 320);
    final narrowName = t.getTopLeft(find.text('楽天カード')).dy;
    final narrowAmount = t.getTopLeft(find.text('¥1,280')).dy;
    expect(narrowAmount, greaterThan(narrowName + 30), reason: '下段に移る');
  });

  testWidgets('支払済み・記録のみは文字で分かる（色や取り消し線だけにしない）', (t) async {
    await pumpRow(t, payment(paid: true), width: 390);
    expect(find.text('支払済み'), findsOneWidget);
    await pumpRow(t, payment(infoOnly: true), width: 390);
    expect(find.text('記録のみ'), findsOneWidget);
    expect(find.text('他のカードで計上済み'), findsOneWidget);
  });

  testWidgets('利用先が無ければ「利用先未入力」と出す', (t) async {
    await pumpRow(t, payment(note: ''), width: 390);
    expect(find.text('利用先未入力'), findsOneWidget);
  });

  testWidgets('操作は「︙」から名前付きで出し、対象外の操作は出さない', (t) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PaymentRow(
          payment: payment(),
          actions: PaymentActions(onEditNote: () {}, onTogglePaid: () {}, onDelete: () {}),
          onTap: () {},
        ),
      ),
    ));
    await t.tap(find.byTooltip('操作'));
    await t.pumpAndSettle();
    expect(find.text('利用先を編集'), findsOneWidget);
    expect(find.text('支払済みにする'), findsOneWidget);
    expect(find.text('削除（ゴミ箱へ）'), findsOneWidget);
    expect(find.text('支払いカードを変更'), findsNothing, reason: 'Amazon以外は出さない');
    expect(find.text('分割払いへ変更'), findsNothing, reason: '分割できないものは出さない');
  });

  test('金額の表記（桁区切り・マイナス）', () {
    expect(formatYen(0), '¥0');
    expect(formatYen(1234567), '¥1,234,567');
    expect(formatYen(-3000), '−¥3,000');
  });
}
