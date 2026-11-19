// 💡 保存（SharedPreferences）の失敗を再現するためのストア。
//   failAfter 回の書き込みが成功した後、次の書き込みから失敗する（保存の途中で止まる状況）。
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class FailingPrefsStore extends InMemorySharedPreferencesStore {
  FailingPrefsStore(Map<String, Object> data) : super.withData(data);
  int? failAfter; // null = 失敗しない
  int writes = 0;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (failAfter != null && writes >= failAfter!) {
      throw StateError('保存に失敗（テスト）: $key');
    }
    writes++;
    return super.setValue(valueType, key, value);
  }
}

/// 今の保存内容を引き継いだ、失敗させられるストアに差し替える
Future<FailingPrefsStore> useFailingStore() async {
  final current = await SharedPreferencesStorePlatform.instance.getAll();
  final store = FailingPrefsStore(current);
  SharedPreferencesStorePlatform.instance = store;
  return store;
}
