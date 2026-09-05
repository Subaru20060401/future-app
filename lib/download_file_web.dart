// 💡 Web版は端末にファイルを書けないので、ブラウザのダウンロードとして保存させる。
//   （バックアップJSONを別の端末へ持っていくのに、コピペでは現実的でないため）
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

bool downloadTextFile(String fileName, String content, String mime) {
  try {
    // 日本語がそのまま保存されるようUTF-8にする
    final bytes = Uint8List.fromList(utf8.encode(content));
    final blob = web.Blob(
      <JSAny>[bytes.toJS].toJS,
      web.BlobPropertyBag(type: '$mime;charset=utf-8'),
    );
    final url = web.URL.createObjectURL(blob);
    final a = web.document.createElement('a') as web.HTMLAnchorElement
      ..href = url
      ..download = fileName;
    web.document.body!.appendChild(a);
    a.click();
    a.remove();
    web.URL.revokeObjectURL(url);
    return true;
  } catch (_) {
    return false; // 失敗したら呼び出し側がテキスト表示に切り替える
  }
}
