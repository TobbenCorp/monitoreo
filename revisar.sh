#!/usr/bin/env bash
# Revisa cada sitio de sitios.txt (3 intentos separados por 20 s antes de darlo
# por caído) y los días que le quedan a su certificado HTTPS.
# Escribe caidos.txt y certificados.txt (vacíos si todo está bien).
set -uo pipefail
: > caidos.txt
: > certificados.txt
declare -A hosts_vistos
while IFS='|' read -r nombre url esperado; do
  nombre="$(echo "$nombre" | xargs)"; url="$(echo "$url" | xargs)"; esperado="$(echo "$esperado" | xargs)"
  [ -z "$nombre" ] || [[ "$nombre" == \#* ]] && continue
  ok=""; ultimo=""
  for intento in 1 2 3; do
    ultimo="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -A 'TobbenCorp-monitoreo' "$url" || echo "000")"
    [ "$ultimo" = "$esperado" ] && ok=1 && break
    [ "$intento" -lt 3 ] && sleep 20
  done
  if [ -z "$ok" ]; then
    echo "- **$nombre** ($url): respondió \`$ultimo\`, se esperaba \`$esperado\`" >> caidos.txt
  fi
  host="$(echo "$url" | sed -E 's#https?://([^/]+).*#\1#')"
  if [ -z "${hosts_vistos[$host]:-}" ]; then
    hosts_vistos[$host]=1
    fin="$(echo | timeout 15 openssl s_client -servername "$host" -connect "$host:443" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
    if [ -n "$fin" ]; then
      dias=$(( ( $(date -d "$fin" +%s) - $(date +%s) ) / 86400 ))
      echo "$host: certificado vence en $dias días"
      [ "$dias" -lt 14 ] && echo "- **$host**: el certificado HTTPS vence en $dias días ($fin)" >> certificados.txt
    fi
  fi
  echo "$nombre: ${ok:+OK}${ok:-CAÍDO} ($ultimo)"
done < sitios.txt
