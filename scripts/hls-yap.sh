#!/usr/bin/env bash
# Tek bir videoyu HLS klasörüne çevirir. GitHub Actions üzerinde çalışır.
# Kullanım: hls-yap.sh <girdi-video> <cikti-klasoru> [auto|copy|encode]
#
# auto:   H.264 + AAC ise yeniden kodlamadan böler (çok hızlı, kalite aynı).
#         Uyumsuz kodek ya da 24 MiB'ı aşan parça çıkarsa encode'a düşer.
# copy:   her zaman yeniden kodlamadan böler.
# encode: H.264 + AAC olarak yeniden kodlar (yavaş, her kaynakta çalışır).
#
# Şifreleme (isteğe bağlı): ANAHTAR_BILGI ffmpeg'in anahtar bilgi dosyası. 1. satır "k" (listedeki
# anahtar adresi), 2. satır 16 baytlık anahtar dosyası, IV satırı yok. Anahtar dosyası çıktı
# klasörünün DIŞINDA olmalı, yoksa tar ile kutuya gider. Parçalar AES-128 ile şifrelenir, listede
# tek satır #EXT-X-KEY:METHOD=AES-128,URI="k" kalır (IV = parçanın sıra numarası).
set -euo pipefail

GIRDI="$1"
CIKTI="$2"
MOD="${3:-auto}"
MAX_PARCA=$((24 * 1024 * 1024))   # Pages sınırı 25 MiB, 1 MiB pay
PARCA_SURE="${PARCA_SURE:-10}"    # hedef parça süresi (sn); copy modunda en yakın anahtar karede kesilir

