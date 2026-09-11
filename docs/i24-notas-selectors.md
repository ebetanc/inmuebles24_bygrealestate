# Inmuebles24 · pestaña Notas (DOM verificado 2026-09-11)

Descubrimiento hecho desde Windows con Brave + CDP (`--remote-debugging-port=9222`,
`connect_over_cdp`) sobre el lead `266673624`. Solo lectura: nunca se pulsó Anotar.
Selectores vivos en `src/inmobiliaria24/i24_notes.py`.

| Elemento | DOM real | Selector Playwright |
|---|---|---|
| Pestaña Notas | `<button class="sc-…"><svg/><div><span>Notas</span><span></span></div></button>` (sin `role`, sin `id`, clases styled-components) | `text=/^\s*Notas\s*$/` (clic en el span burbujea al button). `role=tab` NO existe. |
| Caja de texto | `<textarea placeholder="Escribí una nota interna. No será compartida con tu contacto" rows="1">` — aparece solo tras pulsar Notas y **reemplaza** al textarea de mensajes (`placeholder="Escribe un mensaje"`) | `textarea[placeholder^='Escribí una nota interna']` |
| Botón | `<button type="button" size="200" disabled><span>Anotar</span></button>` — `disabled` hasta que hay texto; `page.fill` lo habilita | `button:has-text('Anotar')` + `is_disabled` |
| Nota existente | `<div class="sc-kSgnbT …"><svg/><b>Nota interna: </b>Gina</div>` seguido de `<span>13:04</span>` | `text=/^\s*Nota interna:\s*<texto>\s*$/` (matchea el div, textContent `Nota interna: Gina`) |

Texto de la nota (migración `20260913100000_v3_i24_note_ledger.sql`):
`<PrimerNombre> · V3 HH:MM` o `SIN ASIGNACIÓN · V3 HH:MM` (hora CDMX del desenlace).
La marca `V3` distingue nota automática de manual.

Receta de descubrimiento: cerrar Brave, relanzar
`brave.exe --remote-debugging-port=9222 --restore-last-session --profile-directory=Default`,
`curl 127.0.0.1:9222/json/version`, y correr `scripts/i24_notes_discover.py` adaptado a
`pw.chromium.connect_over_cdp("http://127.0.0.1:9222")`. Nunca desde el Pi de día.
