#!/usr/bin/env bash
# deploy.sh — Pull latest code and restart the scraper service.
# Usage: sudo bash deploy.sh
set -euo pipefail

APP_DIR="/opt/inmobiliaria24"
VENV="${APP_DIR}/.venv"

echo "==> Pulling latest code..."
cd "$APP_DIR"
git pull --ff-only origin main

echo "==> Installing dependencies..."
"${VENV}/bin/pip" install -e . --quiet

echo "==> Reloading systemd and restarting timer..."
install -m 644 deploy/inmobiliaria24.timer /etc/systemd/system/inmobiliaria24.timer
install -m 644 deploy/inmobiliaria24-dispatch.service /etc/systemd/system/inmobiliaria24-dispatch.service
install -m 644 deploy/inmobiliaria24-dispatch.timer /etc/systemd/system/inmobiliaria24-dispatch.timer
systemctl daemon-reload
systemctl restart inmobiliaria24.timer
systemctl enable inmobiliaria24.timer
systemctl enable --now inmobiliaria24-dispatch.timer

echo "==> Timer status:"
systemctl status inmobiliaria24.timer --no-pager

echo "==> Done!"
