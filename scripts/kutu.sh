# Kutu (Pages projesi) yayını ve GitHub release dosyaları için ortak işlevler. Source edilir:
#   . scripts/panel.sh; . scripts/kutu.sh
# Kutular artık GitHub'da paket tutmaz: her yayın, kutudaki videoların panelde saklanan Pages
# manifestleri + yerelde yeni olan dosyalarla yapılır (scripts/pages-yayinla.mjs). Eski düzende
# kutu-NN release'inde <slug>.tar olarak duran videolar ilk yayında manifeste taşınır.
#
# Ortam: GH_REPO, GH_TOKEN, PAGES_NPM, GITHUB_SHA, PANEL_HATA_DOSYASI (isteğe bağlı)

KUTU_BURASI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CF_API="${CF_API_TABAN:-https://api.cloudflare.com/client/v4}"
GH_API="${GH_API_TABAN:-https://api.github.com}"

# Çalışma klasörü: /mnt daha boşsa orası (GitHub runner'ında ayrı ve büyük disk), değilse RUNNER_TEMP.
calisma_koku() {
  local tmp="${RUNNER_TEMP:-/tmp}" tb mb
  df -h / /mnt "$tmp" 2>/dev/null || true
  tb=$({ df -Pk "$tmp" 2>/dev/null || true; } | awk 'END { print $4 + 0 }')
  mb=$({ df -Pk /mnt 2>/dev/null || true; } | awk 'END { print $4 + 0 }')
  if [ "$mb" -gt "$tb" ] && sudo -n mkdir -p /mnt/hls-is 2>/dev/null && sudo -n chown "$(id -u):$(id -g)" /mnt/hls-is; then
    KOK=/mnt/hls-is
  else
    KOK="$tmp/hls-is"
  fi
  rm -rf "${KOK:?}" && mkdir -p "$KOK"
  echo "Çalışma klasörü: $KOK ($(bos_bayt "$KOK" | awk '{ printf "%.1f", $1 / 1073741824 }') GiB boş)"
}

bos_bayt() { df -PB1 "$1" | awk 'END { print $4 }'; }
gib() { awk -v b="$1" 'BEGIN { printf "%.1f", b / 1073741824 }'; }

# Release dosyaları: {"id": <release id>, "assets": [{id, name, size}]} (sayfalı, 100'den fazlası da gelir).
# Release yoksa 2 döner.
release_varliklari() { # <etiket>
  local rid e
  e=$(mktemp)
  if ! rid=$(gh api "repos/$GH_REPO/releases/tags/$1" --jq .id 2> "$e"); then
    if grep -q 'HTTP 404' "$e"; then rm -f "$e"; return 2; fi
    cat "$e" >&2; rm -f "$e"; return 1
  fi
  rm -f "$e"
  gh api --paginate "repos/$GH_REPO/releases/$rid/assets?per_page=100" |
    jq -sc --argjson rid "$rid" '{id: $rid, assets: (add // [] | map({id, name, size}))}'
}

varlik_indir() { # <asset id> <hedef dosya>; kesilirse curl dosyayı sıfırlayıp yeniden dener
  curl -sSL --fail --retry 5 --retry-delay 5 --retry-all-errors --connect-timeout 30 \
    -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/octet-stream" \
    -o "$2" "$GH_API/repos/$GH_REPO/releases/assets/$1"
}

varlik_sil() { gh api -X DELETE "repos/$GH_REPO/releases/assets/$1" > /dev/null; }   # <asset id>

# Kutu kökündeki dosyalar (baytları değişirse Pages'e yeniden yüklenir, yine de sorun olmaz)
kok_dosyalari() { # <klasör>
  printf '/*\n  X-Robots-Tag: noindex, nofollow\n\n/v/*.ts\n  Cache-Control: public, max-age=86400\n' > "$1/_headers"
  printf 'User-agent: *\nDisallow: /\n' > "$1/robots.txt"
  printf 'Bulunamadı\n' > "$1/404.html"   # yoksa Pages eksik dosyada 200 + index.html döndürür
  # Nötr sayfa: bağlantı ve yönlendirme yok, panelin adresi burada görünmemeli
  printf '<!doctype html>\n<meta charset="utf-8">\n<meta name="robots" content="noindex">\n<title>Dosya deposu</title>\n' > "$1/index.html"
}

