#!/bin/bash
# install-hermes-server.sh — Idempotent installer for Hermes + Traefik local
# Detecta o que já existe, instala só o que falta, roda quantas vezes quiser

set -euo pipefail

# ============================================
# CORES E HELPERS
# ============================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERRO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
skip() { echo -e "${BLUE}[SKIP]${NC} $*"; }

# ============================================
# ESTADO GLOBAL (preenchido pelo check_all)
# ============================================
HAS_HERMES=false
HAS_TRAEFIK=false
HAS_DOCKER=false
HAS_DOCKER_COMPOSE=false
HERMES_VERSION=""
TRAEFIK_VERSION=""
DOCKER_VERSION=""
OS=""
INIT=""

# ============================================
# CHECKS INDIVIDUAIS (retornam 0 se OK, 1 se falta)
# ============================================
check_hermes() {
    if command -v hermes >/dev/null 2>&1; then
        HERMES_VERSION=$(hermes --version 2>&1 | head -1 | awk '{print $NF}')
        HAS_HERMES=true
        ok "Hermes: $HERMES_VERSION"
        return 0
    fi
    warn "Hermes: não encontrado"
    return 1
}

check_traefik() {
    if command -v traefik >/dev/null 2>&1; then
        TRAEFIK_VERSION=$(traefik version 2>&1 | head -1 | awk '{print $NF}')
        HAS_TRAEFIK=true
        ok "Traefik: $TRAEFIK_VERSION"
        return 0
    fi
    warn "Traefik: não encontrado"
    return 1
}

check_docker() {
    if command -v docker >/dev/null 2>&1; then
        DOCKER_VERSION=$(docker --version 2>&1 | awk '{print $3}' | sed 's/,//')
        HAS_DOCKER=true
        ok "Docker: $DOCKER_VERSION"
        # Verifica se serviço Docker está rodando
        if systemctl is-active --quiet docker 2>/dev/null || rc-service docker status 2>/dev/null | grep -q started; then
            ok "Docker daemon: rodando"
        else
            warn "Docker daemon: parado (precisa start)"
        fi
    else
        warn "Docker: não instalado"
        HAS_DOCKER=false
    fi
    if command -v docker-compose >/dev/null 2>&1 || docker compose version >/dev/null 2>&1; then
        HAS_DOCKER_COMPOSE=true
        ok "Docker Compose: disponível"
    else
        warn "Docker Compose: não disponível"
    fi
    return 0  # Docker é opcional
}

check_os() {
    if [ -f /etc/alpine-release ]; then
        OS="alpine"; INIT="openrc"
    elif [ -f /etc/debian_version ]; then
        OS="debian"; INIT="systemd"
    else
        err "OS não suportado (precisa Alpine, Debian ou Ubuntu)"
        exit 1
    fi
    ok "OS: $OS ($INIT)"
}

# ============================================
# EXECUTA TODOS OS CHECKS EM FILA
# ============================================
check_all() {
    log "=== VERIFICANDO AMBIENTE ==="
    check_os
    check_hermes
    check_traefik
    check_docker
    log "=== FIM DA VERIFICAÇÃO ==="
    echo
}

# ============================================
# INSTALADORES (só rodam se check falhar)
# ============================================
install_hermes() {
    if $HAS_HERMES; then
        skip "Hermes já instalado ($HERMES_VERSION)"
        return 0
    fi
    log "Instalando Hermes..."
    if [ "$OS" = "alpine" ]; then
        apk add --no-cache python3 py3-pip
        pip3 install --break-system-packages hermes-agent
    else
        apt-get update && apt-get install -y python3 python3-pip python3-venv
        python3 -m venv /opt/hermes-venv
        /opt/hermes-venv/bin/pip install --upgrade pip
        /opt/hermes-venv/bin/pip install hermes-agent
        ln -sf /opt/hermes-venv/bin/hermes /usr/local/bin/hermes
    fi
    HERMES_VERSION=$(hermes --version 2>&1 | head -1 | awk '{print $NF}')
    HAS_HERMES=true
    ok "Hermes instalado: $HERMES_VERSION"
}