sifreli=false
sifre=()
bayrak=independent_segments
if [ -n "${ANAHTAR_BILGI:-}" ]; then
  anahtar=$(sed -n 2p "$ANAHTAR_BILGI")
  if [ "$(sed -n 1p "$ANAHTAR_BILGI")" != k ] || [ "$(sed -n '$=' "$ANAHTAR_BILGI")" != 2 ]; then
    echo "HATA: anahtar bilgi dosyası iki satır olmalı: 'k' ve anahtar dosyasının yolu." >&2; exit 1
  fi
  [ "$(stat -c %s "$anahtar" 2>/dev/null || echo 0)" = 16 ] || { echo "HATA: anahtar dosyası 16 bayt değil." >&2; exit 1; }
  case "$(realpath -m "$anahtar")" in "$(realpath -m "$CIKTI")"/*)
    echo "HATA: anahtar dosyası çıktı klasörünün içinde olamaz." >&2; exit 1 ;;
  esac
  anahtar_hex=$(od -An -tx1 "$anahtar" | tr -d ' \n')
  # periodic_rekey: ffmpeg anahtar bilgisini her parçada yeniden okur, böylece her parçanın IV'si
  # kendi sıra numarası olur. Bu bayrak olmadan bütün parçalar IV=0 ile şifrelenir.
  sifre=(-hls_key_info_file "$ANAHTAR_BILGI")
  bayrak=independent_segments+periodic_rekey
  sifreli=true
fi

probe() { ffprobe -v error -select_streams "$1" -show_entries "$2" -of default=nw=1:nk=1 "$GIRDI" | sed -n 1p; }

vkodek=$(probe v:0 stream=codec_name)
pixfmt=$(probe v:0 stream=pix_fmt)
akodek=$(probe a:0 stream=codec_name || true)
sure=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$GIRDI" | sed -n 1p)
echo "Kaynak: video=$vkodek ($pixfmt) ses=${akodek:-yok} sure=${sure}s şifreli=$sifreli"

# Kaynağın anahtar kare aralığı: copy modunda parçalar ancak anahtar karelerde kesilebilir.
anahtar_aralik() {
  ffprobe -v error -read_intervals %+90 -select_streams v:0 \
    -show_entries packet=pts_time,flags -of csv=p=0 "$GIRDI" |
    awk -F, '$2 ~ /K/ { if (n++) { d = $1 - p; s += d } p = $1 } END { if (n > 1) printf "%.2f", s / (n - 1); else print 0 }'
}

parcala() {
  local vmod="$1" amod="$2" hls_sure="$3"
  rm -rf "$CIKTI" && mkdir -p "$CIKTI"
  local vargs aargs
  if [ "$vmod" = copy ]; then
    vargs=(-c:v copy)
  else
    # 1080p üstünü küçült, parça süresinin yarısında bir anahtar kare (parça içinde de sarılabilsin),
    # tepe bit hızı sınırlı (parça boyutu öngörülebilir kalsın)
    vargs=(-c:v libx264 -preset veryfast -crf 22 -profile:v high -pix_fmt yuv420p
      -vf "scale='if(gt(iw,ih),min(1920,iw),-2)':'if(gt(iw,ih),-2,min(1920,ih))'"
      -maxrate 6M -bufsize 12M -sc_threshold 0
      -force_key_frames "expr:gte(t,n_forced*$(awk -v s="$hls_sure" 'BEGIN { print s / 2 }'))")
  fi
  if [ "$amod" = copy ]; then aargs=(-c:a copy); else aargs=(-c:a aac -b:a 128k -ac 2); fi

  ffmpeg -hide_banner -loglevel warning -stats -y -i "$GIRDI" \
    -map 0:v:0 -map '0:a:0?' "${vargs[@]}" "${aargs[@]}" \
    -f hls -hls_time "$hls_sure" -hls_playlist_type vod -hls_list_size 0 \
    -hls_flags "$bayrak" "${sifre[@]}" \
    -hls_segment_filename "$CIKTI/p%05d.ts" "$CIKTI/index.m3u8"
}

en_buyuk() { find "$CIKTI" -name '*.ts' -printf '%s\n' | sort -n | tail -1; }

# ffmpeg her parçanın önüne kendi IV'siyle bir #EXT-X-KEY satırı yazar. Hepsi sıra numarasına
# eşitse tek bir IV'siz satıra indirilir (oynatıcı IV olarak sıra numarasını kullanır).
liste_duzelt() {
  local m="$CIKTI/index.m3u8"
  if ! awk '
    /^#EXT-X-MEDIA-SEQUENCE:/ { sira = substr($0, 23) + 0 }
    /^#EXT-X-KEY:/ {
      if (index($0, "#EXT-X-KEY:METHOD=AES-128,URI=\"k\"") != 1) hata = 1
      iv = ""
      if (match($0, /,IV=0[xX][0-9a-fA-F]+/)) iv = tolower(substr($0, RSTART + 6, RLENGTH - 6))
      if (!yazildi) { print "#EXT-X-KEY:METHOD=AES-128,URI=\"k\""; yazildi = 1 }
      next
    }
    /^[^#]/ { if (iv != "" && iv != sprintf("%032x", sira)) hata = 1; sira++ }
    { print }
    END { exit (hata || !yazildi) ? 1 : 0 }' "$m" > "$m.yeni"; then
    rm -f "$m.yeni"
    echo "HATA: listedeki #EXT-X-KEY satırları beklenmedik (URI \"k\" ve IV = sıra numarası olmalı)." >&2
    exit 1
  fi
  mv "$m.yeni" "$m"
}

# Anahtar denetimi: ilk ve son parça anahtarla (IV = sıra numarası) çözülüp TS (0x47) olarak
# başlamalı. IV'nin doğruluğunu liste_duzelt denetler (yanlış IV sadece ilk bloğun son baytlarını bozar).
# Çözülen ilk parça ILK_PARCA'da kalır (yükseklik ondan okunur, iş bitince silinir).
sifre_denetle() {
  local sira ad c
  while read -r sira ad; do
    c=$(mktemp)
    if ! openssl enc -d -aes-128-cbc -K "$anahtar_hex" -iv "$(printf '%032x' "$sira")" \
        -in "$CIKTI/$ad" -out "$c" 2>/dev/null || [ "$(od -An -tx1 -N1 "$c" | tr -d ' ')" != 47 ]; then
      rm -f "$c"
      echo "HATA: $ad anahtarla çözülemedi." >&2
      exit 1
    fi
    if [ -z "$ILK_PARCA" ]; then ILK_PARCA="$c"; else rm -f "$c"; fi
  done < <(awk '/^#EXT-X-MEDIA-SEQUENCE:/ { s = substr($0, 23) + 0 } /^[^#]/ { print s, $0; s++ }' \
    "$CIKTI/index.m3u8" | sed -n '1p;$p')
  [ -n "$ILK_PARCA" ] || { echo "HATA: listede parça yok." >&2; exit 1; }
}

vmod=encode; amod=aac
if [ "$MOD" = copy ] || { [ "$MOD" = auto ] && [ "$vkodek" = h264 ] && [[ "$pixfmt" =~ ^yuvj?420p$ ]]; }; then
  vmod=copy
fi
if [ "$MOD" = copy ] || { [ "$MOD" = auto ] && [ "${akodek:-}" = aac ]; }; then
  amod=copy
fi

hls_sure="$PARCA_SURE"
aralik=0
if [ "$vmod" = copy ]; then
  aralik=$(anahtar_aralik)
  echo "Anahtar kare aralığı: ~${aralik}s (parçalar ${hls_sure}s'den sonraki ilk anahtar karede kesilir)"
fi

echo "Mod: video=$vmod ses=$amod parça=${hls_sure}s"
parcala "$vmod" "$amod" "$hls_sure"   # aşağıdaki yeniden denemeler de aynı ANAHTAR_BILGI, yani aynı anahtar
buyuk=$(en_buyuk)

# 25 MiB'ı aşan parça: önce yeniden kodlamadan, parça süresini anahtar kare aralığına indirerek dene
if [ "$buyuk" -gt "$MAX_PARCA" ] && [ "$vmod" = copy ] &&
    awk -v a="$aralik" -v s="$hls_sure" 'BEGIN { exit !(a >= 1 && a < s) }'; then
  echo "En büyük parça $((buyuk / 1048576)) MiB, sınırı aşıyor. Parça süresi anahtar kare aralığına (${aralik}s) iniyor."
  hls_sure="$aralik"
  parcala "$vmod" "$amod" "$hls_sure"
  buyuk=$(en_buyuk)
fi
# Olmazsa auto modunda yeniden kodla (parça süresi yine PARCA_SURE)
if [ "$buyuk" -gt "$MAX_PARCA" ] && [ "$MOD" = auto ] && [ "$vmod" = copy ]; then
  echo "En büyük parça $((buyuk / 1048576)) MiB, sınırı aşıyor. Yeniden kodlanıyor."
  vmod=encode
  hls_sure="$PARCA_SURE"
  parcala "$vmod" "$amod" "$hls_sure"
  buyuk=$(en_buyuk)
fi
if [ "$buyuk" -gt "$MAX_PARCA" ]; then
  echo "HATA: parça $((buyuk / 1048576)) MiB, Pages sınırı 25 MiB. PARCA_SURE'yi düşürüp encode ile dene." >&2
  exit 1
fi

ILK_PARCA="$CIKTI/p00000.ts"
if [ "$sifreli" = true ]; then
  liste_duzelt
  ILK_PARCA=
  sifre_denetle
  echo "Şifre denetimi: ilk ve son parça anahtarla çözüldü."
fi

# Liste için kapak görseli (videonun %10'undan bir kare)
ffmpeg -hide_banner -loglevel error -y -ss "$(awk -v d="$sure" 'BEGIN { printf "%.1f", d * 0.1 }')" \
  -i "$GIRDI" -frames:v 1 -vf "scale=-2:360" -q:v 4 "$CIKTI/kapak.jpg" || true

# Zaman çizelgesi önizlemesi (ilerleme çubuğu küçük kareleri): $CIKTI içine iki dosya yazar,
# kutuyla birlikte yayınlanır (pages-yayinla.mjs tüm klasörü alır, elemez).
#   thumbs.jpg : video boyunca örneklenmiş küçük karelerin tek sprite'ı (10 sütunlu ızgara)
#   thumbs.vtt : her zaman aralığını thumbs.jpg üzerindeki bir bölgeye eşleyen WebVTT
# Oynatıcı (Plyr previewThumbnails) /v/<slug>/thumbs.vtt'yi okur; görsel adresi VTT'ye göre çözülür.
# İsteğe bağlı: üretilemezse video yine hazır olur, meta.onizleme=false kalır.
onizleme=false
onizleme_yap() {
  local cols=10 interval n rows sw sh th w h
  interval=$(awk -v d="${sure:-0}" 'BEGIN { i = int(d / 150 + 0.5); if (i < 2) i = 2; print i }')
  n=$(awk -v d="${sure:-0}" -v i="$interval" 'BEGIN { print int((d + i - 1) / i) }')
  [ "${n:-0}" -ge 1 ] 2>/dev/null || return 1
  rows=$(( (n + cols - 1) / cols ))
  sw=$(probe v:0 stream=width); sh=$(probe v:0 stream=height)
  { [ -n "$sw" ] && [ -n "$sh" ] && [ "$sw" -gt 0 ] && [ "$sh" -gt 0 ]; } 2>/dev/null || return 1
  # scale=160:-2 en-boyu korur; TH = çift(yuvarla(160*sh/sw)). Sprite'tan da doğrulanır (aşağıda).
  th=$(awk -v sw="$sw" -v sh="$sh" 'BEGIN { t = int(160 * sh / sw + 0.5); if (t % 2) t++; if (t < 2) t = 2; print t }')

  # Tek geçiş: fps=1/interval ile aralıklı kare al, 160 genişliğe ölçekle (yükseklik -2 ile çift),
  # cols x rows ızgaraya diz. Sadece video (0:v:0); copy modunda .ts'nin timed_id3 veri akışına
  # takılmamak için -an -sn -dn.
  ffmpeg -y -hide_banner -loglevel error -i "$GIRDI" \
    -map 0:v:0 -an -sn -dn \
    -vf "fps=1/${interval},scale=160:-2,tile=${cols}x${rows}" \
    -frames:v 1 -qscale:v 4 "$CIKTI/thumbs.jpg" || return 1
  [ -s "$CIKTI/thumbs.jpg" ] || return 1

  # Sprite boyutunu doğrula: genişlik cols*160 olmalı. Gerçek kare yüksekliğini sprite'tan türet
  # (scale=160:-2 yuvarlaması th'den 2 piksel sapabilir; VTT bölgeleri sprite'la birebir olmalı).
  w=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=nw=1:nk=1 "$CIKTI/thumbs.jpg" | sed -n 1p)
  h=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=nw=1:nk=1 "$CIKTI/thumbs.jpg" | sed -n 1p)
  [ "$w" = "$((cols * 160))" ] || { echo "::warning::önizleme: sprite genişliği $w, $((cols * 160)) olmalıydı." >&2; return 1; }
  if [ -n "$h" ] && [ "$((h % rows))" -eq 0 ] && [ "$((h / rows))" -gt 0 ]; then
    [ "$((h / rows))" = "$th" ] || echo "önizleme: kare yüksekliği sprite'tan $((h / rows)) alındı (hesap $th)."
    th=$((h / rows))
  fi

  # thumbs.vtt: WEBVTT başlığı + her i için [i*interval, min((i+1)*interval, sure)] aralığı ve
  # sprite üzerindeki xywh bölgesi. Görsel adresi göreli 'thumbs.jpg#xywh=...' (VTT'ye göre çözülür).
  awk -v n="$n" -v iv="$interval" -v dur="${sure:-0}" -v cols="$cols" -v th="$th" '
    function hms(t,   hh, mm) {
      if (t < 0) t = 0
      hh = int(t / 3600); t -= hh * 3600
      mm = int(t / 60);   t -= mm * 60
      return sprintf("%02d:%02d:%06.3f", hh, mm, t)
    }
    BEGIN {
      print "WEBVTT"; print ""
      for (i = 0; i < n; i++) {
        start = i * iv; end = (i + 1) * iv; if (end > dur) end = dur
        x = (i % cols) * 160; y = int(i / cols) * th
        print hms(start) " --> " hms(end)
        print "thumbs.jpg#xywh=" x "," y ",160," th
        print ""
      }
    }' > "$CIKTI/thumbs.vtt" || return 1
  [ -s "$CIKTI/thumbs.vtt" ] || return 1
  return 0
}
if onizleme_yap; then
  onizleme=true
else
  echo "::warning::önizleme küçük kareleri üretilemedi (video yine hazır)."
  rm -f "$CIKTI/thumbs.jpg" "$CIKTI/thumbs.vtt"
fi

parca=$(find "$CIKTI" -name '*.ts' | wc -l)
dosya=$(find "$CIKTI" -type f | wc -l); dosya=$((dosya + 1))   # + meta.json
boyut=$(du -sb "$CIKTI" | cut -f1)
yukseklik=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=nw=1:nk=1 "$ILK_PARCA" | sed -n 1p || true)
[ "$sifreli" = false ] || rm -f "$ILK_PARCA"
jq -n --arg slug "$(basename "$CIKTI")" --arg baslik "${BASLIK:-$(basename "$CIKTI")}" \
  --argjson sure "$sure" --argjson parca "$parca" --argjson dosya "$dosya" --argjson boyut "$boyut" \
  --argjson en_buyuk "$buyuk" --argjson parca_sure "$hls_sure" --argjson yukseklik "${yukseklik:-0}" \
  --arg video "$vmod" --arg ses "$amod" --argjson sifreli "$sifreli" --argjson onizleme "$onizleme" \
  --arg tarih "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{slug: $slug, baslik: $baslik, sure: $sure, parca: $parca, dosya: $dosya, boyut: $boyut, en_buyuk_parca: $en_buyuk,
    parca_sure: $parca_sure, yukseklik: $yukseklik, mod: {video: $video, ses: $ses}, sifreli: $sifreli,
    onizleme: $onizleme, tarih: $tarih}' \
  > "$CIKTI/meta.json"

echo "Bitti: $parca parça, toplam $((boyut / 1048576)) MiB, en büyük parça $((buyuk / 1048576)) MiB, şifreli=$sifreli"
