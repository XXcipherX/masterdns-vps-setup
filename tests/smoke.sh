#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
TMP_ROOT="$(mktemp -d)"
readonly TMP_ROOT
trap 'rm -rf -- "$TMP_ROOT"' EXIT

fail() {
  printf 'SMOKE FAILED: %s\n' "$*" >&2
  exit 1
}

assert_file() {
  [[ -f "$1" ]] || fail "missing file: $1"
}

assert_contains() {
  local file="$1"
  local text="$2"
  grep -Fq -- "$text" "$file" || fail "$file does not contain: $text"
}

assert_not_contains() {
  local file="$1"
  local text="$2"
  if grep -Fq -- "$text" "$file"; then
    fail "$file unexpectedly contains: $text"
  fi
}

assert_fails() {
  if "$@" >"$TMP_ROOT/expected-failure.log" 2>&1; then
    fail "command unexpectedly succeeded: $*"
  fi
}

cd "$REPO_ROOT"

bash -n vps-setup.sh tests/smoke.sh

(
  # shellcheck disable=SC1091
  source "$REPO_ROOT/vps-setup.sh"
  validate_domain "v.example.com"
  validate_domain "a-b.example.co.uk"
  if validate_domain "example"; then fail "accepted a single-label domain"; fi
  if validate_domain "-v.example.com"; then fail "accepted an invalid leading hyphen"; fi
  if validate_domain "v..example.com"; then fail "accepted an empty DNS label"; fi
  if validate_domain "https://v.example.com"; then fail "accepted a URL as a domain"; fi
  [[ "$(encryption_method_id chacha20)" == "2" ]]
  [[ "$(encryption_method_name 5)" == "aes-256-gcm" ]]
  [[ "$(key_length_for_method 3)" == "16" ]]
  [[ "$(key_length_for_method 4)" == "24" ]]
  [[ "$(key_length_for_method 5)" == "32" ]]
  [[ "$ENCRYPTION_NAME" == "xor" ]]

  command() {
    if [[ "${1:-}" == "-v" ]]; then
      return 0
    fi
    builtin command "$@"
  }
  SKIP_DNS_CHECK=true
  install_base_dependencies

  docker() {
    return 0
  }
  COMPOSE_FILE="$TMP_ROOT/no-container/compose.yaml"
  ENV_FILE="$TMP_ROOT/no-container/.env"
  ensure_container_name_available

  port53_listeners() {
    return 0
  }
  ensure_port53_available

  SKIP_FIREWALL=true
  configure_firewall
)

(
  # shellcheck disable=SC1091
  source "$REPO_ROOT/vps-setup.sh"
  installer_path="$TMP_ROOT/docker-installer"

  mktemp() {
    printf '%s\n' "$installer_path"
  }
  curl() {
    : >"$installer_path"
  }
  bash() {
    [[ "${1:-}" == "$installer_path" ]]
  }

  docker_install
  [[ ! -e "$installer_path" ]] || fail "successful Docker installer was not removed"

  curl() {
    : >"$installer_path"
    return 1
  }
  if docker_install; then
    fail "failed Docker download was accepted"
  fi
  [[ ! -e "$installer_path" ]] || fail "failed Docker installer was not removed"
)

DEFAULT_DIR="$TMP_ROOT/default/deployment"
bash vps-setup.sh install \
  --dry-run \
  --domain V.Example.COM. \
  --install-dir "$DEFAULT_DIR" \
  --image ghcr.io/masterking32/masterdnsvpn:latest

for file in \
  "$DEFAULT_DIR/.masterdns-vps-setup" \
  "$DEFAULT_DIR/.env" \
  "$DEFAULT_DIR/compose.yaml" \
  "$DEFAULT_DIR/data/server_config.toml" \
  "$DEFAULT_DIR/data/encrypt_key.txt" \
  "$DEFAULT_DIR/client/client_config.toml" \
  "$DEFAULT_DIR/client/client_resolvers.txt"; do
  assert_file "$file"
done

assert_contains "$DEFAULT_DIR/.env" "MASTERDNS_DOMAIN=v.example.com"
assert_contains "$DEFAULT_DIR/.env" "MASTERDNS_IMAGE=ghcr.io/masterking32/masterdnsvpn:latest"
assert_contains "$DEFAULT_DIR/data/server_config.toml" 'DOMAIN = ["v.example.com"]'
assert_contains "$DEFAULT_DIR/data/server_config.toml" "DATA_ENCRYPTION_METHOD = 1"
assert_contains "$DEFAULT_DIR/data/server_config.toml" 'LOG_LEVEL = "WARN"'
assert_contains "$DEFAULT_DIR/client/client_config.toml" 'DOMAINS = ["v.example.com"]'
assert_contains "$DEFAULT_DIR/client/client_config.toml" "DATA_ENCRYPTION_METHOD = 1"
assert_contains "$DEFAULT_DIR/compose.yaml" "NET_BIND_SERVICE"
assert_contains "$DEFAULT_DIR/compose.yaml" "no-new-privileges:true"
assert_contains "$DEFAULT_DIR/compose.yaml" '"53:53/udp"'
assert_contains "$DEFAULT_DIR/compose.yaml" '"53:53/tcp"'