install_traefik() {
    if $HAS_TRAEFIK; then
        skip "Traefik já instalado ($TRAEFIK_VERSION)"
        return 0
    fi
    log "Instalando Traefik..."
    if [ "$OS" = "alpine" ]; then
        apk add --no-cache traefik
    else
        curl -fsSL https://raw.githubusercontent.com/traefik/traefik/v2.11.2/install.sh | bash -s -- -b /usr/local/bin v2.11.2
    fi
    TRAEFIK_VERSION=$(traefik version 2>&1 | head -1 | awk '{print $NF}')
    HAS_TRAEFIK=true
    ok "Traefik instalado: $TRAEFIK_VERSION"
}

install_docker() {
    if $HAS_DOCKER; then
        skip "Docker já instalado ($DOCKER_VERSION)"
        # Garante serviço rodando
        if [ "$INIT" = "systemd" ]; then
            systemctl enable --now docker
        else
            rc-update add docker default
            rc-service docker start
        fi
        return 0
    fi
    log "Instalando Docker..."
    if [ "$OS" = "alpine" ]; then
        apk add --no-cache docker docker-compose
        rc-update add docker default
        rc-service docker start
    else
        apt-get update && apt-get install -y docker.io docker-compose
        systemctl enable --now docker
    fi
    DOCKER_VERSION=$(docker --version 2>&1 | awk '{print $3}' | sed 's/,//')
    HAS_DOCKER=true
    HAS_DOCKER_COMPOSE=true
    ok "Docker instalado: $DOCKER_VERSION"
}

# ============================================
# CONFIGURAÇÕES (idempotentes: sobrescrevem se mudar)
# ============================================
configure_hermes() {
    log "Configurando Hermes..."
    HERMES_HOME="/root/.hermes"
    mkdir -p "$HERMES_HOME"/{skills,plugins,logs,sessions,memories}

    # Gera hash se não existir ou se senha mudou
    if [ ! -f "$HERMES_HOME/config.yaml" ] || ! grep -q "password_hash: $DASH_PASS_HASH" "$HERMES_HOME/config.yaml" 2>/dev/null; then
        cat > "$HERMES_HOME/config.yaml" << EOF
model:
  default: free-stack
  provider: custom
  base_url: https://routers.riquest.com.br/v1
  api_key: CHANGE_ME

dashboard:
  basic_auth:
    username: "$DASH_USER"
    password_hash: "$DASH_PASS_HASH"
    secret: "$DASH_SECRET"
    session_ttl_seconds: 43200

agent:
  max_turns: 90
  gateway_timeout: 1800

toolsets:
  - hermes-cli
EOF
        chmod 600 "$HERMES_HOME/config.yaml"
        ok "Config Hermes atualizada"
    else
        skip "Config Hermes já OK"
    fi
}

configure_traefik() {
    log "Configurando Traefik local (HTTP only)..."
    mkdir -p /etc/traefik/dynamic /var/log/traefik /var/lib/traefik

    # Static config
    cat > /etc/traefik/traefik.yaml << 'EOF'
global:
  checkNewVersion: false
  sendAnonymousUsage: false
api:
  dashboard: false
entryPoints:
  web:
    address: ":80"
providers:
  file:
    directory: /etc/traefik/dynamic
    watch: true
log:
  level: INFO
  filePath: /var/log/traefik/traefik.log
  format: common
accessLog:
  filePath: /var/log/traefik/access.log
  format: common
EOF

    # Dynamic config (sempre atualiza com domínio atual)
    cat > /etc/traefik/dynamic/hermes.yaml << EOF
http:
  routers:
    hermes:
      rule: "Host(\`$DOMAIN\`)"
      entryPoints: [web]
      service: hermes-svc
  services:
    hermes-svc:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:9119"
        passHostHeader: true
EOF
    ok "Config Traefik atualizada"
}

