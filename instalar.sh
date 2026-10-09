#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────
#  SIGADI - Sistema Interno de Gestão Administrativa Integrada
#  Instalador para Debian 13
#  Uso:  sudo ./instalar.sh [porta]
#
#  Genérico para qualquer unidade: pergunta nome, cidade e porta na hora —
#  nada fica preso a uma unidade específica no código.
# ─────────────────────────────────────────────────────────────────────────
set -euo pipefail

DEST=/opt/sigadi
SRC="$(cd "$(dirname "$0")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

ok()    { echo -e "${GREEN}  ✔ $*${NC}"; }
warn()  { echo -e "${YELLOW}  ⚠ $*${NC}"; }
erro()  { echo -e "${RED}  ✖ $*${NC}" >&2; }
info()  { echo -e "${CYAN}  → $*${NC}"; }
titulo(){ echo -e "\n${BOLD}${CYAN}$1${NC}\n"; }
ask()   { echo -e "${BOLD}  $*${NC}"; }
confirmar_padrao_nao() {
    local resposta
    read -rp "  $* [s/N]: " resposta
    case "$resposta" in [sSyY]*) return 0 ;; *) return 1 ;; esac
}

if [ "$(id -u)" -ne 0 ]; then
    echo "Execute como root:  sudo ./instalar.sh"
    exit 1
fi

# Instalação antiga (nome "sgf")? Migra para "sigadi" antes de tudo: preserva
# banco, backups, unidade.conf e a porta que os usuários já conhecem.
PORTA_ANTERIOR=""
if [ -f "$SRC/migrar-sgf-para-sigadi.sh" ]; then
    bash "$SRC/migrar-sgf-para-sigadi.sh" || { erro "A migração falhou — nada foi apagado. Veja as mensagens acima."; exit 1; }
    if [ -f /run/sigadi-porta-anterior ]; then
        PORTA_ANTERIOR=$(cat /run/sigadi-porta-anterior)
        rm -f /run/sigadi-porta-anterior
    fi
fi

# ═══════════════════════════════════════════════════════════════════════
#  Validadores — mesmo critério usado no restante do projeto (octetos
#  0-255, prefixo 0-32, gateway precisa ser vizinho na mesma rede).
# ═══════════════════════════════════════════════════════════════════════
_OCT='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
valida_ip()     { echo "$1" | grep -qE "^(${_OCT}\.){3}${_OCT}$"; }
valida_mascara(){ echo "$1" | grep -qE "^(${_OCT}\.){3}${_OCT}$"; }

ip_para_int() {
    local IFS=.; read -r a b c d <<< "$1"
    echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}
mascara_para_prefixo() {
    local ip_int prefixo=0 m
    ip_int=$(ip_para_int "$1")
    for ((i = 31; i >= 0; i--)); do
        m=$(( (ip_int >> i) & 1 ))
        [ "$m" -eq 1 ] && prefixo=$((prefixo + 1)) || break
    done
    echo "$prefixo"
}
rede_de_ip() {
    local ip_int=$(ip_para_int "$1") prefixo="$2"
    local mascara=$(( 0xFFFFFFFF << (32 - prefixo) & 0xFFFFFFFF ))
    local rede=$(( ip_int & mascara ))
    echo "$(( (rede>>24)&255 )).$(( (rede>>16)&255 )).$(( (rede>>8)&255 )).$(( rede&255 ))/${prefixo}"
}
gateway_valido() {
    local gw="$1" ip="$2" prefixo="$3"
    valida_ip "$gw" || { warn "Gateway inválido: '${gw}'"; return 1; }
    case "$gw" in
        127.*)   warn "127.x é o próprio computador — não é um gateway."; return 1 ;;
        0.0.0.0) warn "0.0.0.0 não é um gateway."; return 1 ;;
    esac
    [ "$gw" = "$ip" ] && { warn "O gateway não pode ser o IP desta máquina."; return 1; }
    if [ "$(rede_de_ip "$gw" "$prefixo")" != "$(rede_de_ip "$ip" "$prefixo")" ]; then
        warn "O gateway ${gw} está fora da rede desta máquina."
        return 1
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════════
titulo "── SIGADI — Instalação ──"

