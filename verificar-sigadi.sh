#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
#  Verifica se o SIGADI foi removido deste servidor e se os dados sobreviveram.
#
#  Uso:  sudo bash verificar-sigadi.sh
#
#  O script NÃO apaga nada. A única coisa que ele escreve é uma cópia de
#  segurança do banco, caso ele ainda exista.
# ─────────────────────────────────────────────────────────────────────────────

ok()    { printf '  \033[32m[ok]\033[0m    %s\n' "$*"; }
falta() { printf '  \033[33m[resta]\033[0m %s\n' "$*"; }
aviso() { printf '  \033[36m[nota]\033[0m  %s\n' "$*"; }
titulo(){ printf '\n\033[1;36m%s\033[0m\n' "$*"; }

PENDENCIAS=0

# A porta real só é conhecida enquanto a unit ainda existir (vem do
# ExecStart, preenchido pelo instalador). Depois de removida não há como
# saber qual foi escolhida — cai no padrão do projeto (8091), com aviso.
PORTA_SIGADI=""
PORTA_ORIGEM="padrão do projeto"
if [ -f /etc/systemd/system/sigadi.service ]; then
    PORTA_SIGADI=$(grep -oP 'run_sigadi\.py \K[0-9]+' /etc/systemd/system/sigadi.service 2>/dev/null)
    [ -n "$PORTA_SIGADI" ] && PORTA_ORIGEM="lida da unit ainda presente"
fi
PORTA_SIGADI="${PORTA_SIGADI:-8091}"

titulo "1. Serviço do SIGADI"
if systemctl list-unit-files 2>/dev/null | grep -q '^sigadi\.service'; then
    falta "a unidade sigadi.service ainda está registrada"
    systemctl is-active sigadi >/dev/null 2>&1 && falta "e o serviço está ATIVO"
    echo  "         remover com: sudo systemctl disable --now sigadi"
    PENDENCIAS=$((PENDENCIAS+1))
else
    ok "nenhum serviço sigadi registrado"
fi

for arq in /etc/systemd/system/sigadi.service /etc/cron.d/sigadi-backup; do
    if [ -e "$arq" ]; then
        falta "$arq ainda existe   (remover: sudo rm $arq)"
        PENDENCIAS=$((PENDENCIAS+1))
    else
        ok "$arq — removido"
    fi
done

titulo "2. Porta do SIGADI (${PORTA_SIGADI}, ${PORTA_ORIGEM})"
EM_USO=$(ss -tlnp 2>/dev/null | grep ":${PORTA_SIGADI} ")
if [ -n "$EM_USO" ]; then
    falta "algo ainda escuta na porta ${PORTA_SIGADI}:"
    echo "$EM_USO" | sed 's/^/         /'
    PENDENCIAS=$((PENDENCIAS+1))
else
    ok "porta ${PORTA_SIGADI} livre"
fi
if [ "$PORTA_ORIGEM" = "padrão do projeto" ]; then
    aviso "não foi possível confirmar a porta real (unit já removida)."
    aviso "se o SIGADI foi instalado em porta diferente de ${PORTA_SIGADI}, confira à mão:"
    echo  "         ss -tlnp | grep LISTEN"
fi

titulo "3. Usuário de serviço"
if id sigadi >/dev/null 2>&1; then
    aviso "o usuário 'sigadi' ainda existe (inofensivo; remover: sudo userdel sigadi)"
else
    ok "usuário 'sigadi' removido"
fi

titulo "4. Dados do SIGADI"
BANCO=/opt/sigadi/sigadi_dados.json
if [ -f "$BANCO" ]; then
    ok "o banco AINDA EXISTE em $BANCO"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$BANCO" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding='utf-8'))
    print("         motoristas: %d | viagens: %d | abastecimentos: %d | usuarios: %d"
          % (len(d.get('motoristas', [])), len(d.get('viagensFCT', [])),
             len(d.get('abastecimentos', [])), len(d.get('usuarios', []))))
except Exception as e:
    print("         (não foi possível ler o conteúdo: %s)" % e)
PY
    fi
    DESTINO="/root/sigadi-linux-$(date +%F-%H%M).json"
    if cp "$BANCO" "$DESTINO" 2>/dev/null; then
        ok "cópia de segurança criada em $DESTINO"
    else
        falta "não consegui copiar o banco (rode com sudo)"
    fi
else
    aviso "não há banco em $BANCO"
    if [ -d /opt/sigadi/backups ]; then
        ok "mas existem backups automáticos:"
        ls -1t /opt/sigadi/backups/*.json 2>/dev/null | head -5 | sed 's/^/         /'
        echo "         (o mais recente é o primeiro da lista)"
    elif [ -d /opt/sigadi ]; then
        aviso "a pasta /opt/sigadi existe, mas sem banco. Conteúdo:"
        ls -la /opt/sigadi 2>/dev/null | sed 's/^/         /' | head -12
    else
        aviso "a pasta /opt/sigadi não existe mais"
        aviso "procurando cópias nos lugares prováveis..."
        # Busca limitada: varrer o disco inteiro poderia demorar muito.
        ACHOU=$(find /root /home /opt /var/backups /tmp /srv -maxdepth 4 \
                     -name 'sigadi*dados*.json' -o -name 'sgf*dados*.json' -o -name 'backup_sigadi*.json' 2>/dev/null | head -10)
        if [ -n "$ACHOU" ]; then
            echo "$ACHOU" | sed 's/^/         /'
        else
            echo "         nenhuma cópia encontrada nesses diretórios"
            echo "         (busca completa, se quiser: sudo find / -name 'sigadi_dados*.json' 2>/dev/null)"
        fi
    fi
fi

titulo "5. Serviços que devem CONTINUAR no ar"
for par in "smbd:compartilhamento Samba" "nginx:servidor web (portal-samba)" "portal-samba:portal de administração do Samba"; do
    svc="${par%%:*}"; desc="${par#*:}"
    if systemctl is-active "$svc" >/dev/null 2>&1; then
        ok "$svc ativo ($desc)"
    else
        aviso "$svc não está ativo ($desc) — confira se isso é esperado"
    fi
done

titulo "Resumo"
if [ "$PENDENCIAS" -eq 0 ]; then
    printf '  \033[32mLimpeza concluída. A porta %s está livre.\033[0m\n' "$PORTA_SIGADI"
    echo  "  Instale com:  sudo ./instalar.sh          (porta 8091 por padrão)"
else
    printf '  \033[33m%d item(ns) ainda pendente(s) — veja as linhas [resta] acima.\033[0m\n' "$PENDENCIAS"
fi
echo
