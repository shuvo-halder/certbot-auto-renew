#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

LOG_FILE="/var/log/certbot-auto-renew.log"
LOCK_FILE="/var/lock/certbot-auto-renew.lock"
LETENCRYPT_RENEWAL_DIR="/etc/letsencrypt/renewal"
PORTS=("80/tcp" "443/tcp")

# -------- logging --------
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 0640 "$LOG_FILE"

exec > >(tee -a "$LOG_FILE") 2>&1

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

# -------- globals --------
OS_ID=""
OS_VERSION=""
PKG_MANAGER="unknown"

FIREWALL_TYPE="none"   # none|ufw|firewalld
WEB_SERVICES=()        # nginx / apache2 / httpd
OPENED_UFW_PORTS=()    # ports opened by this run
OPENED_FW_ZONES=()     # firewalld zones opened by this run
OPENED_FW_PORTS=()     # matching list of ports opened by this run

cleanup() {
  set +e

  # Close firewalld runtime ports that this run opened
  if [[ "${FIREWALL_TYPE}" == "firewalld" ]]; then
    local i zone port
    for i in "${!OPENED_FW_ZONES[@]}"; do
      zone="${OPENED_FW_ZONES[$i]}"
      port="${OPENED_FW_PORTS[$i]}"
      if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --zone="$zone" --remove-port="$port" >/dev/null 2>&1 || true
      fi
    done
  fi

  # Remove UFW rules that this run added
  if [[ "${FIREWALL_TYPE}" == "ufw" ]]; then
    local port
    for port in "${OPENED_UFW_PORTS[@]}"; do
      if command -v ufw >/dev/null 2>&1; then
        ufw delete allow "$port" >/dev/null 2>&1 || true
      fi
    done
  fi
}

on_exit() {
  local rc=$?
  cleanup
  if [[ $rc -eq 0 ]]; then
    log "Completed successfully."
  else
    log "Completed with exit code: $rc"
  fi
  exit "$rc"
}

trap on_exit EXIT INT TERM

# -------- helpers --------
require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run this script as root."
  fi
}

acquire_lock() {
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
      log "Another renewal job is already running. Exiting."
      exit 0
    fi
  else
    log "flock not found; lock protection skipped."
  fi
}

detect_os() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"
  else
    OS_ID="unknown"
    OS_VERSION="unknown"
  fi

  case "$OS_ID" in
    ubuntu|debian)
      PKG_MANAGER="apt"
      ;;
    centos|rhel|rocky|almalinux|fedora|ol)
      if command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
      else
        PKG_MANAGER="yum"
      fi
      ;;
    *)
      PKG_MANAGER="unknown"
      ;;
  esac

  log "Detected OS: ${OS_ID} ${OS_VERSION} (package manager: ${PKG_MANAGER})"
}