if rg -n '__[A-Z0-9_]+__' "$DEFAULT_DIR" >/dev/null 2>&1; then
  fail "unrendered placeholder found"
elif ! command -v rg >/dev/null 2>&1 \
  && grep -R -E '__[A-Z0-9_]+__' "$DEFAULT_DIR" >/dev/null 2>&1; then
  fail "unrendered placeholder found"
fi

server_key="$(tr -d '\r\n[:space:]' <"$DEFAULT_DIR/data/encrypt_key.txt")"
client_key="$(
  sed -nE 's/^ENCRYPTION_KEY = "([^"]+)"$/\1/p' \
    "$DEFAULT_DIR/client/client_config.toml"
)"
[[ "$server_key" =~ ^[0-9a-f]{32}$ ]] || fail "invalid generated XOR key"
[[ "$server_key" == "$client_key" ]] || fail "client and server keys differ"

sed -i \
  's/DOMAIN = \["v.example.com"\]/DOMAIN = ["v.example.com", "w.example.com"]/' \
  "$DEFAULT_DIR/data/server_config.toml"
(
  # shellcheck disable=SC1091
  source "$REPO_ROOT/vps-setup.sh"
  INSTALL_DIR="$DEFAULT_DIR"
  canonicalize_install_dir
  render_client_files
)
assert_contains \
  "$DEFAULT_DIR/client/client_config.toml" \
  'DOMAINS = ["v.example.com", "w.example.com"]'
sed -i \
  's/DOMAIN = \["v.example.com", "w.example.com"\]/DOMAIN = ["v.example.com"]/' \
  "$DEFAULT_DIR/data/server_config.toml"

printf '\n192.0.2.53\n' >>"$DEFAULT_DIR/client/client_resolvers.txt"
bash vps-setup.sh install \
  --dry-run \
  --domain v.example.com \
  --install-dir "$DEFAULT_DIR"
assert_contains "$DEFAULT_DIR/client/client_resolvers.txt" "192.0.2.53"
[[ "$(tr -d '\r\n[:space:]' <"$DEFAULT_DIR/data/encrypt_key.txt")" == "$server_key" ]] \
  || fail "idempotent install rotated the key"

AES_DIR="$TMP_ROOT/aes/deployment"
bash vps-setup.sh install \
  --dry-run \
  --domain dns.example.net \
  --encryption aes-192-gcm \
  --image ghcr.io/masterking32/masterdnsvpn:v-test \
  --install-dir "$AES_DIR"
assert_contains "$AES_DIR/data/server_config.toml" "DATA_ENCRYPTION_METHOD = 4"
assert_contains "$AES_DIR/client/client_config.toml" "DATA_ENCRYPTION_METHOD = 4"
[[ "$(tr -d '\r\n[:space:]' <"$AES_DIR/data/encrypt_key.txt")" =~ ^[0-9a-f]{24}$ ]] \
  || fail "invalid generated AES-192-GCM key"

assert_fails bash vps-setup.sh install \
  --dry-run \
  --domain example \
  --install-dir "$TMP_ROOT/invalid-domain"
assert_fails bash vps-setup.sh install \
  --dry-run \
  --domain v.example.com \
  --image 'bad image;command' \
  --install-dir "$TMP_ROOT/invalid-image"
assert_fails bash vps-setup.sh install \
  --dry-run \
  --domain v.example.com \
  --encryption rot13 \
  --install-dir "$TMP_ROOT/invalid-encryption"
assert_fails bash vps-setup.sh install \
  --dry-run \
  --domain v.example.com \
  --install-dir /tmp
assert_fails bash vps-setup.sh install \
  --dry-run \
  --domain changed.example.com \
  --install-dir "$DEFAULT_DIR"
assert_fails bash vps-setup.sh install \
  --dry-run \
  --domain v.example.com \
  --encryption aes-256-gcm \
  --install-dir "$DEFAULT_DIR"

assert_fails bash vps-setup.sh uninstall \
  --dry-run \
  --yes \
  --purge \
  --install-dir "$TMP_ROOT/purge/deployment"

assert_contains vps-setup.sh "https://get.docker.com"
assert_contains vps-setup.sh 'bash "$installer"'
assert_not_contains vps-setup.sh "curl -fsSL https://get.docker.com |"
assert_not_contains vps-setup.sh "kill -9"
assert_contains README.md "dig +short NS"
assert_contains README.md "client_config.toml"
assert_contains SECURITY.md "rotate-key"

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  docker compose \
    --project-directory "$DEFAULT_DIR" \
    --env-file "$DEFAULT_DIR/.env" \
    -f "$DEFAULT_DIR/compose.yaml" \
    config --quiet
fi

printf 'SMOKE: OK\n'
