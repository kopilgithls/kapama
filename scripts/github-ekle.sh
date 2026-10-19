#!/usr/bin/env bash
# Yeni bir GitHub hesabını sisteme ekler (daha çok Actions dakikası için). Bu reponun kodunu
# yeni hesabın boş reposuna gönderir, sonra bağlantıyı panele ekler. Token panodan okunur,
# sohbete/ekrana düşmez. Her GitHub hesabı kendi 2000 dk/ay Actions hakkını getirir.
#
# Önce: yeni hesapta BOŞ bir ÖZEL repo aç (README ekleme). Sonra bu script'i çalıştır.
# Kullanım (repo kökünde, Git Bash): bash scripts/github-ekle.sh
set -uo pipefail

KOK="$(cd "$(dirname "$0")/.." && pwd)"
VARS="$KOK/web/.prod.vars"
[ -f "$VARS" ] || { echo "HATA: $VARS yok." >&2; exit 1; }
PANEL="https://hls-test-cyr.pages.dev"
J="$(mktemp)"; GOVDE="$(mktemp)"; trap 'rm -f "$J" "$GOVDE" 2>/dev/null || true' EXIT
val() { sed -n "s/^$1=//p" "$VARS"; }
jget() { node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(String(eval(process.argv[1])))}catch(e){process.exit(3)}})' "$1"; }
jstr() { node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$1"; }  # güvenli JSON string

command -v node >/dev/null || { echo "HATA: node bulunamadı." >&2; exit 1; }
command -v git  >/dev/null || { echo "HATA: git bulunamadı." >&2; exit 1; }

echo "Panele giriliyor..."
node -e 'require("fs").writeFileSync(process.argv[1],JSON.stringify({kullanici:process.argv[2],sifre:process.argv[3]}))' "$GOVDE" "$(val PANEL_KULLANICI)" "$(val PANEL_SIFRE)"
kod=$(curl -sS -o /dev/null -w '%{http_code}' -b "$J" -c "$J" -X POST -H 'x-hls: 1' -H 'content-type: application/json' --data-binary @"$GOVDE" "$PANEL/api/giris")
[ "$kod" = 200 ] || { echo "HATA: panel girişi başarısız ($kod)." >&2; exit 1; }

echo
read -rp "Yeni reponun tam adı (kullanici/repo, ör. yenihesap/hls-test): " REPO
REPO="$(printf '%s' "$REPO" | tr -d ' ' | sed 's#^https://github.com/##; s#\.git$##; s#/*$##')"
case "$REPO" in */*) : ;; *) echo "HATA: 'kullanici/repo' biçiminde yaz." >&2; exit 1 ;; esac
read -rp "Panelde görünecek ad (boş: ${REPO%%/*}): " AD; AD="${AD:-${REPO%%/*}}"

URL="https://github.com/settings/personal-access-tokens/new"
cat <<YONERGE

ÖNEMLİ: Tarayıcıda YENİ hesabına giriş yapmış ol (token o hesapta oluşmalı).
Token oluşturma sayfası açılıyor. Şunları seç:

  Repository access      : Only select repositories -> $REPO
  Repository permissions :
      Contents  : Read and write
      Actions   : Read and write
      Workflows : Read and write
      Variables : Read and write
  Account permissions    :
      Plan      : Read-only     (Actions dakikasını okumak için)

Generate token -> çıkan token'ı Copy ile KOPYALA (github_pat_ ile başlar).

YONERGE
powershell.exe -NoProfile -Command "Start-Process '$URL'" >/dev/null 2>&1 || echo "Tarayıcı açılamadı, elle aç: $URL"

read -rp "Token'ı kopyaladıysan Enter'a bas (ya da buraya yapıştır): " GIRILEN
TOKEN="$GIRILEN"
[ -n "$TOKEN" ] || TOKEN="$(powershell.exe -NoProfile -Command "Get-Clipboard" 2>/dev/null | tr -d '\r\n' || true)"
case "$TOKEN" in github_pat_*|ghp_*) : ;; *) echo "HATA: geçerli token görünmüyor (github_pat_ ile başlamalı)." >&2; exit 1 ;; esac

echo
echo "Kod yeni repoya gönderiliyor ($REPO)... (repo boş ve özel olmalı)"
if ! git -C "$KOK" push "https://x-access-token:${TOKEN}@github.com/${REPO}.git" HEAD:main 2>"$GOVDE.err"; then
  sed 's#x-access-token:[^@]*@#***@#g' "$GOVDE.err" >&2
  rm -f "$GOVDE.err"
  echo "HATA: push başarısız. Repo var mı, boş mu, token'da Contents: Read and write var mı?" >&2
  exit 1
fi
rm -f "$GOVDE.err"
echo "Kod gönderildi."

# Bağlantı panelde zaten var mı? (panelden elle eklenmiş olabilir)
repo_kucuk="$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')"
mevcut=$(curl -sS -b "$J" "$PANEL/api/githublar" | jget 'const g=JSON.parse(s).githublar.find(x=>x.repo&&x.repo.toLowerCase()==="'"$repo_kucuk"'");g?g.id:""' 2>/dev/null || true)
if [ -n "$mevcut" ]; then
  echo "Bağlantı panelde zaten var, token güncellenip yeniden doğrulanıyor (kaynak release kuruluyor)..."
  printf '{"token":%s}' "$(jstr "$TOKEN")" > "$GOVDE"
  yanit=$(curl -sS -b "$J" -X PATCH -H 'x-hls: 1' -H 'content-type: application/json' --data-binary @"$GOVDE" "$PANEL/api/githublar/$mevcut")
  ok=$(printf '%s' "$yanit" | jget 'JSON.parse(s).ok?"1":""' 2>/dev/null || true)
else
  echo "Panele bağlantı ekleniyor (GitHub'da deneniyor, kaynak release ve PANEL_ADRES kuruluyor)..."
  printf '{"ad":%s,"repo":%s,"token":%s}' "$(jstr "$AD")" "$(jstr "$REPO")" "$(jstr "$TOKEN")" > "$GOVDE"
  yanit=$(curl -sS -b "$J" -X POST -H 'x-hls: 1' -H 'content-type: application/json' --data-binary @"$GOVDE" "$PANEL/api/githublar")
  ok=$(printf '%s' "$yanit" | jget 'JSON.parse(s).id?"1":""' 2>/dev/null || true)
fi
if [ "$ok" != 1 ]; then
  echo "HATA: $(printf '%s' "$yanit" | jget 'JSON.parse(s).hata||s')" >&2
  exit 1
fi
echo "Bağlantı hazır."
# Doğrulama durumunu göster
curl -sS -b "$J" "$PANEL/api/githublar" | jget 'const g=JSON.parse(s).githublar.find(x=>x.repo&&x.repo.toLowerCase()==="'"$repo_kucuk"'");const k=g.kontroller;`Kontroller -> erisim:${k.erisim?"tamam":"eksik"} workflow:${k.workflow?"tamam":"eksik"} kaynak:${k.kaynak_release?"tamam":"eksik"} panel_adres:${k.panel_adres?"tamam":"eksik"}`'
echo

echo "Kullanım okunuyor..."; sleep 2
curl -sS -b "$J" "$PANEL/api/kullanim" | jget '
  const r=JSON.parse(s); const g=r.github.find(x=>x.repo && x.repo.toLowerCase()==="'"$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')"'");
  g ? (g.aylik_dakika!==null
    ? `Yeni hesap Actions: ${g.aylik_dakika} / ${g.aylik_limit} dk (aylik)`
    : `Eklendi ama dakika okunamadi: ${g.hata}`)
  : "Eklendi."'
echo
echo "Bitti. Artik panelden yuklenen videolar en bos GitHub hesabina dagilir."
echo "Panel: $PANEL/#/github"
