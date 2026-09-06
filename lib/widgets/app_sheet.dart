// 💡 ボトムシートの共通の入れ物。
//   中身が画面に収まらないとスクロールできず、下の項目が選べなくなる
//   （iPhoneのようにブラウザのバーで縦が狭い端末で起きやすい）。
//   高さに上限を設けてスクロールできるようにし、下端はSafeAreaで確保する。
import 'package:flutter/material.dart';

Future<T?> showAppSheet<T>(BuildContext context, WidgetBuilder builder,
    {bool dragHandle = false}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true, // 画面の高さいっぱいまで使えるようにする
    showDragHandle: dragHandle,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        // 画面いっぱいにすると背景が見えず、閉じ方が分からなくなるので少し残す
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.85,
        ),
        child: SingleChildScrollView(child: builder(ctx)),
      ),
    ),
  );
}
