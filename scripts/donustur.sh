#!/usr/bin/env bash
# GitHub Actions: "kaynak" release'indeki videoları şifreli HLS'e çevirir ve her birini hemen
# panelin seçtiği kutuya (Pages projesi) yayınlar. HLS paketleri GitHub'da tutulmaz; kutudaki
# her videonun Pages manifesti panelde saklanır. Kayıt yeri paneldir (web/API.md "CI API").
# Bir videodaki hata diğerlerini durdurmaz.
#
# Kaynak: "kaynak" release'inde <ad> ya da <ad>.part001, .part002... (panelden 90 MiB'lık,
# yayinla.sh'tan 1900 MiB'lık parçalar). Parçalar sırayla inip tek dosyada birleşir.
#
# Ortam: VIDEO (boşsa ve KUTU da boşsa: hiçbir kutuda yayında olmayan, parçalı olmayan bütün kaynaklar),
#        KUTU (iş girdisi; video boş ve kutu doluysa sadece kutu yayını istenmiştir), MOD (auto|copy|encode),
#        YENIDEN (true: kutuda olsa da yeniden üret), PANEL_ADRES, GH_TOKEN, PAGES_NPM,
#        GITHUB_RUN_ID, GITHUB_SERVER_URL, GITHUB_REPOSITORY, GITHUB_SHA
# Çıktı: GITHUB_OUTPUT'a kutular="1 3" (bu işte yayınlanan kutular)
set -euo pipefail

VIDEO="${VIDEO:-}"
KUTU="${KUTU:-}"
MOD="${MOD:-auto}"
YENIDEN="${YENIDEN:-false}"
export GH_REPO="${GH_REPO:-$GITHUB_REPOSITORY}"
RUN_ID="$GITHUB_RUN_ID"
RUN_URL="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
BURASI="$(cd "$(dirname "$0")" && pwd)"
IKI_GIB="${KAYNAK_TEK_SINIR:-$((2 * 1024 * 1024 * 1024))}"     # bundan küçük kaynak tek dosya (GitHub < 2 GiB)
PARCA_BAYT="${KAYNAK_PARCA_BAYT:-$((1900 * 1024 * 1024))}"  # büyük kaynağın parça boyu
. "$BURASI/panel.sh"
. "$BURASI/kutu.sh"

calisma_koku
IS="$KOK/is"                    # girdi ve HLS çıktısı
ANAHTARLAR="$KOK/anahtar"       # IS'in dışında: anahtar asla yayına girmez
KUTU_LISTESI="$KOK/kutular"     # alt kabuklar buraya yazar
ADIM="$KOK/adim"                # hata olursa panele gidecek kısa açıklama
export PANEL_HATA_DOSYASI="$KOK/panel-hata"
: > "$KUTU_LISTESI"

# Dosya adından adres dostu kısa ad: "Bölüm 5 (Final).MP4" -> "bolum-5-final" (paneldeki JS ile aynı).
# Yerel ayardan bağımsız: Türkçe harfler bayt dizisi olarak tek tek değişir, kalan ASCII dışı her şey "-".
slug() {
  local s="${1%.*}"
  s=$(printf '%s' "$s" | LC_ALL=C sed 's/ç/c/g; s/Ç/c/g; s/ğ/g/g; s/Ğ/g/g; s/ı/i/g; s/İ/i/g; s/ö/o/g; s/Ö/o/g; s/ş/s/g; s/Ş/s/g; s/ü/u/g; s/Ü/u/g')
  printf '%s' "$s" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'
}

# <ad>.partNNN dosyaları, numara sırasıyla: [{id, name, size, n}]
PARCA_JQ='[.assets[] | select(.name | startswith($on)) | . + {n: (.name | ltrimstr($on))}
  | select(.n | test("^[0-9]+$")) | .n |= tonumber] | sort_by(.n)'

adim() { printf '%s' "$1" > "$ADIM"; }   # sıradaki adım başarısız olursa panele gidecek metin

# /api/ci/video gövdesi: <ad> <slug> <durum> [ek alanlar json]
video_govde() {
  local ek="${4:-}"
  [ -n "$ek" ] || ek='{}'
  jq -nc --arg kaynak_ad "$1" --arg slug "$2" --arg baslik "${1%.*}" --arg durum "$3" \
    --argjson run_id "$RUN_ID" --arg run_url "$RUN_URL" --argjson ek "$ek" \
    '{kaynak_ad: $kaynak_ad, slug: $slug, baslik: $baslik, durum: $durum, run_id: $run_id, run_url: $run_url} + $ek'
}

