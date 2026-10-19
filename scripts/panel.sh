# Panel API yardımcıları. GitHub Actions'ta source edilir: . scripts/panel.sh
# Kimlik GitHub OIDC (workflow'da "id-token: write" izni gerekli), ayrıntı web/API.md "CI API".
#
# Ortam: PANEL_ADRES (repo değişkeni), ACTIONS_ID_TOKEN_REQUEST_URL/TOKEN (runner verir),
#        PANEL_HATA_DOSYASI (isteğe bağlı: son panel hatasının yazılacağı dosya)
# Anahtarlar asla ekrana yazılmaz.

# Her çağrıda taze bir OIDC anahtarı (ömrü kısa).
panel_jwt() {
  [ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] && [ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ] || {
    echo "HATA: OIDC yok. Workflow'da 'permissions: id-token: write' olmalı." >&2
    return 1
  }
  local jwt
  jwt=$(curl -sS --retry 3 --connect-timeout 20 --max-time 60 \
    -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
    "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=hls-panel" | jq -r '.value // empty') || jwt=
  [ -n "$jwt" ] || { echo "HATA: GitHub OIDC anahtarı alınamadı." >&2; return 1; }
  printf '%s' "$jwt"
}

# panel <METHOD> <yol> [json]
# Başarılıysa yanıt gövdesini yazar. 2xx değilse panelin {hata} metnini stderr'e yazar, 1 döner.
panel() {
  local yontem="$1" yol="$2" govde="${3:-}" jwt yanit kod hata dosya giden=""
  [ -n "${PANEL_ADRES:-}" ] || { echo "HATA: PANEL_ADRES boş." >&2; return 1; }
  jwt=$(panel_jwt) || return 1
  # Yanıt dosyaya: curl yeniden denerken dosyayı sıfırlar (stdout'ta denemeler birbirine eklenirdi)
  dosya=$(mktemp)
  local args=(-sS -X "$yontem" --retry 2 --connect-timeout 20 --max-time 300 -o "$dosya" -w '%{http_code}'
    -H "Authorization: Bearer $jwt" -H "Content-Type: application/json")
  # Gövde de dosyadan: Linux'ta tek komut argümanı en fazla 128 KB, büyük manifest'ler bunu aşar.
  if [ -n "$govde" ]; then
    giden=$(mktemp)
    printf '%s' "$govde" > "$giden"
    args+=(--data-binary "@$giden")
  fi
  kod=$(curl "${args[@]}" "${PANEL_ADRES%/}$yol") || kod=000
  yanit=$(cat "$dosya")
  rm -f "$dosya" ${giden:+"$giden"}
  if [[ "$kod" == 2[0-9][0-9] ]]; then
    printf '%s\n' "$yanit"
    return 0
  elif [ "$kod" = 000 ]; then
    hata="panele ulaşılamadı"
  else
    hata=$(jq -r '.hata // empty' <<< "$yanit" 2>/dev/null || true)
    [ -n "$hata" ] || hata="HTTP $kod: $(printf '%s' "$yanit" | tr -s '\n\r' '  ' | cut -c1-200)"
  fi
  echo "HATA: panel $yontem $yol: $hata" >&2
  [ -z "${PANEL_HATA_DOSYASI:-}" ] || printf '%s' "$hata" > "$PANEL_HATA_DOSYASI"
  return 1
}
