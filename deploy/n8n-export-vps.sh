#!/bin/bash
# Forced SSH command for the Pi's dedicated n8n export key. Streams only BYG workflows.
set -euo pipefail
PATH=/usr/sbin:/usr/bin:/bin
umask 077

container=root-n8n-1
container_file="/tmp/i24-n8n-export-$$.json"
work=$(mktemp -d /tmp/i24-n8n-export.XXXXXX)
cleanup() {
  docker exec "$container" rm -f "$container_file" >/dev/null 2>&1 || true
  rm -rf -- "$work"
}
trap cleanup EXIT

docker exec "$container" n8n export:workflow --all --output="$container_file" >/dev/null
docker cp "$container:$container_file" "$work/all.json"
mkdir "$work/filtered"
python3 - "$work/all.json" "$work/filtered" <<'PY'
import json
import sys
from pathlib import Path

allowed = {
    'ZUO5otqPzu9VYv8Z', '04aQhTOiXlDmN9bK', 'JM2HxJxl53k4zlki',
    'UNIKqyAvIUAZkNIs', 'tnvPoAmVZ0zqGzOs', 'pYGcyX1ur24dQVew',
    'snF6Sr9CBJIevMVD', 'xzBG0GIsHCUd44DC', 'LHQukWVhcmSfPwQb',
    'Obr38705ZZYS3FB8', 'ZI5mD6269xSZhltN', 'w7yJr7naWoxPq6Pw',
    'K8Hzk2fCYjZHWNKi', 'Zwp2aENlqLQwF3Ry', 'T9hj26uXtPUR69Xh',
    'wf1smoketest01', 'wf15smoketest01', 'wf16smoketest01',
    'Mu3YTTH8IgtaH7Ml', 'Bo2YbbUpmBzRbhDa', 'YkhDEps0WbqaszMX',
    'zOHmTODH4QSqALnp', '2nB5HkGii7ftzosn', 'pYV88ntxI0Lc4NCB',
    'He95yJflKVspGFyb', 'Z89IQDw1fgWlqXEW', 'MjfHw3tYE2qYgJfM',
    'NpPnb8GHubpGSsku', 'WF24V3MonitorDia',
}
workflows = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8-sig'))
found = set()
for workflow in workflows:
    workflow_id = workflow.get('id')
    if workflow_id not in allowed:
        continue
    name = workflow['name']
    slug = ''.join(c if c.isascii() and (c.isalnum() or c in '_-') else '_'
                   for c in name + '\n')
    path = Path(sys.argv[2]) / (slug + '.json')
    if path.exists() or workflow_id in found:
        raise RuntimeError('Duplicate BYG workflow export')
    path.write_text(json.dumps([workflow], ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    found.add(workflow_id)
if found != allowed:
    raise RuntimeError(f'Missing {len(allowed - found)} BYG workflows in n8n export')
PY
tar -C "$work/filtered" -czf - .
