// Gerçek panelde arayüz testi: giriş, Videolar (erişim kontrolü), Önizle penceresinde oynatma,
// Paylaş kodu, diğer sayfalar. Dosya verilirse panelden yükler ve "Yüklendi"yi bekler.
//
// Kullanım (repo kökünde): node scripts/panel-testi.cjs [yuklenecek-dosya]
// Şifre web/.prod.vars'tan okunur. Ekran görüntüleri %TEMP%\hls-panel-*.png
const fs = require('fs');
const path = require('path');
const { chromium } = require(process.env.PLAYWRIGHT || 'C:/Users/Ben/animasyon-atolyesi/node_modules/playwright');

const PANEL = process.env.PANEL || 'https://hls-test-cyr.pages.dev';
const vars = fs.readFileSync(path.join(__dirname, '..', 'web', '.prod.vars'), 'utf8');
const al = (k) => (vars.match(new RegExp(`^${k}=(.*)$`, 'm')) || [])[1];
const dosya = process.argv[2];
const ekran = (ad) => path.join(process.env.TEMP || '.', `hls-panel-${ad}.png`);

(async () => {
  const browser = await chromium.launch({ executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true });
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  const hatalar = [];
  page.on('console', (m) => { if (m.type() === 'error' && !/status of 401/.test(m.text())) hatalar.push(m.text()); });
  page.on('pageerror', (e) => hatalar.push('pageerror: ' + e.message));

  await page.goto(PANEL);
  await page.waitForSelector('#giris:not([hidden])');
  await page.fill('#giris-kullanici', al('PANEL_KULLANICI'));
  await page.fill('#giris-sifre', al('PANEL_SIFRE'));
  await page.click('#giris-dugme');
  await page.waitForSelector('#uygulama:not([hidden])');
  await page.waitForSelector('table.videolar');
  await page.waitForTimeout(4000); // erişim kontrolü
  const satirlar = await page.locator('table.videolar tbody tr').allInnerTexts();
  console.log('Videolar:\n  ' + satirlar.map((s) => s.replace(/\s+/g, ' ').slice(0, 220)).join('\n  '));
  await page.screenshot({ path: ekran('videolar'), fullPage: true });

  // Önizle: iframe içindeki oynatıcı oynuyor mu?
  const hazir = page.locator('table.videolar tbody tr', { hasText: 'Hazır' }).first();
  await hazir.locator('button', { hasText: 'Önizle' }).click();
  const cerceve = await (await page.waitForSelector('dialog.modal[open] iframe')).contentFrame();
  await cerceve.waitForSelector('#v');
  await cerceve.evaluate(() => { const v = document.getElementById('v'); v.muted = true; return v.play(); });
  await cerceve.waitForFunction(() => document.getElementById('v').currentTime > 1, null, { timeout: 30000 });
  console.log('Önizleme oynuyor:', JSON.stringify(await cerceve.evaluate(() => { const v = document.getElementById('v'); return { t: +v.currentTime.toFixed(1), boyut: `${v.videoWidth}x${v.videoHeight}` }; })));
  await page.screenshot({ path: ekran('onizle') });
  await page.locator('dialog.modal[open] .modal-bas button').click();

  // Paylaş kodu
  await hazir.locator('button', { hasText: 'Paylaş' }).click();
  const kod = await (await page.waitForSelector('dialog.modal[open] textarea')).inputValue();
  console.log('iframe kodu:', kod.replace(/\s+/g, ' ').slice(0, 260));
  await page.screenshot({ path: ekran('paylas') });
  await page.locator('dialog.modal[open] .modal-bas button').click();

  for (const s of ['kutular', 'hesaplar', 'github', 'ayarlar', 'yukle']) {
    await page.click(`.menu a[data-sayfa="${s}"]`);
    await page.waitForTimeout(2500);
    if (s === 'github') {
      await page.locator('.kart').first().locator('button', { hasText: 'Son işler' }).click();
      await page.waitForSelector('.isler table', { timeout: 15000 });
    }
    console.log(`${s}: ${(await page.locator('main').innerText()).replace(/\s+/g, ' ').slice(0, 300)}`);
    await page.screenshot({ path: ekran(s), fullPage: true });
  }

  if (dosya) {
    const t0 = Date.now();
    await page.setInputFiles('#dosya-girdi', dosya);
    await page.waitForSelector('.secilen-dosya');
    await page.locator('button', { hasText: 'Yüklemeyi başlat' }).click();
    await page.waitForSelector('.basari', { timeout: 15 * 60e3 });
    console.log('Panelden yükleme bitti:', Math.round((Date.now() - t0) / 1000), 'sn ·', (await page.locator('.basari').innerText()).replace(/\s+/g, ' '));
    await page.screenshot({ path: ekran('yuklendi'), fullPage: true });
  }
  console.log('Konsol hataları:', hatalar.length ? hatalar.join(' | ') : 'yok');
  await browser.close();
})().catch((e) => { console.error('TEST HATASI:', e.message); process.exit(1); });
