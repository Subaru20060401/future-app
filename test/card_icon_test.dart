// 💡 カードのアイコン: 既定のマーク（頭文字・色・形）と、自分の画像（縮小した PNG）。
//   ・再起動・バックアップの取り込み・ドライブ同期のあとも、カードとの対応が保たれる
//   ・名前を変える・まとめるとアイコンも付け替わる
//   ・保存に失敗したら（容量不足など）元のアイコンのまま、家計データも壊れない
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:my_counter_app/app_state.dart';
import 'package:my_counter_app/drive_sync.dart';
import 'package:my_counter_app/ui/card_icon.dart';
import 'package:my_counter_app/ui/card_icon_image.dart';

import 'drive_push_pull_test.dart' show FakeDriveStore;
import 'save_paths_test.dart' show install, restart, f, day;
import 'support/test_app.dart';

// 架空の小さな画像（1×1 の PNG）。中身は何でもよい（アイコンの対応だけを確かめる）
const iconA = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
const iconB = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

Future<Uint8List> pngOf(int w, int h) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
      ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), ui.Paint()..color = const ui.Color(0xFF00AA00));
  final img = await recorder.endRecording().toImage(w, h);
  final bd = await img.toByteData(format: ui.ImageByteFormat.png);
  return bd!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('既定のマーク（色だけでなく頭文字と形でも見分ける）', () {
    test('主なカードは頭文字と形が決まっている', () {
      final amazon = cardMarkOf('Amazonマスター');
      expect((amazon.text, amazon.shape), ('a', CardMarkShape.circle));
      final olive = cardMarkOf('三井OLIVE');
      expect((olive.text, olive.shape), ('O', CardMarkShape.rounded));
      expect(cardMarkOf('楽天カード').text, 'R');
      expect(cardMarkOf('PayPayカード').text, 'P');
      expect(cardMarkOf('メルカード').text, 'メ');
      expect(cardMarkOf('三菱UFJカード').text, 'MU');
    });

    test('赤系のカード（楽天・PayPay）は形も違う', () {
      expect(cardMarkOf('楽天カード').shape, isNot(cardMarkOf('PayPayカード').shape));
    });

    test('知らないカードは名前の 1 文字目', () {
      expect(cardMarkOf('テストカード').text, 'テ');
      expect(cardMarkOf('').text, '?');
    });
  });

  group('自分の画像とカードの対応', () {
    test('再起動しても残る', () async {
      final a = await fixedApp(day);
      expect(await a.setCardIcon('カードA', iconA), isTrue);
      final b = await reloadApp(day);
      expect(b.cardIconOf('カードA'), iconA);
      expect(b.cardIconOf('カードB'), isNull);
    });

    test('バックアップの取り込み・ドライブからの取り込みで、カードとの対応が保たれる', () async {
      final src = await fixedApp(day);
      src.cardIcons.addAll({'カードA': iconA, 'カードB': iconB});
      final json = src.exportJson();
      final a = await fixedApp(day);
      a.cardIcons['カードA'] = iconB; // 取り込みは置き換え
      await a.importJson(json);
      expect(a.cardIcons, {'カードA': iconA, 'カードB': iconB});

      final c = await fixedApp(day);
      final remote = DriveSnapshot(updatedAt: day, device: 'test', json: json);
      final r = await DriveSync.withStore(FakeDriveStore()..remote = remote).pullNow(c, snapshot: remote);
      expect(r.state, DriveSyncState.upToDate);
      expect(c.cardIcons, {'カードA': iconA, 'カードB': iconB});
      final d = await reloadApp(day);
      expect(d.cardIcons, {'カードA': iconA, 'カードB': iconB});
    });

    test('アイコンの無い以前のバックアップも読める（すべて既定のマーク）', () async {
      final a = await fixedApp(day);
      final data = jsonDecode(a.exportJson()) as Map<String, dynamic>..remove('cardIcons');
      a.cardIcons['カードA'] = iconA;
      await a.importJson(jsonEncode(data));
      expect(a.cardIcons, isEmpty);
    });

    test('名前を変えるとアイコンも付け替わる。まとめ先に画像があればそちらを使う', () async {
      final a = await fixedApp(day);
      a.cardPaymentDays.addAll({'カードA': 26, 'カードB': 27});
      a.cardIcons.addAll({'カードA': iconA, 'カードB': iconB});
      a.renameOrMergeCard('カードA', 'カードA2'); // 名前の変更
      expect(a.cardIconOf('カードA2'), iconA);
      expect(a.cardIconOf('カードA'), isNull);
      a.renameOrMergeCard('カードA2', 'カードB'); // まとめる（まとめ先の画像を使う）
      expect(a.cardIconOf('カードB'), iconB);
      expect(a.cardIcons.keys, ['カードB']);
    });

    test('既定に戻すと画像を消す', () async {
      final a = await fixedApp(day);
      await a.setCardIcon('カードA', iconA);
      expect(await a.setCardIcon('カードA', null), isTrue);
      expect(a.cardIconOf('カードA'), isNull);
      final b = await reloadApp(day);
      expect(b.cardIconOf('カードA'), isNull);
    });
  });

  group('保存に失敗したとき（容量不足など）', () {
    Future<AppState> withIconA() async {
      final a = await fixedApp(day);
      a.currentBalance = 12345;
      await a.setCardIcon('カードA', iconA);
      return a;
    }

    test('一時保存が書けない → false。元のアイコンのまま、家計データも変わらない', () async {
      final a = await withIconA();
      final s = await install();
      s.falseOnSet = {f(AppState.kPendingWriteKey)};
      expect(await a.setCardIcon('カードA', iconB), isFalse);
      expect(a.cardIconOf('カードA'), iconA, reason: 'メモリも元のアイコンに戻る');
      s.heal();
      final b = await restart();
      expect(b.cardIconOf('カードA'), iconA);
      expect(b.currentBalance, 12345);
    });

    test('アイコンのキーだけ書けない → false。次の起動でも元のアイコン', () async {
      final a = await withIconA();
      final s = await install();
      s.falseOnSet = {f('saved_card_icons')};
      expect(await a.setCardIcon('カードA', iconB), isFalse);
      expect(a.cardIconOf('カードA'), iconA);
      s.heal();
      final b = await restart();
      expect(b.cardIconOf('カードA'), iconA);
      expect(b.currentBalance, 12345);
    });
  });

  group('画像の縮小（端末の中で 96×96 の PNG にする）', () {
    testWidgets('横長の画像も 96×96 の PNG になる（縦横比を保って余白は透明）', (tester) async {
      await tester.runAsync(() async {
        final src = await pngOf(300, 150);
        final b64 = await makeCardIconPng(src);
        final out = base64Decode(b64);
        expect(out.length, lessThan(src.length + 1000));
        final codec = await ui.instantiateImageCodec(out);
        final img = (await codec.getNextFrame()).image;
        expect((img.width, img.height), (96, 96));
      });
    });

    testWidgets('画像でないものは、分かる言葉の失敗になる', (tester) async {
      await tester.runAsync(() async {
        await expectLater(makeCardIconPng(Uint8List.fromList(utf8.encode('画像ではない'))),
            throwsA(isA<CardIconImageError>()));
        await expectLater(makeCardIconPng(Uint8List(0)), throwsA(isA<CardIconImageError>()));
      });
    });
  });

  group('表示', () {
    testWidgets('自分の画像があれば画像、無ければ既定のマーク（設定と支払い管理で同じ部品）', (tester) async {
      late AppState app;
      await tester.runAsync(() async {
        app = await fixedApp(day);
        app.cardIcons['カードA'] = iconA;
      });
      await tester.pumpWidget(ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(
          home: Scaffold(
            body: Column(children: [
              CardIcon('カードA', key: Key('a')),
              CardIcon('Amazonマスター', key: Key('b')),
            ]),
          ),
        ),
      ));
      expect(find.descendant(of: find.byKey(const Key('a')), matching: find.byType(Image)), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('b')), matching: find.text('a')), findsOneWidget);
    });

    testWidgets('Provider が無い場面でも既定のマークを出す', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: CardIcon('楽天カード')));
      expect(find.text('R'), findsOneWidget);
    });
  });
}