detect_web_server() {
  WEB_SERVICES=()

  if systemctl is-active --quiet nginx 2>/dev/null; then
    WEB_SERVICES+=("nginx")
  fi

  if systemctl is-active --quiet apache2 2>/dev/null; then
    WEB_SERVICES+=("apache2")
  elif systemctl is-active --quiet httpd 2>/dev/null; then
    WEB_SERVICES+=("httpd")
  fi

  if [[ ${#WEB_SERVICES[@]} -eq 0 ]]; then
    log "No active Nginx/Apache service detected."
  else
    log "Active web service(s): ${WEB_SERVICES[*]}"
  fi
}

detect_firewall() {
  FIREWALL_TYPE="none"

  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -qi '^Status: active'; then
      FIREWALL_TYPE="ufw"
      log "Detected firewall: UFW (active)"
      return
    fi
  fi

  if command -v firewall-cmd >/dev/null 2>&1; then
    if systemctl is-active --quiet firewalld 2>/dev/null || firewall-cmd --state >/dev/null 2>&1; then
      FIREWALL_TYPE="firewalld"
      log "Detected firewall: firewalld (active)"
      return
    fi
  fi

  log "No active firewall detected."
}

web_server_reload() {
  local svc
  if [[ ${#WEB_SERVICES[@]} -eq 0 ]]; then
    log "Skipping web server reload: no active web service detected."
    return 0
  fi

  for svc in "${WEB_SERVICES[@]}"; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      log "Reloading ${svc}"
      systemctl reload "$svc"
    else
      log "Skipping reload for ${svc}: service not active."
    fi
  done
}

firewall_port_open_ufw() {
  local port="$1"

  # UFW status output is human-readable; only add if the port is not already allowed.
  if ufw status 2>/dev/null | grep -Eq "^[[:space:]]*${port%/*}[[:space:]]+ALLOW|${port}.*ALLOW"; then
    return 0
  fi

  log "UFW: allowing ${port}"
  ufw allow "$port"
  OPENED_UFW_PORTS+=("$port")
}

firewall_port_close_ufw() {
  local port="$1"
  log "UFW: removing temporary rule for ${port}"
  ufw delete allow "$port" >/dev/null 2>&1 || true
}

get_firewalld_zones() {
  firewall-cmd --get-active-zones 2>/dev/null | awk 'NF && $1 !~ /^[[:space:]]/ { print $1 }'
}

firewall_port_open_firewalld() {
  local port="$1"
  local zone

  while IFS= read -r zone; do
    [[ -z "$zone" ]] && continue

    if firewall-cmd --zone="$zone" --query-port="$port" >/dev/null 2>&1; then
      continue
    fi

    log "firewalld: allowing ${port} in zone ${zone}"
    firewall-cmd --zone="$zone" --add-port="$port"
    OPENED_FW_ZONES+=("$zone")
    OPENED_FW_PORTS+=("$port")
  done < <(get_firewalld_zones)
}

firewall_port_close_firewalld() {
  local zone="$1"
  local port="$2"
  log "firewalld: removing temporary rule ${port} from zone ${zone}"
  firewall-cmd --zone="$zone" --remove-port="$port" >/dev/null 2>&1 || true
}

open_firewall() {
  local port
  case "$FIREWALL_TYPE" in
    ufw)
      for port in "${PORTS[@]}"; do
        firewall_port_open_ufw "$port"
      done
      ;;
    firewalld)
      for port in "${PORTS[@]}"; do
        firewall_port_open_firewalld "$port"
      done
      ;;
    none)
      ;;
  esac
}

close_firewall() {
  local i zone port
  case "$FIREWALL_TYPE" in
    ufw)
      for port in "${OPENED_UFW_PORTS[@]}"; do
        firewall_port_close_ufw "$port"
      done
      OPENED_UFW_PORTS=()
      ;;
    firewalld)
      for i in "${!OPENED_FW_ZONES[@]}"; do
        zone="${OPENED_FW_ZONES[$i]}"
        port="${OPENED_FW_PORTS[$i]}"
        firewall_port_close_firewalld "$zone" "$port"
      done
      OPENED_FW_ZONES=()
      OPENED_FW_PORTS=()
      ;;
    none)
      ;;
  esac
}

renew_one_certificate() {
  local cert_name="$1"
  local live_dir="/etc/letsencrypt/live/${cert_name}"
  local fullchain="${live_dir}/fullchain.pem"
  local before_mtime=""
  local after_mtime=""
  local rc=0

  if [[ ! -f "/etc/letsencrypt/renewal/${cert_name}.conf" ]]; then
    log "Skipping ${cert_name}: renewal config not found."
    return 0
  fi

  if [[ -e "$fullchain" ]]; then
    before_mtime="$(stat -Lc '%Y' "$fullchain" 2>/dev/null || echo '')"
  fi

  log "Renewing certificate: ${cert_name}"
  open_firewall

  set +e
  certbot renew --cert-name "$cert_name" --quiet --non-interactive
  rc=$?
  set -e

  close_firewall

  if [[ $rc -ne 0 ]]; then
    log "Renewal failed for ${cert_name} (exit code ${rc})"
    return "$rc"
  fi

  if [[ -e "$fullchain" ]]; then
    after_mtime="$(stat -Lc '%Y' "$fullchain" 2>/dev/null || echo '')"
  fi

  if [[ -n "$before_mtime" && -n "$after_mtime" && "$before_mtime" != "$after_mtime" ]]; then
    log "Certificate updated for ${cert_name}; reloading web server."
    web_server_reload
  else
    log "No certificate change detected for ${cert_name}; reload skipped."
  fi

  return 0
}

main() {
  require_root
  acquire_lock
  detect_os
  detect_web_server
  detect_firewall

  command -v certbot >/dev/null 2>&1 || die "certbot is not installed or not in PATH."

  if [[ ! -d "$LETENCRYPT_RENEWAL_DIR" ]]; then
    log "No Let’s Encrypt renewal directory found at ${LETENCRYPT_RENEWAL_DIR}. Nothing to do."
    exit 0
  fi

  shopt -s nullglob
  local conf_files=("$LETENCRYPT_RENEWAL_DIR"/*.conf)
  shopt -u nullglob

  if [[ ${#conf_files[@]} -eq 0 ]]; then
    log "No renewal configuration files found. Nothing to do."
    exit 0
  fi

  local conf cert_name failures=0
  for conf in "${conf_files[@]}"; do
    cert_name="$(basename "$conf" .conf)"
    if ! renew_one_certificate "$cert_name"; then
      failures=1
    fi
  done

  if [[ $failures -ne 0 ]]; then
    die "One or more certificate renewals failed."
  fi
}

main "$@"