# ============================================
# SERVIÇOS (idempotentes: cria se não existe, restart se config mudou)
# ============================================
setup_services() {
    log "Configurando serviços ($INIT)..."

    if [ "$INIT" = "openrc" ]; then
        # Hermes dashboard
        if [ ! -f /etc/init.d/hermes-dashboard ] || ! grep -q "hermes dashboard" /etc/init.d/hermes-dashboard; then
            cat > /etc/init.d/hermes-dashboard << 'EOF'
#!/sbin/openrc-run
name="hermes-dashboard"
description="Hermes Agent Web Dashboard"
command="/usr/bin/hermes"
command_args="dashboard --host 0.0.0.0 --port 9119 --no-open --skip-build"
command_background=true
pidfile="/run/hermes-dashboard.pid"
output_log="/var/log/hermes-dashboard.log"
error_log="/var/log/hermes-dashboard.log"
depend() { need net; after firewall; }
start_pre() {
    checkpath -f -m 0644 -o root:root /var/log/hermes-dashboard.log
    checkpath -d -m 0755 -o root:root /run
}
EOF
            chmod +x /etc/init.d/hermes-dashboard
            rc-update add hermes-dashboard default
            ok "Serviço hermes-dashboard criado"
        else
            skip "Serviço hermes-dashboard já existe"
        fi

        # Traefik
        if [ ! -f /etc/init.d/traefik ] || ! grep -q "traefik.yaml" /etc/init.d/traefik; then
            cat > /etc/init.d/traefik << 'EOF'
#!/sbin/openrc-run
name="traefik"
description="Traefik Reverse Proxy (HTTP only - Central terminates TLS)"
command="/usr/sbin/traefik"
command_args="--configfile=/etc/traefik/traefik.yaml"
command_background=true
pidfile="/run/traefik.pid"
output_log="/var/log/traefik/traefik.log"
error_log="/var/log/traefik/traefik.log"
depend() { need net; after firewall; }
start_pre() {
    checkpath -f -m 0644 -o traefik:traefik /var/log/traefik/traefik.log
    checkpath -f -m 0644 -o traefik:traefik /var/log/traefik/access.log
    checkpath -d -m 0755 -o traefik:traefik /run
}
EOF
            chmod +x /etc/init.d/traefik
            rc-update add traefik default
            ok "Serviço traefik criado"
        else
            skip "Serviço traefik já existe"
        fi

        # Start/restart
        rc-service hermes-dashboard restart
        rc-service traefik restart

    else
        # systemd
        cat > /etc/systemd/system/hermes-dashboard.service << EOF
[Unit]
Description=Hermes Agent Web Dashboard
After=network.target
[Service]
Type=simple
User=root
Environment=HERMES_DASHBOARD_BASIC_AUTH_USERNAME=$DASH_USER
Environment=HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=$DASH_PASS
Environment=HERMES_DASHBOARD_BASIC_AUTH_SECRET=$DASH_SECRET
ExecStart=/usr/local/bin/hermes dashboard --host 0.0.0.0 --port 9119 --no-open --skip-build
Restart=on-failure
RestartSec=5
StandardOutput=append:/var/log/hermes-dashboard.log
StandardError=append:/var/log/hermes-dashboard.log
[Install]
WantedBy=multi-user.target
EOF

        cat > /etc/systemd/system/traefik.service << EOF
[Unit]
Description=Traefik Reverse Proxy
After=network.target
[Service]
Type=simple
User=traefik
ExecStart=/usr/local/bin/traefik --configfile=/etc/traefik/traefik.yaml
Restart=on-failure
RestartSec=5
StandardOutput=append:/var/log/traefik/traefik.log
StandardError=append:/var/log/traefik/traefik.log
[Install]
WantedBy=multi-user.target
EOF

        useradd -r -s /bin/false traefik 2>/dev/null || true
        chown -R traefik:traefik /var/log/traefik /var/lib/traefik /etc/traefik

        systemctl daemon-reload
        systemctl enable --now hermes-dashboard traefik
        ok "Serviços systemd configurados"
    fi
}

