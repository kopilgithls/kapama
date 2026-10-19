#!/usr/bin/env node
// Cloudflare Pages'e doğrudan yükleme: wrangler 4.151.1 `pages deploy`'un yaptığının aynısı
// (src/pages/upload.ts, src/api/pages/deploy.ts, src/pages/constants.ts), tek farkla: yayının
// manifestine, yerelde olmayan ama Pages'te zaten yüklü dosyalar da (panelin sakladığı manifest)
// eklenebilir. Pages içerik özetiyle çalışır; yüklü özetler tekrar gönderilmez.
//
// Kullanım:
//   node scripts/pages-yayinla.mjs --account <id> --project <ad> --dir <yerel klasör>
//        [--manifest <dış manifest.json>] [--message "Kutu 01"] [--commit-hash <sha>]
//        [--out <yerel manifest.json>] [--ozet <özet.json>] [--sadece-denetle]
// Ortam: CLOUDFLARE_API_TOKEN, PAGES_NPM (blake3-wasm@2.1.5 ve mime@3.0.0'ın kurulu olduğu klasör)
//
// --sadece-denetle: yükleme ve yayın yapmaz; yerel dosyaların özetini Pages'e sorar, eksikleri yazar.
import fs from 'node:fs/promises';
import path from 'node:path';
import { createRequire } from 'node:module';
import { parseArgs } from 'node:util';

const require = createRequire(process.env.PAGES_NPM ? path.join(process.env.PAGES_NPM, 'paket.js') : import.meta.url);
const blake3 = require('blake3-wasm');   // wrangler'ın kullandığı
const mime = require('mime');            // mime@3.0.0, wrangler'ın pages validate'te kullandığı

// wrangler src/pages/constants.ts (Linux değerleri)
const MAX_ASSET_COUNT_DEFAULT = 20000;
const MAX_ASSET_SIZE = 25 * 1024 * 1024;
const MAX_BUCKET_SIZE = 40 * 1024 * 1024;
const MAX_BUCKET_FILE_COUNT = 2000;
const BULK_UPLOAD_CONCURRENCY = 3;
const MAX_UPLOAD_ATTEMPTS = 5;
const MAX_UPLOAD_GATEWAY_ERRORS = 5;
const MAX_DEPLOYMENT_ATTEMPTS = 3;
const MAX_DEPLOYMENT_STATUS_ATTEMPTS = 5;
const MAX_CHECK_MISSING_ATTEMPTS = 5;
const MAX_COMMIT_MESSAGE_BYTES = 384;           // src/api/pages/deploy.ts
const UNAUTHORIZED = 8000013, UNKNOWN_ERROR = 8000000;
// wrangler validate: yayına dosya olarak girmeyenler (_headers ve _redirects ayrı form alanı olarak gider)
const KOKTE_ATLA = new Set(['_worker.js', '_redirects', '_headers', '_routes.json', 'functions', '.wrangler']);
const HER_YERDE_ATLA = new Set(['.DS_Store', 'node_modules', '.git']);
const API = process.env.CF_API_TABAN || 'https://api.cloudflare.com/client/v4';   // testte sahte sunucu

const { values: arg } = parseArgs({
  options: {
    account: { type: 'string' }, project: { type: 'string' }, dir: { type: 'string' },
    manifest: { type: 'string' }, message: { type: 'string' }, 'commit-hash': { type: 'string' },
    out: { type: 'string' }, ozet: { type: 'string' }, 'sadece-denetle': { type: 'boolean' },
  },
});
const TOKEN = process.env.CLOUDFLARE_API_TOKEN;
function dur(mesaj) { console.error(`HATA: ${mesaj}`); process.exit(1); }
if (!arg.account || !arg.project || !arg.dir) dur('--account, --project ve --dir gerekli.');
if (!TOKEN) dur('CLOUDFLARE_API_TOKEN yok.');

const bekle = (ms) => new Promise((r) => setTimeout(r, ms));
const mib = (b) => (b / 1048576).toFixed(1).replace('.', ',');

// wrangler deploy-helpers/src/deploy/helpers/hash.ts
function ozetle(icerik, ad) {
  const uzanti = path.extname(ad).substring(1);
  return blake3.hash(icerik.toString('base64') + uzanti).toString('hex').slice(0, 32);
}

class ApiHatasi extends Error {
  constructor(mesaj, status, code) { super(mesaj); this.status = status; this.code = code; }
  gecitHatasi() { return [502, 503, 504, 524].includes(this.status); }   // APIError.isGatewayError
}

