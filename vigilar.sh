#!/usr/bin/env bash
# Vigilante local de los sitios de esta VPS. Lo corre cron cada 10 minutos.
#
# Existe porque el scheduler de GitHub Actions no es fiable: el workflow del
# repo TobbenCorp/monitoreo declara "*/10 * * * *" pero GitHub lo ejecuta cada
# 6-9 horas. El 26-11-2026 las tres demos estuvieron ~12 h devolviendo 502 y el
# aviso tardó 4 h en abrirse.
#
# Hace tres cosas:
#   1. revisa los sitios de sitios.txt. La lista vive en el repo de monitoreo
#      (única fuente de verdad) y se cachea aquí por si GitHub no responde;
#   2. repara el único fallo conocido: frd-caddy recreado sin la red
#      demos_edge, que deja todos los *.demos.tobben.site en 502;
#   3. cuando el estado CAMBIA (se cae algo, o se recupera todo), dispara el
#      workflow de monitoreo para que el aviso en GitHub salga al momento en
#      lugar de esperar su próxima corrida. Eso necesita un token en
#      /etc/monitoreo.env; sin token ese paso se salta con un aviso en el log y
#      los otros dos siguen funcionando igual.
#
# Los reintentos aquí son cortos a propósito (2 intentos) porque el filtro fino
# lo hace revisar.sh en el runner, con 3 intentos separados por 20 s, antes de
# abrir cualquier aviso. Este script prioriza reparar y avisar rápido.
set -uo pipefail

DIR=/opt/monitoreo
LISTA="$DIR/sitios.txt"
ESTADO="$DIR/estado"
LOG=/var/log/monitoreo/vigilar.log
FUENTE=https://raw.githubusercontent.com/TobbenCorp/monitoreo/main/sitios.txt
REPO=TobbenCorp/monitoreo
CADDY=frd-caddy
RED=demos_edge
MAX_LOG=5242880 # 5 MB

mkdir -p "$DIR" "$(dirname "$LOG")"

registrar() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

# Rotar antes de escribir, para que el log no crezca sin fin como le pasó a
# /var/log/mfc-cron.log (466 KB de un cron que fallaba desde hacía 14 días).
if [ -f "$LOG" ] && [ "$(stat -c %s "$LOG")" -gt "$MAX_LOG" ]; then
	mv -f "$LOG" "$LOG.1"
	registrar "log rotado"
fi

# Una sola instancia a la vez: si la revisión anterior aún corre, salir.
exec 9>"$DIR/.lock"
flock -n 9 || exit 0

# ---------------------------------------------------------------- lista
if curl -fsS --max-time 20 "$FUENTE" -o "$LISTA.nuevo" 2>/dev/null; then
	# Solo aceptarla si trae al menos una línea útil, para no quedarnos con un
	# archivo vacío o una página de error de GitHub.
	if grep -qE '^[^#]+\|[^|]+\|' "$LISTA.nuevo"; then
		mv -f "$LISTA.nuevo" "$LISTA"
	else
		rm -f "$LISTA.nuevo"
		registrar "la lista descargada no tiene formato válido; uso la copia local"
	fi
else
	rm -f "$LISTA.nuevo"
	[ -f "$LISTA" ] || { registrar "ERROR: no pude descargar sitios.txt y no hay copia local"; exit 1; }
fi

# ---------------------------------------------------------------- revisar
revisar() { # revisar <intentos> -> imprime "nombre|url" de cada caído
	local intentos="$1" nombre url esperado codigo i
	while IFS='|' read -r nombre url esperado; do
		nombre="$(echo "$nombre" | xargs)"
		url="$(echo "$url" | xargs)"
		esperado="$(echo "$esperado" | xargs)"
		[ -z "$nombre" ] || [[ "$nombre" == \#* ]] && continue
		[ -z "$url" ] && continue
		for ((i = 1; i <= intentos; i++)); do
			codigo="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
				-A 'TobbenCorp-vigilante' "$url" || echo 000)"
			[ "$codigo" = "$esperado" ] && break
			[ "$i" -lt "$intentos" ] && sleep 10
		done
		[ "$codigo" = "$esperado" ] || echo "$nombre|$url|$codigo|$esperado"
	done < "$LISTA"
}

caidos="$(revisar 2)"

# ---------------------------------------------------------------- reparar
# Único arreglo automático, deliberadamente estrecho: si hay demos caídas y
# frd-caddy no está en demos_edge, reconectarlo. Es idempotente y no reinicia
# nada. Cualquier otra causa se registra y se deja para una persona.
if [ -n "$caidos" ] && grep -q 'demos\.tobben\.site' <<< "$caidos"; then
	if ! docker ps --format '{{.Names}}' | grep -qx "$CADDY"; then
		registrar "demos caídas y $CADDY no está corriendo: no toco nada, requiere revisión"
	elif ! docker network ls --format '{{.Name}}' | grep -qx "$RED"; then
		registrar "demos caídas y la red $RED no existe: no toco nada, requiere revisión"
	elif docker inspect "$CADDY" \
		--format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' |
		grep -qw "$RED"; then
		registrar "demos caídas pero $CADDY ya está en $RED: la causa es otra, requiere revisión"
	else
		if docker network connect "$RED" "$CADDY" 2>>"$LOG"; then
			registrar "REPARADO: $CADDY no estaba en $RED y lo reconecté"
			sleep 3
			caidos="$(revisar 1)"
			[ -z "$caidos" ] && registrar "tras reparar, todo responde"
		else
			registrar "ERROR: falló docker network connect $RED $CADDY"
		fi
	fi
fi

# ---------------------------------------------------------------- avisar
firma="$(cut -d'|' -f1 <<< "${caidos:-}" | sort | paste -sd ',' -)"
previo="$(cat "$ESTADO" 2>/dev/null || echo '')"
printf '%s' "$firma" > "$ESTADO"

if [ -n "$caidos" ]; then
	registrar "CAÍDOS: $(while IFS='|' read -r n u c e; do
		[ -n "$n" ] && printf '%s (respondió %s, esperaba %s) ' "$n" "$c" "$e"
	done <<< "$caidos")"
else
	# Una línea por revisión sana sería ruido; basta con registrar el momento en
	# que todo vuelve a estar bien.
	[ -n "$previo" ] && registrar "todo responde otra vez"
fi

# Disparar el aviso solo en los cambios de estado, no en cada revisión: así no
# se gastan 144 corridas diarias del workflow y el issue se abre o se cierra en
# cuanto algo pasa de verdad.
if [ "$firma" != "$previo" ]; then
	# shellcheck source=/dev/null
	[ -f /etc/monitoreo.env ] && . /etc/monitoreo.env
	if [ -n "${GH_TOKEN:-}" ]; then
		codigo="$(curl -s -o /dev/null -w '%{http_code}' -X POST --max-time 20 \
			-H "Authorization: Bearer $GH_TOKEN" \
			-H "Accept: application/vnd.github+json" \
			-H "X-GitHub-Api-Version: 2022-11-28" \
			"https://api.github.com/repos/$REPO/actions/workflows/monitoreo.yml/dispatches" \
			-d '{"ref":"main"}')"
		if [ "$codigo" = "204" ]; then
			registrar "cambio de estado: disparé el workflow de monitoreo"
		else
			registrar "ERROR: el disparo del workflow devolvió $codigo (¿token vencido o sin permiso actions:write?)"
		fi
	else
		registrar "cambio de estado, pero no hay GH_TOKEN en /etc/monitoreo.env: el aviso en GitHub esperará su propia corrida"
	fi
fi
