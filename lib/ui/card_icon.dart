// 💡 カードのアイコン。自分の画像（AppState.cardIcons）があればそれ、無ければ既定のマーク。
//   既定のマークは色だけでなく、頭文字と形（丸・角丸）も変えて、小さくても見分けられるようにする。
//   ⚠️ 公式ロゴは同梱しない（商標で、公開リポジトリで配布できる条件の素材が無いため）。
//     本物のロゴを使いたいときは、自分の画像として端末から設定する（リポジトリには入らない）。
//   アイコンは飾り。カード名は必ず横に文字で出す（読み上げもカード名で行う）。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';

enum CardMarkShape { circle, rounded }

class CardMark {
  const CardMark(this.text, this.background, this.foreground, this.shape);
  final String text;
  final Color background;
  final Color foreground;
  final CardMarkShape shape;
}

/// カード名から既定のマーク（頭文字・色・形）を決める
CardMark cardMarkOf(String name) {
  if (name.contains('Amazon') || name.contains('アマゾン')) {
    return const CardMark('a', Color(0xFF232F3E), Color(0xFFFF9900), CardMarkShape.circle);
  }
  if (name.contains('三井') || name.contains('OLIVE') || name.contains('Olive')) {
    return const CardMark('O', Color(0xFF1B5E20), Colors.white, CardMarkShape.rounded);
  }
  if (name.contains('楽天')) {
    return const CardMark('R', Color(0xFFBF0000), Colors.white, CardMarkShape.rounded);
  }
  if (name.contains('PayPay') || name.contains('ペイペイ')) {
    return const CardMark('P', Color(0xFFE60033), Colors.white, CardMarkShape.circle);
  }
  if (name.contains('メル')) {
    return const CardMark('メ', Color(0xFFAD1457), Colors.white, CardMarkShape.rounded);
  }
  if (name.contains('三菱') || name.contains('UFJ') || name.contains('MUFG')) {
    return const CardMark('MU', Color(0xFF4527A0), Colors.white, CardMarkShape.circle);
  }
  final trimmed = name.trim();
  final first = trimmed.isEmpty ? '?' : String.fromCharCode(trimmed.runes.first);
  return CardMark(first, const Color(0xFF616161), Colors.white, CardMarkShape.rounded);
}

/// カードのアイコン。[imageBase64] を渡さなければ AppState の設定から読む（無ければ既定のマーク）。
/// [useDefault] が true なら、自分の画像があっても既定のマークを出す（編集画面の見比べ用）。
class CardIcon extends StatelessWidget {
  const CardIcon(this.cardName, {super.key, this.size = 28, this.imageBase64, this.useDefault = false});

  final String cardName;
  final double size;
  final String? imageBase64;
  final bool useDefault;

  @override
  Widget build(BuildContext context) {
    var data = imageBase64;
    if (data == null && !useDefault) {
      // 💡 Provider が無い場面（単体の部品テストなど）では既定のマークを出す
      try {
        data = context.select<AppState, String?>((a) => a.cardIconOf(cardName));
      } on ProviderNotFoundException {
        data = null;
      }
    }
    final Widget child;
    final bytes = useDefault ? null : _decode(data);
    if (bytes != null) {
      child = ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.22),
        child: Image.memory(bytes,
            width: size,
            height: size,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            // 壊れた画像なら既定のマーク
            errorBuilder: (_, _, _) => _mark()),
      );
    } else {
      child = _mark();
    }
    return ExcludeSemantics(child: SizedBox(width: size, height: size, child: child));
  }

  Widget _mark() {
    final m = cardMarkOf(cardName);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: m.background,
        shape: m.shape == CardMarkShape.circle ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: m.shape == CardMarkShape.rounded ? BorderRadius.circular(size * 0.22) : null,
      ),
      child: Text(
        m.text,
        maxLines: 1,
        textScaler: TextScaler.noScaling, // 💡 枠に収める（カード名の文字は別に拡大される）
        style: TextStyle(
          color: m.foreground,
          fontWeight: FontWeight.bold,
          fontSize: size * (m.text.length > 1 ? 0.38 : 0.5),
          height: 1.0,
        ),
      ),
    );
  }

  static Uint8List? _decode(String? b64) {
    if (b64 == null || b64.isEmpty) return null;
    try {
      return base64Decode(b64);
    } catch (_) {
      return null;
    }
  }
}
