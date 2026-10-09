#!/bin/bash
# Backup do banco do SIGADI (sigadi_dados.json). Mantém os últimos 30.
# Agendado pelo instalador em /etc/cron.d/sigadi-backup (diário, 20h00).
set -euo pipefail

DIR=/opt/sigadi
DEST="$DIR/backups"

[ -f "$DIR/sigadi_dados.json" ] || exit 0
mkdir -p "$DEST"
cp "$DIR/sigadi_dados.json" "$DEST/sigadi_dados_$(date +%F_%H%M).json"

# Retenção: apaga os mais antigos, mantendo 30
ls -1t "$DEST"/sigadi_dados_*.json 2>/dev/null | tail -n +31 | xargs -r rm --
