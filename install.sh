#!/usr/bin/env bash
# install.sh — Set up SigNoz on a Sprite sandbox (sprites.dev)
#
# One-liner install:
#   curl https://raw.githubusercontent.com/lubien/fly-011y/main/install.sh | bash
#
# When running non-interactively (pipe / CI), supply required values via env:
#   FLY_ORG=myorg \
#   SIGNOZ_EXTERNAL_URL=https://NAME.sprites.app \
#   FLY_API_TOKEN=FlyV1_... \
#   curl https://raw.githubusercontent.com/lubien/fly-011y/main/install.sh | bash

set -euo pipefail

# ─── Configuration ─────────────────────────────────────────────────────────────
REPO_URL="https://github.com/lubien/fly-011y.git"
INSTALL_DIR="/home/sprite/fly-o11y"
SETUP_DIR="${INSTALL_DIR}/setup"

# ─── Terminal detection ────────────────────────────────────────────────────────
# Used to decide between interactive prompts and env-var-only mode.
STDIN_IS_TTY=0
[ -t 0 ] && STDIN_IS_TTY=1

STDOUT_IS_TTY=0
[ -t 1 ] && STDOUT_IS_TTY=1

# ─── Colors (strip when stdout is not a terminal) ──────────────────────────────
if [ "${STDOUT_IS_TTY}" -eq 1 ]; then
  BOLD='\033[1m'; DIM='\033[2m'
  GREEN='\033[0;32m'; CYAN='\033[0;36m'
  YELLOW='\033[1;33m'; RED='\033[0;31m'
  NC='\033[0m'
else
  BOLD=''; DIM=''; GREEN=''; CYAN=''; YELLOW=''; RED=''; NC=''
fi

# ─── Logging helpers ───────────────────────────────────────────────────────────
info()    { printf "  ${CYAN}▸${NC} %s\n"  "$*"; }
success() { printf "  ${GREEN}✓${NC} %s\n" "$*"; }
warn()    { printf "  ${YELLOW}⚠${NC}  %s\n" "$*" >&2; }
die()     { printf "  ${RED}✗${NC} %s\n"   "$*" >&2; exit 1; }
section() { printf "\n${BOLD}── %s${NC}\n" "$*"; }

# ─── Script-level globals (set by configure(), read by print_access_info()) ───
INGESTION_KEY=""
_FLY_ORG=""
_SIGNOZ_URL=""

# ─── Helper: generate a random hex secret ──────────────────────────────────────
# gen_secret <bytes>  →  <bytes*2> hex chars
# e.g. gen_secret 32  →  64 chars | gen_secret 20  →  40 chars
gen_secret() {
  openssl rand -hex "${1:-32}"
}

# ─── Helper: extract a single KEY=VALUE line from a .env file ─────────────────
# Usage: env_get FILE KEY
env_get() {
  grep "^${2}=" "${1}" 2>/dev/null | cut -d= -f2- || true
}

# ══════════════════════════════════════════════════════════════════════════════
# Step 1 — Verify we are running inside a Sprite
# ══════════════════════════════════════════════════════════════════════════════
check_sprite() {
  section "Checking Sprite environment"
  if ! command -v sprite-env &>/dev/null; then
    die "sprite-env not found. This script is designed for Sprites (https://sprites.dev)."
  fi
  success "Sprite environment confirmed."
}

# ══════════════════════════════════════════════════════════════════════════════
# Step 2 — Install Docker (official apt repo) if absent
# ══════════════════════════════════════════════════════════════════════════════
install_docker() {
  section "Docker"
  if command -v docker &>/dev/null; then
    success "Docker already installed: $(docker --version 2>&1 | head -1)"
    return 0
  fi

  info "Installing Docker from the official Ubuntu repository…"

  sudo apt-get update -qq
  sudo apt-get install -y ca-certificates curl git gettext-base

  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
       -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc

  # Resolve the Ubuntu codename and CPU architecture
  local codename arch
  # shellcheck disable=SC1091
  codename=$(. /etc/os-release \
    && printf '%s' "${UBUNTU_CODENAME:-${VERSION_CODENAME:-jammy}}")
  arch=$(dpkg --print-architecture)

  sudo tee /etc/apt/sources.list.d/docker.sources > /dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${codename}
Components: stable
Architectures: ${arch}
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  sudo apt-get update -qq
  sudo apt-get install -y \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

  success "Docker installed."
}

