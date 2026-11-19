// 指定した時刻の静止画を撮る。ページのエラーや、読み込めなかった画像があれば、終了コード1で止まる。
// 使い方: Q='?theme=light' PAGE=index.html node still.mjs <作業フォルダー（絶対パス）> <時刻> [<時刻>...]
import { createRequire } from 'module';
import path from 'path';
const require = createRequire(import.meta.url);
const core = process.env.PLAYWRIGHT_CORE || process.env.HOME + '/.volta/tools/image/packages/@playwright/cli/lib/node_modules/@playwright/cli/node_modules/playwright-core';
const { chromium } = require(core);
const dir = path.resolve(process.argv[2]); const times = process.argv.slice(3).map(Number);
const b = await chromium.launch({ channel: 'chrome', args: ['--allow-file-access-from-files'] });
const p = await b.newPage({ viewport: { width: 1080, height: 1080 } });
let failed = false;
p.on('pageerror', e => { console.error('ページのエラー:', e.message); failed = true; });
await p.goto('file://' + dir + '/' + (process.env.PAGE || 'index.html') + (process.env.Q || ''), { timeout: 0 });
await p.evaluate(() => window.ready);
for (const t of times) {
  // 撮る前に画像のデコードを待つ。待たないと、読み込んだはずの画像が写らない
  const broken = await p.evaluate(async t => {
    window.render(t);
    const imgs = [...document.images].filter(i => i.getAttribute('src'));
    await Promise.all(imgs.map(i => i.decode().catch(() => {})));
    return imgs.filter(i => i.complete && i.naturalWidth === 0).map(i => i.getAttribute('src'));
  }, t);
  if (broken.length) { console.error(`読み込めなかった画像（${t}秒）:`, [...new Set(broken)].slice(0, 5)); failed = true; }
  await p.screenshot({ path: `${dir}/s_${t}.png` });
}
await b.close();
if (failed) process.exit(1);
