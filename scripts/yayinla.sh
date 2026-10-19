#!/usr/bin/env bash
# Yerel bilgisayardan çalışır (Git Bash). Videoyu sadece GitHub'a YÜKLER; çevirme, kutuya koyma
# ve yayın GitHub Actions'ta yapılır. Video panelde kendiliğinden görünür (Actions kaydeder).
# 2 GiB ve üstü dosyalar 1900 MiB'lık <ad>.part001, .part002... olarak gider (GitHub release
# dosyası 2 GiB'tan küçük olmalı); diskte bir anda tek parça durur.
#
# Kullanım:
#   bash scripts/yayinla.sh "D:/klasor/video.mp4" [auto|copy|encode]
#   bash scripts/yayinla.sh --sadece-yayinla [kutu]   # yeni video yok: kutuda olmayan kaynakları işler,
#                                                     # istenen kutuları ("1 3" ya da hepsi) yeniden yayınlar
# Ortam: HLS_REPO (varsayılan minoricin/hls-test)
set -euo pipefail

REPO="${HLS_REPO:-minoricin/hls-test}"
WF=hls.yml
IKI_GIB="${KAYNAK_TEK_SINIR:-$((2 * 1024 * 1024 * 1024))}"     # bundan küçük kaynak tek dosya (GitHub < 2 GiB)
PARCA_BAYT="${KAYNAK_PARCA_BAYT:-$((1900 * 1024 * 1024))}"  # büyük kaynağın parça boyu

calistir_ve_izle() {
  local once id=""
  once=$(gh run list -R "$REPO" -w "$WF" -L 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || true)
  gh workflow run "$WF" -R "$REPO" "$@"
  for _ in $(seq 30); do
    sleep 2
    id=$(gh run list -R "$REPO" -w "$WF" -L 1 --json databaseId -q '.[0].databaseId')
    [ -n "$id" ] && [ "$id" != "$once" ] && break
    id=""
  done
  [ -n "$id" ] || { echo "Başlatılan iş bulunamadı: https://github.com/$REPO/actions" >&2; exit 1; }
  echo "İş: https://github.com/$REPO/actions/runs/$id"
  if ! gh run watch "$id" -R "$REPO" --exit-status --interval 10; then
    echo "İş başarısız: https://github.com/$REPO/actions/runs/$id" >&2
    exit 1
  fi
  echo "Bitti: https://github.com/$REPO/actions/runs/$id"
}

# donustur.sh ile aynı: "Bölüm 5 (Final).MP4" -> "bolum-5-final"
slug() {
  local s="${1%.*}"
  s=$(printf '%s' "$s" | LC_ALL=C sed 's/ç/c/g; s/Ç/c/g; s/ğ/g/g; s/Ğ/g/g; s/ı/i/g; s/İ/i/g; s/ö/o/g; s/Ö/o/g; s/ş/s/g; s/Ş/s/g; s/ü/u/g; s/Ü/u/g')
  printf '%s' "$s" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'
}

# kaynak release'indeki dosyalar, sayfalı: id <TAB> boyut <TAB> tarih <TAB> ad
varliklar() {
  gh api --paginate "repos/$REPO/releases/$KAYNAK_ID/assets?per_page=100" --jq '.[] | [.id, .size, .created_at, .name] | @tsv'
}
parcalari() { # <ad>: <ad>.partNNN satırları
  awk -F'\t' -v on="$1.part" 'index($4, on) == 1 && substr($4, length(on) + 1) ~ /^[0-9]+$/'
}

if [ "${1:-}" = --sadece-yayinla ]; then
  calistir_ve_izle -f video= -f kutu="${2:-}"
  exit 0
fi

DOSYA="${1:?Kullanım: yayinla.sh <video> [auto|copy|encode]  ya da  yayinla.sh --sadece-yayinla [kutu]}"
MOD="${2:-auto}"
case "$MOD" in auto|copy|encode) ;; *) echo "Mod auto, copy ya da encode olmalı: $MOD" >&2; exit 1 ;; esac
[ -f "$DOSYA" ] || { echo "Dosya yok: $DOSYA" >&2; exit 1; }
boyut=$(stat -c %s "$DOSYA")
KAYNAK_ID=$(gh api "repos/$REPO/releases/tags/kaynak" --jq .id)

if [ "$boyut" -lt "$IKI_GIB" ]; then
  echo "Yükleniyor: $(basename "$DOSYA") ($((boyut / 1048576)) MB) -> $REPO kaynak"
  gh release upload kaynak "$DOSYA" -R "$REPO" --clobber
  # GitHub dosya adını değiştirebilir (boşluk -> nokta). Boyutu tutan en yeni dosyayı bul.
  ad=$(varliklar | awk -F'\t' -v b="$boyut" '$2 == b' | sort -t$'\t' -k3,3 | tail -n 1 | cut -f4)
  [ -n "$ad" ] || { echo "Yüklenen dosya kaynak release'inde bulunamadı." >&2; exit 1; }
else
  # Büyük dosya: adı kendimiz koyarız (GitHub parça adlarını değiştirmesin), panelin yaptığı gibi
  taban=$(basename "$DOSYA")
  ad=$(slug "$taban")
  [ -n "$ad" ] || { echo "Dosya adından adres adı çıkmadı: $taban" >&2; exit 1; }
  [[ "$taban" != *.* ]] || ad="$ad.$(printf '%s' "${taban##*.}" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  sayi=$(( (boyut + PARCA_BAYT - 1) / PARCA_BAYT ))
  # Yarım kalmış önceki denemeden ya da aynı adlı eski kaynaktan kalan parçalar silinir
  varliklar | parcalari "$ad" | cut -f1 | while read -r id; do
    gh api -X DELETE "repos/$REPO/releases/assets/$id" > /dev/null
  done
  echo "Yükleniyor: $taban ($((boyut / 1048576)) MB) -> $REPO kaynak, $sayi parça: $ad.part001..."
  gecici=$(mktemp -d)
  export REPO
  split -b "$PARCA_BAYT" -a 3 --numeric-suffixes=1 \
    --filter='cat > "$FILE" && echo "  ${FILE##*/}" && gh release upload kaynak "$FILE" -R "$REPO" --clobber && rm -f "$FILE"' \
    "$DOSYA" "$gecici/$ad.part"
  rmdir "$gecici"
  read -r n toplam < <(varliklar | parcalari "$ad" | awk -F'\t' '{ n++; s += $2 } END { print n + 0, s + 0 }')
  if [ "$n" -ne "$sayi" ] || [ "$toplam" -ne "$boyut" ]; then
    echo "Parçalar eksik yüklendi: $n/$sayi parça, $toplam/$boyut bayt. Tekrar çalıştırın." >&2
    exit 1
  fi
fi
echo "GitHub'daki adı: $ad"
calistir_ve_izle -f video="$ad" -f mod="$MOD"
