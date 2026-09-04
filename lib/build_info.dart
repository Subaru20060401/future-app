// 💡 動いているビルドを画面から確認できるようにする。
//   「直したのに反映されない」がキャッシュのせいなのかバグなのかを切り分けるため、
//   設定の一番下にこの情報を出している。
//   値は CI が --dart-define で埋め込む（ローカルビルドは 開発版 のまま）。
const String kBuildTime = String.fromEnvironment('BUILD_TIME', defaultValue: '');
const String kBuildSha = String.fromEnvironment('BUILD_SHA', defaultValue: '');

String get buildLabel {
  if (kBuildTime.isEmpty && kBuildSha.isEmpty) return '開発版（ローカルビルド）';
  final sha = kBuildSha.isEmpty ? '' : ' (${kBuildSha.substring(0, 7)})';
  return '$kBuildTime$sha';
}
