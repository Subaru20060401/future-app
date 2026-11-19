# 再構築の進捗（再開用メモ）

会話が途切れても続きから再開できるように、段階・検証結果・次の作業を書く。
設計は `docs/architecture-plan.md`、調査は `docs/survey.md`。

## 基本情報

- 開始時のコミット: `84a1c780023cc3e8c0a001bfa353dc6f5c49ca09`
- 作業ブランチ: `claude/zen-heisenberg-xq1194`（push・公開はしない）
- 開始時の未コミット変更: なし
- 使った Flutter: 3.50.0 stable（`/opt/flutter-sdk/flutter/bin` に手で入れた。CI も stable）
- ⚠️ `flutter pub get` で `pubspec.lock` と `windows/flutter/generated_*` が書き換わる。ツールの再生成なのでコミットしない

## ベースライン（変更前）

- `flutter test`: 577 成功・2 スキップ
- `flutter analyze lib/`: 46 件（全部 Flutter 3.47 以降の非推奨予告の info）
- `flutter build web --release --base-href /future-app/`: 成功

## 段階

| 段階 | 状態 | メモ |
|---|---|---|
| 0 調査・設計 | 済み（GPT レビュー待ち） | `docs/survey.md`・`docs/architecture-plan.md` |
| 1 時刻の注入・特性テスト | 未着手 | |
| 2 日付規則・データ型の分離 | 未着手 | |
| 3 月の予想の一本化 | 未着手 | |
| 4 不具合の修正（B1・B2・B5〜B8） | 未着手 | |
| 5 確認済みの仕様修正（Q1〜Q3・Q6） | 未着手（回答待ち） | |
| 6 UI | 未着手 | |
| 7 検証・引き継ぎ文書 | 未着手 | |

## 次の作業

1. ユーザーから GPT のレビュー結果と §9 の質問への回答を受け取る
2. 指摘をコードと照合し、`architecture-plan.md` の「レビュー対応」に採用・不採用と根拠を書く
3. 段階 1 から実装

## UI 確認の手順（再現用）

- `flutter build web --release --base-href /future-app/` のあと、`build/web` を `/future-app/` 配下で配信する小さな HTTP サーバーと
  Playwright で撮影した。CanvasKit は既定で gstatic から読むが、この環境では外へ出られないので、
  `build/web/canvaskit/` をそのまま返すようにリクエストを差し替えた
- データは架空の家計データ（勤務先「カフェ」、カード 3 枚、定期 2 件）を localStorage（`flutter.saved_*`）に入れて表示した。実データは使っていない
