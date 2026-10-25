// 💡 web/ocr.js の pocketOcrDigits を呼ぶ（tesseract.js で数字と「:」を位置つきで読む）。
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'shift_calendar_ocr.dart';

@JS('pocketOcrDigits')
external JSPromise<JSString> _pocketOcrDigits(JSUint8Array bytes);

bool get ocrDigitsAvailable => globalContext.has('pocketOcrDigits');

Future<OcrPage> ocrDigits(Uint8List bytes) async {
  final raw = (await _pocketOcrDigits(bytes.toJS).toDart).toDart;
  final m = jsonDecode(raw) as Map<String, dynamic>;
  return OcrPage(
    (m['w'] as num? ?? 0).toDouble(),
    (m['h'] as num? ?? 0).toDouble(),
    [
      for (final e in (m['words'] as List? ?? const []))
        if (e is Map)
          OcrWord(
            '${e['t'] ?? ''}',
            (e['x0'] as num).toDouble(),
            (e['y0'] as num).toDouble(),
            (e['x1'] as num).toDouble(),
            (e['y1'] as num).toDouble(),
          ),
    ],
  );
}
