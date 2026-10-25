import 'dart:typed_data';

import 'shift_calendar_ocr.dart';

bool get ocrDigitsAvailable => false;

Future<OcrPage> ocrDigits(Uint8List bytes) =>
    throw UnsupportedError('この端末では画像の読み取りに対応していません（Web版で使ってください）');
