# Monitoreo

Revisa que los sitios de TobbenCorp respondan y que sus certificados HTTPS no estén por vencer. Si
algo falla (3 intentos separados por 20 s), abre un **aviso** en [Issues](../../issues) asignado al
administrador —GitHub avisa por correo y en la app—; cuando todo vuelve, lo cierra solo.

- Sitios revisados: [`sitios.txt`](sitios.txt) (`nombre | url | código esperado`).
- Revisar ahora: **Actions → Monitoreo → Run workflow**.

El código esperado es el que devuelve curl **sin** seguir redirecciones. Por eso un dominio que
redirige se vigila con su `301` (así se comprueba que el redirect sigue vivo) y la API de la
funeraria con su `404`, que es lo que responde sana.

## Por qué hay dos capas

El workflow declara `cron: "*/10 * * * *"`, pero **GitHub no lo cumple**: en la práctica lo ejecuta
cada 6–9 horas, porque deprioriza los `schedule` de Actions. El 26-11-2026 las tres demos
estuvieron ~12 h devolviendo 502 y el aviso tardó 4 h en abrirse.

Así que la vigilancia real vive en la VPS y este repo se queda con lo que sabe hacer bien —
comprobar desde fuera y gestionar el aviso:

| | [`revisar.sh`](revisar.sh) + [`avisar.sh`](avisar.sh) (aquí) | [`vigilar.sh`](vigilar.sh) (en la VPS) |
|---|---|---|
| Lo corre | GitHub Actions, cada 6–9 h | cron de la VPS, cada 10 min de verdad |
| Mira desde | fuera (runner de GitHub) | dentro (hairpin a sus propios dominios) |
| Reintentos | 3, separados por 20 s | 2, separados por 10 s |
| Abre y cierra el aviso | sí | no, solo dispara este workflow |
| Repara | no | sí, el fallo conocido de `demos_edge` |

`vigilar.sh` se guarda aquí para que esté versionado, pero **el que corre es la copia de
`/opt/monitoreo/vigilar.sh` en la VPS**. Si lo cambias, súbelo con `scp` a esa ruta. Este repo es
público, así que no lleva ni la dirección del servidor ni credenciales.

La lista de sitios no se duplica: `vigilar.sh` descarga `sitios.txt` de este repo en cada revisión
(y cachea la última copia buena por si GitHub no responde), así que **este archivo es la única
fuente de verdad**. Añade aquí cada demo nueva que publiques.

## El vigilante de la VPS

- Log: `/var/log/monitoreo/vigilar.log`, se rota solo a los 5 MB.
- **Con todo sano no escribe nada**, para no generar ruido. Si quieres confirmar que corrió, mira la
  fecha de `/opt/monitoreo/estado`, que se reescribe en cada revisión.
- Repara un solo fallo, a propósito: si alguna `*.demos` está caída y `frd-caddy` no está en la red
  `demos_edge`, la reconecta. Es idempotente y no reinicia nada. Cualquier otra causa solo se
  registra, para que la vea una persona.
  - Ese fallo ocurre porque `/opt/demos/add-demo.sh` conecta Caddy a `demos_edge` a mano, así que
    cualquier `docker compose up -d` en `/opt/funeraria` lo dejaba fuera y todas las demos
    respondían 502. Ya está declarado en el compose de la funeraria, y esto es el cinturón de
    seguridad.
- Dispara este workflow solo cuando **cambia** el estado (se cae algo o se recupera todo), no en
  cada revisión, para no gastar 144 corridas al día. Necesita un PAT en `/etc/monitoreo.env`
  (`GH_TOKEN`), fine-grained, solo este repo, permiso `Actions: Read and write`. Sin token sigue
  revisando y reparando, y lo anota en el log.
