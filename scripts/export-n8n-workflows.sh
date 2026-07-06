#!/bin/bash
# Weekly export of BYG n8n workflows from the shared VPS n8n instance into git.
#
# The VPS n8n (root-n8n-1) hosts ~500 workflows across many unrelated clients —
# only ours (named "WF<n> - ..." or "BYG WF<n> ...") may land in this repo.
#
# Read-only against n8n: `n8n export:workflow` only reads the DB, it never
# touches/imports/activates anything, so this cannot repeat the "workflows
# got deactivated" incident. Do not add an import step here.
#
# ponytail: name-based filtering (regex below), not a maintained allowlist of
# workflow IDs — cheaper to keep in sync, add an ID allowlist if the naming
# convention ever gets inconsistent.
set -euo pipefail

VPS_HOST="root@69.62.108.2"
VPS_PASS_FILE="/root/.vps_pass"
CONTAINER="root-n8n-1"
REPO_DIR="/opt/inmobiliaria24"
EXPORT_DIR="$REPO_DIR/n8n-export"
REMOTE_TMP="/tmp/wf-export-$$"
# Matches: "WF1 - ...", "WF3a - ...", "BYG WF20 ..."
NAME_FILTER='^(BYG )?WF[0-9]'

if [ ! -f "$VPS_PASS_FILE" ]; then
    echo "Missing $VPS_PASS_FILE (VPS root password, chmod 600 root:root)" >&2
    exit 1
fi
VPS_PASS=$(cat "$VPS_PASS_FILE")

echo "==> Exporting + filtering workflows on the VPS (read-only)"
sshpass -p "$VPS_PASS" ssh -o StrictHostKeyChecking=no "$VPS_HOST" bash -s <<REMOTE_SCRIPT
set -euo pipefail
rm -rf "$REMOTE_TMP" "$REMOTE_TMP-filtered"
mkdir -p "$REMOTE_TMP" "$REMOTE_TMP-filtered"
docker exec "$CONTAINER" sh -c "rm -rf /tmp/wf-export && mkdir -p /tmp/wf-export && n8n export:workflow --all --separate --output=/tmp/wf-export/"
docker cp "$CONTAINER":/tmp/wf-export/. "$REMOTE_TMP"/
docker exec "$CONTAINER" rm -rf /tmp/wf-export
for f in "$REMOTE_TMP"/*.json; do
    name=\$(jq -r '.name' "\$f")
    if echo "\$name" | grep -Eq '$NAME_FILTER'; then
        slug=\$(echo "\$name" | tr -c 'A-Za-z0-9_-' '_')
        cp "\$f" "$REMOTE_TMP-filtered/\${slug}.json"
    fi
done
echo "Filtered \$(ls "$REMOTE_TMP-filtered" | wc -l) BYG workflows out of \$(ls "$REMOTE_TMP" | wc -l) total"
rm -rf "$REMOTE_TMP"
REMOTE_SCRIPT

echo "==> Pulling filtered workflows to $EXPORT_DIR"
mkdir -p "$EXPORT_DIR"
find "$EXPORT_DIR" -maxdepth 1 -name '*.json' -delete
sshpass -p "$VPS_PASS" scp -o StrictHostKeyChecking=no "$VPS_HOST:$REMOTE_TMP-filtered/*.json" "$EXPORT_DIR/"
sshpass -p "$VPS_PASS" ssh -o StrictHostKeyChecking=no "$VPS_HOST" "rm -rf $REMOTE_TMP-filtered"

echo "==> Committing snapshot"
cd "$REPO_DIR"
git add n8n-export/
if git diff --cached --quiet; then
    echo "No changes in n8n-export/ — nothing to commit"
else
    git -c user.name="pi-exporter" -c user.email="pi@byg" commit -m "chore(n8n): weekly workflow export snapshot ($(date +%F))"
fi

echo "==> Attempting push to n8n-backup (best-effort, never to main)"
if git push origin HEAD:refs/heads/n8n-backup 2>/tmp/n8n-export-push.log; then
    echo "Pushed to origin/n8n-backup"
else
    echo "Push unavailable (no stored credentials) — commit left local only. See /tmp/n8n-export-push.log"
fi
