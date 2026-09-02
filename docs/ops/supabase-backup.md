# Backup nocturno de Supabase Postgres

## Qué hace y cuándo

`scripts/supabase-backup.sh` corre en el VPS (Hostinger) vía
`deploy/supabase-backup.timer` todas las noches a las **09:20 UTC (03:20
CDMX)**, con hasta 5 min de jitter (`RandomizedDelaySec`). Es de solo
lectura contra la base: usa `pg_dump` dentro del contenedor
`postgres:17-alpine` (no toca n8n ni `root-n8n-1`, no reinicia nada).

Genera dos archivos por corrida:
- `supabase-<timestamp>.dump` — dump `--format=custom` de los schemas
  `public` y `supabase_migrations` (si el rol no puede leer
  `supabase_migrations`, se omite y queda anotado en el log).
- `supabase-<timestamp>.schema.sql.gz` — dump `--schema-only` en SQL plano,
  para diffs legibles.

Cada corrida valida el `.dump` con `pg_restore --list` (debe reportar más de
0 entradas) antes de darla por buena, y escribe una línea de resultado en el
log.

## Dónde quedan los dumps

`/root/backups/supabase/` en el VPS:
- `supabase-*.dump`, `supabase-*.schema.sql.gz`
- `backup.log` — una línea por corrida: timestamp UTC, `OK`/`FAIL`, tamaño,
  # de entradas.

Retención: se conservan los **14 `.dump` más recientes** (y su `.sql.gz`
correspondiente); los más viejos se borran automáticamente.

## Cómo restaurar un dump

```sh
docker run --rm --env-file /root/.supabase-backup.env -e PGSSLMODE=require \
  -v /root/backups/supabase:/in postgres:17-alpine \
  pg_restore --no-password --clean --if-exists -d "$PGDATABASE" \
  /in/supabase-<timestamp>.dump
```

Usar siempre contra una base de prueba primero si no es una restauración de
emergencia — `--clean --if-exists` dropea objetos existentes antes de
recrearlos.

## Cómo verificar que el backup corrió bien

```sh
systemctl list-timers supabase-backup.timer
tail -5 /root/backups/supabase/backup.log
```

Una línea `OK` reciente con `entries` > 0 y un tamaño razonable = backup
sano. `FAIL` en el log o timer inactivo = investigar (`journalctl -u
supabase-backup.service`).