# [1/8] python3
if ! command -v python3 >/dev/null 2>&1; then
    info "Instalando python3..."
    apt-get update -qq && apt-get install -y -qq python3
fi
ok "python3 OK ($(python3 --version 2>&1))"

# ═══════════════════════════════════════════════════════════════════════
#  [2/8] REDE — detecta interfaces e IP atual; oferece IP fixo opcional.
#  Só mexe na rede se o operador pedir — o padrão é sempre "manter como
#  está". Mudar rede errado já derrubou acesso a servidores neste projeto;
#  aqui a mesma cautela: valida tudo, faz backup, nunca reinicia o serviço
#  de rede (só aplica o endereço novo por cima, sem derrubar o antigo).
# ═══════════════════════════════════════════════════════════════════════
titulo "── [2/8] Rede ──"

mapfile -t IFACES < <(ip -o -4 addr show 2>/dev/null | awk '$2 != "lo" {print $2}' | sort -u)
IFACE_PADRAO=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')

if [ ${#IFACES[@]} -eq 0 ]; then
    warn "Nenhuma interface de rede com IP encontrada. Siga mesmo assim —"
    warn "confira a rede manualmente depois da instalação."
    IFACE=""
    IP_ATUAL=""
else
    echo "  Interfaces com IP nesta máquina:"
    for i in "${IFACES[@]}"; do
        _ip=$(ip -o -4 addr show "$i" 2>/dev/null | awk '{print $4}' | head -1)
        _marca=""
        [ "$i" = "$IFACE_PADRAO" ] && _marca="  ${DIM}(rota padrão)${NC}"
        echo -e "    ${BOLD}${i}${NC}  ${_ip}${_marca}"
    done

    IFACE="${IFACE_PADRAO:-${IFACES[0]}}"
    if [ ${#IFACES[@]} -gt 1 ]; then
        echo ""
        ask "Qual interface o SIGADI deve usar? [${IFACE}]:"
        read -rp "  > " _IN
        IFACE="${_IN:-$IFACE}"
    fi

    IP_CIDR_ATUAL=$(ip -o -4 addr show "$IFACE" 2>/dev/null | awk '{print $4}' | head -1)
    IP_ATUAL="${IP_CIDR_ATUAL%/*}"
    ok "Interface: ${IFACE}   IP atual: ${IP_ATUAL:-nenhum}"
fi

echo ""
echo "  O SIGADI não precisa de IP fixo para funcionar — ele escuta em todas"
echo "  as interfaces desta máquina, seja qual for o IP. Fixar o endereço"
echo "  só evita que ele mude sozinho (DHCP) e derrube o link que os"
echo "  usuários guardaram no navegador."
if confirmar_padrao_nao "Definir IP fixo agora?"; then
    while true; do
        ask "IP fixo desta máquina [${IP_ATUAL:-ex: 192.168.0.10}]:"
        read -rp "  > " NOVO_IP
        NOVO_IP="${NOVO_IP:-$IP_ATUAL}"
        valida_ip "$NOVO_IP" && break
        warn "IP inválido: '${NOVO_IP}'"
    done

    while true; do
        ask "Máscara de rede [255.255.255.0]:"
        read -rp "  > " NOVA_MASCARA
        NOVA_MASCARA="${NOVA_MASCARA:-255.255.255.0}"
        valida_mascara "$NOVA_MASCARA" && break
        warn "Máscara inválida — use o formato 255.255.255.0"
    done
    NOVO_PREFIXO=$(mascara_para_prefixo "$NOVA_MASCARA")

    _GW_ATUAL=$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}')
    while true; do
        ask "Gateway (vazio = sem gateway) [${_GW_ATUAL:-}]:"
        read -rp "  > " NOVO_GW
        NOVO_GW="${NOVO_GW:-$_GW_ATUAL}"
        [ -z "$NOVO_GW" ] && break
        gateway_valido "$NOVO_GW" "$NOVO_IP" "$NOVO_PREFIXO" && break
    done

    if [ -f /etc/network/interfaces ]; then
        cp -a /etc/network/interfaces "/etc/network/interfaces.bak-$(date +%Y%m%d%H%M%S)"
        info "Backup: /etc/network/interfaces.bak-*"
    fi

    {
        echo "# Gerado por instalar.sh do SIGADI em $(date '+%Y-%m-%d %H:%M:%S')"
        echo "auto lo"
        echo "iface lo inet loopback"
        echo ""
        echo "auto ${IFACE}"
        echo "iface ${IFACE} inet static"
        echo "    address ${NOVO_IP}"
        echo "    netmask ${NOVA_MASCARA}"
        [ -n "$NOVO_GW" ] && echo "    gateway ${NOVO_GW}"
    } > /etc/network/interfaces

    # Aplica sem derrubar a interface atual — o endereço antigo some só no
    # próximo boot. Uma sessão SSH conectada pelo IP antigo não cai agora.
    ip addr add "${NOVO_IP}/${NOVO_PREFIXO}" dev "$IFACE" 2>/dev/null || true
    ip link set "$IFACE" up 2>/dev/null || true
    [ -n "$NOVO_GW" ] && ip route replace default via "$NOVO_GW" dev "$IFACE" 2>/dev/null || true

    ok "IP fixo: ${NOVO_IP}/${NOVO_PREFIXO}${NOVO_GW:+ via ${NOVO_GW}}"
    warn "O IP anterior continua ativo até o próximo reboot — a sessão atual não cai."
    IP_ATUAL="$NOVO_IP"
else
    info "Rede mantida como está."
fi

# ═══════════════════════════════════════════════════════════════════════
#  [3/8] UNIDADE — nome, cidade/UF e coordenadoria regional. Grava fora do
#  index.html e fora do git (unidade.conf) — nunca editar o HTML por
#  unidade, e um 'git pull' nunca conflita com essa personalização.
# ═══════════════════════════════════════════════════════════════════════
titulo "── [3/8] Identidade da unidade ──"
echo "  Aparece na tela, nos impressos (FCT, Ordem de Saída) e no romaneio."
echo ""

_NOME_ANTERIOR=""
[ -f "${DEST}/unidade.conf" ] && _NOME_ANTERIOR=$(awk -F= '/^UNIDADE_NOME=/{print $2}' "${DEST}/unidade.conf" 2>/dev/null)

while true; do
    ask "Nome completo da unidade [${_NOME_ANTERIOR:-Ex: Centro de Detenção Provisória de Nova Independência}]:"
    read -rp "  > " UNIDADE_NOME
    UNIDADE_NOME="${UNIDADE_NOME:-$_NOME_ANTERIOR}"
    [ -n "$UNIDADE_NOME" ] && break
    warn "Não pode ficar em branco."
done

_CIDADE_ANTERIOR=""
[ -f "${DEST}/unidade.conf" ] && _CIDADE_ANTERIOR=$(awk -F= '/^UNIDADE_CIDADE_UF=/{print $2}' "${DEST}/unidade.conf" 2>/dev/null)
ask "Cidade/UF (para os impressos) [${_CIDADE_ANTERIOR:-Ex: Nova Independência/SP}]:"
read -rp "  > " UNIDADE_CIDADE_UF
UNIDADE_CIDADE_UF="${UNIDADE_CIDADE_UF:-${_CIDADE_ANTERIOR:-$UNIDADE_NOME/SP}}"

_COORD_ANTERIOR=""
[ -f "${DEST}/unidade.conf" ] && _COORD_ANTERIOR=$(awk -F= '/^UNIDADE_COORDENADORIA=/{print $2}' "${DEST}/unidade.conf" 2>/dev/null)
echo ""
echo "  Coordenadoria regional a que a unidade está subordinada (aparece só"
echo "  na Ordem de Saída de Viatura)."
ask "Coordenadoria [${_COORD_ANTERIOR:-Coordenadoria das Unidades Prisionais da Região Oeste do Estado}]:"
read -rp "  > " UNIDADE_COORDENADORIA
UNIDADE_COORDENADORIA="${UNIDADE_COORDENADORIA:-${_COORD_ANTERIOR:-Coordenadoria das Unidades Prisionais da Região Oeste do Estado}}"

ok "Unidade: ${UNIDADE_NOME} (${UNIDADE_CIDADE_UF})"

# ═══════════════════════════════════════════════════════════════════════
#  [4/8] Copia os arquivos
# ═══════════════════════════════════════════════════════════════════════
titulo "── [4/8] Arquivos ──"
mkdir -p "$DEST"
if [ "$(realpath "$SRC")" = "$(realpath "$DEST")" ]; then
    info "Instalando a partir do próprio ${DEST} (cópia dispensada)."
else
    info "Copiando arquivos para ${DEST}..."
    cp -f "$SRC"/servidor.py "$SRC"/run_sigadi.py "$SRC"/index.html \
          "$SRC"/logo.png "$SRC"/logo_pp.png "$SRC"/backup.sh "$DEST/"
    # Bibliotecas locais (chart.js, xlsx, Font Awesome): sem depender de internet.
    rm -rf "$DEST/vendor"
    cp -r "$SRC/vendor" "$DEST/vendor"

    # Migração de dados: se houver um sigadi_dados.json (ou o antigo
    # sgf_dados.json) ao lado do instalador e ainda não existir banco no
    # destino, ele é aproveitado. NUNCA sobrescreve um banco já existente.
    if [ ! -f "$DEST/sigadi_dados.json" ]; then
        if [ -f "$SRC/sigadi_dados.json" ]; then
            info "Banco sigadi_dados.json encontrado, migrando."
            cp "$SRC/sigadi_dados.json" "$DEST/"
        elif [ -f "$SRC/sgf_dados.json" ]; then
            info "Banco antigo sgf_dados.json encontrado, migrando como sigadi_dados.json."
            cp "$SRC/sgf_dados.json" "$DEST/sigadi_dados.json"
        fi
    fi
fi
chmod +x "$DEST/backup.sh"

# Grava a identidade da unidade — servidor.py lê isto a cada request de
# index.html, então uma reinstalação/atualização nunca perde a personalização
# (o arquivo não fica dentro do que o cp acima copia, e não é git-tracked).
cat > "$DEST/unidade.conf" <<EOF
# Gerado por instalar.sh em $(date '+%Y-%m-%d %H:%M:%S') — NÃO versionado no
# git. Editar aqui tem efeito imediato (próxima vez que a página recarregar).
UNIDADE_NOME=${UNIDADE_NOME}
UNIDADE_CIDADE_UF=${UNIDADE_CIDADE_UF}
UNIDADE_COORDENADORIA=${UNIDADE_COORDENADORIA}
EOF
ok "unidade.conf gravado."

# ═══════════════════════════════════════════════════════════════════════
#  [5/8] PORTA — 80 quando nada mais está usando (o usuário só digita o
#  IP), 8091 quando a 80 já pertence a outro sistema desta máquina. Se a
#  porta escolhida (por argumento ou aqui) estiver ocupada, pergunta de
#  novo na hora, sem precisar reiniciar a instalação inteira.
# ═══════════════════════════════════════════════════════════════════════
titulo "── [5/8] Porta ──"

_porta_livre() { ! (command -v ss >/dev/null 2>&1 && ss -lntH "sport = :$1" 2>/dev/null | grep -q .); }

if [ -n "${1:-}" ]; then
    PORT="$1"
    info "Porta definida por parâmetro: ${PORT}"
else
    if [ -n "$PORTA_ANTERIOR" ] && _porta_livre "$PORTA_ANTERIOR"; then
        PORT_SUGERIDA="$PORTA_ANTERIOR"
        info "Mantendo a porta da instalação anterior: ${PORT_SUGERIDA}."
    elif _porta_livre 80; then
        PORT_SUGERIDA=80
        info "Porta 80 livre nesta máquina — o usuário digita só o IP, sem porta."
    else
        PORT_SUGERIDA=8091
        info "Porta 80 já está em uso (outro portal nesta máquina) — sugerindo 8091."
    fi
    ask "Porta do SIGADI [${PORT_SUGERIDA}]:"
    read -rp "  > " PORT
    PORT="${PORT:-$PORT_SUGERIDA}"
fi

while ! _porta_livre "$PORT"; do
    echo ""
    warn "A porta ${PORT} já está ocupada por outro processo:"
    ss -lptnH "sport = :$PORT" 2>/dev/null | sed 's/^/    /' || true
    echo ""
    if [ "$PORT" = "80" ] || [ "$PORT" = "8080" ] || [ "$PORT" = "8443" ]; then
        echo "  Pela convenção do projeto essa porta já pertence a outro sistema:"
        echo "    80 portal-sistemas   8080 painel do GWOS   8443 portal-samba"
    fi
    ask "Tente outra porta [8091]:"
    read -rp "  > " PORT
    PORT="${PORT:-8091}"
done
ok "Porta: ${PORT}"

# ═══════════════════════════════════════════════════════════════════════
#  [6/8] Usuário de serviço
# ═══════════════════════════════════════════════════════════════════════
titulo "── [6/8] Usuário de serviço ──"
id -u sigadi >/dev/null 2>&1 || useradd --system --home "$DEST" --shell /usr/sbin/nologin sigadi
chown -R sigadi:sigadi "$DEST"
ok "Usuário 'sigadi' pronto."

# ═══════════════════════════════════════════════════════════════════════
#  [7/8] systemd
# ═══════════════════════════════════════════════════════════════════════
titulo "── [7/8] Serviço systemd ──"
sed "s|@PORT@|$PORT|" "$SRC/sigadi.service" > /etc/systemd/system/sigadi.service
systemctl daemon-reload
# restart (e não só enable --now): numa reinstalação por cima, carrega o código novo
systemctl enable sigadi.service
systemctl restart sigadi.service
ok "Serviço ativo na porta ${PORT}."

# ═══════════════════════════════════════════════════════════════════════
#  [8/8] Backup diário
# ═══════════════════════════════════════════════════════════════════════
titulo "── [8/8] Backup diário ──"
cat > /etc/cron.d/sigadi-backup <<'EOF'
0 20 * * * sigadi /opt/sigadi/backup.sh
EOF
ok "Agendado para as 20h00 (retém 30 cópias)."

# O firewall do Samba (nftables, política DROP) só libera esta porta se for
# reinstalado/re-executado DEPOIS do SIGADI instalado — ele detecta o sistema sozinho,
# mas só quando roda. Instalando o SIGADI depois, é preciso avisar.
if command -v nft >/dev/null 2>&1 && nft list tables 2>/dev/null | grep -q "inet cdpni"; then
    echo ""
    warn "Firewall do Samba detectado nesta máquina (política padrão: bloquear)."
    echo "   Para a rede alcançar a porta ${PORT}, rode uma vez:"
    echo "     cd /opt/smb && sudo bash scripts/atualizar_firewall.sh"
    echo "   (idempotente — não altera usuários, RAID nem dados já configurados)"
fi

IP_FINAL="${IP_ATUAL:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
echo ""
echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN} SIGADI instalado e ATIVO — ${UNIDADE_NOME}${NC}"
echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════${NC}"
echo -e "   Acesso na rede:   ${BOLD}http://${IP_FINAL:-<ip-do-servidor>}$( [ "$PORT" != 80 ] && echo ":$PORT" )${NC}"
echo "   Status:           systemctl status sigadi"
echo "   Logs:             journalctl -u sigadi -f"
echo "   Trocar a unidade: edite ${DEST}/unidade.conf (efeito imediato)"
echo ""
