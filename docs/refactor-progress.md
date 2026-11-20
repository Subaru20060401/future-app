# 再構築の進捗（再開用メモ）

会話が途切れても続きから再開できるように、段階・検証結果・次の作業を書く。
設計は `docs/architecture-plan.md`、調査は `docs/survey.md`。

## 基本情報

- 開始時のコミット: `84a1c780023cc3e8c0a001bfa353dc6f5c49ca09`
- 作業ブランチ: `claude/zen-heisenberg-xq1194`（push と main 向けの下書き PR は許可済み。マージ・公開はしない）
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
| 0 調査・設計 | 済み | `docs/survey.md`・`docs/architecture-plan.md`（GPT レビューへの採否も記載） |
| 1 時刻の注入・特性テスト | 済み `afde9ea` | 手計算 `test/forecast_hand_calc_test.dart`、回帰 `test/regression/` |
| 2 日付規則・データ型の分離 | 済み `e3db900` | `lib/finance/billing_dates.dart`、`lib/models/`、`test/architecture_test.dart` |
| 3 月の予想の一本化 | 済み `bbe4179` | `lib/finance/forecast.dart`、`AppState.forecastMonths` |
| 4 不具合の修正（B1・B2・B5〜B8） | 済み `049936d` | `test/persistence_test.dart`・`drive_push_pull_test.dart`・`expense_detail_sum_test.dart` |
| 5 確認済みの仕様修正（Q1〜Q3・Q6） | 済み `a75463d` | `expense_meaning_test.dart`・`pending_draws_rules_test.dart`・`bank_holiday_test.dart`。予想の行を実際の日付の月へ |
| 6 UI | 済み `89d8aa3` | `lib/ui/`・`lib/widgets/home_sections.dart`・`test/home_screen_test.dart` |
| 7 検証・引き継ぎ文書 | 済み | `docs/review-handoff.md`、CLAUDE.md 更新 |

## 公開前の確認（2026-11-20）

GPT の完了報告レビューの 4 点を再現し（`0e6398b`）、ユーザーの条件を反映して実装した。詳細は `docs/prepublish-review-plan.md`。

| 項目 | コミット |
|---|---|
| 1 確認待ちからの二重引き落とし | `692794a`（保存の失敗との組み合わせは `0fa2482`） |
| 2 請求の月と実際の引落日 | `441c102` |
| 4 カレンダーの引き落とし額 | `a6b94cd` |
| 3 保存の途中失敗からの回復 | `0fa2482` |
| 5 残りの UI（表記・色だけに頼らない・見た目） | `69843d9` |

## GPT 実装レビュー（83d9ca5）への対応（2026-11-20）

3 件（保存中のカード設定変更・取り込み中の編集の同期済み扱い・false の保存）を、受け取った再現テストを配置して修正。
詳細は `docs/review-handoff.md` §1.5。全履歴を取得してバンドルを作り直した。

## GPT 再レビュー（f5eef6e）の残件への対応（2026-11-20）

取り込み中は家計データの変更を止める（画面の覆い・AppState で断る・自動の処理は保留・二重の取り込みを断る・
先に走っていた保存を待つ）。詳細は `docs/review-handoff.md` §1.6、テストは `test/import_lock_test.dart`。

## 変更後の検証（最終）

- `flutter test`: 727 成功・2 スキップ（スキップは開始時と同じ）
- `flutter analyze lib/`: 50 件（すべて非推奨予告の info）
- `flutter build web --release --base-href /future-app/`: 成功
- ブラウザ（Chromium）: 全タブ・根拠シート・残高の書き直し・引き落としの反映シート・推移・カレンダーの印。コンソールエラー 0 件

## 次の作業

1. GPT の実装レビュー（`docs/review-handoff.md` を案内として使う。レビュー用のバンドルを作ってある）
2. 実環境の確認（Google ドライブの実際の読み書き、iOS/Android、実データでの見え方・保存の速さ）
3. 残っている課題は `docs/review-handoff.md` §9

## UI 確認の手順（再現用）

- `flutter build web --release --base-href /future-app/` のあと、`build/web` を `/future-app/` 配下で配信する小さな HTTP サーバーと
  Playwright で撮影した。CanvasKit は既定で gstatic から読むが、この環境では外へ出られないので、
  `build/web/canvaskit/` をそのまま返すようにリクエストを差し替えた
- データは架空の家計データ（勤務先「カフェ」、カード 3 枚、定期 2 件）を localStorage（`flutter.saved_*`）に入れて表示した。実データは使っていない
