// 💡 金額の数字を桁区切りにする（¥12000 と ¥12,000 が画面ごとに混ざらないように）。
//   「¥」や「+」「−」は呼ぶ側の文のまま残し、数字の部分だけをここで整える。
import 'package:intl/intl.dart';

final NumberFormat _yen = NumberFormat.decimalPattern('ja');

String yenNum(num amount) => _yen.format(amount);