# Kutuyu yayınlar ve yeni/taşınan videoların manifestini panele yazar. yayinlandi'yi kutu_bitir yapar.
# Yeni video verilirse onun HLS klasörü yayına girer, panelde eski manifesti varsa yok sayılır.
# Global olarak bırakır: KUTU_NN, KUTU_PROJE, KUTU_ACCOUNT, KUTU_TOKEN, KUTU_DIZIN, KUTU_SLUGLAR, KUTU_OZET
kutu_dagit() { # <no> [<slug> <hls klasörü>]
  local no="$1" yeni="${2:-}" hls="${3:-}" yanit man varliklar rc=0 s id tasinan=() eksikler=() videolar atlanan
  yanit=$(panel GET "/api/ci/kutu/$no")
  KUTU_TOKEN=$(jq -r '.token // empty' <<< "$yanit")
  [ -z "$KUTU_TOKEN" ] || echo "::add-mask::$KUTU_TOKEN"
  KUTU_PROJE=$(jq -r '.proje // empty' <<< "$yanit")
  KUTU_ACCOUNT=$(jq -r '.account_id // empty' <<< "$yanit")
  KUTU_NN=$(jq -r --arg nn "$(printf '%02d' "$no")" '.nn // $nn' <<< "$yanit")
  local release
  release=$(jq -r --arg r "kutu-$KUTU_NN" '.release // $r' <<< "$yanit")
  videolar=$(jq -c '.videolar // []' <<< "$yanit")
  if [ -z "$KUTU_TOKEN" ] || [ -z "$KUTU_PROJE" ] || [ -z "$KUTU_ACCOUNT" ]; then
    echo "HATA: panel kutu $no için proje, hesap ya da anahtar vermedi." >&2
    return 1
  fi

  KUTU_DIZIN="$KOK/kutu-$KUTU_NN"
  rm -rf "$KUTU_DIZIN" "$KUTU_DIZIN".* && mkdir -p "$KUTU_DIZIN/v"
  kok_dosyalari "$KUTU_DIZIN"
  [ -z "$yeni" ] || mv "$hls" "$KUTU_DIZIN/v/$yeni"

  # Kutudaki diğer videolar: panelde saklanan manifestleri (dosyaları Pages'te zaten var)
  man=$(panel GET "/api/ci/kutu/$no/manifest")
  jq --arg p "/v/$yeni/" '.manifest // {} | with_entries(select(.key | startswith($p) | not))' <<< "$man" > "$KUTU_DIZIN.dis.json"

  # Eski düzen: manifesti olmayan hazır videolar kutu-NN release'inde <slug>.tar olarak durur.
  # Açılıp yayına yerel dosya olarak girer (Pages'te zaten yüklü oldukları için tekrar gönderilmez).
  mapfile -t eksikler < <(jq -r --arg y "$yeni" '.eksik // [] | .[] | select(. != $y)' <<< "$man")
  if [ -n "${eksikler[*]}" ]; then
    varliklar=$(release_varliklari "$release") || rc=$?
    if [ "$rc" -eq 2 ]; then varliklar='{"assets":[]}'; elif [ "$rc" -ne 0 ]; then return 1; fi
    for s in "${eksikler[@]}"; do
      id=$(jq -r --arg n "$s.tar" '[.assets[] | select(.name == $n) | .id] | first // empty' <<< "$varliklar")
      if [ -z "$id" ]; then
        echo "HATA: kutu $KUTU_NN: '$s' videosunun ne panelde manifesti ne de $release içinde $s.tar paketi var." >&2
        [ -z "${PANEL_HATA_DOSYASI:-}" ] || printf "'%s' videosunun manifesti de paketi de yok" "$s" > "$PANEL_HATA_DOSYASI"
        return 1
      fi
      echo "Eski paket açılıyor: $release/$s.tar"
      varlik_indir "$id" "$KOK/$s.tar"
      tar -xf "$KOK/$s.tar" -C "$KUTU_DIZIN/v" "$s"
      rm -f "$KOK/$s.tar"
      tasinan+=("$s:$id")
    done
  fi

  KUTU_OZET="$KUTU_DIZIN.ozet.json"
  if ! CLOUDFLARE_API_TOKEN="$KUTU_TOKEN" node "$KUTU_BURASI/pages-yayinla.mjs" \
      --account "$KUTU_ACCOUNT" --project "$KUTU_PROJE" --dir "$KUTU_DIZIN" \
      --manifest "$KUTU_DIZIN.dis.json" --message "Kutu $KUTU_NN" --commit-hash "${GITHUB_SHA:-yerel}" \
      --out "$KUTU_DIZIN.yerel.json" --ozet "$KUTU_OZET" 2> "$KUTU_DIZIN.err"; then
    cat "$KUTU_DIZIN.err" >&2
    [ -z "${PANEL_HATA_DOSYASI:-}" ] || sed -n 's/^HATA: //p' "$KUTU_DIZIN.err" | tail -n 1 > "$PANEL_HATA_DOSYASI"
    return 1
  fi
  cat "$KUTU_DIZIN.err" >&2

  # Yeni ve taşınan videoların manifesti panele; taşınanın tar'ı silinir
  for s in ${yeni:+"$yeni:"} ${tasinan[@]+"${tasinan[@]}"}; do
    id="${s#*:}"; s="${s%%:*}"
    panel PUT "/api/ci/video/$s/manifest" \
      "$(jq -c --arg p "/v/$s/" '{manifest: with_entries(select(.key | startswith($p)))}' "$KUTU_DIZIN.yerel.json")" > /dev/null
    if [ -n "$id" ]; then
      varlik_sil "$id"
      echo "Taşındı: $s (manifest panelde, $release/$s.tar silindi)"
    fi
  done
  if [ "${#tasinan[@]}" -gt 0 ]; then
    rc=0; varliklar=$(release_varliklari "$release") || rc=$?
    if [ "$rc" -eq 0 ] && [ "$(jq '.assets | length' <<< "$varliklar")" -eq 0 ]; then
      gh release delete "$release" -y --cleanup-tag
      echo "Boşalan $release release'i silindi."
    fi
  fi

  KUTU_SLUGLAR=$(jq -sc '(.[0] + .[1]) | [keys[] | capture("^/v/(?<s>[^/]+)/") | .s] | unique' \
    "$KUTU_DIZIN.dis.json" "$KUTU_DIZIN.yerel.json")
  atlanan=$(jq -r --argjson y "$KUTU_SLUGLAR" '. - $y | join(", ")' <<< "$videolar")
  [ -z "$atlanan" ] || echo "Yayına girmeyen (hiç yayınlanmamış) videolar: $atlanan"
}

