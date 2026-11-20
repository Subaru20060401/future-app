// 💡 金額の数字を桁区切りにする（¥12000 と ¥12,000 が画面ごとに混ざらないように）。
//   「¥」や「+」「−」は呼ぶ側の文のまま残し、数字の部分だけをここで整える。
import 'package:intl/intl.dart';

final NumberFormat _yen = NumberFormat.decimalPattern('ja');

String yenNum(num amount) => _yen.format(amount);

/// 💡 画面に出す金額の表記は、ここ 1 か所で決める。
///   ¥12,000 ／ −¥12,000（マイナスは記号「−」を ¥ の前に）／ signed: true なら +¥12,000
///   ⚠️ 以前は「¥ 85,000」「¥85,000」「-¥」「−¥」が画面ごとに混ざっていた。
String yen(int amount, {bool signed = false}) {
  final n = _yen.format(amount.abs());
  if (amount < 0) return '−¥$n';
  if (signed && amount > 0) return '+¥$n';
  return '¥$n';
}

/// 読み上げ用（「マイナス」「プラス」を言葉で）
String yenSpoken(int amount, {bool signed = false}) =>
    '${amount < 0 ? 'マイナス' : (signed && amount > 0 ? 'プラス' : '')}${_yen.format(amount.abs())}円';