# ══════════════════════════════════════════════════════════════════════════════
# Ensure git + envsubst are present (safety net if Docker was pre-installed)
# ══════════════════════════════════════════════════════════════════════════════
ensure_tools() {
  local need_install=0
  command -v git      &>/dev/null || need_install=1
  command -v envsubst &>/dev/null || need_install=1

  if [ "${need_install}" -eq 1 ]; then
    info "Installing missing utilities (git, gettext-base)…"
    sudo apt-get update -qq
    command -v git      &>/dev/null || sudo apt-get install -y git
    command -v envsubst &>/dev/null || sudo apt-get install -y gettext-base
    success "Utilities ready."
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Step 3 — Register + start dockerd via sprite-env services
# ══════════════════════════════════════════════════════════════════════════════
start_dockerd() {
  section "Docker daemon"

  if sprite-env services get dockerd &>/dev/null; then
    success "dockerd sprite-env service already registered."
  else
    info "Registering dockerd as a sprite-env service…"
    sprite-env services create dockerd --cmd sudo --args dockerd --no-stream
    success "dockerd service created."
  fi

  info "Waiting for Docker daemon to be reachable (up to 60 s)…"
  local attempts=0
  until docker info &>/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [ "${attempts}" -ge 20 ]; then
      die "Docker daemon did not become ready after ${attempts} attempts." \
          "Debug: sprite-env services get dockerd"
    fi
    sleep 3
  done
  success "Docker daemon is ready."
}

# ══════════════════════════════════════════════════════════════════════════════
# Step 4 — Clone or update the repository
# ══════════════════════════════════════════════════════════════════════════════
clone_or_update_repo() {
  section "Repository"

  # SKIP_CLONE=1 — used when files are already in place (e.g. local testing
  # before the repo is public, or when running from inside the repo itself).
  if [ "${SKIP_CLONE:-0}" = "1" ]; then
    info "SKIP_CLONE=1 — skipping git clone/pull, using existing files at ${INSTALL_DIR}"
    [ -d "${INSTALL_DIR}" ] || die "INSTALL_DIR ${INSTALL_DIR} does not exist."
    return 0
  fi

  if [ -d "${INSTALL_DIR}/.git" ]; then
    info "Existing clone found at ${INSTALL_DIR}. Pulling latest changes…"
    git -C "${INSTALL_DIR}" pull --ff-only
    success "Repository updated."
  else
    info "Cloning ${REPO_URL} → ${INSTALL_DIR}"
    git clone "${REPO_URL}" "${INSTALL_DIR}"
    success "Repository cloned."
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Steps 5–9 — Generate secrets.env, prepare otel/, produce config files
# ══════════════════════════════════════════════════════════════════════════════
configure() {
  section "Configuration"

  if [ ! -d "${SETUP_DIR}" ]; then
    die "Setup directory not found: ${SETUP_DIR}" \
        "(expected after cloning the repo)"
  fi

  cd "${SETUP_DIR}"
  local secrets_env="./secrets.env"

  # ── 5a. Collect or load credentials ────────────────────────────────────────
  if [ -f "${secrets_env}" ]; then
    # ── Reuse existing secrets ──────────────────────────────────────────────
    success "secrets.env already exists — reusing."

    INGESTION_KEY=$(env_get "${secrets_env}" "INGESTION_KEY")
    _FLY_ORG=$(env_get "${secrets_env}" "FLY_ORG")
    _SIGNOZ_URL=$(env_get "${secrets_env}" "SIGNOZ_GLOBAL_EXTERNAL__URL")

    [ -n "${INGESTION_KEY}" ] || die "Could not read INGESTION_KEY from secrets.env"
    [ -n "${_FLY_ORG}" ]     || die "Could not read FLY_ORG from secrets.env"
    [ -n "${_SIGNOZ_URL}" ]  || die "Could not read SIGNOZ_GLOBAL_EXTERNAL__URL from secrets.env"

    # FLY_API_TOKEN is not stored in secrets.env; skip token-file refresh.
    local fly_api_token=""

  else
    # ── Generate fresh secrets ──────────────────────────────────────────────
    info "Generating new secrets…"

    local jwt_secret ingestion_key
    jwt_secret=$(gen_secret 32)    # 32 bytes → 64 hex chars
    ingestion_key=$(gen_secret 20) # 20 bytes → 40 hex chars

    # User-provided values — env vars or interactive prompts
    local fly_org="${FLY_ORG:-}"
    local fly_api_token="${FLY_API_TOKEN:-}"
    local signoz_external_url="${SIGNOZ_EXTERNAL_URL:-}"

    if [ "${STDIN_IS_TTY}" -eq 1 ]; then
      # ── Interactive mode ──────────────────────────────────────────────────
      echo ""
      while [ -z "${fly_org}" ]; do
        printf "  Fly.io org slug (e.g., personal): "
        read -r fly_org || fly_org=""
        [ -n "${fly_org}" ] || warn "Fly.io org slug is required."
      done

      while [ -z "${signoz_external_url}" ]; do
        printf "  Sprite public URL (e.g., https://NAME.sprites.app): "
        read -r signoz_external_url || signoz_external_url=""
        [ -n "${signoz_external_url}" ] || warn "Sprite public URL is required."
      done

      printf "  Fly.io read-only API token (Enter to skip): "
      read -r fly_api_token || fly_api_token=""

    else
      # ── Pipe / non-interactive mode ───────────────────────────────────────
      [ -n "${fly_org}" ] || \
        die "Pipe mode: \$FLY_ORG is not set." \
            "Prefix the curl command: FLY_ORG=myorg SIGNOZ_EXTERNAL_URL=https://... curl ... | bash"
      [ -n "${signoz_external_url}" ] || \
        die "Pipe mode: \$SIGNOZ_EXTERNAL_URL is not set." \
            "Prefix the curl command: FLY_ORG=myorg SIGNOZ_EXTERNAL_URL=https://... curl ... | bash"
    fi

    # Strip accidental trailing slash from the URL
    signoz_external_url="${signoz_external_url%/}"

    # ── Optional SMTP / alertmanager config ──────────────────────────────────
    local smtp_smarthost="" smtp_from="" smtp_user="" smtp_pass=""
    local emailing_enabled="false"
    local emailing_address="" emailing_tls="true"
    local emailing_user="" emailing_pass="" emailing_from=""

    if [ "${STDIN_IS_TTY}" -eq 1 ]; then
      echo ""
      printf "  ── SMTP / Alertmanager (optional — press Enter to skip all) ──\n"
      printf "  SMTP smarthost (e.g., smtp.resend.com:465): "
      read -r smtp_smarthost || smtp_smarthost=""

      if [ -n "${smtp_smarthost}" ]; then
        printf "  SMTP from address: "
        read -r smtp_from || smtp_from=""
        printf "  SMTP username: "
        read -r smtp_user || smtp_user=""
        printf "  SMTP password: "
        read -rs smtp_pass || smtp_pass=""
        echo ""   # newline after silent read

        emailing_enabled="true"
        emailing_address="${smtp_smarthost}"
        emailing_user="${smtp_user}"
        emailing_pass="${smtp_pass}"
        emailing_from="${smtp_from}"
      fi
    fi

    # ── Write secrets.env (Docker env_file format — raw, unquoted values) ────
    #    Raw values are intentional: Docker reads env_file without shell
    #    interpretation.  Auto-generated values (hex) never contain special
    #    chars; user-supplied values (slug, URL, token) almost never do either.
    info "Writing secrets.env…"
    {
      printf '# Auto-generated by install.sh on %s — DO NOT COMMIT\n' \
        "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
      printf 'SIGNOZ_JWT_SECRET=%s\n'           "${jwt_secret}"
      printf 'SIGNOZ_TOKENIZER_JWT_SECRET=%s\n' "${jwt_secret}"
      printf 'INGESTION_KEY=%s\n'               "${ingestion_key}"
      printf 'FLY_ORG=%s\n'                     "${fly_org}"
      printf 'SIGNOZ_GLOBAL_EXTERNAL__URL=%s\n' "${signoz_external_url}"
      printf '# Alertmanager SMTP\n'
      printf 'SIGNOZ_ALERTMANAGER_SIGNOZ_GLOBAL_SMTP__SMARTHOST=%s\n'      "${smtp_smarthost}"
      printf 'SIGNOZ_ALERTMANAGER_SIGNOZ_GLOBAL_SMTP__FROM=%s\n'           "${smtp_from}"
      printf 'SIGNOZ_ALERTMANAGER_SIGNOZ_GLOBAL_SMTP__AUTH__USERNAME=%s\n' "${smtp_user}"
      printf 'SIGNOZ_ALERTMANAGER_SIGNOZ_GLOBAL_SMTP__AUTH__PASSWORD=%s\n' "${smtp_pass}"
      printf '# Emailing service\n'
      printf 'SIGNOZ_EMAILING_ENABLED=%s\n'              "${emailing_enabled}"
      printf 'SIGNOZ_EMAILING_SMTP_ADDRESS=%s\n'         "${emailing_address}"
      printf 'SIGNOZ_EMAILING_SMTP_TLS_ENABLED=%s\n'     "${emailing_tls}"
      printf 'SIGNOZ_EMAILING_SMTP_AUTH_USERNAME=%s\n'   "${emailing_user}"
      printf 'SIGNOZ_EMAILING_SMTP_AUTH_PASSWORD=%s\n'   "${emailing_pass}"
      printf 'SIGNOZ_EMAILING_SMTP_FROM=%s\n'            "${emailing_from}"
    } > "${secrets_env}"
    chmod 600 "${secrets_env}"
    success "secrets.env written (chmod 600)."

    # Publish to script-level globals
    INGESTION_KEY="${ingestion_key}"
    _FLY_ORG="${fly_org}"
    _SIGNOZ_URL="${signoz_external_url}"
  fi

  # ── 6. Prepare the otel/ directory ─────────────────────────────────────────
  info "Preparing otel/ directory…"
  mkdir -p otel/secret
  chmod 777 otel/
  touch otel/signozcol-config.yaml
  chmod 666 otel/signozcol-config.yaml
  success "otel/ directory ready."

  # ── 7. Write Fly API token to file ─────────────────────────────────────────
  if [ -n "${fly_api_token:-}" ]; then
    printf '%s' "${fly_api_token}" > otel/secret/fly_api_token
    chmod 600 otel/secret/fly_api_token
    success "Fly API token written to otel/secret/fly_api_token"
  elif [ -f "otel/secret/fly_api_token" ]; then
    success "otel/secret/fly_api_token already exists — keeping."
  else
    info "FLY_API_TOKEN not set — skipping token file (Fly metrics will be unavailable)."
  fi

  # ── 8. Generate otel-collector-config.yaml from template ───────────────────
  if [ -f "otel-collector-config.yaml.template" ]; then
    info "Generating otel-collector-config.yaml…"
    sed "s/__FLY_ORG__/${_FLY_ORG}/g" \
      otel-collector-config.yaml.template > otel-collector-config.yaml
    success "otel-collector-config.yaml generated."
  else
    warn "otel-collector-config.yaml.template not found — skipping."
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Step 10 — Start Docker Compose
# ══════════════════════════════════════════════════════════════════════════════
start_compose() {
  section "Starting services"
  cd "${SETUP_DIR}"
  info "Running docker compose up -d…"
  docker compose up -d
  success "Docker Compose services started."
}

# ══════════════════════════════════════════════════════════════════════════════
# Step 11 — Print access information
# ══════════════════════════════════════════════════════════════════════════════
print_access_info() {
  local url="${_SIGNOZ_URL:-<your-sprite-url>}"
  local key="${INGESTION_KEY:-<generated-key>}"

  printf "\n"
  printf "${BOLD}═══════════════════════════════════════════════════════════${NC}\n"
  printf "${BOLD}  🚀  SigNoz is starting up!${NC}\n"
  printf "\n"
  printf "  %-18s %s\n"  "UI:"            "${url}"
  printf "  %-18s %s\n"  "Ingestion key:" "${key}"
  printf "\n"
  printf "  Add this header to send OTLP telemetry:\n"
  printf "    ${DIM}signoz-ingestion-key: %s${NC}\n" "${key}"
  printf "\n"
  printf "  ${YELLOW}⏳${NC}  Allow ~2 minutes for all services to initialize.\n"
  printf "${BOLD}═══════════════════════════════════════════════════════════${NC}\n"
  printf "\n"
}

# ══════════════════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════════════════
main() {
  printf "\n${BOLD}  ✦  SigNoz × Sprite Installer${NC}\n\n"

  check_sprite
  install_docker
  ensure_tools
  start_dockerd
  clone_or_update_repo
  configure
  start_compose
  print_access_info
}

main
