#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="0.1.0"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly DEFAULT_INSTALL_DIR="/opt/masterdns-vps-setup"
readonly DEFAULT_IMAGE="ghcr.io/masterking32/masterdnsvpn:latest"
readonly RESOLVED_DROP_IN="/etc/systemd/resolved.conf.d/90-masterdnsvpn.conf"

INSTALL_DIR="${MASTERDNS_INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
COMMAND="install"
DOMAIN=""
IMAGE=""
ENCRYPTION_NAME="chacha20"
ENCRYPTION_SET=false
ASSUME_YES=false
DRY_RUN=false
PURGE=false
FOLLOW_LOGS=false
SKIP_DNS_CHECK=false
SKIP_FIREWALL=false
SKIP_DOCKER_INSTALL=false
ALLOW_RESOLVED_FIX=true
RESOLVED_CHANGED_THIS_RUN=false
FIREWALL_CHANGED_THIS_RUN=false
INSTALL_COMPLETED=false

DATA_DIR=""
CLIENT_DIR=""
STATE_DIR=""
COMPOSE_FILE=""
ENV_FILE=""
MARKER_FILE=""

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  readonly RED=$'\033[1;31m'
  readonly GREEN=$'\033[1;32m'
  readonly YELLOW=$'\033[1;33m'
  readonly BLUE=$'\033[1;34m'
  readonly BOLD=$'\033[1m'
  readonly RESET=$'\033[0m'
else
  readonly RED=""
  readonly GREEN=""
  readonly YELLOW=""
  readonly BLUE=""
  readonly BOLD=""
  readonly RESET=""
fi

log_info() {
  printf '%s[INFO]%s %s\n' "$BLUE" "$RESET" "$*"
}

log_success() {
  printf '%s[OK]%s %s\n' "$GREEN" "$RESET" "$*"
}

log_warn() {
  printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*" >&2
}

die() {
  printf '%s[ERROR]%s %s\n' "$RED" "$RESET" "$*" >&2
  rollback_host_changes_if_needed
  exit 1
}

usage() {
  cat <<'EOF'
MasterDnsVPN VPS setup

Usage:
  sudo ./vps-setup.sh [command] [options]

Commands:
  install        Install or finish an existing deployment (default)
  update         Pull the configured image and recreate the container
  start          Start the service
  stop           Stop the service
  restart        Restart the service
  status         Show container and deployment status
  logs           Show the latest container logs
  doctor         Run local deployment diagnostics
  check-dns      Check NS delegation and nameserver A records
  client-config  Rebuild client_config.toml from the active server settings
  rotate-key     Generate a new server key and matching client configuration
  config         Edit server_config.toml and restart the service
  uninstall      Stop and remove the container; keep data unless --purge is used

Options:
  --domain DOMAIN          Delegated tunnel domain, for example v.example.com
  --image IMAGE            Container image/tag/digest
  --encryption METHOD      chacha20 (default), aes-128-gcm, aes-192-gcm,
                           aes-256-gcm, xor, or none
  --install-dir PATH       Deployment directory (default: /opt/masterdns-vps-setup)
  --yes, -y                Accept safe non-destructive prompts
  --follow, -f             Follow logs
  --purge                  With uninstall, also delete persistent data
  --skip-dns-check         Do not check public DNS during installation
  --skip-firewall          Do not add UFW/firewalld rules
  --skip-docker-install    Fail instead of installing missing Docker packages
  --no-resolved-fix        Do not offer to release port 53 from systemd-resolved
  --dry-run                Render a deployment without Docker or host changes
  --help, -h               Show this help
  --version                Show script version

Examples:
  sudo ./vps-setup.sh install --domain v.example.com
  sudo ./vps-setup.sh update
  sudo ./vps-setup.sh update --image ghcr.io/masterking32/masterdnsvpn:v2026.06.13.234407-7de2476
  sudo ./vps-setup.sh doctor
  sudo ./vps-setup.sh uninstall
  sudo ./vps-setup.sh uninstall --purge
EOF
}

known_command() {
  case "$1" in
    install|update|start|stop|restart|status|logs|doctor|check-dns|client-config|rotate-key|config|uninstall)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

parse_args() {
  if (($# > 0)) && [[ "$1" != -* ]]; then
    known_command "$1" || die "Unknown command: $1"
    COMMAND="$1"
    shift
  fi

  while (($# > 0)); do
    case "$1" in
      --domain)
        (($# >= 2)) || die "--domain requires a value"
        DOMAIN="$2"
        shift 2
        ;;
      --domain=*)
        DOMAIN="${1#*=}"
        shift
        ;;
      --image)
        (($# >= 2)) || die "--image requires a value"
        IMAGE="$2"
        shift 2
        ;;
      --image=*)
        IMAGE="${1#*=}"
        shift
        ;;
      --encryption)
        (($# >= 2)) || die "--encryption requires a value"
        ENCRYPTION_NAME="${2,,}"
        ENCRYPTION_SET=true
        shift 2
        ;;
      --encryption=*)
        ENCRYPTION_NAME="${1#*=}"
        ENCRYPTION_NAME="${ENCRYPTION_NAME,,}"
        ENCRYPTION_SET=true
        shift
        ;;
      --install-dir)
        (($# >= 2)) || die "--install-dir requires a value"
        INSTALL_DIR="$2"
        shift 2
        ;;
      --install-dir=*)
        INSTALL_DIR="${1#*=}"
        shift
        ;;
      --yes|-y)
        ASSUME_YES=true
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --purge)
        PURGE=true
        shift
        ;;
      --follow|-f)
        FOLLOW_LOGS=true
        shift
        ;;
      --skip-dns-check)
        SKIP_DNS_CHECK=true
        shift
        ;;
      --skip-firewall)
        SKIP_FIREWALL=true
        shift
        ;;
      --skip-docker-install)
        SKIP_DOCKER_INSTALL=true
        shift
        ;;
      --no-resolved-fix)
        ALLOW_RESOLVED_FIX=false
        shift
        ;;
      --version)
        printf '%s\n' "$SCRIPT_VERSION"
        exit 0
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done
}