# Panelden 90 MiB'lık parçalarla gelen kaynağı kalıcı biçime getirir: 2 GiB'tan küçükse tek dosya,
# değilse 1900 MiB'lık .partNNN. Yeni parçalar önce geçici adla (.yeniNNN) yüklenir, eski parçalar
# ancak hepsi yerine oturunca silinir; diskte bir anda tek parça durur (split --filter).
kaynak_derle() { # <yerel dosya> <ad> <eski parçalar json>
  local f="$1" ad="$2" eski="$3" boyut varliklar yeni sayi toplam id n
  boyut=$(stat -c %s "$f")
  mkdir -p "$IS/yukle"
  if [ "$boyut" -lt "$IKI_GIB" ]; then
    mv "$f" "$IS/yukle/$ad"
    gh release upload kaynak "$IS/yukle/$ad" --clobber
    rm -f "$IS/yukle/$ad"
    varliklar=$(release_varliklari kaynak)
    [ "$(jq --arg ad "$ad" '[.assets[] | select(.name == $ad) | .size] | first // 0' <<< "$varliklar")" = "$boyut" ] ||
      { echo "HATA: birleşik kaynak '$ad' adıyla görünmüyor." >&2; return 1; }
  else
    GH_REPO="$GH_REPO" split -b "$PARCA_BAYT" -a 3 --numeric-suffixes=1 \
      --filter='cat > "$FILE" && gh release upload kaynak "$FILE" --clobber > /dev/null && rm -f "$FILE"' \
      "$f" "$IS/yukle/$ad.yeni"
    rm -f "$f"
    varliklar=$(release_varliklari kaynak)
    yeni=$(jq -c --arg on "$ad.yeni" "$PARCA_JQ" <<< "$varliklar")
    sayi=$(( (boyut + PARCA_BAYT - 1) / PARCA_BAYT ))
    toplam=$(jq 'map(.size) | add // 0' <<< "$yeni")
    if [ "$(jq length <<< "$yeni")" -ne "$sayi" ] || [ "$toplam" != "$boyut" ]; then
      echo "HATA: yeni parçalar eksik ($sayi bekleniyordu), eski parçalar yerinde bırakıldı." >&2
      return 1
    fi
  fi
  for id in $(jq -r '.[].id' <<< "$eski"); do varlik_sil "$id"; done
  if [ "$boyut" -ge "$IKI_GIB" ]; then
    while read -r id n; do
      gh api -X PATCH "repos/$GH_REPO/releases/assets/$id" -f name="$(printf '%s.part%03d' "$ad" "$n")" > /dev/null
    done < <(jq -r '.[] | "\(.id) \(.n)"' <<< "$yeni")
  fi
  echo "Kaynak kalıcı biçimde: $ad ($([ "$boyut" -lt "$IKI_GIB" ] && echo "tek dosya" || echo "$sayi parça"), $(gib "$boyut") GiB)"
}

