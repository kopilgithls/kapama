#!/usr/bin/env bash
# GitHub bağlantısının token'ını yeniler: tarayıcıda token oluşturma sayfasını açar, sen token'ı
# oluşturup kopyalarsın, script panodan alıp panele yazar ve kullanımı (Actions dakikası) gösterir.
# Aynı token hem hattı çalıştırır (Contents/Actions/Variables) hem de Actions dakikasını okur (Plan).
#
# Kullanım (repo kökünde, Git Bash): bash scripts/token-ayarla.sh
set -euo pipefail

KOK="$(cd "$(dirname "$0")/.." && pwd)"
VARS="$KOK/web/.prod.vars"
[ -f "$VARS" ] || { echo "HATA: $VARS yok." >&2; exit 1; }
PANEL="https://hls-test-cyr.pages.dev"
J="$(mktemp)"; trap 'rm -f "$J" "$GOVDE" 2>/dev/null || true' EXIT
GOVDE="$(mktemp)"
val() { sed -n "s/^$1=//p" "$VARS"; }

jget() { node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(String(eval(process.argv[1])))}catch(e){process.exit(3)}})' "$1"; }
api() { # <METHOD> <yol> [json-govde]
  local m="$1" yol="$2" veri="${3:-}"
  if [ -n "$veri" ]; then printf '%s' "$veri" > "$GOVDE"; fi
  curl -sS -b "$J" -c "$J" -X "$m" -H 'x-hls: 1' -H 'content-type: application/json' \
    ${veri:+--data-binary @"$GOVDE"} "$PANEL/api/$yol"
}

echo "Panele giriliyor..."
node -e 'require("fs").writeFileSync(process.argv[1],JSON.stringify({kullanici:process.argv[2],sifre:process.argv[3]}))' "$GOVDE" "$(val PANEL_KULLANICI)" "$(val PANEL_SIFRE)"
kod=$(curl -sS -o /dev/null -w '%{http_code}' -b "$J" -c "$J" -X POST -H 'x-hls: 1' -H 'content-type: application/json' --data-binary @"$GOVDE" "$PANEL/api/giris")
[ "$kod" = 200 ] || { echo "HATA: panel girişi başarısız ($kod). Şifre web/.prod.vars'ta güncel mi?" >&2; exit 1; }

# GitHub bağlantısını seç (tek bağlantı varsa onu, yoksa sor)
baglantilar=$(api GET githublar)
sayi=$(printf '%s' "$baglantilar" | jget 'JSON.parse(s).githublar.length')
[ "$sayi" -ge 1 ] || { echo "HATA: panelde GitHub bağlantısı yok. Önce panelden ekle." >&2; exit 1; }
printf '%s' "$baglantilar" | jget 'JSON.parse(s).githublar.map((g,i)=>`  ${i+1}) ${g.ad}  (${g.repo})  token ${g.token_ipucu}`).join("\n")'
echo
if [ "$sayi" = 1 ]; then secim=1; else read -rp "Hangi bağlantı? (1-$sayi): " secim; fi
GID=$(printf '%s' "$baglantilar" | jget "String(JSON.parse(s).githublar[$secim-1].id)")
REPO=$(printf '%s' "$baglantilar" | jget "JSON.parse(s).githublar[$secim-1].repo")
[ -n "$GID" ] || { echo "HATA: geçersiz seçim." >&2; exit 1; }

URL="https://github.com/settings/personal-access-tokens/new"
cat <<YONERGE

GitHub token oluşturma sayfası tarayıcıda açılıyor. Orada şunları seç:

  Token name            : hls-test paneli
  Expiration            : dilediğin süre (ör. 1 yıl ya da No expiration)
  Repository access     : Only select repositories -> $REPO
  Repository permissions:
      Contents          : Read and write
      Actions           : Read and write
      Workflows         : Read and write
      Variables         : Read and write
      (Metadata otomatik Read olur)
  Account permissions:
      Plan              : Read-only        <-- Actions dakikasını okumak için şart

Sonra en altta "Generate token" -> çıkan token'ı "Copy" ile KOPYALA.
(Token github_pat_ ile başlar ve bir daha gösterilmez.)

YONERGE

# Varsayılan tarayıcıda (senin oturumlu Chrome'un) aç
powershell.exe -NoProfile -Command "Start-Process '$URL'" >/dev/null 2>&1 || {
  echo "Tarayıcı otomatik açılamadı. Elle aç: $URL"; }

read -rp "Token'ı oluşturup kopyaladın mı? Panodan alayım, Enter'a bas (ya da token'ı yapıştırıp Enter): " GIRILEN

TOKEN="$GIRILEN"
if [ -z "$TOKEN" ]; then
  TOKEN=$(powershell.exe -NoProfile -Command "Get-Clipboard" 2>/dev/null | tr -d '\r\n' || true)
fi
case "$TOKEN" in
  github_pat_*|ghp_*) : ;;
  *) echo "HATA: geçerli bir token görünmüyor (github_pat_ ile başlamalı). Tekrar kopyalayıp çalıştır." >&2; exit 1 ;;
esac

echo "Token panele yazılıyor ve GitHub'da deneniyor..."
yanit=$(api PATCH "githublar/$GID" "$(node -e 'process.stdout.write(JSON.stringify({token:process.argv[1]}))' "$TOKEN")")
if [ "$(printf '%s' "$yanit" | jget 'JSON.parse(s).ok?"1":""' 2>/dev/null || true)" != 1 ]; then
  echo "HATA: $(printf '%s' "$yanit" | jget 'JSON.parse(s).hata||s')" >&2
  echo "İzinleri (özellikle Contents/Actions/Variables) kontrol edip tekrar dene." >&2
  exit 1
fi
echo "Token güncellendi."

echo "Kullanım okunuyor (birkaç saniye)..."
sleep 2
api GET kullanim | jget '
  const r=JSON.parse(s); const g=r.github.find(x=>String(x.github_id)==="'"$GID"'");
  g ? (g.aylik_dakika!==null
    ? `Actions bu ay: ${g.aylik_dakika} / ${g.aylik_limit} dk (aylik), kalan ${g.aylik_limit-g.aylik_dakika} dk`
    : `Hala okunamadi: ${g.hata}  (token Plan: Read iznine sahip mi?)`)
  : "Baglanti bulunamadi."'
echo
echo "Bitti. Panelde GitHub sayfasında da görebilirsin: $PANEL/#/github"
