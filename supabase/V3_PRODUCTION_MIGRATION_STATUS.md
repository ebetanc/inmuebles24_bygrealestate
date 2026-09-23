# Lead Routing V3 — estado de migraciones de producción

Proyecto Supabase: `wkaeutndwawkdhswisqe` (BYG Real Estate).

Los encabezados `PROPOSED / NO APLICADO` dentro de las migraciones
`20260827154900` y `20260827154901` describen su estado al momento de redactar
los archivos. Esos archivos ya fueron aplicados y se conservan sin cambios para
que sus hashes sigan coincidiendo con la evidencia de producción.

| Versión | Aplicada UTC | SHA-256 | Evidencia |
| --- | --- | --- | --- |
| `20260827154900` | `2026-08-27T15:52:33.654955Z` | `21969b0cefbb7184387a68555d5b326000adebe62c92720027e08d2d80132d9a` | `output/v3-execution/supabase-production-apply.json` |
| `20260827154901` | `2026-08-27T15:52:33.654955Z` | `2b5d5c36edb3c6e501a5643e6428bddabe6cf8e678c433147f860a6afa34de5a` | `output/v3-execution/supabase-production-apply.json` |
| `20260827154902` | `2026-08-27T15:52:33.654955Z` | `6df8ea15112449872c0526e2fc84ce3f951cbdff22c79fb5a9bfd3123ac15527` | `output/v3-execution/supabase-production-apply.json` |
| `20260827154903` | `2026-08-27T15:52:33.654955Z` | `cf26cdb1f80a78fa65fdfa9b8b085db7fafb20722ef480ab2d9d8be39d5928ef` | `output/v3-execution/supabase-production-apply.json` |
| `20260827173500` | `2026-08-27T17:43:38.586253Z` | `a95a94806bb1c7ef778f0424698dcb122019d3d4c9deb3c3c9fec2ac7b9427ef` | `output/v3-execution/supabase-assigned-notice-apply.json` |
| `20260827184755` | `2026-08-27T18:53:21.806328Z` | `52a4ff33f1dc5094c12c07ef11e69eb332b1c59283eb99b004e61d79224128bb` | `output/v3-execution/supabase-safe-offer-claim-apply.json` |

La migración incremental `20260827184755` corrige el reclamo de ofertas
obsoletas. Está aplicada y verificada; WF23 continúa inactivo hasta el gate
operativo explícito de reactivación.

## Verificación 2026-09-23

El registro `supabase_migrations.schema_migrations` termina en
`20260923000000`. El 2026-09-23 se reconciliaron las cinco versiones que
faltaban (`20260911100000`, `20260912100000`, `20260913100000`,
`20260913190000` y `20260923000000`). Antes de registrarlas se compararon las
definiciones de 12 funciones con producción y se comprobaron las tablas,
restricciones y políticas relevantes. Se registró el contenido SQL de cada
archivo sin volver a ejecutar sus instrucciones. Una lectura posterior confirmó
las cinco entradas y una instrucción registrada para cada una.

El 2026-09-23 se aplicaron directamente, en una sola transacción, las dos
funciones de `20260923000000_v3_terminal_route_guard.sql`. Se comparó el cuerpo
de ambas funciones con `20260912100000_v3_unassigned.sql` antes de sustituirlas
y se verificó el cuerpo resultante antes del commit. El SHA-256 del archivo
aplicado fue `753bfed8b82354a9668c2a9bcf03deabb57ef0d2c0d6353d84d39b11b37a3c85`.
Hay copias de reversión de cada definición en `/tmp/codex_rollback_*_20260923.sql`
de la Raspberry Pi. La versión correspondiente ya figura en el registro tras
la reconciliación anterior.

La función de creación automática ahora exige que la captura sea posterior a
`2026-09-23T02:00:00Z` y tenga menos de 24 horas. Los casos anteriores quedan
en la cola histórica para revisión, sin un nuevo POST automático a EasyBroker.