# kutu_dagit'ten sonra: panele yayınlandı bilgisi, eski yayınların silinmesi, temizlik.
kutu_bitir() { # <no>
  panel POST "/api/ci/kutu/$1/yayinlandi" \
    "$(jq -c --argjson slugs "$KUTU_SLUGLAR" '{slugs: $slugs, dosya: .dosya, bayt: .yerel_bayt}' "$KUTU_OZET")" > /dev/null
  echo "Kutu $KUTU_NN yayında: $(jq length <<< "$KUTU_SLUGLAR") video, $(jq .dosya "$KUTU_OZET") dosya"
  eski_yayinlari_sil "$KUTU_ACCOUNT" "$KUTU_TOKEN" "$KUTU_PROJE" || echo "::warning::$KUTU_PROJE eski yayınları silinemedi."
  rm -rf "$KUTU_DIZIN" "$KUTU_DIZIN".*
}

# Pages eski yayınları <hash>.<proje>.pages.dev adresinde açık tutar: silinen videolar orada
# kalmasın diye en yeni yayın dışındakiler silinir. Başarısızlık yayını bozmaz.
eski_yayinlari_sil() { # <account_id> <token> <proje>
  local proje_api="$CF_API/accounts/$1/pages/projects/$3"
  local api="$proje_api/deployments" ids id n=0 canli
  canli=$(curl -sS -H "Authorization: Bearer $2" "$proje_api" | jq -r '.result.canonical_deployment.id // empty')
  [ -n "$canli" ] || return 1
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    ids=$(curl -sS -H "Authorization: Bearer $2" "$api" |
      jq -r --arg c "$canli" 'if .success then .result[] | select(.id != $c) | .id else empty end') || return 1
    [ -n "$ids" ] || break
    for id in $ids; do
      curl -sS -X DELETE -H "Authorization: Bearer $2" "$api/$id?force=true" | jq -e '.success' > /dev/null && n=$((n + 1))
    done
  done
  [ "$n" -eq 0 ] || echo "$3: $n eski yayın silindi."
}