# ============================================
# VERIFICAÇÃO FINAL
# ============================================
verify_all() {
    log "=== VERIFICAÇÃO FINAL ==="
    sleep 5

    # Hermes
    if curl -sf http://127.0.0.1:9119/ >/dev/null; then
        ok "Hermes dashboard: respondendo na porta 9119"
    else
        warn "Hermes dashboard: não responde (verifique logs)"
    fi

    # Traefik local
    if curl -sf -H "Host: $DOMAIN" http://127.0.0.1/ >/dev/null; then
        ok "Traefik local: roteando $DOMAIN -> 9119"
    else
        warn "Traefik local: não roteando (verifique logs)"
    fi

    # Portas
    if command -v ss >/dev/null; then
        ss -tlnp | grep -E ":80|:443|:9119" || true
    elif command -v netstat >/dev/null; then
        netstat -tlnp | grep -E ":80|:443|:9119" || true
    fi
}

# ============================================
# MAIN
# ============================================
main() {
    echo
    echo "============================================"
    echo "  INSTALADOR IDEMPOTENTE: HERMES + TRAEFIK"
    echo "============================================"
    echo

    # Inputs
    read -p "Domínio (ex: agente.metabancaria.com.br): " DOMAIN
    [ -z "$DOMAIN" ] && { err "Domínio obrigatório"; exit 1; }

    read -p "IP do Traefik Central (ex: 192.168.25.101): " CENTRAL_IP
    [ -z "$CENTRAL_IP" ] && { err "IP do Central obrigatório"; exit 1; }

    read -p "Usuário dashboard (default: admin): " DASH_USER
    DASH_USER=${DASH_USER:-admin}

    read -sp "Senha dashboard: " DASH_PASS; echo
    [ -z "$DASH_PASS" ] && { err "Senha obrigatória"; exit 1; }

    read -p "Email Let's Encrypt (Central): " LE_EMAIL
    LE_EMAIL=${LE_EMAIL:-tecnologia@sooretama.es.gov.br}

    # Secrets
    DASH_SECRET=$(openssl rand -base64 32 2>/dev/null || head -c 32 /dev/urandom | base64)
    DASH_PASS_HASH=$(python3 -c "
try:
    from plugins.dashboard_auth.basic import hash_password
    print(hash_password('$DASH_PASS'))
except:
    import hashlib, secrets
    salt = secrets.token_bytes(16)
    print('scrypt\$' + hashlib.sha256(('$DASH_PASS' + salt.hex()).encode()).hexdigest())
" 2>/dev/null || echo "scrypt\$fallback")

    echo
    log "Resumo: Domain=$DOMAIN | User=$DASH_USER | Central=$CENTRAL_IP"
    read -p "Confirma instalação/atualização? (s/N): " CONF
    [[ "$CONF" =~ ^[sS]$ ]] || { err "Cancelado"; exit 1; }

    # === PIPELINE DE CHECKS + INSTALLS ===
    check_all

    log "=== INSTALANDO O QUE FALTA ==="
    install_hermes
    install_traefik
    install_docker

    log "=== CONFIGURANDO ==="
    configure_hermes
    configure_traefik
    setup_services

    verify_all

    # Output pro Central
    SERVER_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || hostname -I | awk '{print $1}')
    echo
    echo "============================================"
    echo "  CONCLUÍDO"
    echo "============================================"
    echo
    echo "Servidor: $SERVER_IP"
    echo "Domínio: $DOMAIN"
    echo "Dashboard local: http://$SERVER_IP:9119"
    echo "Via Traefik local: http://$DOMAIN (precisa Central)"
    echo "User: $DASH_USER"
    echo
    echo "--------------------------------------------"
    echo "COLE NO TRAEFIK CENTRAL (servers.yml):"
    echo "--------------------------------------------"
    cat << EOF

  # Router $DOMAIN (Central termina TLS)
  ${DOMAIN//./-}:
    rule: "Host(\`$DOMAIN\`)"
    entryPoints: [websecure]
    service: ${DOMAIN//./-}-svc
    tls:
      certResolver: letsencrypt
      domains:
        - main: $DOMAIN

  services:
    ${DOMAIN//./-}-svc:
      loadBalancer:
        passHostHeader: true
        servers:
          - url: "http://$SERVER_IP"   # HTTP porta 80
EOF
    echo
    echo "Depois no Central:"
    echo "  docker service update --force traefik-central_traefik-central"
}

main "$@"