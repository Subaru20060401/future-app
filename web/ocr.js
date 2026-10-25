// 💡 端末の中で、画像の文字（数字と「:」だけ）を位置つきで読む（シフト画面のスクリーンショット用）。
//   画像はどこにも送らない（ブラウザの中の Web Worker で読む）。AIは使わない。
//   読み取りの部品（tesseract.js と英数字の学習データ）は、初めて使うときにだけ CDN から読み込む
//   （普段のアプリの表示を重くしないため。2回目からはブラウザのキャッシュが使われる）。
(function () {
  var loading = null;

  function load() {
    if (window.Tesseract) return Promise.resolve();
    if (loading) return loading;
    loading = new Promise(function (resolve, reject) {
      var s = document.createElement('script');
      // ⚠️ 版を固定する（勝手に新しい版に変わって動きが変わらないように）
      s.src = 'https://cdn.jsdelivr.net/npm/tesseract.js@5.1.1/dist/tesseract.min.js';
      s.onload = function () { resolve(); };
      s.onerror = function () {
        loading = null;
        reject(new Error('文字読み取りの部品を読み込めませんでした。電波の良い場所でもう一度お試しください'));
      };
      document.head.appendChild(s);
    });
    return loading;
  }

  // bytes: Uint8Array（画像ファイルの中身）。
  // 戻り値: {w, h, words:[{t, x0, y0, x1, y1}]} のJSON文字列（w・hは画像の幅・高さ）
  window.pocketOcrDigits = async function (bytes) {
    await load();
    var blob = new Blob([bytes]);
    var size = { w: 0, h: 0 };
    try {
      var bmp = await createImageBitmap(blob);
      size = { w: bmp.width, h: bmp.height };
      bmp.close();
    } catch (e) { /* 幅が分からなくても読み取りは続ける */ }
    var worker = await window.Tesseract.createWorker('eng');
    try {
      await worker.setParameters({
        tessedit_char_whitelist: '0123456789:',
        tessedit_pageseg_mode: '11', // まばらな文字（カレンダーのマス）向け
      });
      var r = await worker.recognize(blob);
      var words = (r.data.words || []).map(function (w) {
        return { t: w.text, x0: w.bbox.x0, y0: w.bbox.y0, x1: w.bbox.x1, y1: w.bbox.y1 };
      });
      return JSON.stringify({ w: size.w, h: size.h, words: words });
    } finally {
      await worker.terminate();
    }
  };
})();
