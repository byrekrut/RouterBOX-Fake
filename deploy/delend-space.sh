#!/usr/bin/env bash
set -Eeuo pipefail

DEFAULT_CONFIG_DIR=/etc/routerbox-fake
CONFIG_FILE=${ROUTERBOX_FAKE_ENV:-$DEFAULT_CONFIG_DIR/routerbox-fake.env}

load_config_defaults() {
  local key
  local value

  if [[ ! -f "$CONFIG_FILE" ]]; then
    return
  fi

  while IFS='=' read -r key value; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue

    if [[ -z "${!key+x}" ]]; then
      printf -v "$key" '%s' "$value"
      export "$key"
    fi
  done < "$CONFIG_FILE"
}

load_config_defaults

ROUTERBOX_DOMAIN=${ROUTERBOX_DOMAIN:-delend.space}
ROUTEBOX_PANEL_DOMAIN=${ROUTEBOX_PANEL_DOMAIN:-panel.delend.space}
ROUTEBOX_EMAIL=${ROUTEBOX_EMAIL:-admin@delend.space}
INSTALL_ROOT=${INSTALL_ROOT:-/opt/routerbox-fake}
CONFIG_DIR=${CONFIG_DIR:-$DEFAULT_CONFIG_DIR}
MYFAKESITE_REPO=${MYFAKESITE_REPO:-https://github.com/iqubik/myfakesite.git}
MYFAKESITE_BRANCH=${MYFAKESITE_BRANCH:-main}
ROUTEBOX_REPO=${ROUTEBOX_REPO:-https://github.com/hoaxisr/routebox.git}
ROUTEBOX_BRANCH=${ROUTEBOX_BRANCH:-source}
ROUTEBOX_PANEL_PORT=${ROUTEBOX_PANEL_PORT:-8443}
VPN_PUBLIC_HOST=${VPN_PUBLIC_HOST:-$ROUTERBOX_DOMAIN}
VPN_PUBLIC_PORT=${VPN_PUBLIC_PORT:-443}
AWG_LISTEN_PORT=${AWG_LISTEN_PORT:-2053}
ROUTEBOX_STAGING=${ROUTEBOX_STAGING:-0}
ROUTEBOX_USE_UPSTREAM_INSTALLER=${ROUTEBOX_USE_UPSTREAM_INSTALLER:-0}

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "Run this installer as root or via sudo." >&2
    exit 1
  fi
}

nodejs_version_ok() {
  command -v node >/dev/null 2>&1 || return 1
  node -e 'const [major, minor] = process.versions.node.split(".").map(Number); process.exit((major > 20 || (major === 20 && minor >= 19)) ? 0 : 1)'
}

install_nodejs() {
  if nodejs_version_ok; then
    return
  fi

  if command -v apt-get >/dev/null 2>&1; then
    apt-get remove -y npm || true
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y nodejs
  elif command -v dnf >/dev/null 2>&1; then
    dnf module disable -y nodejs || true
    dnf install -y nodejs npm
  elif command -v yum >/dev/null 2>&1; then
    yum install -y nodejs npm
  fi

  if ! nodejs_version_ok; then
    echo "Node.js 20.19+ or 22.12+ is required to build RouteBox frontend." >&2
    echo "Current node: $(node --version 2>/dev/null || echo missing)" >&2
    exit 1
  fi
}

install_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl git golang-go openssl certbot
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y ca-certificates curl git golang openssl certbot
  elif command -v yum >/dev/null 2>&1; then
    yum install -y ca-certificates curl git golang openssl certbot
  else
    echo "Unsupported package manager. Install ca-certificates, curl, git, Go, Node.js, npm, openssl and certbot manually." >&2
    exit 1
  fi

  install_nodejs
}

sync_repo() {
  local repo_url=$1
  local branch=$2
  local target_dir=$3

  if [[ -d "$target_dir/.git" ]]; then
    git -C "$target_dir" fetch --prune origin "$branch"
    git -C "$target_dir" checkout "$branch"
    git -C "$target_dir" reset --hard "origin/$branch"
  else
    rm -rf "$target_dir"
    git clone --branch "$branch" --depth 1 "$repo_url" "$target_dir"
  fi
}

sync_routebox_repo() {
  local target_dir=$1

  sync_repo "$ROUTEBOX_REPO" "$ROUTEBOX_BRANCH" "$target_dir"

  if [[ -d "$target_dir/frontend" && -d "$target_dir/backend" ]]; then
    return
  fi

  if [[ "$ROUTEBOX_BRANCH" != "source" ]]; then
    echo "RouteBox branch '$ROUTEBOX_BRANCH' does not contain frontend/backend; retrying branch 'source'." >&2
    ROUTEBOX_BRANCH=source
    sync_repo "$ROUTEBOX_REPO" "$ROUTEBOX_BRANCH" "$target_dir"
  fi

  if [[ ! -d "$target_dir/frontend" || ! -d "$target_dir/backend" ]]; then
    echo "RouteBox repository layout is invalid in $target_dir." >&2
    echo "Expected directories: frontend and backend." >&2
    git -C "$target_dir" branch --show-current >&2 || true
    git -C "$target_dir" rev-parse --short HEAD >&2 || true
    find "$target_dir" -maxdepth 2 -type d | sort >&2 || true
    exit 1
  fi
}

