// 💡 Gemini API（Google AI Studio のキー）への接続。
//   サーバーが無いので、本人のAPIキーでブラウザから直接呼ぶ。
// ⚠️ キーの扱い:
//   ・既定はメモリだけ（開いている間）。「この端末に保存」を選んだときだけ端末に残す
//   ・エクスポート・ドライブ同期・診断には含めない（保存キーは saved_ で始めない）
//   ・URLには載せない（ヘッダーで渡す）
// ⚠️ モデル名は固定で決め打ちしない。提供状況が変わるので、一覧から選べるようにしている。
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'shift_image_import.dart';

class GeminiException implements Exception {
  final String message;
  const GeminiException(this.message);
  @override
  String toString() => message;
}

class GeminiClient {
  GeminiClient._();
  static final GeminiClient instance = GeminiClient._();

  static const String _kKey = 'local_gemini_api_key'; // ⚠️ saved_ で始めない（同期対象外）
  static const String _kModel = 'local_gemini_model';
  static const String defaultModel = 'gemini-2.5-flash';
  static const String _base = 'https://generativelanguage.googleapis.com/v1beta';

  String? _key;
  String model = defaultModel;
  bool keySaved = false;
  bool _loaded = false;

  // テストで差し替えるため
  http.Client Function() clientFactory = http.Client.new;

  bool get hasKey => (_key ?? '').isNotEmpty;
  // 保存のオン／オフだけ切り替えるとき用（画面には出さない）
  String get currentKeyForResave => _key ?? '';

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final k = prefs.getString(_kKey);
      if (k != null && k.isNotEmpty) {
        _key = k;
        keySaved = true;
      }
      model = prefs.getString(_kModel) ?? defaultModel;
    } catch (_) {}
  }

  Future<void> setKey(String key, {required bool remember}) async {
    _key = key.trim();
    keySaved = remember;
    final prefs = await SharedPreferences.getInstance();
    if (remember && _key!.isNotEmpty) {
      await prefs.setString(_kKey, _key!);
    } else {
      await prefs.remove(_kKey);
    }
  }

  Future<void> clearKey() async {
    _key = null;
    keySaved = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kKey);
  }

  Future<void> setModel(String m) async {
    model = m.trim().isEmpty ? defaultModel : m.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kModel, model);
  }

  Map<String, String> get _headers => {
        'x-goog-api-key': _key ?? '',
        'Content-Type': 'application/json',
      };

  // 💡 このキーで使えるモデル（画像を読めて generateContent に対応するもの）
  Future<List<String>> listModels() async {
    if (!hasKey) throw const GeminiException('APIキーが入力されていません');
    final client = clientFactory();
    try {
      final res = await client
          .get(Uri.parse('$_base/models?pageSize=200'), headers: _headers)
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) throw GeminiException(describeGeminiError(res.statusCode, res.body));
      final map = jsonDecode(res.body) as Map<String, dynamic>;
      final out = <String>[];
      for (final m in (map['models'] as List?) ?? const []) {
        if (m is! Map) continue;
        final methods = (m['supportedGenerationMethods'] as List?) ?? const [];
        final name = '${m['name'] ?? ''}'.replaceFirst('models/', '');
        if (methods.contains('generateContent') && name.startsWith('gemini')) out.add(name);
      }
      return out;
    } finally {
      client.close();
    }
  }

  // 💡 シフト表の画像を読み取り、JSON文字列を返す（検証は parseShiftReadJson で行う）。
  //   ⚠️ 家計データやメールは送らない。送るのは画像と、名前・年月だけ。
  Future<String> readShiftImage({
    required List<int> bytes,
    required String mimeType,
    required String personName,
    required int year,
    required int month,
  }) async {
    if (!hasKey) throw const GeminiException('APIキーが入力されていません');
    final body = jsonEncode({
      'contents': [
        {
          'role': 'user',
          'parts': [
            {'text': buildShiftReadPrompt(personName: personName, year: year, month: month)},
            {
              'inline_data': {'mime_type': mimeType, 'data': base64Encode(bytes)},
            },
          ],
        },
      ],
      'generationConfig': {
        'temperature': 0,
        'responseMimeType': 'application/json',
        'responseSchema': kShiftReadSchema,
      },
    });
    final client = clientFactory();
    try {
      final res = await client
          .post(Uri.parse('$_base/models/$model:generateContent'),
              headers: _headers, body: body)
          .timeout(const Duration(seconds: 90));
      if (res.statusCode != 200) throw GeminiException(describeGeminiError(res.statusCode, res.body));
      return extractGeminiText(res.body);
    } on GeminiException {
      rethrow;
    } catch (e) {
      throw GeminiException('Geminiに接続できませんでした（$e）。電波の良い場所でもう一度お試しください');
    } finally {
      client.close();
    }
  }
}

// 💡 応答から本文を取り出す。拒否・途中終了は例外（＝1件も登録しない）。
String extractGeminiText(String responseBody) {
  final Map<String, dynamic> map;
  try {
    map = jsonDecode(responseBody) as Map<String, dynamic>;
  } catch (_) {
    throw const GeminiException('Geminiの応答を読めませんでした');
  }
  final block = (map['promptFeedback'] as Map?)?['blockReason'];
  if (block != null) throw GeminiException('Geminiが画像の読み取りを断りました（$block）');
  final cands = map['candidates'] as List?;
  if (cands == null || cands.isEmpty) throw const GeminiException('Geminiから結果が返りませんでした');
  final c = cands.first as Map;
  final reason = c['finishReason'];
  if (reason != null && reason != 'STOP') {
    throw GeminiException(reason == 'MAX_TOKENS'
        ? '結果が長すぎて途中で切れました。画像を1か月分・自分の行の周りに切り出してください'
        : 'Geminiの読み取りが途中で止まりました（$reason）');
  }
  final parts = ((c['content'] as Map?)?['parts'] as List?) ?? const [];
  final text = parts.whereType<Map>().map((p) => p['text'] ?? '').join();
  if (text.trim().isEmpty) throw const GeminiException('Geminiから結果が返りませんでした');
  return text;
}

// 💡 エラーを「次に何をすればいいか」が分かる文に。
String describeGeminiError(int status, String body) {
  final lower = body.toLowerCase();
  if (status == 400 && lower.contains('api key not valid')) {
    return 'APIキーが正しくありません。Google AI Studioで発行したキーを入れ直してください';
  }
  if (status == 401 || status == 403) {
    return 'APIキーが使えません（$status）。キーが有効か、Gemini APIが使える設定かを確認してください';
  }
  if (status == 404) {
    return 'モデル「${GeminiClient.instance.model}」が見つかりません。設定の「モデルを選ぶ」から選び直してください';
  }
  if (status == 429) {
    return '利用の上限に達しました（429）。少し待つか、Google AI Studioで利用枠を確認してください';
  }
  if (status >= 500) return 'Gemini側で一時的なエラーが起きました（$status）。少し待ってからお試しください';
  return 'Geminiでエラーが起きました（$status）';
}
