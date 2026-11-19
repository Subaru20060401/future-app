# ポケットメイド

シフト管理と家計予測の Flutter アプリ。バイトのシフトから収入を見積もり、
カード明細を Gmail から取り込んで、今月末・来月末・翌々月末の口座残高を予測する。

- 主に **Web 版**（GitHub Pages）で使う: https://subaru20060401.github.io/future-app/
- iOS アプリ版もあるが、無料の Personal Team 署名なので 7 日で失効する
- やりとりは日本語

## コマンド

```bash
flutter pub get
flutter test               # 変更したら必ず。お金の計算は特に
flutter analyze lib/
flutter run -d chrome
flutter build web --release --base-href /future-app/
```

`main` に push すると GitHub Actions（`.github/workflows/deploy-web.yml`）が
ビルドして Pages へ自動デプロイする。手作業のデプロイは無い。

iOS のビルドは macOS + Xcode でしかできない。Windows では Web と Android のみ。
実機更新に `flutter install` は使わない（アプリを一度消す＝端末内のデータが消える）。

## アーキテクチャ

- **サーバーも DB も無い。** GitHub Pages は静的ファイルを配るだけ。
  URL が公開されていても、他人が開くのは空のアプリ
- データは `SharedPreferences`（Web では localStorage、キーは `flutter.saved_*`）。
  **端末×ブラウザごとに完全に独立**している
- 端末間は Google ドライブの `appDataFolder` で同期する（`lib/drive_sync.dart`）
- 画面から使うデータ・計算の窓口は `lib/app_state.dart` の `AppState`。**画面は計算しない**
  （合計・規則の判定は AppState に置き、画面は受け取った値を出すだけ）
- 純粋な部品は AppState の外に置き、AppState から呼ぶ（画面からは直接呼ばない）:
  - `lib/models/`: データ型と JSON（`app_state.dart` から再 export。既存の import のままで使える）
  - `lib/finance/`: 日付の規則（`billing_dates.dart`）、予想の行と月（`forecast.dart`）
  - ⚠️ この 2 つは AppState・画面・外部サービス・Flutter を import しない。`DateTime.now()` も読まない
    （`test/architecture_test.dart` で固定）
- 「今日」は `AppState.clockNow()`。計算・判定で `DateTime.now()` を直接読まない（テストで時刻を固定するため）
- 見た目の決まりと共通部品は `lib/ui/`（`tokens.dart`・`components.dart`）。色だけで区別しない
- Google 連携（Gmail・Drive・Calendar）は `lib/gmail_service.dart` に集約。同じトークンを使う
- カレンダーは Google カレンダーの専用カレンダー「ポケットメイド」へ一方向で書き出す
  （`lib/google_calendar_sync.dart`）。iOS/Mac の純正カレンダーには端末側で Google アカウントを
  追加すれば届く。Apple 側の連携（`calendar_sync.dart`）は二重になるので繋いでいない

## お金の計算で壊してはいけないこと

どれも実際に踏んだもの。このアプリのバグは画面を壊さず **金額が静かに間違う** 形で出る。

- **二重計上ゲート**: 残高を手で書いた日（`balanceUpdatedAt`）より後の支出だけ予想から引く。
  ゲートは「残高の予想」だけに使う。履歴・推移・年間支出（利用月の支出）には使わない
- 金額は 3 つの意味を混ぜない（`docs/architecture-plan.md` §11）:
  ① 利用月の支出（`expenseBreakdownOf`）② 支払日の入出金 ③ 残高の予想（②のうちゲートより後）
- **予想の式は 1 か所**: 月末・内訳・日ごとの並び・最低残高・足りない日は、すべて `forecastMonths` の行から作る。
  足し引きを増やすときは `_forecastLinesOf` にだけ足す
- 予想の行は **実際の日付の月** に入れる（月末が休みで翌月にずれた引落は翌月の予想に入る）
- 銀行の休業日は土日祝＋年末年始（12/31〜1/3）。年末年始は `isBankHoliday` だけで、祝日（`isJapaneseHoliday`）には入れない
- 確認待ちの引き落とし（`pendingDraws`）は予想と同じ日付・金額の規則（`cardBillAmountOf`）。
  ただし予想のゲートでは消さない（処理したときだけ消える）
- 引き落としは「**n 月の引き落とし＝n-1 月の利用ぶん**」。
  ただし頭金・予定支出など **一度きりの出費は月ズレさせず、日付どおりの月に引く**（`oneTimeExpensesIn`）
- 締め日が月末以外のカードは `cardClosingPeriodOf` で締め期間ごとに集計する
- **分割払い・カード払いのローン/頭金は、そのカードの請求に合算する**（独立スライスにしない）。
  独立させると引き落とし日が根拠のない日付になり、カードごとの引き落としとズレる
- 口座払いのローンは 1 本ずつ独立したスライス（返済日が個別のため）
- 銀行の引落確定（`PaymentSource.bank`）が正本。確定済みの月は分割などを足さない
- Gmail 取り込みは **自動明細の作り直し方式**。1 件でも取得に失敗したら反映しない（`lastFetchFailures`）
- 作り直しで消えたり戻ったりしないための記録:
  `deletedSourceIds` / `deletedDupKeys`（削除した明細を復活させない）、
  `convertedSourceIds`（分割に移した明細をカードに戻さない）、
  `paymentNotes`（手書きの利用先メモを貼り直す）、
  `amazonCardOverrides`（Amazon 明細の付け替え）、`cardAliases`（銀行表記のカード名をまとめる）
