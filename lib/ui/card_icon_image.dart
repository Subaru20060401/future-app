// 💡 カードのアイコン用に、選んだ画像を端末の中で小さな PNG にする（96×96、透明の余白で正方形に）。
//   元の画像は保存しない。縮小した PNG（数 KB）だけを base64 で AppState.cardIcons に保存する。
//   ⚠️ 写真をそのまま保存すると、localStorage（5MB ほど）を圧迫し、ドライブ同期のデータも大きくなる。
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

const int kCardIconPixels = 96;
// 選べる元画像の大きさの上限（読み込みで止まらないように）
const int kMaxCardIconSourceBytes = 15 * 1024 * 1024;

class CardIconImageError implements Exception {
  CardIconImageError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 画像のバイト列から、アイコン用の PNG（base64）を作る。読めない画像なら CardIconImageError。
Future<String> makeCardIconPng(Uint8List source) async {
  if (source.isEmpty) throw CardIconImageError('画像を読み込めませんでした');
  if (source.length > kMaxCardIconSourceBytes) {
    throw CardIconImageError('画像が大きすぎます（${(source.length / 1024 / 1024).toStringAsFixed(1)}MB）。'
        '15MB以下にしてください');
  }
  final ui.Image image;
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(source);
    final codec = await ui.instantiateImageCodecWithSize(buffer, getTargetSize: (w, h) {
      // 長い辺を 96px に合わせる（縦横比はそのまま）
      final scale = kCardIconPixels / math.max(w, h);
      return ui.TargetImageSize(
        width: math.max(1, (w * scale).round()),
        height: math.max(1, (h * scale).round()),
      );
    });
    image = (await codec.getNextFrame()).image;
  } catch (_) {
    throw CardIconImageError('画像として読めませんでした。PNG・JPEG などの画像を選んでください');
  }
  try {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    const size = kCardIconPixels;
    final dx = (size - image.width) / 2;
    final dy = (size - image.height) / 2;
    canvas.drawImage(image, ui.Offset(dx, dy), ui.Paint()..filterQuality = ui.FilterQuality.high);
    final out = await recorder.endRecording().toImage(size, size);
    final png = await out.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) throw CardIconImageError('アイコンを作れませんでした');
    return base64Encode(png.buffer.asUint8List());
  } finally {
    image.dispose();
  }
}
