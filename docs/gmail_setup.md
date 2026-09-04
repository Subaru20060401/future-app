# Gmail連携 セットアップ手順

カード利用メールを自動取り込みするための **Google Cloud 設定**（あなたの手作業）。
コード側（OAuthログイン・メール取得・解析）は実装済みです。

---

## 1. Google Cloud プロジェクト作成
1. https://console.cloud.google.com/ にアクセス
2. 上部のプロジェクト選択 →「新しいプロジェクト」→ 名前 `PocketMaid` などで作成

## 2. Gmail API を有効化
1. 「APIとサービス」→「ライブラリ」
2. `Gmail API` を検索 →「有効にする」

## 3. OAuth同意画面の設定
1. 「APIとサービス」→「OAuth同意画面」
2. User Type: **External（外部）** を選択
3. アプリ名・サポートメール（自分のGmail）を入力
4. **スコープを追加** → `.../auth/gmail.readonly` を追加
5. **テストユーザー** に自分のGmailアドレス（grecotop555@gmail.com）を追加
   - テストモードのままで自分のアカウントは利用可能（審査不要）

## 4. iOS用 OAuthクライアントID を作成
1. 「APIとサービス」→「認証情報」→「認証情報を作成」→「OAuthクライアントID」
2. アプリケーションの種類: **iOS**
3. バンドルID: `com.example.myCounterApp`
4. 作成すると **iOS クライアントID** が発行される
   例: `123456789-abcdef.apps.googleusercontent.com`

## 5. Info.plist に反映
`ios/Runner/Info.plist` の2か所のプレースホルダを置き換える：

| プレースホルダ | 置き換える値 |
|----------------|--------------|
| `GIDClientID` の `YOUR_IOS_CLIENT_ID.apps.googleusercontent.com` | 発行されたクライアントID |
| URLスキームの `com.googleusercontent.apps.YOUR_IOS_CLIENT_ID` | **REVERSED_CLIENT_ID**（クライアントIDの逆順） |

REVERSED_CLIENT_ID は、クライアントID `123456789-abcdef.apps.googleusercontent.com` なら
`com.googleusercontent.apps.123456789-abcdef` の形式。

## 6. 実行
```bash
flutter run
```
設定タブ →「Gmail連携」→「Googleでログイン」→「カード利用メールを取得」

---

## 補足
- 対応カード: 三井住友 / 楽天カード / PayPayカード / メルカード（送信元・キーワードで検索）
- メール本文から **最大金額を請求額**、`M月D日` や `YYYY/MM/DD` を日付として抽出
- 解析結果は一覧表示され、**+ボタンで手動確認してから**支払いに追加（誤検出対策）
- 解析ルールは `lib/gmail_service.dart` の `_rules` / `_extractAmount` / `_extractDate` で調整可能
- Androidも使う場合は別途 Android用OAuthクライアント（SHA-1指紋）の作成が必要
