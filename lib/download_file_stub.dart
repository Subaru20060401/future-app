// 非Web（iOS/Android）ではブラウザのダウンロードは使わない。
// 呼び出し側は false を見て、従来の共有シート／テキスト表示にフォールバックする。
bool downloadTextFile(String fileName, String content, String mime) => false;
