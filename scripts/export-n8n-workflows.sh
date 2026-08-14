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

VPS_HOST="${VPS_HOST:-root@69.62.108.2}"
VPS_SSH_KEY="${VPS_SSH_KEY:-$HOME/.ssh/id_rsa}"
CONTAINER="root-n8n-1"
REPO_DIR="/opt/inmobiliaria24"
EXPORT_DIR="$REPO_DIR/n8n-export"
REMOTE_TMP="/tmp/wf-export-$$"
# Matches: "WF1 - ...", "WF3a - ...", "BYG WF20 ..."
NAME_FILTER='^(BYG )?WF[0-9]'

# One options array for both ssh and scp; quoted expansion keeps key paths with spaces intact.
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o BatchMode=yes -i "$VPS_SSH_KEY")

if [ ! -f "$VPS_SSH_KEY" ]; then
    echo "FATAL: SSH key not found at $VPS_SSH_KEY. Set VPS_SSH_KEY env var or place your key at the default path." >&2
    echo "Generate one with: ssh-keygen -t ed25519 -C 'export-n8n' -f ~/.ssh/id_ed25519_n8n" >&2
    echo "Then copy to the VPS: ssh-copy-id -i ~/.ssh/id_ed25519_n8n $VPS_HOST" >&2
    exit 1
fi

echo "==> Exporting + filtering workflows on the VPS (read-only)"
ssh "${SSH_OPTS[@]}" "$VPS_HOST" bash -s <<REMOTE_SCRIPT
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
scp "${SSH_OPTS[@]}" "$VPS_HOST:$REMOTE_TMP-filtered/*.json" "$EXPORT_DIR/"
ssh "${SSH_OPTS[@]}" "$VPS_HOST" "rm -rf $REMOTE_TMP-filtered"

echo "==> Scrubbing real credential ids to REPLACE_WITH_* placeholders"
# Live exports embed real n8n credential ids. The repo invariant (enforced by
# tests/test_lrv2_e2e_regression.py) is placeholders-only: scrub before committing.
python3 - "$EXPORT_DIR" <<'SCRUB'
import json, sys
from pathlib import Path

def scrub_nodes(nodes):
    changed = False
    for node in nodes or []:
        for ctype, cred in (node.get("credentials") or {}).items():
            if isinstance(cred, dict) and "id" in cred:
                placeholder = "REPLACE_WITH_%s_CREDENTIAL_ID" % "".join(
                    c if c.isalnum() else "_" for c in ctype).upper()
                if cred["id"] != placeholder:
                    cred["id"] = placeholder
                    changed = True
    return changed

for path in sorted(Path(sys.argv[1]).glob("*.json")):
    data = json.loads(path.read_text(encoding="utf-8-sig"))
    changed = scrub_nodes(data.get("nodes"))
    if isinstance(data.get("activeVersion"), dict):
        changed |= scrub_nodes(data["activeVersion"].get("nodes"))
    if changed:
        path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print("scrubbed %s" % path.name)
SCRUB

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