async function cf(yol, { method = 'GET', headers = {}, body } = {}) {
  let res;
  try {
    res = await fetch(API + yol, { method, headers: { Authorization: `Bearer ${TOKEN}`, ...headers }, body });
  } catch (e) {
    throw new ApiHatasi(`${method} ${yol}: bağlantı hatası (${e.cause?.code ?? e.message})`);
  }
  const metin = await res.text();
  let veri;
  try { veri = JSON.parse(metin); } catch {
    throw new ApiHatasi(`${method} ${yol}: HTTP ${res.status} ${metin.slice(0, 200)}`, res.status);
  }
  if (!veri.success) {
    const e = veri.errors?.[0];
    throw new ApiHatasi(`${method} ${yol}: ${e?.message ?? 'bilinmeyen hata'} (kod ${e?.code ?? res.status})`, res.status, e?.code);
  }
  return veri.result;
}

// deploy-helpers/src/deploy/helpers/jwt.ts
const jwtYuku = (t) => JSON.parse(Buffer.from(t.split('.')[1], 'base64').toString());
function jwtSuresiDoldu(t) { try { return jwtYuku(t).exp <= Date.now() / 1000; } catch { return true; } }

// src/pages/validate.ts: klasörü gezer, her dosyanın özetini çıkarır
async function gez(kok) {
  const dosyalar = new Map();
  async function yuru(dizin) {
    for (const ad of (await fs.readdir(dizin)).sort()) {
      const tam = path.join(dizin, ad);
      const goreli = path.relative(kok, tam).split(path.sep).join('/');
      if (KOKTE_ATLA.has(goreli) || HER_YERDE_ATLA.has(ad)) continue;
      const st = await fs.lstat(tam);
      if (st.isSymbolicLink()) continue;
      if (st.isDirectory()) { await yuru(tam); continue; }
      if (st.size > MAX_ASSET_SIZE) dur(`Pages en fazla 25 MiB'lık dosya kabul eder: ${goreli} ${mib(st.size)} MiB.`);
      dosyalar.set(goreli, {
        path: tam, sizeInBytes: st.size,
        contentType: mime.getType(goreli) || 'application/octet-stream',
        hash: ozetle(await fs.readFile(tam), goreli),
      });
      if (dosyalar.size % 1000 === 0) console.log(`Özet: ${dosyalar.size} dosya...`);
    }
  }
  await yuru(kok);
  return dosyalar;
}

function utf8Kes(metin, sinir) {   // truncateUtf8Bytes
  const b = Buffer.from(metin);
  if (b.length <= sinir) return metin;
  return b.subarray(0, sinir).toString('utf8').replace(/�+$/, '');
}

const projeYolu = `/accounts/${arg.account}/pages/projects/${arg.project}`;

