#!/usr/bin/env bash
# GitHub Actions: kutuları yeniden yayınlar (video silindiğinde, elle istendiğinde). Yeni dosya yok:
# yayın, kutudaki videoların panelde saklanan manifestleriyle yapılır, silinen videolar listeden
# düştüğü için kutudan da kalkar. Eski düzendeki (tar) videolar bu sırada manifeste taşınır.
# Bir kutudaki hata diğerlerini durdurmaz, sonda iş başarısız olur.
#
# Ortam: KUTULAR ("1 3", "hepsi" ya da boş), YAPILDI (bu işte zaten yayınlanmış kutular, atlanır),
#        PANEL_ADRES, GH_TOKEN, GITHUB_REPOSITORY, GITHUB_SHA, PAGES_NPM
set -euo pipefail

KUTULAR="${KUTULAR:-}"
YAPILDI=" ${YAPILDI:-} "
export GH_REPO="${GH_REPO:-$GITHUB_REPOSITORY}"
BURASI="$(cd "$(dirname "$0")" && pwd)"
. "$BURASI/panel.sh"
. "$BURASI/kutu.sh"

# Kutu numaraları: "hepsi" bu GitHub bağlantısının bütün kutuları; "01" ile "1" aynı, tekrarlar atılır
liste=""
for k in $KUTULAR; do
  case "$k" in
    hepsi) liste+=" $(panel GET /api/ci/kutular | jq -r '.kutular[]' | tr '\n' ' ')" ;;
    *[!0-9]*) echo "::warning::Geçersiz kutu numarası atlandı: $k" ;;
    *) liste+=" $((10#$k))" ;;
  esac
done
KUTULAR=""
for k in $(printf '%s\n' $liste | sort -nu); do
  if [[ "$YAPILDI" == *" $k "* ]]; then echo "Kutu $k bu işte zaten yayınlandı."; else KUTULAR+="$k "; fi
done
KUTULAR="${KUTULAR% }"
echo "Yayınlanacak kutular: ${KUTULAR:-yok}"
[ -n "$KUTULAR" ] || exit 0

calisma_koku
basarisiz=0
for no in $KUTULAR; do
  echo "::group::Kutu $no"
  set +e
  ( set -e; kutu_dagit "$no"; kutu_bitir "$no" )
  rc=$?
  set -e
  rm -rf "$KOK"/kutu-*
  echo "::endgroup::"
  if [ "$rc" -ne 0 ]; then
    echo "::error::Kutu $no yayınlanamadı."
    basarisiz=$((basarisiz + 1))
  fi
done

if [ "$basarisiz" -gt 0 ]; then
  echo "HATA: $basarisiz kutu yayınlanamadı." >&2
  exit 1
fi
