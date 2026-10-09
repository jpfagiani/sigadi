#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────
#  Migra uma instalação ANTIGA (nome "sgf") para o nome novo "sigadi".
#
#  Uso:  sudo ./migrar-sgf-para-sigadi.sh        (o instalar.sh já chama isto)
#
#  O que faz (idempotente — pode rodar quantas vezes quiser; sem instalação
#  antiga, não faz nada):
#    • copia o banco para /root/sgf-premigracao-<data>.json (segurança)
#    • para o serviço sgf e remove sgf.service e /etc/cron.d/sgf-backup
#    • move /opt/sgf → /opt/sigadi e renomeia banco, backups e log
#    • renomeia o usuário/grupo de serviço sgf → sigadi
#    • guarda a porta usada em /run/sigadi-porta-anterior (o instalador
#      reaproveita, para o link que os usuários guardaram continuar valendo)
#  NUNCA apaga o banco; nunca sobrescreve um banco já existente em /opt/sigadi.
# ─────────────────────────────────────────────────────────────────────────
set -uo pipefail

OLD=/opt/sgf
NEW=/opt/sigadi
UNIT_OLD=/etc/systemd/system/sgf.service
CRON_OLD=/etc/cron.d/sgf-backup

if [ "$(id -u)" -ne 0 ]; then
    echo "Execute como root:  sudo ./migrar-sgf-para-sigadi.sh"
    exit 1
fi

msg()  { echo -e "\033[0;36m  → $*\033[0m"; }
ok()   { echo -e "\033[0;32m  ✔ $*\033[0m"; }
warn() { echo -e "\033[1;33m  ⚠ $*\033[0m"; }

tem_legado=0
{ [ -d "$OLD" ] || [ -f "$UNIT_OLD" ] || [ -f "$CRON_OLD" ] || id -u sgf >/dev/null 2>&1; } && tem_legado=1
if [ "$tem_legado" -eq 0 ]; then
    echo "  Nenhuma instalação antiga (sgf) encontrada — nada a migrar."
    exit 0
fi

echo -e "\n\033[1;36m── Migração SGF → SIGADI ──\033[0m\n"

# 1) cópia de segurança do banco, antes de qualquer mudança
if [ -f "$OLD/sgf_dados.json" ]; then
    SEG="/root/sgf-premigracao-$(date +%F-%H%M).json"
    cp -p "$OLD/sgf_dados.json" "$SEG" && ok "Cópia de segurança do banco: $SEG"
fi

# 2) porta atual (vem do ExecStart da unit antiga) e parada do serviço
PORTA_ANT=""
if [ -f "$UNIT_OLD" ]; then
    PORTA_ANT=$(grep -oP 'run_sgf\.py \K[0-9]+' "$UNIT_OLD" 2>/dev/null | head -1)
fi
if [ -n "$PORTA_ANT" ]; then
    echo "$PORTA_ANT" > /run/sigadi-porta-anterior
    msg "Porta usada até agora: ${PORTA_ANT} (será mantida)"
fi
systemctl disable --now sgf.service >/dev/null 2>&1 || true
rm -f "$UNIT_OLD" "$CRON_OLD"
systemctl daemon-reload
ok "Serviço sgf parado e removido (unit e cron antigos)."

# 3) pasta
if [ -d "$OLD" ]; then
    if [ -e "$NEW" ]; then
        warn "$NEW já existe — não vou sobrescrever. Os dados antigos continuam em $OLD."
        warn "Se o banco certo é o antigo:  sudo cp -p $OLD/sgf_dados.json $NEW/sigadi_dados.json"
    else
        mv "$OLD" "$NEW" && ok "Pasta movida: $OLD → $NEW"
    fi
fi

# 4) arquivos dentro da pasta nova
if [ -d "$NEW" ]; then
    renomear() {  # renomear <de> <para>  — só se o destino ainda não existe
        [ -e "$1" ] || return 0
        if [ -e "$2" ]; then warn "$2 já existe; mantive $1 como está."; else mv "$1" "$2"; fi
    }
    renomear "$NEW/sgf_dados.json"     "$NEW/sigadi_dados.json"
    renomear "$NEW/sgf_dados.json.bak" "$NEW/sigadi_dados.json.bak"
    renomear "$NEW/sgf_servidor.log"   "$NEW/sigadi_servidor.log"
    for f in "$NEW"/sgf_dados.json.corrompido.*; do
        [ -e "$f" ] && renomear "$f" "$NEW/sigadi_dados.json.corrompido.${f##*.}"
    done
    if [ -d "$NEW/backups" ]; then
        for f in "$NEW"/backups/sgf_dados_*.json; do
            [ -e "$f" ] && renomear "$f" "$NEW/backups/sigadi_dados_${f##*/sgf_dados_}"
        done
    fi
    rm -f "$NEW/run_sgf.py"   # o instalador copia o run_sigadi.py novo
    ok "Banco, backups e log renomeados para o padrão sigadi."
fi

# 5) usuário/grupo de serviço
if id -u sgf >/dev/null 2>&1; then
    if id -u sigadi >/dev/null 2>&1; then
        warn "Usuário 'sigadi' já existe; o 'sgf' antigo foi mantido (inofensivo)."
    else
        usermod -l sigadi sgf 2>/dev/null && \
        { getent group sgf >/dev/null && groupmod -n sigadi sgf 2>/dev/null; true; } && \
        { [ -d "$NEW" ] && usermod -d "$NEW" sigadi 2>/dev/null; true; } && \
        ok "Usuário de serviço renomeado: sgf → sigadi" || warn "Não consegui renomear o usuário 'sgf' (o instalador criará 'sigadi')."
    fi
fi
[ -d "$NEW" ] && id -u sigadi >/dev/null 2>&1 && chown -R sigadi:sigadi "$NEW"

echo ""
ok "Migração concluída. O instalador (ou 'sudo ./instalar.sh') instala o serviço 'sigadi'."