async function ana() {
  const kok = path.resolve(arg.dir);
  const proje = await cf(projeYolu);
  if (proje.production_branch !== 'main') console.log(`Uyarı: ${arg.project} üretim dalı "${proje.production_branch}", yayın main'e gidiyor.`);

  const yereller = await gez(kok);
  const yerel = Object.fromEntries([...yereller].map(([ad, d]) => [`/${ad}`, d.hash]));
  let dis = {};
  if (arg.manifest) {
    dis = JSON.parse(await fs.readFile(arg.manifest, 'utf8'));
    for (const [k, v] of Object.entries(dis)) {
      if (!k.startsWith('/') || k.includes('..') || !/^[0-9a-f]{32}$/.test(v)) dur(`Dış manifestte geçersiz kayıt: ${k}`);
    }
  }
  const ortak = Object.keys(yerel).filter((k) => k in dis);
  if (ortak.length) console.log(`Uyarı: ${ortak.length} yol hem yerelde hem dış manifestte, yereldeki kullanılıyor (ör. ${ortak[0]}).`);
  const manifest = { ...dis, ...yerel };
  const toplam = Object.keys(manifest).length;
  const yerelBayt = [...yereller.values()].reduce((s, d) => s + d.sizeInBytes, 0);
  console.log(`${arg.project}: ${toplam} dosya (yerel ${yereller.size}, ${mib(yerelBayt)} MiB; panelden ${toplam - yereller.size})`);

  let jwt;
  const jwtAl = async () => (await cf(`${projeYolu}/upload-token`)).jwt;
  jwt = await jwtAl();
  let sinir = MAX_ASSET_COUNT_DEFAULT;
  try { const m = jwtYuku(jwt).max_file_count_allowed; if (typeof m === 'number') sinir = m; } catch {}
  if (toplam > sinir) dur(`${arg.project} ${toplam} dosya, Pages sınırı ${sinir}.`);

  const asset = (yol, body) => cf(`/pages/assets/${yol}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${jwt}` }, body: JSON.stringify(body),
  });

  // check-missing: bütün özetler (yereldekiler ve dış manifesttekiler)
  const ozetler = [...new Set(Object.values(manifest))];
  let eksik;
  for (let deneme = 0; ; deneme++) {
    try { eksik = await asset('check-missing', { hashes: ozetler }); break; } catch (e) {
      if (deneme >= MAX_CHECK_MISSING_ATTEMPTS) throw e;
      await bekle(2 ** deneme * 1000);
      if (e.code === UNAUTHORIZED || jwtSuresiDoldu(jwt)) jwt = await jwtAl();
    }
  }
  const eksikKume = new Set(eksik);
  const yerelOzet = new Set(Object.values(yerel));

  if (arg['sadece-denetle']) {
    for (const [ad, d] of yereller) console.log(`${eksikKume.has(d.hash) ? 'EKSİK ' : 'VAR   '} ${d.hash}  /${ad}`);
    console.log(`Denetim: ${ozetler.length} özet, ${eksik.length} eksik.`);
    process.exit(0);
  }

  // Dış manifestteki bir dosya Pages'te yoksa yükleyemeyiz: hangi videonun olduğunu söyle
  const disEksik = Object.entries(dis).filter(([k, v]) => eksikKume.has(v) && !yerelOzet.has(v) && !(k in yerel));
  if (disEksik.length) {
    const sluglar = [...new Set(disEksik.map(([k]) => k.match(/^\/v\/([^/]+)\//)?.[1] ?? k))];
    dur(`Pages'te bulunmayan ${disEksik.length} dosya panel manifestinde var, yerelde yok: ${sluglar.join(', ')}. ` +
      'Bu videolar yeniden işlenmeli (panelden "Yeniden işle").');
  }

  // Yükleme: wrangler'ın kova düzeni (büyükten küçüğe, 3 kova, 40 MiB, 2000 dosya)
  const gorulen = new Set();
  const yuklenecek = [...yereller.values()]
    .filter((d) => eksikKume.has(d.hash) && !gorulen.has(d.hash) && gorulen.add(d.hash))
    .sort((a, b) => b.sizeInBytes - a.sizeInBytes);
  const kovalar = Array.from({ length: BULK_UPLOAD_CONCURRENCY }, () => ({ files: [], remainingSize: MAX_BUCKET_SIZE }));
  let kayma = 0;
  for (const d of yuklenecek) {
    let kondu = false;
    for (let i = 0; i < kovalar.length; i++) {
      const k = kovalar[(i + kayma) % kovalar.length];
      if (k.remainingSize >= d.sizeInBytes && k.files.length < MAX_BUCKET_FILE_COUNT) {
        k.files.push(d); k.remainingSize -= d.sizeInBytes; kondu = true; break;
      }
    }
    if (!kondu) kovalar.push({ files: [d], remainingSize: MAX_BUCKET_SIZE - d.sizeInBytes });
    kayma++;
  }
  const doluKovalar = kovalar.filter((k) => k.files.length);
  const yukBayt = yuklenecek.reduce((s, d) => s + d.sizeInBytes, 0);
  const baslangic = Date.now();
  const kuyruk = { esZaman: BULK_UPLOAD_CONCURRENCY };
  let biten = 0, bitenBayt = 0, sonYuzde = -1;

  async function kovaYukle(kova) {
    let deneme = 0, gecit = 0;
    for (;;) {
      const govde = await Promise.all(kova.files.map(async (d) => ({
        key: d.hash, value: (await fs.readFile(d.path)).toString('base64'),
        metadata: { contentType: d.contentType }, base64: true,
      })));
      try { await asset('upload', govde); return; } catch (e) {
        if (deneme >= MAX_UPLOAD_ATTEMPTS) throw e;
        console.log(`Yükleme hatası, tekrar denenecek: ${e.message}`);
        await bekle(2 ** deneme * 1000);
        if (e instanceof ApiHatasi && e.gecitHatasi()) {
          kuyruk.esZaman = 1;
          await bekle(2 ** gecit * 5000);
          if (++gecit >= MAX_UPLOAD_GATEWAY_ERRORS) deneme++;
        } else if (e.code === UNAUTHORIZED || jwtSuresiDoldu(jwt)) {
          jwt = await jwtAl(); deneme++;
        } else deneme++;
      }
    }
  }

  if (doluKovalar.length) {
    console.log(`Yüklenecek: ${yuklenecek.length} dosya, ${mib(yukBayt)} MiB, ${doluKovalar.length} paket`);
    await new Promise((tamam, hata) => {
      let sira = 0, aktif = 0, durdu = false;
      const ilerle = () => {
        if (durdu) return;
        if (sira >= doluKovalar.length && aktif === 0) { tamam(); return; }
        while (aktif < kuyruk.esZaman && sira < doluKovalar.length) {
          const kova = doluKovalar[sira++];
          aktif++;
          kovaYukle(kova).then(() => {
            aktif--; biten += kova.files.length;
            bitenBayt += kova.files.reduce((s, d) => s + d.sizeInBytes, 0);
            const yuzde = Math.floor((bitenBayt / yukBayt) * 10) * 10;
            if (yuzde !== sonYuzde) { sonYuzde = yuzde; console.log(`Yükleniyor... %${yuzde} (${biten}/${yuklenecek.length})`); }
            ilerle();
          }, (e) => { durdu = true; hata(e); });
        }
      };
      ilerle();
    });
  }
  const sure = ((Date.now() - baslangic) / 1000).toFixed(1).replace('.', ',');
  console.log(`Yüklendi: ${yuklenecek.length} dosya, ${mib(yukBayt)} MiB, ${sure} sn (${ozetler.length - eksik.length} dosya Pages'te zaten vardı)`);

  // upsert-hashes: yayındaki bütün özetler (dış manifesttekiler de, bir sonraki yayında da "var" görünsünler)
  try { await asset('upsert-hashes', { hashes: ozetler }); } catch {
    await bekle(1000);
    if (jwtSuresiDoldu(jwt)) jwt = await jwtAl();
    try { await asset('upsert-hashes', { hashes: ozetler }); } catch (e) {
      console.log(`Uyarı: özetler güncellenemedi (${e.message}). Yayın etkilenmez, sonraki yükleme yavaşlayabilir.`);
    }
  }

  // Yayın: multipart, _headers ve _redirects ayrı dosya alanı
  const form = () => {
    const f = new FormData();
    f.append('manifest', JSON.stringify(manifest));
    f.append('branch', 'main');
    if (arg.message) f.append('commit_message', utf8Kes(arg.message, MAX_COMMIT_MESSAGE_BYTES));
    if (arg['commit-hash']) f.append('commit_hash', arg['commit-hash']);
    f.append('commit_dirty', 'false');
    for (const ozel of ['_headers', '_redirects']) {
      if (ozelDosya[ozel] !== undefined) f.append(ozel, new File([ozelDosya[ozel]], ozel));
    }
    return f;
  };
  const ozelDosya = {};
  for (const ozel of ['_headers', '_redirects']) {
    try { ozelDosya[ozel] = await fs.readFile(path.join(kok, ozel), 'utf8'); } catch {}
  }
  let yayin;
  for (let deneme = 0; ; ) {
    try { yayin = await cf(`${projeYolu}/deployments`, { method: 'POST', body: form() }); break; } catch (e) {
      if (e.code === UNKNOWN_ERROR && deneme < MAX_DEPLOYMENT_ATTEMPTS - 1) { await bekle(2 ** deneme++ * 1000); continue; }
      throw e;
    }
  }

  let asama, durum = 'belirsiz';
  for (let deneme = 0; deneme < MAX_DEPLOYMENT_STATUS_ATTEMPTS; deneme++) {
    await bekle(2 ** deneme * 1000);
    try { asama = (await cf(`${projeYolu}/deployments/${yayin.id}`)).latest_stage; } catch { continue; }
    if (asama?.status === 'failure') { durum = 'hata'; break; }
    if (asama?.name === 'deploy' && asama?.status === 'success') { durum = 'tamam'; break; }
  }
  if (durum === 'hata') {
    let satir = '';
    try {
      const kayit = await cf(`${projeYolu}/deployments/${yayin.id}/history/logs?size=10000000`);
      satir = kayit.data?.[kayit.total - 1]?.line ?? '';
    } catch {}
    dur(`Yayın başarısız (${asama?.name}): ${satir}`);
  }
  console.log(durum === 'tamam'
    ? `Yayın tamam: ${yayin.url}`
    : `Yayın gönderildi ama son durumu okunamadı: ${yayin.url}`);

  const ozet = { dosya: toplam, yerel_dosya: yereller.size, yerel_bayt: yerelBayt, yuklenen: yuklenecek.length,
    yuklenen_bayt: yukBayt, id: yayin.id, url: yayin.url, durum };
  if (arg.out) await fs.writeFile(arg.out, JSON.stringify(yerel));
  if (arg.ozet) await fs.writeFile(arg.ozet, JSON.stringify(ozet));
}

ana().catch((e) => dur(e.message));
