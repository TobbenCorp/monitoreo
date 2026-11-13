#!/usr/bin/env bash
# Abre, actualiza o cierra el aviso (issue con etiqueta "caido") según revisar.sh.
# El aviso se asigna al administrador: GitHub le avisa por correo y en la app.
set -euo pipefail
ASIGNADO="${ASIGNADO:-TobbenTT}"
gh label create caido --color B60205 --description "Algún sitio no responde" >/dev/null 2>&1 || true
abierto="$(gh issue list --label caido --state open --json number --jq '.[0].number // empty')"
problemas="$(cat caidos.txt certificados.txt)"
ahora="$(TZ=America/Santiago date '+%d-%m-%Y %H:%M')"
if [ -n "$problemas" ]; then
  cuerpo="$(printf 'Revisión del %s (hora de Chile):\n\n%s\n\nSe vuelve a revisar cada 10 minutos. Este aviso se cierra solo cuando todo responda.' "$ahora" "$problemas")"
  if [ -z "$abierto" ]; then
    titulo="🔴 Problema: $(grep -oE '\*\*[^*]+\*\*' <<<"$problemas" | tr -d '*' | paste -sd ', ' -)"
    gh issue create --title "$titulo" --body "$cuerpo" --label caido --assignee "$ASIGNADO" >/dev/null
    echo "aviso abierto"
  else
    previo="$(gh issue view "$abierto" --json comments,body --jq '(.comments | last | .body) // .body')"
    # solo comentar si cambió la lista de problemas (no repetir cada 10 minutos)
    if [ "$(sed -n '3,$p' <<<"$previo" | grep -E '^- ' || true)" != "$(grep -E '^- ' <<<"$problemas")" ]; then
      gh issue comment "$abierto" --body "$cuerpo" >/dev/null
      echo "aviso actualizado"
    fi
  fi
elif [ -n "$abierto" ]; then
  gh issue comment "$abierto" --body "✅ Todo responde otra vez ($ahora, hora de Chile)." >/dev/null
  gh issue close "$abierto" >/dev/null
  echo "aviso cerrado"
else
  echo "todo bien"
fi