- Amazon 明細は既定で Amazonマスター として計上。別のカードへ付け替えられる。
  付け替え先に同日・同額の明細があれば `infoOnly`（記録のみ）にする
- 既定のカードは `kSeedCardPaymentDays` を **初回起動時だけ** 書き込む。コードに焼き付けない。
  `importJson` は **置き換え**（マージすると別端末で消したものが復活する）
- **計算を直しても、既に作られた行は消えない。** 起動時・取り込み時に自己修復する処理を入れること。
  自己修復は `repairData()` の 1 か所（読込と `importJson` の両方が通る）。何度走らせても同じ結果にし、
  失った情報（予定の ID など）を推測で作らない
- 保存（`saveData`）はカードの引落日・締め日も毎回書く。`importJson` は保存の完了を待つ（`Future`）
- ドライブ同期は「新しい方で黙って上書き」しない。両方変わっていたら選ばせる（`decideSyncState`）。
  マージもしない

## Google 認証の落とし穴

- iOS（WebKit）では Google の JS ライブラリ（ポップアップ／FedCM）が動かない。
  `isPopupUnfriendly` のときはページ移動のリダイレクト方式（`lib/google_redirect_auth_web.dart`）
- `requestScopes` は失敗しても例外ではなく `false` を返すことがある。成功したときだけ return する
- ブラウザではリフレッシュトークンを発行できない。アクセストークン（約 1 時間）を保存して使い回す
- 連携の判定は **`isUsable`（実際に API を叩けるか）**。`isSignedIn` は iOS で永久に false なので使わない
- リダイレクト URI は `document.baseURI`（`https://subaru20060401.github.io/future-app/`）。
  Cloud Console の **「承認済みのリダイレクト URI」** 欄に登録する（「JavaScript 生成元」欄ではない）
- OAuth 同意画面は **「テスト」のまま**（`gmail.readonly` は制限付きスコープ）
- スコープを増やしたら: Cloud Console で API を有効化 → スコープを追加 → アプリで「連携し直す」

## Gmail API

- 1 分あたり 15,000 ユニット／ユーザー。list も get も 1 回 5 ユニット。
  並列で投げっぱなしにすると 403（Quota exceeded）で同期ごと落ちるので、30 回/秒に直列化している
- 解析結果をメール ID ごとにキャッシュ（`GmailCacheEntry`）。
  **パーサーを変えたら `_cacheKey` のバージョンを上げる**（古い解析結果が残るため）
- 通常の更新は先月 1 日から。過去 2 年分は設定から明示的に実行したときだけ
- 403 は原因が複数（スコープ不足／API 無効／クォータ）。エラー本文で切り分ける

## Gemini（シフト表の画像読み取り）

- `lib/gemini_client.dart`。本人の Google AI Studio の API キーでブラウザから直接呼ぶ
- キーは既定でメモリのみ。保存キーは `local_` 始まりで、書き出し・ドライブ同期・診断に含めない。URL に載せない
- 送るのは画像と名前・年月だけ。応答は `responseSchema` で JSON の形を決め、受け取ったあと自前でも検証し、
  確認画面を経てから登録する（拒否・途中終了なら 1 件も登録しない）
- **Google AI Plus などの契約は API には効かない**（プランの特典は AI Studio の画面内だけ。API キーの利用は別会計）
- ⚠️ **無料枠では送った内容が Google の改善に使われ、人が読むことがある。規約上、個人情報を送るべきでない。**
  シフト表には他のスタッフの名前が写るので、自分の行だけ切り抜いて送るのが安全。メール本文を送る機能は無料枠では作らない
- 請求先アカウントを紐づけると有料扱いになり、前払い残高が 0 円だと `402` で止まる（自動では無料枠に戻らない）。
  無料に戻すには Google Cloud でプロジェクトの課金を無効にする

## 未対応の課題

`docs/handoff.md` にまとめてある。作業を始める前に読むこと。
2026-11 の再構築（調査・設計・進捗・レビュー用の案内）は `docs/survey.md`・`docs/architecture-plan.md`・
`docs/refactor-progress.md`・`docs/review-handoff.md`。

## Web 固有

- Service Worker は新ビルドを見つけたら即切り替える（`web/index.html`）。
  設定の最下部にビルド時刻と SHA を出している。「反映されない」はまずここを見る
- `MaterialApp.builder` の中で `context.watch` しない。
  データが変わるたびに全体が作り直され、SnackBar が取り残されてタブバーが浮く。`Selector` を使う
- ボトムシートは `showAppSheet`（高さの上限＋スクロール）を使う。素の `Column` だと下が選べなくなる
- ファイル保存は `download_file.dart`、リダイレクト認証は `google_redirect_auth.dart`
  （どちらも Web と端末で実装を切り替える条件付きインポート）

## 開発の約束

- **public リポジトリ。** 秘密情報・個人情報（メールアドレスなど）をコミットしない
- コメントは日本語。意図は 💡、罠は ⚠️ で書く
- お金の計算を変えたら必ずテストを足す
- 金額の計算を変えたら、手計算のテスト（期待値をコメントの計算から書く）を足す。
  `test/regression/` の記録は「その時点の出力」で正しさの根拠ではない。意図して変えたときだけ
  `--dart-define=UPDATE_SNAPSHOT=true` で記録し直し、変わった項目と理由をコミットに書く
- **推測で直さない。** 「同期の状態を確認」（`authDiagnostics` など）で実際の値を見てから直す。
  推測で直して外れたことが何度もある
- コミットメッセージは日本語で、何が起きていて・なぜそう直したかを書く
