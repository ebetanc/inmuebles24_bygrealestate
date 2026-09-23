#!/bin/bash
# Weekly export of BYG n8n workflows from the shared VPS to root-only Pi backups.
#
# The VPS n8n hosts workflows for other clients. A forced SSH command on the
# dedicated key streams only the fixed BYG workflow allowlist.
#
# Read-only against n8n: `n8n export:workflow` only reads the DB, it never
# touches/imports/activates anything, so this cannot repeat the "workflows
# got deactivated" incident. Do not add an import step here.
#
# The VPS allowlist is explicit because its n8n instance is shared.
set -euo pipefail

VPS_HOST="${VPS_HOST:-root@69.62.108.2}"
VPS_SSH_KEY="${VPS_SSH_KEY:-$HOME/.ssh/id_rsa}"
BACKUP_DIR="/var/backups/inmobiliaria24/n8n-export"
STAGE=$(mktemp -d /tmp/i24-n8n-export.XXXXXX)
trap 'rm -rf -- "$STAGE"' EXIT

# Quoted expansion keeps key paths with spaces intact.
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o BatchMode=yes -i "$VPS_SSH_KEY")

if [ ! -f "$VPS_SSH_KEY" ]; then
    echo "FATAL: SSH key not found at $VPS_SSH_KEY. Set VPS_SSH_KEY env var or place your key at the default path." >&2
    echo "Generate one with: ssh-keygen -t ed25519 -C 'export-n8n' -f ~/.ssh/id_ed25519_n8n" >&2
    echo "Then copy to the VPS: ssh-copy-id -i ~/.ssh/id_ed25519_n8n $VPS_HOST" >&2
    exit 1
fi

echo "==> Receiving allowlisted workflow snapshot from VPS"
ssh "${SSH_OPTS[@]}" "$VPS_HOST" > "$STAGE/export.tar.gz"
mkdir "$STAGE/new"
tar -xzf "$STAGE/export.tar.gz" -C "$STAGE/new"
count=$(find "$STAGE/new" -maxdepth 1 -name '*.json' -type f | wc -l)
[ "$count" -eq 29 ] || { echo "FATAL: expected 29 BYG workflows, got $count" >&2; exit 1; }

echo "==> Scrubbing real credential ids to REPLACE_WITH_* placeholders"
# Live exports embed real n8n credential ids. The repo invariant (enforced by
# tests/test_lrv2_e2e_regression.py) is placeholders-only: scrub before archiving.
python3 - "$STAGE/new" <<'SCRUB'
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
    changed = False
    for workflow in data if isinstance(data, list) else [data]:
        changed |= scrub_nodes(workflow.get("nodes"))
        if isinstance(workflow.get("activeVersion"), dict):
            changed |= scrub_nodes(workflow["activeVersion"].get("nodes"))
    if changed:
        path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print("scrubbed %s" % path.name)
SCRUB

echo "==> Saving private, dated snapshot on the Pi"
install -d -m 700 "$BACKUP_DIR"
archive="$BACKUP_DIR/$(date -u +%Y-%m-%dT%H%M%SZ).tar.gz"
tar -C "$STAGE/new" -czf "$STAGE/snapshot.tar.gz" .
install -m 600 "$STAGE/snapshot.tar.gz" "$archive"
sha256sum "$archive" > "$archive.sha256"
chmod 600 "$archive.sha256"
echo "Saved $count workflows to $archive"