validate_option_scope() {
  if [[ "$DRY_RUN" == true && "$COMMAND" != "install" ]]; then
    die "--dry-run is supported only with the install command."
  fi
  if [[ "$PURGE" == true && "$COMMAND" != "uninstall" ]]; then
    die "--purge is supported only with the uninstall command."
  fi
  if [[ "$FOLLOW_LOGS" == true && "$COMMAND" != "logs" ]]; then
    die "--follow is supported only with the logs command."
  fi
  if [[ -n "$IMAGE" && "$COMMAND" != "install" && "$COMMAND" != "update" ]]; then
    die "--image is supported only with install or update."
  fi
  if [[ "$ENCRYPTION_SET" == true && "$COMMAND" != "install" ]]; then
    die "--encryption is supported only with install."
  fi
  if [[ -n "$DOMAIN" && "$COMMAND" != "install" && "$COMMAND" != "check-dns" ]]; then
    die "--domain is supported only with install or check-dns."
  fi
}

canonicalize_install_dir() {
  [[ -n "$INSTALL_DIR" ]] || die "Install directory cannot be empty"
  [[ "$INSTALL_DIR" != *$'\n'* && "$INSTALL_DIR" != *$'\r'* ]] \
    || die "Install directory contains an invalid newline"

  if command -v readlink >/dev/null 2>&1; then
    INSTALL_DIR="$(readlink -m -- "$INSTALL_DIR")"
  fi

  [[ "$INSTALL_DIR" == /* ]] || die "Install directory must be absolute: $INSTALL_DIR"
  case "$INSTALL_DIR" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
      die "Install directory is too broad: $INSTALL_DIR"
      ;;
  esac

  DATA_DIR="$INSTALL_DIR/data"
  CLIENT_DIR="$INSTALL_DIR/client"
  STATE_DIR="$INSTALL_DIR/state"
  COMPOSE_FILE="$INSTALL_DIR/compose.yaml"
  ENV_FILE="$INSTALL_DIR/.env"
  MARKER_FILE="$INSTALL_DIR/.masterdns-vps-setup"
}

on_error() {
  local line="$1"
  local code="$2"

  trap - ERR
  rollback_host_changes_if_needed
  printf '%s[ERROR]%s Command failed at line %s (exit %s).\n' \
    "$RED" "$RESET" "$line" "$code" >&2
  exit "$code"
}

trap 'on_error "$LINENO" "$?"' ERR

rollback_host_changes_if_needed() {
  if [[ "$INSTALL_COMPLETED" == true ]]; then
    return
  fi
  if [[ "$FIREWALL_CHANGED_THIS_RUN" == true ]]; then
    log_warn "Installation failed; restoring firewall rules added during this run."
    restore_firewall || true
  fi
  if [[ "$RESOLVED_CHANGED_THIS_RUN" == true ]]; then
    log_warn "Installation failed; restoring the previous systemd-resolved setup."
    restore_systemd_resolved || true
  fi
}

require_root() {
  if [[ "$DRY_RUN" == true ]]; then
    return
  fi
  [[ "$(id -u)" -eq 0 ]] || die "Run this command as root (sudo)."
}

require_linux() {
  if [[ "$DRY_RUN" == true ]]; then
    return
  fi
  [[ "$(uname -s)" == "Linux" ]] || die "This installer supports Linux VPS hosts only."
}

require_templates() {
  local file
  for file in compose.yaml server_config.toml client_config.toml client_resolvers.txt; do
    [[ -f "$SCRIPT_DIR/templates/$file" ]] \
      || die "Missing required template: $SCRIPT_DIR/templates/$file"
  done
}

validate_domain() {
  local domain="${1,,}"
  local label
  local -a labels=()

  [[ ${#domain} -le 253
    && "$domain" == *.*
    && "$domain" =~ ^[a-z0-9.-]+$
    && "$domain" != .*
    && "$domain" != *.
    && "$domain" != *..* ]] || return 1

  IFS='.' read -r -a labels <<<"$domain"
  for label in "${labels[@]}"; do
    [[ ${#label} -ge 1
      && ${#label} -le 63
      && "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
  done
}

normalize_domain() {
  DOMAIN="${DOMAIN%.}"
  DOMAIN="${DOMAIN,,}"
  validate_domain "$DOMAIN" \
    || die "Invalid domain '$DOMAIN'. Use an ASCII hostname such as v.example.com."
}

validate_image() {
  local image="$1"
  [[ -n "$image"
    && ${#image} -le 512
    && "$image" =~ ^[A-Za-z0-9][A-Za-z0-9._/@:-]*$ ]] \
    || die "Invalid container image reference: $image"
}

encryption_method_id() {
  case "${1,,}" in
    none|0) printf '0\n' ;;
    xor|1) printf '1\n' ;;
    chacha20|chacha|2) printf '2\n' ;;
    aes-128-gcm|aes128|3) printf '3\n' ;;
    aes-192-gcm|aes192|4) printf '4\n' ;;
    aes-256-gcm|aes256|5) printf '5\n' ;;
    *) return 1 ;;
  esac
}

encryption_method_name() {
  case "$1" in
    0) printf 'none\n' ;;
    1) printf 'xor\n' ;;
    2) printf 'chacha20\n' ;;
    3) printf 'aes-128-gcm\n' ;;
    4) printf 'aes-192-gcm\n' ;;
    5) printf 'aes-256-gcm\n' ;;
    *) return 1 ;;
  esac
}

key_length_for_method() {
  case "$1" in
    3) printf '16\n' ;;
    4) printf '24\n' ;;
    0|1|2|5) printf '32\n' ;;
    *) return 1 ;;
  esac
}

read_env_value() {
  local key="$1"
  local file="$2"
  [[ -f "$file" ]] || return 0
  awk -F= -v wanted="$key" '$1 == wanted { sub(/^[^=]*=/, ""); print; exit }' "$file"
}

server_config_domain() {
  local file="$DATA_DIR/server_config.toml"
  [[ -f "$file" ]] || return 0
  sed -nE 's/^[[:space:]]*DOMAIN[[:space:]]*=[[:space:]]*\["([^"]+)".*/\1/p' "$file" \
    | head -n1
}

server_config_domains_toml() {
  local file="$DATA_DIR/server_config.toml"
  [[ -f "$file" ]] || return 0
  sed -nE 's/^[[:space:]]*DOMAIN[[:space:]]*=[[:space:]]*(\[.*\])[[:space:]]*$/\1/p' "$file" \
    | head -n1
}

server_config_method() {
  local file="$DATA_DIR/server_config.toml"
  [[ -f "$file" ]] || return 0
  awk -F= '
    /^[[:space:]]*DATA_ENCRYPTION_METHOD[[:space:]]*=/ {
      value=$2
      gsub(/[[:space:]]/, "", value)
      print value
      exit
    }
  ' "$file"
}

ensure_domain() {
  local saved_domain=""

  if [[ -z "$DOMAIN" ]]; then
    saved_domain="$(read_env_value MASTERDNS_DOMAIN "$ENV_FILE")"
    [[ -n "$saved_domain" ]] || saved_domain="$(server_config_domain)"
    DOMAIN="$saved_domain"
  fi

  if [[ -z "$DOMAIN" ]]; then
    if [[ -t 0 ]]; then
      read -r -p "Delegated tunnel domain (for example v.example.com): " DOMAIN
    else
      die "A domain is required. Pass --domain v.example.com."
    fi
  fi
  normalize_domain
}

ensure_image() {
  local saved_image=""
  if [[ -z "$IMAGE" ]]; then
    saved_image="$(read_env_value MASTERDNS_IMAGE "$ENV_FILE")"
    IMAGE="${saved_image:-$DEFAULT_IMAGE}"
  fi
  validate_image "$IMAGE"
}

confirm() {
  local prompt="$1"
  local reply=""

  if [[ "$ASSUME_YES" == true ]]; then
    return 0
  fi
  [[ -t 0 ]] || return 1
  read -r -p "$prompt [y/N]: " reply
  [[ "${reply,,}" == "y" || "${reply,,}" == "yes" ]]
}

ensure_layout() {
  mkdir -p -- "$DATA_DIR" "$CLIENT_DIR" "$STATE_DIR"
  chmod 700 "$INSTALL_DIR" "$DATA_DIR" "$CLIENT_DIR" "$STATE_DIR"
  if [[ ! -f "$MARKER_FILE" ]]; then
    printf 'masterdns-vps-setup=%s\n' "$SCRIPT_VERSION" >"$MARKER_FILE"
    chmod 600 "$MARKER_FILE"
  fi
}

atomic_write() {
  local target="$1"
  local mode="$2"
  local content="$3"
  local temp

  temp="$(mktemp "${target}.tmp.XXXXXX")"
  printf '%s\n' "$content" >"$temp"
  chmod "$mode" "$temp"

  if [[ -f "$target" ]] && cmp -s "$temp" "$target"; then
    rm -f -- "$temp"
    return
  fi
  mv -f -- "$temp" "$target"
}

install_compose_template() {
  local content
  content="$(<"$SCRIPT_DIR/templates/compose.yaml")"
  atomic_write "$COMPOSE_FILE" 600 "$content"
}

write_env_file() {
  local content
  content="$(printf \
    'COMPOSE_PROJECT_NAME=masterdnsvpn\nMASTERDNS_DOMAIN=%s\nMASTERDNS_IMAGE=%s' \
    "$DOMAIN" "$IMAGE")"
  atomic_write "$ENV_FILE" 600 "$content"
}

render_server_config() {
  local method_id="$1"
  local content
  content="$(<"$SCRIPT_DIR/templates/server_config.toml")"
  content="${content//__DOMAIN__/$DOMAIN}"
  content="${content//__ENCRYPTION_METHOD__/$method_id}"
  atomic_write "$DATA_DIR/server_config.toml" 600 "$content"
}

generate_key() {
  local method_id="$1"
  local key_file="$DATA_DIR/encrypt_key.txt"
  local required_length
  local key

  required_length="$(key_length_for_method "$method_id")"
  if [[ -s "$key_file" ]]; then
    key="$(tr -d '\r\n[:space:]' <"$key_file")"
    if [[ ${#key} -eq "$required_length" && "$key" =~ ^[0-9a-fA-F]+$ ]]; then
      chmod 600 "$key_file"
      return
    fi
    die "Existing key has the wrong format for encryption method $method_id: $key_file"
  fi

  key="$(generate_key_material "$method_id")" \
    || die "Could not generate an encryption key."
  [[ ${#key} -eq "$required_length" ]] || die "Could not generate an encryption key."
  atomic_write "$key_file" 600 "$key"
}

generate_key_material() {
  local method_id="$1"
  local required_length
  local byte_count
  local key

  required_length="$(key_length_for_method "$method_id")" || return 1
  byte_count=$(((required_length + 1) / 2))
  if command -v openssl >/dev/null 2>&1; then
    key="$(openssl rand -hex "$byte_count")" || return 1
  else
    key="$(od -An -N "$byte_count" -tx1 /dev/urandom | tr -d ' \n')" || return 1
  fi
  key="${key:0:required_length}"
  [[ ${#key} -eq "$required_length" && "$key" =~ ^[0-9a-f]+$ ]] || return 1
  printf '%s\n' "$key"
}

render_client_files() {
  local method_id
  local key
  local content
  local resolver_content
  local domains_toml

  method_id="$(server_config_method)"
  [[ "$method_id" =~ ^[0-5]$ ]] \
    || die "Could not read DATA_ENCRYPTION_METHOD from $DATA_DIR/server_config.toml"
  DOMAIN="$(server_config_domain)"
  normalize_domain
  domains_toml="$(server_config_domains_toml)"
  [[ "$domains_toml" == \[*\] ]] \
    || die "Could not read the DOMAIN array from $DATA_DIR/server_config.toml"
  generate_key "$method_id"
  key="$(tr -d '\r\n[:space:]' <"$DATA_DIR/encrypt_key.txt")"

  content="$(<"$SCRIPT_DIR/templates/client_config.toml")"
  content="${content//__DOMAINS_TOML__/$domains_toml}"
  content="${content//__ENCRYPTION_METHOD__/$method_id}"
  content="${content//__ENCRYPTION_KEY__/$key}"
  atomic_write "$CLIENT_DIR/client_config.toml" 600 "$content"

  resolver_content="$(<"$SCRIPT_DIR/templates/client_resolvers.txt")"
  if [[ ! -f "$CLIENT_DIR/client_resolvers.txt" ]]; then
    atomic_write "$CLIENT_DIR/client_resolvers.txt" 600 "$resolver_content"
  else
    chmod 600 "$CLIENT_DIR/client_resolvers.txt"
  fi
}

validate_architecture() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64|aarch64|arm64|armv5*|armv7*|mips64el|mips64le)
      ;;
    *)
      die "The official MasterDnsVPN image does not document support for architecture: $arch"
      ;;
  esac
}

load_os_release() {
  [[ -r /etc/os-release ]] || die "Cannot detect the Linux distribution."
  # shellcheck disable=SC1091
  source /etc/os-release
}

install_base_dependencies() {
  local -a missing=()
  local cmd
  local package

  for cmd in curl openssl ss; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [[ "$SKIP_DNS_CHECK" != true ]] && ! command -v dig >/dev/null 2>&1; then
    missing+=("dig")
  fi
  ((${#missing[@]} > 0)) || return

  load_os_release
  case "${ID:-}" in
    debian|ubuntu)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      local -a packages=(ca-certificates curl openssl iproute2)
      for package in "${missing[@]}"; do
        if [[ "$package" == "dig" ]]; then
          packages+=(dnsutils)
        fi
      done
      apt-get install -y --no-install-recommends "${packages[@]}"
      ;;
    *)
      die "Install the missing commands manually (${missing[*]}) and rerun the installer."
      ;;
  esac
}

docker_conflicting_packages() {
  local package
  local -a conflicts=()
  for package in docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc; do
    if dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null | grep -q '^ii'; then
      conflicts+=("$package")
    fi
  done
  if ((${#conflicts[@]} > 0)); then
    printf '%s\n' "${conflicts[@]}"
  fi
}

install_docker_apt() {
  local repo_os
  local codename
  local arch
  local key_temp
  local conflicts

  load_os_release
  case "${ID:-}" in
    debian|ubuntu) repo_os="$ID" ;;
    *) die "Automatic Docker installation supports Debian and Ubuntu only." ;;
  esac

  conflicts="$(docker_conflicting_packages)"
  if [[ -n "$conflicts" ]]; then
    local conflict
    log_warn "Conflicting packages are installed:"
    while IFS= read -r conflict; do
      printf '  %s\n' "$conflict" >&2
    done <<<"$conflicts"
    die "Remove or repair the conflicting Docker packages manually; the installer will not remove them."
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings

  key_temp="$(mktemp)"
  curl -fsSL --retry 3 "https://download.docker.com/linux/$repo_os/gpg" -o "$key_temp"
  install -m 0644 "$key_temp" /etc/apt/keyrings/docker.asc
  rm -f -- "$key_temp"

  codename="${VERSION_CODENAME:-}"
  if [[ "$repo_os" == "ubuntu" && -n "${UBUNTU_CODENAME:-}" ]]; then
    codename="$UBUNTU_CODENAME"
  fi
  [[ -n "$codename" ]] || die "Could not determine the distribution codename."
  arch="$(dpkg --print-architecture)"

  if [[ ! -e /etc/apt/sources.list.d/docker.sources ]]; then
    cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/$repo_os
Suites: $codename
Components: stable
Architectures: $arch
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  else
    log_info "Using existing /etc/apt/sources.list.d/docker.sources."
  fi

  apt-get update
  apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker
  fi
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    [[ "$SKIP_DOCKER_INSTALL" != true ]] \
      || die "Docker is missing and --skip-docker-install was specified."
    log_info "Installing Docker Engine from Docker's official apt repository."
    install_docker_apt
  fi

  if ! docker compose version >/dev/null 2>&1; then
    [[ "$SKIP_DOCKER_INSTALL" != true ]] \
      || die "The Docker Compose plugin is missing."
    load_os_release
    case "${ID:-}" in
      debian|ubuntu)
        apt-get update
        apt-get install -y docker-compose-plugin
        ;;
      *)
        die "Install the Docker Compose plugin and rerun the installer."
        ;;
    esac
  fi

  docker info >/dev/null 2>&1 \
    || die "Docker is installed, but the daemon is not available."
}

require_docker() {
  command -v docker >/dev/null 2>&1 \
    || die "Docker is not installed."
  docker compose version >/dev/null 2>&1 \
    || die "The Docker Compose plugin is not installed."
  docker info >/dev/null 2>&1 \
    || die "Docker is installed, but the daemon is not available."
}

compose() {
  docker compose \
    --project-directory "$INSTALL_DIR" \
    --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" \
    "$@"
}

managed_container_running() {
  local container_id=""
  [[ -f "$COMPOSE_FILE" && -f "$ENV_FILE" ]] || return 1
  container_id="$(compose ps -q masterdnsvpn 2>/dev/null || true)"
  [[ -n "$container_id" ]] || return 1
  [[ "$(docker inspect -f '{{.State.Running}}' "$container_id" 2>/dev/null || true)" == "true" ]]
}

ensure_container_name_available() {
  local existing_id=""
  local managed_id=""

  existing_id="$(docker ps -aq --filter 'name=^/masterdnsvpn$' | head -n1)"
  [[ -n "$existing_id" ]] || return
  managed_id="$(compose ps --all --quiet masterdnsvpn 2>/dev/null | head -n1 || true)"
  if [[ -z "$managed_id" || "$existing_id" != "$managed_id" ]]; then
    die "A container named 'masterdnsvpn' already exists and is not managed from $INSTALL_DIR."
  fi
}

port53_listeners() {
  ss -H -lntup 'sport = :53' 2>/dev/null || true
}

backup_resolv_conf() {
  if [[ -L /etc/resolv.conf ]]; then
    readlink /etc/resolv.conf >"$STATE_DIR/resolv.conf.symlink"
    chmod 600 "$STATE_DIR/resolv.conf.symlink"
  elif [[ -e /etc/resolv.conf ]]; then
    cp -a /etc/resolv.conf "$STATE_DIR/resolv.conf.backup"
  fi
}

release_systemd_resolved() {
  local current_target=""

  command -v systemctl >/dev/null 2>&1 \
    || die "systemd-resolved owns port 53, but systemctl is unavailable."
  systemctl is-active --quiet systemd-resolved \
    || die "Port 53 appears to be owned by systemd-resolved, but the service is not active."

  if [[ -e "$RESOLVED_DROP_IN" && ! -f "$STATE_DIR/resolved-managed" ]]; then
    die "$RESOLVED_DROP_IN already exists and is not managed by this installer."
  fi

  backup_resolv_conf
  install -m 0755 -d /etc/systemd/resolved.conf.d
  cat >"$RESOLVED_DROP_IN" <<'EOF'
[Resolve]
DNSStubListener=no
EOF
  touch "$STATE_DIR/resolved-managed"
  chmod 600 "$STATE_DIR/resolved-managed"
  RESOLVED_CHANGED_THIS_RUN=true

  if [[ -L /etc/resolv.conf ]]; then
    current_target="$(readlink /etc/resolv.conf)"
    if [[ "$current_target" == *stub-resolv.conf* ]]; then
      ln -sfn /run/systemd/resolve/resolv.conf /etc/resolv.conf
    fi
  elif [[ -f /etc/resolv.conf ]] \
    && grep -Eq '^[[:space:]]*nameserver[[:space:]]+127\.0\.0\.53([[:space:]]|$)' /etc/resolv.conf \
    && [[ -f /run/systemd/resolve/resolv.conf ]]; then
    cp -f /run/systemd/resolve/resolv.conf /etc/resolv.conf
  fi

  systemctl restart systemd-resolved
  log_success "Released the local systemd-resolved stub from port 53."
}

restore_systemd_resolved() {
  [[ -f "$STATE_DIR/resolved-managed" ]] || return 0

  rm -f -- "$RESOLVED_DROP_IN"
  if [[ -f "$STATE_DIR/resolv.conf.symlink" ]]; then
    local target
    target="$(<"$STATE_DIR/resolv.conf.symlink")"
    rm -f -- /etc/resolv.conf
    ln -s "$target" /etc/resolv.conf
  elif [[ -f "$STATE_DIR/resolv.conf.backup" ]]; then
    rm -f -- /etc/resolv.conf
    cp -a "$STATE_DIR/resolv.conf.backup" /etc/resolv.conf
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart systemd-resolved 2>/dev/null || true
  fi
  rm -f -- \
    "$STATE_DIR/resolved-managed" \
    "$STATE_DIR/resolv.conf.symlink" \
    "$STATE_DIR/resolv.conf.backup"
  RESOLVED_CHANGED_THIS_RUN=false
  log_success "Restored the previous systemd-resolved configuration."
}

ensure_port53_available() {
  local listeners
  local foreign

  if managed_container_running; then
    return
  fi

  listeners="$(port53_listeners)"
  [[ -n "$listeners" ]] || return

  log_warn "Port 53 is already in use:"
  printf '%s\n' "$listeners" >&2
  foreign="$(printf '%s\n' "$listeners" | grep -Eiv 'systemd-resolve(d)?' || true)"

  if [[ -z "$foreign" && "$ALLOW_RESOLVED_FIX" == true ]]; then
    if confirm "Disable only the local systemd-resolved stub listener to free port 53?"; then
      release_systemd_resolved
      listeners="$(port53_listeners)"
      [[ -z "$listeners" ]] || die "Port 53 is still occupied after changing systemd-resolved."
      return
    fi
  fi

  die "Free TCP/UDP port 53 and rerun the installer. No process was terminated."
}

configure_firewall() {
  local protocol

  [[ "$SKIP_FIREWALL" != true ]] || return
  if command -v ufw >/dev/null 2>&1 \
    && LC_ALL=C ufw status 2>/dev/null | head -n1 | grep -qi 'active'; then
    for protocol in udp tcp; do
      if ! LC_ALL=C ufw status 2>/dev/null \
        | grep -Eiq "(^|[[:space:]])53/$protocol([[:space:]]|$).*ALLOW"; then
        ufw allow "53/$protocol" comment "MasterDnsVPN DNS"
        touch "$STATE_DIR/firewall-ufw-$protocol"
        FIREWALL_CHANGED_THIS_RUN=true
      fi
    done
    log_success "Opened TCP/UDP port 53 in UFW."
    return
  fi

  if command -v firewall-cmd >/dev/null 2>&1 \
    && command -v systemctl >/dev/null 2>&1 \
    && systemctl is-active --quiet firewalld; then
    for protocol in udp tcp; do
      if ! firewall-cmd --permanent --query-port="53/$protocol" >/dev/null; then
        firewall-cmd --permanent --add-port="53/$protocol"
        touch "$STATE_DIR/firewall-firewalld-$protocol"
        FIREWALL_CHANGED_THIS_RUN=true
      fi
    done
    firewall-cmd --reload
    log_success "Opened TCP/UDP port 53 in firewalld."
    return
  fi

  log_warn "No active UFW/firewalld detected; host firewall rules were not changed."
  log_warn "Allow TCP and UDP port 53 in the VPS provider firewall/security group."
}

restore_firewall() {
  local protocol
  local reload_firewalld=false

  for protocol in udp tcp; do
    if [[ -f "$STATE_DIR/firewall-ufw-$protocol" ]]; then
      if command -v ufw >/dev/null 2>&1; then
        ufw --force delete allow "53/$protocol" >/dev/null 2>&1 || true
      fi
      rm -f -- "$STATE_DIR/firewall-ufw-$protocol"
    fi

    if [[ -f "$STATE_DIR/firewall-firewalld-$protocol" ]]; then
      if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --remove-port="53/$protocol" >/dev/null 2>&1 || true
        reload_firewalld=true
      fi
      rm -f -- "$STATE_DIR/firewall-firewalld-$protocol"
    fi
  done

  if [[ "$reload_firewalld" == true ]]; then
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
  FIREWALL_CHANGED_THIS_RUN=false
}

detect_public_ipv4() {
  local ip=""
  command -v curl >/dev/null 2>&1 || return 0
  ip="$(curl -4fsS --connect-timeout 4 --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    printf '%s\n' "$ip"
  fi
}

check_dns_delegation() {
  local domain="$1"
  local ns_records=""
  local public_ip=""
  local ns=""
  local addresses=""
  local found_address=false
  local matched_public_ip=false

  command -v dig >/dev/null 2>&1 \
    || die "The 'dig' command is required for DNS checks."

  printf '%sDNS check for %s%s\n' "$BOLD" "$domain" "$RESET"
  ns_records="$(dig +time=4 +tries=1 +short NS "$domain" 2>/dev/null \
    | sed 's/\.$//' || true)"
  if [[ -z "$ns_records" ]]; then
    log_warn "No public NS delegation found for $domain."
    return 1
  fi

  printf 'NS records:\n%s\n' "$ns_records"
  public_ip="$(detect_public_ipv4)"

  while IFS= read -r ns; do
    [[ -n "$ns" ]] || continue
    addresses="$(dig +time=4 +tries=1 +short A "$ns" 2>/dev/null || true)"
    if [[ -z "$addresses" ]]; then
      log_warn "$ns has no public A record."
      continue
    fi
    found_address=true
    printf '%s A:\n%s\n' "$ns" "$addresses"
    if [[ -n "$public_ip" ]] && grep -Fxq "$public_ip" <<<"$addresses"; then
      matched_public_ip=true
    fi
  done <<<"$ns_records"

  [[ "$found_address" == true ]] || return 1
  if [[ -n "$public_ip" && "$matched_public_ip" != true ]]; then
    log_warn "None of the nameserver A records matches this VPS public IPv4 ($public_ip)."
    return 1
  fi
  if [[ -n "$public_ip" ]]; then
    log_success "Delegation resolves to this VPS public IPv4 ($public_ip)."
  else
    log_success "NS delegation and nameserver A records are present."
  fi
}

wait_for_container() {
  local container_id=""
  local state=""
  local attempts=30

  while ((attempts > 0)); do
    container_id="$(compose ps -q masterdnsvpn 2>/dev/null || true)"
    if [[ -n "$container_id" ]]; then
      state="$(docker inspect -f '{{.State.Status}}' "$container_id" 2>/dev/null || true)"
      if [[ "$state" == "running" ]]; then
        log_success "MasterDnsVPN container is running."
        return
      fi
      if [[ "$state" == "exited" || "$state" == "dead" ]]; then
        break
      fi
    fi
    sleep 1
    attempts=$((attempts - 1))
  done

  compose logs --tail=100 >&2 || true
  log_warn "MasterDnsVPN container did not reach the running state."
  return 1
}

write_new_deployment() {
  local method_id="$1"

  install_compose_template
  write_env_file
  if [[ ! -f "$DATA_DIR/server_config.toml" ]]; then
    render_server_config "$method_id"
  fi
  generate_key "$(server_config_method)"
  render_client_files
}

print_install_summary() {
  local method_id
  local method_name
  method_id="$(server_config_method)"
  method_name="$(encryption_method_name "$method_id")"

  cat <<EOF

${GREEN}${BOLD}MasterDnsVPN deployment is ready.${RESET}

Domain:          $DOMAIN
Image:           $IMAGE
Encryption:      $method_name
Compose file:    $COMPOSE_FILE
Server config:   $DATA_DIR/server_config.toml
Encryption key:  $DATA_DIR/encrypt_key.txt
Client config:   $CLIENT_DIR/client_config.toml
Resolver list:   $CLIENT_DIR/client_resolvers.txt

Next:
  1. Copy both files from $CLIENT_DIR to the client machine.
  2. Put them next to the official MasterDnsVPN client binary.
  3. Start the client; its SOCKS5 proxy listens on 127.0.0.1:18000.

Diagnostics:
  sudo $INSTALL_DIR/vps-setup.sh doctor
  sudo $INSTALL_DIR/vps-setup.sh logs
EOF
}

install_copy() {
  local source="$1"
  local target="$2"
  local mode="$3"
  if [[ -e "$target" && "$source" -ef "$target" ]]; then
    chmod "$mode" "$target"
    return
  fi
  install -m "$mode" "$source" "$target"
}

install_self_copy() {
  install_copy "$SCRIPT_DIR/vps-setup.sh" "$INSTALL_DIR/vps-setup.sh" 0700
  install -m 0755 -d "$INSTALL_DIR/templates"
  install_copy "$SCRIPT_DIR/templates/compose.yaml" "$INSTALL_DIR/templates/compose.yaml" 0600
  install_copy "$SCRIPT_DIR/templates/server_config.toml" "$INSTALL_DIR/templates/server_config.toml" 0600
  install_copy "$SCRIPT_DIR/templates/client_config.toml" "$INSTALL_DIR/templates/client_config.toml" 0600
  install_copy "$SCRIPT_DIR/templates/client_resolvers.txt" "$INSTALL_DIR/templates/client_resolvers.txt" 0600
}

command_install() {
  local method_id
  local existing_domain=""

  ensure_domain
  ensure_image
  method_id="$(encryption_method_id "$ENCRYPTION_NAME")" \
    || die "Unsupported encryption method: $ENCRYPTION_NAME"

  ensure_layout
  existing_domain="$(server_config_domain)"
  if [[ -n "$existing_domain" && "$existing_domain" != "$DOMAIN" ]]; then
    die "Existing server config uses $existing_domain. Edit it with the 'config' command instead."
  fi
  if [[ -f "$DATA_DIR/server_config.toml" && "$ENCRYPTION_SET" == true ]]; then
    local existing_method
    existing_method="$(server_config_method)"
    [[ "$existing_method" == "$method_id" ]] \
      || die "Existing server config uses encryption method $existing_method; it was not overwritten."
  fi

  write_new_deployment "$method_id"
  if [[ "$DRY_RUN" == true ]]; then
    log_success "Dry-run deployment rendered in $INSTALL_DIR."
    return
  fi

  validate_architecture
  install_base_dependencies
  ensure_docker
  install_self_copy
  ensure_container_name_available
  ensure_port53_available
  configure_firewall

  compose config --quiet
  compose pull
  compose up -d --remove-orphans
  wait_for_container || die "MasterDnsVPN failed to start."
  chmod 700 "$DATA_DIR" "$CLIENT_DIR"
  chmod 600 \
    "$DATA_DIR/server_config.toml" \
    "$DATA_DIR/encrypt_key.txt" \
    "$CLIENT_DIR/client_config.toml" \
    "$CLIENT_DIR/client_resolvers.txt"

  if [[ "$SKIP_DNS_CHECK" != true ]]; then
    check_dns_delegation "$DOMAIN" \
      || log_warn "DNS is not ready yet. The container can run, but clients cannot connect until delegation works."
  fi

  INSTALL_COMPLETED=true
  print_install_summary
}

require_deployment() {
  if [[ ! -f "$MARKER_FILE" || -L "$MARKER_FILE"
    || ! -f "$COMPOSE_FILE" || ! -f "$ENV_FILE" ]] \
    || ! grep -Eq '^masterdns-vps-setup=[0-9]+\.[0-9]+\.[0-9]+$' "$MARKER_FILE"; then
    die "No managed deployment found in $INSTALL_DIR."
  fi
}

command_update() {
  local old_env

  require_deployment
  ensure_docker
  DOMAIN="$(read_env_value MASTERDNS_DOMAIN "$ENV_FILE")"
  normalize_domain
  if [[ -n "$IMAGE" ]]; then
    validate_image "$IMAGE"
  else
    IMAGE="$(read_env_value MASTERDNS_IMAGE "$ENV_FILE")"
    IMAGE="${IMAGE:-$DEFAULT_IMAGE}"
  fi

  old_env="$(<"$ENV_FILE")"
  write_env_file
  install_compose_template
  install_self_copy
  compose config --quiet
  if ! compose pull; then
    atomic_write "$ENV_FILE" 600 "$old_env"
    die "Image pull failed; restored the previous environment file."
  fi
  if ! compose up -d --remove-orphans || ! wait_for_container; then
    atomic_write "$ENV_FILE" 600 "$old_env"
    compose up -d --remove-orphans >/dev/null 2>&1 || true
    wait_for_container >/dev/null 2>&1 || true
    die "Update failed; restored the previous image reference."
  fi
  render_client_files
  log_success "MasterDnsVPN was updated using $IMAGE."
}

command_status() {
  local method_id
  local method_name

  require_deployment
  require_docker
  DOMAIN="$(read_env_value MASTERDNS_DOMAIN "$ENV_FILE")"
  IMAGE="$(read_env_value MASTERDNS_IMAGE "$ENV_FILE")"
  method_id="$(server_config_method)"
  method_name="$(encryption_method_name "$method_id" 2>/dev/null || printf 'unknown')"

  printf 'Domain:     %s\n' "$DOMAIN"
  printf 'Image:      %s\n' "$IMAGE"
  printf 'Encryption: %s\n' "$method_name"
  printf 'Directory:  %s\n\n' "$INSTALL_DIR"
  compose ps
}

command_logs() {
  require_deployment
  require_docker
  if [[ "$FOLLOW_LOGS" == true ]]; then
    compose logs --tail=100 --follow
  else
    compose logs --tail=100
  fi
}

command_doctor() {
  local failures=0
  local method_id=""
  local expected_length=""
  local key=""
  local listeners=""

  require_deployment
  require_docker
  DOMAIN="$(read_env_value MASTERDNS_DOMAIN "$ENV_FILE")"
  normalize_domain

  if compose config --quiet; then
    log_success "Compose configuration is valid."
  else
    log_warn "Compose configuration is invalid."
    failures=$((failures + 1))
  fi

  if managed_container_running; then
    log_success "Container is running."
  else
    log_warn "Container is not running."
    failures=$((failures + 1))
  fi

  listeners="$(port53_listeners)"
  if [[ -n "$listeners" ]]; then
    log_success "Port 53 has an active listener."
  else
    log_warn "No TCP/UDP listener is visible on port 53."
    failures=$((failures + 1))
  fi

  method_id="$(server_config_method)"
  if [[ "$method_id" =~ ^[0-5]$ && -s "$DATA_DIR/encrypt_key.txt" ]]; then
    expected_length="$(key_length_for_method "$method_id")"
    key="$(tr -d '\r\n[:space:]' <"$DATA_DIR/encrypt_key.txt")"
    if [[ ${#key} -eq "$expected_length" && "$key" =~ ^[0-9a-fA-F]+$ ]]; then
      log_success "Encryption key format matches method $method_id."
    else
      log_warn "Encryption key format does not match method $method_id."
      failures=$((failures + 1))
    fi
  else
    log_warn "Server encryption settings are missing or invalid."
    failures=$((failures + 1))
  fi

  if command -v stat >/dev/null 2>&1; then
    if [[ "$(stat -c '%a' "$DATA_DIR/encrypt_key.txt" 2>/dev/null || true)" == "600" ]]; then
      log_success "Encryption key permissions are 0600."
    else
      log_warn "Encryption key permissions should be 0600."
      failures=$((failures + 1))
    fi
  fi

  if [[ "$SKIP_DNS_CHECK" != true ]]; then
    check_dns_delegation "$DOMAIN" \
      || { log_warn "DNS delegation check failed."; failures=$((failures + 1)); }
  fi

  if ((failures > 0)); then
    die "Diagnostics found $failures problem(s)."
  fi
  log_success "All diagnostics passed."
}

command_check_dns() {
  if [[ -z "$DOMAIN" ]]; then
    DOMAIN="$(read_env_value MASTERDNS_DOMAIN "$ENV_FILE")"
  fi
  [[ -n "$DOMAIN" ]] || die "Pass --domain when no deployment exists."
  normalize_domain
  command -v dig >/dev/null 2>&1 \
    || die "Install dnsutils (dig) before running this command."
  check_dns_delegation "$DOMAIN"
}

command_client_config() {
  require_deployment
  render_client_files
  log_success "Client files are ready in $CLIENT_DIR."
}

command_rotate_key() {
  local key_file="$DATA_DIR/encrypt_key.txt"
  local backup_file=""
  local method_id=""
  local new_key=""

  require_deployment
  require_docker
  method_id="$(server_config_method)"
  [[ "$method_id" =~ ^[0-5]$ ]] || die "Server encryption method is invalid."
  [[ -s "$key_file" ]] || die "Current encryption key is missing: $key_file"
  if ! confirm "Rotate the tunnel key? Existing clients will stop working until reconfigured."; then
    die "Key rotation cancelled."
  fi

  new_key="$(generate_key_material "$method_id")" \
    || die "Could not generate a replacement key."
  compose stop
  backup_file="$STATE_DIR/encrypt_key.$(date -u +%Y%m%dT%H%M%SZ).bak"
  cp -a -- "$key_file" "$backup_file"
  chmod 600 "$backup_file"
  if ! atomic_write "$key_file" 600 "$new_key"; then
    cp -a -- "$backup_file" "$key_file"
    compose up -d >/dev/null 2>&1 || true
    die "Key rotation failed; the previous key was restored."
  fi
  render_client_files
  if ! compose up -d || ! wait_for_container; then
    cp -a -- "$backup_file" "$key_file"
    render_client_files || true
    compose up -d >/dev/null 2>&1 || true
    wait_for_container >/dev/null 2>&1 || true
    die "The server rejected the new key; the previous key was restored."
  fi
  log_success "Key rotated. Replace both files on every client from $CLIENT_DIR."
  if [[ -n "$backup_file" ]]; then
    log_warn "Previous key kept for manual rollback: $backup_file"
  fi
}

command_config() {
  local editor="${EDITOR:-}"
  local timestamp=""
  local config_backup=""
  local key_backup=""
  local old_env=""
  local new_domain=""
  local method_id=""
  local expected_length=""
  local current_key=""
  local replacement_key=""

  require_deployment
  require_docker
  if [[ -z "$editor" ]]; then
    if command -v nano >/dev/null 2>&1; then
      editor="nano"
    elif command -v vi >/dev/null 2>&1; then
      editor="vi"
    else
      die "Set EDITOR to a text editor and rerun this command."
    fi
  fi

  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  config_backup="$STATE_DIR/server_config.$timestamp.bak"
  key_backup="$STATE_DIR/encrypt_key.$timestamp.bak"
  old_env="$(<"$ENV_FILE")"
  cp -a -- "$DATA_DIR/server_config.toml" "$config_backup"
  cp -a -- "$DATA_DIR/encrypt_key.txt" "$key_backup"
  chmod 600 "$config_backup" "$key_backup"

  if ! "$editor" "$DATA_DIR/server_config.toml"; then
    cp -a -- "$config_backup" "$DATA_DIR/server_config.toml"
    die "Editor exited with an error; the previous configuration was restored."
  fi

  new_domain="$(server_config_domain)"
  new_domain="${new_domain%.}"
  new_domain="${new_domain,,}"
  if ! validate_domain "$new_domain"; then
    cp -a -- "$config_backup" "$DATA_DIR/server_config.toml"
    die "Edited configuration has an invalid or missing DOMAIN; the previous file was restored."
  fi
  method_id="$(server_config_method)"
  if [[ ! "$method_id" =~ ^[0-5]$ ]]; then
    cp -a -- "$config_backup" "$DATA_DIR/server_config.toml"
    die "Edited configuration has an invalid encryption method; the previous file was restored."
  fi

  expected_length="$(key_length_for_method "$method_id")"
  current_key="$(tr -d '\r\n[:space:]' <"$DATA_DIR/encrypt_key.txt")"
  if [[ ${#current_key} -ne "$expected_length" || ! "$current_key" =~ ^[0-9a-fA-F]+$ ]]; then
    replacement_key="$(generate_key_material "$method_id")" \
      || {
        cp -a -- "$config_backup" "$DATA_DIR/server_config.toml"
        die "Could not generate a key for the edited encryption method; configuration was restored."
      }
    atomic_write "$DATA_DIR/encrypt_key.txt" 600 "$replacement_key"
    log_warn "Encryption method requires a different key format; a new key was generated."
  fi

  DOMAIN="$new_domain"
  IMAGE="$(read_env_value MASTERDNS_IMAGE "$ENV_FILE")"
  write_env_file
  if ! compose up -d --force-recreate --remove-orphans || ! wait_for_container; then
    cp -a -- "$config_backup" "$DATA_DIR/server_config.toml"
    cp -a -- "$key_backup" "$DATA_DIR/encrypt_key.txt"
    atomic_write "$ENV_FILE" 600 "$old_env"
    compose up -d --force-recreate --remove-orphans >/dev/null 2>&1 || true
    wait_for_container >/dev/null 2>&1 || true
    die "New configuration failed; the previous configuration and key were restored."
  fi
  render_client_files
  log_success "Configuration applied and client files regenerated."
  log_info "Previous configuration and key are kept in $STATE_DIR."
}

command_simple_compose() {
  local action="$1"
  require_deployment
  require_docker
  case "$action" in
    start)
      compose up -d
      wait_for_container || die "MasterDnsVPN failed to start."
      ;;
    stop)
      compose stop
      ;;
    restart)
      compose restart
      wait_for_container || die "MasterDnsVPN failed to restart."
      ;;
  esac
}

safe_to_purge() {
  [[ -f "$MARKER_FILE" && ! -L "$MARKER_FILE" ]] || return 1
  grep -Eq '^masterdns-vps-setup=[0-9]+\.[0-9]+\.[0-9]+$' "$MARKER_FILE"
}

command_uninstall() {
  require_deployment

  if ! confirm "Stop and remove the MasterDnsVPN container? Persistent data will be kept."; then
    die "Uninstall cancelled."
  fi

  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    compose down --remove-orphans
  else
    log_warn "Docker/Compose is unavailable; skipping container removal."
  fi

  restore_firewall
  restore_systemd_resolved

  if [[ "$PURGE" == true ]]; then
    safe_to_purge || die "Refusing to purge an unrecognized directory: $INSTALL_DIR"
    if [[ "$ASSUME_YES" != true ]] \
      && ! confirm "Permanently delete $INSTALL_DIR, including the encryption key and all configs?"; then
      die "Purge cancelled; deployment data was kept."
    fi
    rm -rf -- "$INSTALL_DIR"
    log_success "Container and persistent deployment data were removed."
  else
    log_success "Container removed. Persistent data is kept in $INSTALL_DIR."
    log_info "Rerun 'install' to deploy it again, or use 'uninstall --purge' to delete it."
  fi
  log_info "Docker itself and cached images were not removed."
}

main() {
  parse_args "$@"
  validate_option_scope
  canonicalize_install_dir

  case "$COMMAND" in
    install)
      require_templates
      require_root
      require_linux
      command_install
      ;;
    update)
      require_templates
      require_root
      require_linux
      command_update
      ;;
    start|stop|restart)
      require_root
      require_linux
      command_simple_compose "$COMMAND"
      ;;
    status)
      require_root
      require_linux
      command_status
      ;;
    logs)
      require_root
      require_linux
      command_logs
      ;;
    doctor)
      require_root
      require_linux
      command_doctor
      ;;
    check-dns)
      require_linux
      command_check_dns
      ;;
    client-config)
      require_templates
      require_root
      command_client_config
      ;;
    rotate-key)
      require_templates
      require_root
      require_linux
      command_rotate_key
      ;;
    config)
      require_templates
      require_root
      require_linux
      command_config
      ;;
    uninstall)
      require_root
      require_linux
      command_uninstall
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
