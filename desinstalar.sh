#!/bin/bash
# Desinstala o serviço SIGADI (e restos da instalação antiga "sgf", se houver).
# O banco de dados (/opt/sigadi/sigadi_dados.json) e os backups são
# PRESERVADOS — remova /opt/sigadi manualmente se quiser.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Execute como root:  sudo ./desinstalar.sh"
    exit 1
fi

systemctl disable --now sigadi.service 2>/dev/null || true
systemctl disable --now sgf.service 2>/dev/null || true
rm -f /etc/systemd/system/sigadi.service /etc/cron.d/sigadi-backup \
      /etc/systemd/system/sgf.service /etc/cron.d/sgf-backup
systemctl daemon-reload

echo "Serviço removido. Dados preservados em /opt/sigadi (apague com: rm -rf /opt/sigadi)"
[ -d /opt/sgf ] && echo "Atenção: ainda existe /opt/sgf (instalação antiga) — rode ./migrar-sgf-para-sigadi.sh se quiser aproveitar os dados."
exit 0
