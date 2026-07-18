#!/usr/bin/env bash
set -Eeuo pipefail

DEFAULT_CONFIG_DIR=/etc/routerbox-fake
CONFIG_FILE=${ROUTERBOX_FAKE_ENV:-$DEFAULT_CONFIG_DIR/routerbox-fake.env}

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

ROUTERBOX_DOMAIN=${ROUTERBOX_DOMAIN:-delend.space}
ROUTEBOX_PANEL_DOMAIN=${ROUTEBOX_PANEL_DOMAIN:-panel.delend.space}
ROUTEBOX_EMAIL=${ROUTEBOX_EMAIL:-admin@delend.space}
INSTALL_ROOT=${INSTALL_ROOT:-/opt/routerbox-fake}
CONFIG_DIR=${CONFIG_DIR:-$DEFAULT_CONFIG_DIR}
MYFAKESITE_REPO=${MYFAKESITE_REPO:-https://github.com/iqubik/myfakesite.git}
MYFAKESITE_BRANCH=${MYFAKESITE_BRANCH:-main}
ROUTEBOX_REPO=${ROUTEBOX_REPO:-https://github.com/hoaxisr/routebox.git}
ROUTEBOX_BRANCH=${ROUTEBOX_BRANCH:-main}
ROUTEBOX_PANEL_PORT=${ROUTEBOX_PANEL_PORT:-8443}
ROUTEBOX_STAGING=${ROUTEBOX_STAGING:-0}
ROUTEBOX_USE_UPSTREAM_INSTALLER=${ROUTEBOX_USE_UPSTREAM_INSTALLER:-0}

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "Run this installer as root or via sudo." >&2
    exit 1
  fi
}

install_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl git golang-go nodejs npm openssl certbot
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y ca-certificates curl git golang nodejs npm openssl certbot
  elif command -v yum >/dev/null 2>&1; then
    yum install -y ca-certificates curl git golang nodejs npm openssl certbot
  else
    echo "Unsupported package manager. Install ca-certificates, curl, git, Go, Node.js, npm, openssl and certbot manually." >&2
    exit 1
  fi
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
public_host = "$ROUTEBOX_PANEL_DOMAIN"
public_port = $ROUTEBOX_PANEL_PORT

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
  sync_repo "$ROUTEBOX_REPO" "$ROUTEBOX_BRANCH" "$INSTALL_ROOT/routebox"

  install_routebox
  install_myfakesite

  cat <<SUMMARY

RouterBOX-Fake deployment completed.
MyFakeSite:      https://$ROUTERBOX_DOMAIN
RouteBox panel:  https://$ROUTEBOX_PANEL_DOMAIN:$ROUTEBOX_PANEL_PORT
Saved config:    $CONFIG_DIR/routerbox-fake.env
SUMMARY
}

main "$@"