# Tek video. Alt kabukta set -e ile çalışır; ilk hatada durur, kısa açıklama $ADIM'dadır.
isle() { # <kaynak adı> <slug>
  local ad="$1" s="$2" kaynak boyut bos gerek yanit anahtar sakla m no girdi id derle=false hedef
  adim "Kaynak dosya bulunamadı"
  kaynak=$(jq -c --arg ad "$ad" '[.assets[] | select(.name == $ad)] | .[:1]' <<< "$KAYNAK_JSON")
  if [ "$kaynak" = "[]" ]; then
    kaynak=$(jq -c --arg on "$ad.part" "$PARCA_JQ" <<< "$KAYNAK_JSON")
    [ "$kaynak" != "[]" ] || { echo "HATA: kaynak release'inde '$ad' de parçaları da yok." >&2; return 1; }
    adim "Yükleme parçaları eksik"
    jq -e 'map(.n) == [range(1; length + 1)]' <<< "$kaynak" > /dev/null ||
      { echo "HATA: parça numaraları 1..n değil: $(jq -c 'map(.n)' <<< "$kaynak")" >&2; return 1; }
  fi
  boyut=$(jq 'map(.size) | add' <<< "$kaynak")

  bos=$(bos_bayt "$KOK")
  gerek=$(awk -v s="$boyut" 'BEGIN { printf "%.0f", s * 2.3 }')
  if [ "$bos" -lt "$gerek" ]; then
    adim "Diskte yer yok: kaynak $(gib "$boyut") GiB, boş $(gib "$bos") GiB, en az $(gib "$gerek") GiB gerekir"
    echo "HATA: $(cat "$ADIM")" >&2
    return 1
  fi

  adim "Panele kaydedilemedi"
  yanit=$(panel POST /api/ci/video "$(video_govde "$ad" "$s" isleniyor "{\"kaynak_boyut\": $boyut}")")
  anahtar=$(jq -r '.anahtar // empty' <<< "$yanit")
  [[ "$anahtar" =~ ^[0-9a-f]{32}$ ]] || { echo "HATA: panelden geçerli anahtar gelmedi." >&2; return 1; }
  echo "::add-mask::$anahtar"
  sakla=$(jq -r 'if .kaynak_sakla == false then "false" else "true" end' <<< "$yanit")

  adim "Kaynak dosya indirilemedi"
  mkdir -p "$IS/girdi" "$ANAHTARLAR"
  chmod 700 "$ANAHTARLAR"
  girdi="$IS/girdi/$ad"
  if [ "$(jq length <<< "$kaynak")" -eq 1 ] && [ "$(jq -r '.[0].name' <<< "$kaynak")" = "$ad" ]; then
    varlik_indir "$(jq -r '.[0].id' <<< "$kaynak")" "$girdi"
  else
    echo "Parçalar birleştiriliyor: $(jq length <<< "$kaynak") parça, $(gib "$boyut") GiB"
    : > "$girdi"
    for id in $(jq -r '.[].id' <<< "$kaynak"); do
      varlik_indir "$id" "$IS/parca.tmp"
      cat "$IS/parca.tmp" >> "$girdi"
      rm -f "$IS/parca.tmp"
    done
  fi
  [ "$(stat -c %s "$girdi")" = "$boyut" ] || { echo "HATA: inen kaynağın boyutu tutmuyor." >&2; return 1; }

  adim "HLS'e çevrilemedi"
  printf "$(sed 's/../\\x&/g' <<< "$anahtar")" > "$ANAHTARLAR/$s.key"   # 16 ham bayt
  printf 'k\n%s\n' "$ANAHTARLAR/$s.key" > "$ANAHTARLAR/$s.keyinfo"
  ANAHTAR_BILGI="$ANAHTARLAR/$s.keyinfo" BASLIK="${ad%.*}" \
    bash "$BURASI/hls-yap.sh" "$girdi" "$IS/cikti/$s" "$MOD"
  rm -f "$ANAHTARLAR/$s.key" "$ANAHTARLAR/$s.keyinfo"
  # Yerel kaynak sadece panel parçaları kalıcı biçime getirilecekse kalır
  if [ "$sakla" = true ] && [ "$(jq -r '.[0].name' <<< "$kaynak")" != "$ad" ]; then
    hedef=$(( boyut < IKI_GIB ? 1 : (boyut + PARCA_BAYT - 1) / PARCA_BAYT ))
    if [ "$hedef" -eq 1 ] || [ "$(jq length <<< "$kaynak")" -ne "$hedef" ]; then derle=true; fi
  fi
  [ "$derle" = true ] || rm -f "$girdi"
  m="$IS/meta.json"
  cp "$IS/cikti/$s/meta.json" "$m"

  adim "Kutu seçilemedi"
  yanit=$(panel POST /api/ci/kutu-sec "$(jq -c --arg slug "$s" '{slug: $slug, bayt: .boyut, dosya: .dosya}' "$m")")
  no=$(jq -r '.no' <<< "$yanit")
  [[ "$no" =~ ^[0-9]+$ ]] || { echo "HATA: panelden kutu numarası gelmedi." >&2; return 1; }

  adim "Panele kaydedilemedi"
  panel POST /api/ci/video "$(video_govde "$ad" "$s" yayinlaniyor "$(jq -c --argjson no "$no" '{kutu_no: $no, meta: .}' "$m")")" > /dev/null

  adim "Kutu yayınlanamadı"
  kutu_dagit "$no" "$s" "$IS/cikti/$s"
  echo "$no" >> "$KUTU_LISTESI"

  # Yayın tamam: kaynak saklanmayacaksa silinir (yayinlandi'den önce, panel bilgiyi hâlâ yayınlanıyor
  # durumundayken alır). Silinemezse video yine hazır olur, kaynak durur.
  if [ "$sakla" = false ]; then
    if ( for id in $(jq -r '.[].id' <<< "$kaynak"); do varlik_sil "$id" || exit 1; done ); then
      echo "Kaynak silindi: $ad"
      panel POST /api/ci/video "$(video_govde "$ad" "$s" yayinlaniyor \
        "$(jq -c --argjson no "$no" '{kutu_no: $no, meta: ., kaynak_duruyor: false}' "$m")")" > /dev/null ||
        echo "::warning::$ad: kaynağın silindiği panele bildirilemedi."
    else
      echo "::warning::$ad: kaynak silinemedi, release'te duruyor."
    fi
  fi

  kutu_bitir "$no"
  echo "Kutu $KUTU_NN: $s ($(jq -r '"\(.parca) parça, \(.boyut / 1048576 | floor) MiB, \(.mod.video)/\(.mod.ses)"' "$m"))"

  if [ "$derle" = true ]; then
    kaynak_derle "$girdi" "$ad" "$kaynak" || echo "::warning::$ad: kaynak parçaları birleştirilemedi, panel parçaları duruyor."
  fi
}

hata_bildir() { # <ad> <slug> <mesaj>
  echo "::error::$1: $3"
  panel POST /api/ci/video "$(video_govde "$1" "$2" hata "$(jq -nc --arg h "$3" '{hata: $h}')")" > /dev/null ||
    echo "::warning::$1 için hata panele bildirilemedi."
}

KAYNAK_JSON=$(release_varliklari kaynak)
YAYINDAKILER="[]"

if [ -n "$VIDEO" ]; then
  liste=("$VIDEO")
elif [ -n "$KUTU" ]; then
  liste=()   # sadece kutu yeniden yayını istendi (ör. video silindi): kaynaklara dokunulmaz
else
  # Parçalı kaynaklar (panelden yüklenmekte olabilir) ve geçici adlar alınmaz
  mapfile -t liste < <(jq -r '.assets[].name | select(test("\\.(part|yeni)[0-9]+$") | not)' <<< "$KAYNAK_JSON")
  if [ "$YENIDEN" != true ] && [ -n "${liste[*]}" ]; then
    # Yayındakiler: kutu manifestlerindeki videolar + eski düzende (tar) duran hazır videolar
    for k in $(panel GET /api/ci/kutular | jq -r '.kutular[]'); do
      YAYINDAKILER=$(jq -c --argjson v "$(panel GET "/api/ci/kutu/$k/manifest" |
        jq -c '[.manifest // {} | keys[] | capture("^/v/(?<s>[^/]+)/").s] + (.eksik // []) | unique')" '. + $v' <<< "$YAYINDAKILER")
    done
  fi
fi

basarisiz=0
for ad in "${liste[@]}"; do
  [ -n "$ad" ] || continue
  s=$(slug "$ad")
  if [ -z "$s" ]; then
    echo "::error::$ad: dosya adından adres adı çıkmadı, atlandı."
    basarisiz=$((basarisiz + 1))
    continue
  fi
  if [ -z "$VIDEO" ] && jq -e --arg s "$s" 'index($s) != null' <<< "$YAYINDAKILER" > /dev/null; then
    echo "Atlandı (yayında): $ad"
    continue
  fi

  echo "::group::$ad -> $s"
  : > "$ADIM"; : > "$PANEL_HATA_DOSYASI"
  set +e
  ( set -e; isle "$ad" "$s" )
  rc=$?
  set -e
  rm -rf "$IS" "$ANAHTARLAR" "$KOK"/kutu-*
  echo "::endgroup::"
  if [ "$rc" -ne 0 ]; then
    mesaj=$(cat "$ADIM")
    [ ! -s "$PANEL_HATA_DOSYASI" ] || mesaj="$mesaj: $(cat "$PANEL_HATA_DOSYASI")"
    hata_bildir "$ad" "$s" "${mesaj:-İşlenemedi}"
    basarisiz=$((basarisiz + 1))
  fi
done

kutular=$(sort -nu "$KUTU_LISTESI" | tr '\n' ' ' | sed 's/ $//')
echo "Yayınlanan kutular: ${kutular:-yok}"
echo "kutular=$kutular" >> "${GITHUB_OUTPUT:-/dev/null}"
if [ "$basarisiz" -gt 0 ]; then
  echo "HATA: $basarisiz video işlenemedi." >&2
  exit 1
fi