write_config() {
  install -d -m 0755 "$CONFIG_DIR"
  cat > "$CONFIG_DIR/routerbox-fake.env" <<CONFIG
ROUTERBOX_DOMAIN=$ROUTERBOX_DOMAIN
ROUTEBOX_PANEL_DOMAIN=$ROUTEBOX_PANEL_DOMAIN
ROUTEBOX_EMAIL=$ROUTEBOX_EMAIL
INSTALL_ROOT=$INSTALL_ROOT
CONFIG_DIR=$CONFIG_DIR
MYFAKESITE_REPO=$MYFAKESITE_REPO
MYFAKESITE_BRANCH=$MYFAKESITE_BRANCH
ROUTEBOX_REPO=$ROUTEBOX_REPO
ROUTEBOX_BRANCH=$ROUTEBOX_BRANCH
ROUTEBOX_PANEL_PORT=$ROUTEBOX_PANEL_PORT
VPN_PUBLIC_HOST=$VPN_PUBLIC_HOST
VPN_PUBLIC_PORT=$VPN_PUBLIC_PORT
AWG_LISTEN_PORT=$AWG_LISTEN_PORT
ROUTEBOX_STAGING=$ROUTEBOX_STAGING
ROUTEBOX_USE_UPSTREAM_INSTALLER=$ROUTEBOX_USE_UPSTREAM_INSTALLER
CONFIG
}

install_myfakesite() {
  local dir="$INSTALL_ROOT/myfakesite"
  bash "$dir/install.sh" -d "$ROUTERBOX_DOMAIN" -p "$dir" -y
}

install_routebox() {
  local dir="$INSTALL_ROOT/routebox"
  local args=(--domain "$ROUTEBOX_PANEL_DOMAIN" --email "$ROUTEBOX_EMAIL" --port "$ROUTEBOX_PANEL_PORT")

  if [[ "$ROUTEBOX_STAGING" == "1" ]]; then
    args+=(--staging)
  fi

  if [[ "$ROUTEBOX_USE_UPSTREAM_INSTALLER" == "1" && -x "$dir/vps-install.sh" ]]; then
    bash "$dir/vps-install.sh" "${args[@]}"
    return
  fi

  issue_routebox_certificate
  build_and_install_routebox "$dir"
}

issue_routebox_certificate() {
  local live_dir="/etc/letsencrypt/live/$ROUTEBOX_PANEL_DOMAIN"
  local certbot_args=(certonly --standalone --non-interactive --agree-tos --email "$ROUTEBOX_EMAIL" -d "$ROUTEBOX_PANEL_DOMAIN")

  if [[ "$ROUTEBOX_STAGING" == "1" ]]; then
    certbot_args+=(--staging)
  fi

  if [[ -s "$live_dir/fullchain.pem" && -s "$live_dir/privkey.pem" ]]; then
    return
  fi

  certbot "${certbot_args[@]}"
}

configure_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -qi '^Status: active'; then
    ufw allow "$ROUTEBOX_PANEL_PORT/tcp"
    ufw allow "$VPN_PUBLIC_PORT/tcp"
    ufw allow "$AWG_LISTEN_PORT/udp"
  fi
}

build_and_install_routebox() {
  local dir=$1
  local password_file=/etc/routebox/routebox-initial-password
  local cert_path="/etc/letsencrypt/live/$ROUTEBOX_PANEL_DOMAIN/fullchain.pem"
  local key_path="/etc/letsencrypt/live/$ROUTEBOX_PANEL_DOMAIN/privkey.pem"

  install -d -m 0755 /etc/routebox /etc/amnezia-box
  if [[ ! -s "$password_file" ]]; then
    umask 077
    openssl rand -base64 24 > "$password_file"
  fi

  (
    cd "$dir/frontend"
    npm ci
    npm run build
  )
  rm -rf "$dir/backend/internal/embedded/dist"
  cp -a "$dir/frontend/build" "$dir/backend/internal/embedded/dist"

  (
    cd "$dir"
    go build -ldflags "-X main.Version=$(git rev-parse --short HEAD)" -o /usr/local/bin/routebox ./backend/cmd/routebox
  )

  cat > /etc/routebox/routebox.toml <<CONFIG
[server]
mode = "vps"
public_host = "$VPN_PUBLIC_HOST"
public_port = $VPN_PUBLIC_PORT

[network]
listen = ":$ROUTEBOX_PANEL_PORT"
tls_cert_path = "$cert_path"
tls_key_path = "$key_path"
acme_enabled = false

[security]
auth_enabled = true
auth_username = "admin"
auth_password = "$(cat "$password_file")"
session_timeout_minutes = 1440

[awg]
listen_port = $AWG_LISTEN_PORT

[singbox]
config_path = "/etc/amnezia-box/config.json"
service_name = "amnezia-box"
binary_name = "amnezia-box"
CONFIG

  cat > /etc/systemd/system/routebox.service <<'SERVICE'
[Unit]
Description=RouteBox VPS panel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/routebox --settings /etc/routebox/routebox.toml --mode vps
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE

  systemctl daemon-reload
  systemctl enable --now routebox
}

main() {
  require_root
  install_packages
  install -d -m 0755 "$INSTALL_ROOT"
  write_config

  sync_repo "$MYFAKESITE_REPO" "$MYFAKESITE_BRANCH" "$INSTALL_ROOT/myfakesite"
  sync_routebox_repo "$INSTALL_ROOT/routebox"

  install_routebox
  configure_firewall
  install_myfakesite

  cat <<SUMMARY

RouterBOX-Fake deployment completed.
MyFakeSite:      https://$ROUTERBOX_DOMAIN
RouteBox panel:  https://$ROUTEBOX_PANEL_DOMAIN:$ROUTEBOX_PANEL_PORT
VPN endpoint:    $VPN_PUBLIC_HOST:$VPN_PUBLIC_PORT
Saved config:    $CONFIG_DIR/routerbox-fake.env
SUMMARY
}

main "$@"
