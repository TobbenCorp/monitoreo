# Monitoreo

Revisa cada 10 minutos que los sitios de TobbenCorp respondan y que sus certificados HTTPS no estén
por vencer. Si algo falla (3 intentos), abre un **aviso** en [Issues](../../issues) asignado al
administrador —GitHub avisa por correo y en la app—; cuando todo vuelve, lo cierra solo.

- Sitios revisados: [`sitios.txt`](sitios.txt) (`nombre | url | código esperado`).
- Revisar ahora: **Actions → Monitoreo → Run workflow**.
