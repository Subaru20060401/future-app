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

## GPT 再レビュー（6880887）の 2 件への対応（2026-11-20）

取り込み後の不足の通知を待つ前の判定で消さない（`_dataGeneration` で中身の置き換わりを知り、やり直す）、
取り込み中は背後の画面からフォーカスを外す（`ExcludeFocus`）。詳細は `docs/review-handoff.md` §1.7。

## GPT 再レビュー（f8a716c）への対応（2026-11-20）

給料日の通知を作っている間に取り込んだとき、取り込んだ中身でも要るかを判定してから記録する（要らなければ消す）。
詳細は `docs/review-handoff.md` §1.8。

## 2026-11-20 の追加の変更（main の 52fc1c2 から。PR #1 とは別の作業）

| 変更 | コミット | 主なテスト |
|---|---|---|
| 1 財布の現金を口座の予想に入れない・ATM で口座→財布 | `a242d47` | `wallet_forecast_test.dart`（回帰の記録を −2,000 円で記録し直し） |
| 2 定期支払いの開始月 | `b0063da` | `subscription_start_month_test.dart` |
| 3 カード明細を最初から新しい順 | `6887bc5` | `payment_header_test.dart` |
| 5 見本の提案を削除し、未承認の見本を片付ける | `a0d212e` | `sample_suggestion_cleanup_test.dart` |
| 4 カードのアイコン（既定のマーク・自分の画像） | `f491209` | `card_icon_test.dart`、Web で画像の選択・プレビュー・取り消し・既定に戻す・再読み込み後も同じアイコン |

ユーザーと決めたこと: ATM の引き出しで口座を減らし財布を増やす／公式ロゴは同梱せず既定のマーク／カレンダーの定期は今回変えない／
今月開始で支払日を過ぎて登録した定期は確認待ちに出す。新しい保存キーは `saved_card_icons`。

## 2026-11-25 日付が過ぎた支払い・入金の確認待ち（ユーザーの画面から）

予定支出（I Phone ¥83,000・11/24）が日付を過ぎても「いまの残高」から引かれず、確認待ちにも出なかった。さらに
予定入金を受け取ると基準日が進み、予想からも黙って消えた。同じ抜けが口座払いのローン（月々・頭金）と給料にもあった。
ユーザーと決めたこと: 予定支出・ローン・給料は確認待ちに出す（自動では引かない）／予定支出の「払った」は残高からも引く。
テストは `test/due_items_test.dart`（手計算）。

## 変更後の検証（最終）

- `flutter test`: 734 成功・2 スキップ（スキップは開始時と同じ）
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
