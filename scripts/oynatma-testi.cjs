// Uçtan uca test: panel girişi, video listesi, gömme oynatıcıda oynatma ve sarma,
// indirici taklidi (başlıksız liste/anahtar isteği 403 olmalı), kutudaki parçanın şifreli olması.
//
// Kullanım (repo kökünde): node scripts/oynatma-testi.cjs [slug]
// Panel şifresi web/.prod.vars'tan okunur. Playwright animasyon-atolyesi'nde kurulu.
const fs = require('fs');
const path = require('path');
const { chromium } = require(process.env.PLAYWRIGHT || 'C:/Users/Ben/animasyon-atolyesi/node_modules/playwright');

const PANEL = process.env.PANEL || 'https://hls-test-cyr.pages.dev';
const vars = fs.readFileSync(path.join(__dirname, '..', 'web', '.prod.vars'), 'utf8');
const al = (k) => (vars.match(new RegExp(`^${k}=(.*)$`, 'm')) || [])[1];
const istenen = process.argv[2];
const EKRAN = (process.env.TEMP || '.') + '/hls-oynatma.png';

(async () => {
  const browser = await chromium.launch({ executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true });
  const ctx = await browser.newContext();
  const api = ctx.request;
  const giris = await api.post(`${PANEL}/api/giris`, { headers: { 'x-hls': '1' }, data: { kullanici: al('PANEL_KULLANICI'), sifre: al('PANEL_SIFRE') } });
  if (!giris.ok()) throw new Error('Panel girişi: ' + giris.status());
  const { videolar } = await (await api.get(`${PANEL}/api/videolar`)).json();
  console.log('Panel videoları:', videolar.map((v) => `${v.slug} [${v.durum}${v.erisim ? ', ' + v.erisim : ''}] kutu ${v.kutu ? v.kutu.proje : '-'} @ ${v.hesap ? v.hesap.ad : '-'} / ${v.github.repo}`).join(' | '));
  const v = videolar.find((x) => (istenen ? x.slug === istenen : x.durum === 'hazir' && x.gomme));
  if (!v || !v.gomme) throw new Error('Gömme linki olan hazır video yok');
  console.log('Gömme linki:', v.gomme);

  // 1) İndirici taklidi: oturum başlığı olmadan liste ve anahtar
  const liste = await fetch(v.gomme + '/v.m3u8');
  const anahtar = await fetch(v.gomme + '/k');
  console.log(`Başlıksız istek: liste ${liste.status}, anahtar ${anahtar.status} (403 beklenir)`);

  // 2) Kutudaki parça şifreli mi? Açık MPEG-TS 0x47 ile başlar ve 188 baytta bir tekrar eder.
  const parca = new Uint8Array(await (await fetch(`https://${v.kutu.adres}/v/${v.slug}/p00000.ts`)).arrayBuffer());
  const acik = parca[0] === 0x47 && parca[188] === 0x47 && parca[376] === 0x47;
  console.log(`Kutudaki p00000.ts: ${parca.length} bayt, ${acik ? 'ŞİFRESİZ (sorun)' : 'şifreli'}`);
  const kutuListe = await (await fetch(`https://${v.kutu.adres}/v/${v.slug}/index.m3u8`)).text();
  console.log('Kutudaki listede anahtar satırı:', (kutuListe.match(/#EXT-X-KEY[^\n]*/) || ['yok'])[0]);

  // 3) Gerçek oynatma, iframe içinde (başka bir siteye gömülmüş gibi)
  const page = await ctx.newPage();
  const hatalar = [];
  page.on('console', (m) => { if (m.type() === 'error') hatalar.push(m.text()); });
  const istekler = [];
  page.on('response', (r) => istekler.push(`${r.status()} ${new URL(r.url()).host}${new URL(r.url()).pathname.replace(/\/e\/[^/]+/, '/e/…')}`));
  await page.setContent(`<!doctype html><body style="margin:0;background:#222"><iframe src="${v.gomme}?oto=1" width="960" height="540" allow="autoplay; fullscreen" allowfullscreen style="border:0"></iframe></body>`);
  const frame = await (await page.waitForSelector('iframe')).contentFrame();
  const t0 = Date.now();
  await frame.waitForFunction(() => { const x = document.getElementById('v'); return x && x.currentTime > 0.5 && !x.paused; }, null, { timeout: 30000 });
  console.log('Otomatik (sessiz) oynatma başladı:', Date.now() - t0, 'ms');
  const t1 = Date.now();
  const hedef = await frame.evaluate(() => {
    const x = document.getElementById('v');
    const h = Math.floor(Math.min(2400, x.duration * 0.8));
    x.currentTime = h;
    return h;
  });
  await frame.waitForFunction((h) => { const x = document.getElementById('v'); return x.currentTime > h + 1 && !x.paused; }, hedef, { timeout: 30000 });
  console.log(`${Math.floor(hedef / 60)}. dakikaya sarma:`, Date.now() - t1, 'ms');
  const durum = await frame.evaluate(() => { const x = document.getElementById('v'); return { boyut: `${x.videoWidth}x${x.videoHeight}`, sessiz: x.muted, hata: x.error && x.error.code, bilgi: document.getElementById('bilgi').hidden ? null : document.getElementById('bilgi').textContent }; });
  console.log('Oynatıcı:', JSON.stringify(durum));
  await page.screenshot({ path: EKRAN });
  const ozet = {};
  for (const s of istekler) { const k = s.replace(/p\d{5}\.ts/, 'pNNNNN.ts'); ozet[k] = (ozet[k] || 0) + 1; }
  console.log('İstekler:', Object.entries(ozet).map(([k, n]) => (n > 1 ? `${k} ×${n}` : k)).join(' | '));
  console.log('Konsol hataları:', hatalar.length ? hatalar.join(' | ') : 'yok');
  console.log('Ekran görüntüsü:', EKRAN);
  await browser.close();
})().catch((e) => { console.error('TEST HATASI:', e.message); process.exit(1); });
