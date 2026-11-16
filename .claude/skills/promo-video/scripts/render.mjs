// 60fps×4サブフレームのコマを、並列で撮る。ユーザーに書き出しを頼まれたときだけ使う。
// ページのエラーや、読み込めなかった画像があれば、終了コード1で止まる。
// 使い方: Q='?theme=light' nice -n 10 node render.mjs <作業フォルダー（絶対パス）> <秒> <空のコマのフォルダー> [並列数]
// 動画にまとめるとき: ffmpeg -framerate 240 -i <コマのフォルダー>/%05d.png -t <秒> -vf "tmix=frames=4:weights='1 1 1 1',fps=60" ...
import { createRequire } from 'module';
import path from 'path';
const require = createRequire(import.meta.url);
const core = process.env.PLAYWRIGHT_CORE || process.env.HOME + '/.volta/tools/image/packages/@playwright/cli/lib/node_modules/@playwright/cli/node_modules/playwright-core';
const { chromium } = require(core);
const [dir, dur, out] = [path.resolve(process.argv[2]), +process.argv[3], path.resolve(process.argv[4])];
// 並列数は3まで。8で動かしたとき、Chromeが中で使うスレッドが重なり、10コアのMacでロードアベレージが260になった
const n = Math.min(3, +process.argv[5] || 3);
const fps = 60, sub = 4, total = Math.round(dur * fps * sub);
const b = await chromium.launch({ channel: 'chrome', args: ['--allow-file-access-from-files'] });
let failed = false;
await Promise.all([...Array(n).keys()].map(async w => {
  const p = await (await b.newContext({ viewport: { width: 1080, height: 1080 } })).newPage();
  p.on('pageerror', e => { console.error('ページのエラー:', e.message); failed = true; });
  // 同時に読み込むと30秒の既定の制限を超えるので、制限をなくす
  await p.goto('file://' + dir + '/' + (process.env.PAGE || 'index.html') + (process.env.Q || ''), { timeout: 0 });
  await p.evaluate(() => window.ready);
  const per = Math.ceil(total / n), from = w * per, to = Math.min(total, from + per);
  for (let f = from; f < to && !failed; f++) {
    const broken = await p.evaluate(async t => {
      window.render(t);
      const imgs = [...document.images].filter(i => i.getAttribute('src'));
      await Promise.all(imgs.map(i => i.decode().catch(() => {})));
      return imgs.filter(i => i.complete && i.naturalWidth === 0).length;
    }, f / (fps * sub));
    if (broken) { console.error(`読み込めなかった画像が${broken}個（コマ${f}）`); failed = true; }
    await p.screenshot({ path: `${out}/${String(f).padStart(5, '0')}.png` });
  }
}));
await b.close();
if (failed) process.exit(1);
console.log(`コマ ${total} 枚`);
