#!/usr/bin/env bash
# install.sh — Set up SigNoz on a Sprite sandbox (sprites.dev)
#
# One-liner install:
#   curl https://raw.githubusercontent.com/lubien/fly-011y/main/install.sh | bash
#
# When running non-interactively (pipe / CI):
#   curl https://raw.githubusercontent.com/lubien/fly-011y/main/install.sh | bash
#
# On older sprites that don't expose sprite_url, supply it explicitly:
#   SIGNOZ_EXTERNAL_URL=https://NAME.sprites.app curl ... | bash
#
#
# Post-install org management:
#   install.sh add-org          — add a Fly.io org (Prometheus metrics)
#   install.sh remove-org       — remove a Fly.io org
#   install.sh list-orgs        — list configured orgs
#   install.sh regen-config     — regenerate otel config from current orgs
#   install.sh add-log-shipper           — deploy a Fly.io log shipper for an org
#   install.sh provision-elixir-pipeline  — push Elixir/Phoenix log parsing pipeline to SigNoz
#   install.sh provision-dashboards        — upsert all dashboards/*.json into SigNoz

set -euo pipefail

# ─── Configuration ─────────────────────────────────────────────────────────────
REPO_URL="https://github.com/lubien/fly-011y.git"
INSTALL_DIR="/home/sprite/fly-o11y"
SETUP_DIR="${INSTALL_DIR}/setup"
LOG_SHIPPER_DIR="${INSTALL_DIR}/log-shipper"

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
  if ! command -v git &>/dev/null; then
    info "Installing missing utilities (git)…"
    sudo apt-get update -qq
    sudo apt-get install -y git
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
    _SIGNOZ_URL=$(env_get "${secrets_env}" "SIGNOZ_GLOBAL_EXTERNAL__URL")

    [ -n "${INGESTION_KEY}" ] || die "Could not read INGESTION_KEY from secrets.env"
    [ -n "${_SIGNOZ_URL}" ]  || die "Could not read SIGNOZ_GLOBAL_EXTERNAL__URL from secrets.env"

  else
    # ── Generate fresh secrets ──────────────────────────────────────────────
    info "Generating new secrets…"

    local jwt_secret ingestion_key
    jwt_secret=$(gen_secret 32)    # 32 bytes → 64 hex chars
    ingestion_key=$(gen_secret 20) # 20 bytes → 40 hex chars

    # User-provided values — env vars or interactive prompts
    local signoz_external_url="${SIGNOZ_EXTERNAL_URL:-}"

    # ── Auto-detect Sprite URL (newer sprites expose it in sprite-env info) ────
    if [ -z "${signoz_external_url}" ] && command -v sprite-env &>/dev/null; then
      local _detected_url
      _detected_url=$(
        sprite-env info 2>/dev/null \
          | grep -o '"sprite_url":"[^"]*"' \
          | cut -d'"' -f4 \
        || true
      )
      if [ -n "${_detected_url}" ]; then
        signoz_external_url="${_detected_url}"
        info "Detected Sprite URL: ${signoz_external_url}"
      fi
    fi

    # ── Prompt if still empty ───────────────────────────────────────────────────
    # Read from /dev/tty so this works even when stdin is the curl pipe.
    if [ -z "${signoz_external_url}" ]; then
      if [ -e /dev/tty ]; then
        while [ -z "${signoz_external_url}" ]; do
          printf "  Sprite public URL (e.g., https://NAME.sprites.app): " >/dev/tty
          read -r signoz_external_url </dev/tty || signoz_external_url=""
          [ -n "${signoz_external_url}" ] || \
            printf "  Sprite public URL is required.\n" >/dev/tty
        done
      else
        die "Could not detect Sprite URL." \
            "Set SIGNOZ_EXTERNAL_URL=https://... and re-run."
      fi
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
    _SIGNOZ_URL="${signoz_external_url}"
  fi

  # ── 6. Prepare the otel/ directory ─────────────────────────────────────────
  info "Preparing otel/ directory…"
  mkdir -p otel/orgs
  chmod 777 otel/
  touch otel/signozcol-config.yaml
  chmod 666 otel/signozcol-config.yaml
  success "otel/ directory ready."

  # ── 7. Generate otel-collector-config.yaml from template + current orgs ─────
  regen_otel_config
}

# ══════════════════════════════════════════════════════════════════════════════
# Fly.io org helpers — otel config generation & CLI subcommands
# ══════════════════════════════════════════════════════════════════════════════

# Count *.token files in otel/orgs/
count_orgs() {
  local count=0
  if [ -d "otel/orgs" ]; then
    for _f in otel/orgs/*.token; do
      [ -f "${_f}" ] && count=$((count + 1))
    done
  fi
  printf '%d' "${count}"
}

# Emit prometheus scrape_config YAML for every org token file
gen_fly_scrape_configs() {
  local orgs_dir="${1:-otel/orgs}"
  [ -d "${orgs_dir}" ] || return 0
  for _tf in "${orgs_dir}"/*.token; do
    [ -f "${_tf}" ] || return 0   # no matches — glob literal returned
    local _slug
    _slug=$(basename "${_tf}" .token)
    printf '        - job_name: fly-federate-%s\n'             "${_slug}"
    printf '          scheme: https\n'
    printf '          metrics_path: /prometheus/%s/federate\n' "${_slug}"
    printf "          params:\n"
    printf "            match[]: ['{__name__=~\"fly_.*\"}']\n"
    printf '          static_configs:\n'
    printf '            - targets: ["api.fly.io"]\n'
    printf '          authorization:\n'
    printf '            type: FlyV1\n'
    printf '            credentials_file: /etc/otel/orgs/%s.token\n' "${_slug}"
  done
}

# Regenerate otel-collector-config.yaml from template + current org token files
regen_otel_config() {
  local template="otel-collector-config.yaml.template"
  local output="otel-collector-config.yaml"

  [ -f "${template}" ] || { warn "Template not found — skipping otel config."; return 0; }

  local _tmp
  _tmp=$(mktemp)
  gen_fly_scrape_configs "otel/orgs" > "${_tmp}"

  awk -v configs_file="${_tmp}" '
    /# __FLY_ORG_SCRAPE_CONFIGS__/ {
      while ((getline line < configs_file) > 0) print line
      close(configs_file)
      next
    }
    { print }
  ' "${template}" > "${output}"

  rm -f "${_tmp}"
  success "otel-collector-config.yaml updated ($(count_orgs) Fly.io org(s))."
}

# ── Subcommand: add-org ──────────────────────────────────────────────────────────────────
cmd_add_org() {
  [ -d "${SETUP_DIR}" ] || die "Setup directory not found: ${SETUP_DIR}"
  cd "${SETUP_DIR}"

  install_flyctl
  ensure_fly_login

  local slug="${1:-}"

  if [ -z "${slug}" ]; then
    info "Fetching your Fly.io orgs…"
    local org_slugs=() org_names=()
    while IFS='|' read -r _slug _name; do
      [ -n "${_slug}" ] || continue
      [ ! -f "otel/orgs/${_slug}.token" ] || continue  # skip already configured
      org_slugs+=("${_slug}")
      org_names+=("${_name}")
    done < <(list_fly_org_pairs)

    if [ "${#org_slugs[@]}" -eq 0 ]; then
      info "All orgs are already configured."
      return 0
    fi

    echo ""
    local _i
    for _i in $(seq 0 $((${#org_slugs[@]} - 1))); do
      printf "  [%d] %s  (%s)\n" "$((_i+1))" "${org_names[_i]}" "${org_slugs[_i]}"
    done
    echo ""
    printf "  Select org: "
    local _sel; read -r _sel || _sel=""
    local _n=$((_sel - 1))
    if [ "${_n}" -ge 0 ] && [ "${_n}" -lt "${#org_slugs[@]}" ]; then
      slug="${org_slugs[_n]}"
    else
      die "Invalid selection '${_sel}'."
    fi
  fi

  info "Generating read-only Prometheus token for '${slug}'…"
  local token
  token=$(fly_cmd tokens create readonly --name "fly-o11y-prometheus" --org "${slug}") || \
    die "Failed to generate token for '${slug}'."
  token="${token#FlyV1 }"  # strip scheme prefix — Prometheus authorization.type adds it back

  mkdir -p otel/orgs
  printf '%s' "${token}" > "otel/orgs/${slug}.token"
  chmod 644 "otel/orgs/${slug}.token"
  success "Org '${slug}' added."

  regen_otel_config

  if docker ps --filter "name=signoz-otel-collector" --filter "status=running" -q 2>/dev/null | grep -q .; then
    info "Restarting otel-collector to apply changes…"
    docker compose restart otel-collector
    success "otel-collector restarted."
  else
    info "otel-collector is not running — changes will apply on next start."
  fi
}

# ── Subcommand: remove-org ──────────────────────────────────────────────────────────────
cmd_remove_org() {
  [ -d "${SETUP_DIR}" ] || die "Setup directory not found: ${SETUP_DIR}"
  cd "${SETUP_DIR}"

  local slug="${1:-}"

  if [ -z "${slug}" ]; then
    cmd_list_orgs
    printf "\n  Org slug to remove: "
    read -r slug || slug=""
  fi
  [ -n "${slug}" ] || die "Org slug is required."

  local token_file="otel/orgs/${slug}.token"
  [ -f "${token_file}" ] || die "No org '${slug}' found in otel/orgs/."

  rm -f "${token_file}"
  success "Org '${slug}' removed."

  regen_otel_config

  if docker ps --filter "name=signoz-otel-collector" --filter "status=running" -q 2>/dev/null | grep -q .; then
    info "Restarting otel-collector to apply changes…"
    docker compose restart otel-collector
    success "otel-collector restarted."
  else
    info "otel-collector is not running — changes will apply on next start."
  fi
}

# ── Subcommand: list-orgs ─────────────────────────────────────────────────────────────────
cmd_list_orgs() {
  [ -d "${SETUP_DIR}" ] || die "Setup directory not found: ${SETUP_DIR}"
  cd "${SETUP_DIR}"

  section "Configured Fly.io orgs"
  if [ ! -d "otel/orgs" ]; then
    info "No orgs directory — run: install.sh add-org"
    return 0
  fi
  local found=0
  for _tf in otel/orgs/*.token; do
    [ -f "${_tf}" ] || continue
    found=1
    printf "  • %s\n" "$(basename "${_tf}" .token)"
  done
  [ "${found}" -eq 1 ] || info "No orgs configured — run: install.sh add-org"
}

# ══════════════════════════════════════════════════════════════════════════════
# Fly.io log shipping — flyctl, auth, deploy, subcommands
# ══════════════════════════════════════════════════════════════════════════════

# Run fly or flyctl — whichever is in PATH (also checks ~/.fly/bin after install)
fly_cmd() {
  if command -v fly &>/dev/null; then
    fly "$@"
  elif command -v flyctl &>/dev/null; then
    flyctl "$@"
  else
    die "flyctl not found. Run: install.sh add-log-shipper  (it will install it)"
  fi
}

# Install flyctl if neither fly nor flyctl is available
install_flyctl() {
  if command -v fly &>/dev/null || command -v flyctl &>/dev/null; then
    return 0
  fi

  info "Installing flyctl…"
  curl -fsSL https://fly.io/install.sh | sh

  # The installer drops binaries in ~/.fly/bin; add to PATH for this session
  export PATH="${HOME}/.fly/bin:${PATH}"

  command -v fly &>/dev/null || command -v flyctl &>/dev/null || \
    die "flyctl install failed. Install manually: https://fly.io/docs/hands-on/install-flyctl/"

  success "flyctl installed: $(fly_cmd version --json 2>/dev/null | grep -o '\"Version\":\"[^\"]*\"' | cut -d'"' -f4 || fly_cmd version 2>&1 | head -1)"
}

# Ensure the user is authenticated with flyctl; open browser login if not
ensure_fly_login() {
  section "Fly.io authentication"

  local email
  if email=$(fly_cmd auth whoami 2>/dev/null) && [ -n "${email}" ]; then
    success "Logged in as: ${email}"
    return 0
  fi

  info "Not logged in — opening Fly.io auth…"
  fly_cmd auth login

  # Verify the login succeeded
  email=$(fly_cmd auth whoami 2>/dev/null) || \
    die "Fly.io authentication failed. Run 'fly auth login' and try again."
  success "Logged in as: ${email}"
}

# Print \"slug|Name\" pairs for every Fly.io org the authed user belongs to
list_fly_org_pairs() {
  fly_cmd orgs list --json 2>/dev/null \
    | grep -o '"[^"]*": "[^"]*"' \
    | sed 's/"\([^"]*\)": "\([^"]*\)"/\1|\2/'
}

# Deploy (or redeploy) a log-shipper Fly app for a single org
deploy_log_shipper() {
  local org_slug="${1}"
  local ingestion_url="${2}"
  local ingestion_key="${3}"

  [ -d "${LOG_SHIPPER_DIR}" ] || \
    die "Log shipper directory not found: ${LOG_SHIPPER_DIR}"
  cd "${LOG_SHIPPER_DIR}"

  local toml_file="fly.${org_slug}.toml"

  if [ -f "${toml_file}" ]; then
    warn "${toml_file} already exists — a shipper for '${org_slug}' may already be deployed."
    printf "  Redeploy? (y/N): "
    local _ans; read -r _ans || _ans=""
    [ "${_ans}" = "y" ] || [ "${_ans}" = "Y" ] || return 0
  fi

  cp "fly.template.toml" "${toml_file}"
  success "Created ${toml_file}."

  info "Generating read-only access token for org '${org_slug}'…"
  local access_token
  access_token=$(fly_cmd tokens create readonly --name "fly-o11y" --org "${org_slug}") || \
    die "Failed to create access token for org '${org_slug}'."

  info "Creating Fly app for '${org_slug}'…"
  fly_cmd launch \
    -c "${toml_file}" \
    --copy-config \
    --internal-port 8686 \
    --secret "ORG=${org_slug}" \
    --secret "ACCESS_TOKEN=${access_token}" \
    --secret "SIGNOZ_INGESTION_URL=${ingestion_url}" \
    --secret "SIGNOZ_INGESTION_KEY=${ingestion_key}" \
    --org "${org_slug}" \
    --no-public-ips \
    --no-deploy \
    --yes

  # Ensure at least 2 machines run for HA (NATS queue group deduplication)
  sed -i 's/min_machines_running = 0/min_machines_running = 2/' "${toml_file}"

  info "Deploying log shipper for '${org_slug}' (this may take a few minutes)…"
  fly_cmd deploy \
    -c "${toml_file}" \
    --no-public-ips \
    --yes

  success "Log shipper deployed for org '${org_slug}'."
}

# Orchestrate log shipper setup at the end of the main install flow
setup_log_shippers() {
  # Only makes sense interactively
  [ "${STDIN_IS_TTY}" -eq 1 ] || return 0

  local secrets_env="${SETUP_DIR}/secrets.env"
  local ingestion_key ingestion_url
  ingestion_key=$(env_get "${secrets_env}" "INGESTION_KEY")
  ingestion_url="$(env_get "${secrets_env}" "SIGNOZ_GLOBAL_EXTERNAL__URL")/logs/vector"

  section "Log shipping (optional)"
  printf "  Ship logs from Fly.io orgs to SigNoz? (y/N): "
  local _ans; read -r _ans || _ans=""
  [ "${_ans}" = "y" ] || [ "${_ans}" = "Y" ] || return 0

  install_flyctl
  ensure_fly_login

  # Build org list
  info "Fetching your Fly.io orgs…"
  local org_slugs=() org_names=()
  while IFS='|' read -r _slug _name; do
    [ -n "${_slug}" ] || continue
    org_slugs+=("${_slug}")
    org_names+=("${_name}")
  done < <(list_fly_org_pairs)
  [ "${#org_slugs[@]}" -gt 0 ] || die "No Fly.io orgs found."

  echo ""
  local _i
  for _i in $(seq 0 $((${#org_slugs[@]} - 1))); do
    printf "  [%d] %s  (%s)\n" "$((_i+1))" "${org_names[_i]}" "${org_slugs[_i]}"
  done
  echo ""
  printf "  Select orgs (comma-separated numbers, Enter to skip): "
  local selection; read -r selection || selection=""
  [ -n "${selection}" ] || return 0

  IFS=',' read -ra _indices <<< "${selection}"
  for _idx in "${_indices[@]}"; do
    _idx=$(printf '%s' "${_idx}" | tr -d ' ')
    local _n=$((_idx - 1))
    if [ "${_n}" -ge 0 ] && [ "${_n}" -lt "${#org_slugs[@]}" ]; then
      deploy_log_shipper "${org_slugs[_n]}" "${ingestion_url}" "${ingestion_key}"
    else
      warn "Invalid selection '${_idx}' — skipping."
    fi
  done
}

# ── Subcommand: add-log-shipper ───────────────────────────────────────────────────────────
cmd_add_log_shipper() {
  local secrets_env="${SETUP_DIR}/secrets.env"
  [ -f "${secrets_env}" ] || die "secrets.env not found — run install first."

  local ingestion_key ingestion_url
  ingestion_key=$(env_get "${secrets_env}" "INGESTION_KEY")
  ingestion_url="$(env_get "${secrets_env}" "SIGNOZ_GLOBAL_EXTERNAL__URL")/logs/vector"

  install_flyctl
  ensure_fly_login

  local org_slug="${1:-}"

  if [ -z "${org_slug}" ]; then
    info "Fetching your Fly.io orgs…"
    local org_slugs=() org_names=()
    while IFS='|' read -r _slug _name; do
      [ -n "${_slug}" ] || continue
      org_slugs+=("${_slug}")
      org_names+=("${_name}")
    done < <(list_fly_org_pairs)
    [ "${#org_slugs[@]}" -gt 0 ] || die "No Fly.io orgs found."

    echo ""
    local _i
    for _i in $(seq 0 $((${#org_slugs[@]} - 1))); do
      printf "  [%d] %s  (%s)\n" "$((_i+1))" "${org_names[_i]}" "${org_slugs[_i]}"
    done
    echo ""
    printf "  Select org: "
    local _sel; read -r _sel || _sel=""
    local _n=$((_sel - 1))
    if [ "${_n}" -ge 0 ] && [ "${_n}" -lt "${#org_slugs[@]}" ]; then
      org_slug="${org_slugs[_n]}"
    else
      die "Invalid selection '${_sel}'."
    fi
  fi

  deploy_log_shipper "${org_slug}" "${ingestion_url}" "${ingestion_key}"
}

# Orchestrate Prometheus metrics org setup after log shippers
setup_prometheus_orgs() {
  [ "${STDIN_IS_TTY}" -eq 1 ] || return 0

  section "Fly.io Prometheus metrics (optional)"
  printf "  Scrape Prometheus metrics from Fly.io orgs? (y/N): "
  local _ans; read -r _ans || _ans=""
  [ "${_ans}" = "y" ] || [ "${_ans}" = "Y" ] || return 0

  # flyctl is already installed + logged in if the user went through setup_log_shippers;
  # install_flyctl / ensure_fly_login are idempotent so safe to call again.
  install_flyctl
  ensure_fly_login

  cd "${SETUP_DIR}"

  info "Fetching your Fly.io orgs…"
  local org_slugs=() org_names=()
  while IFS='|' read -r _slug _name; do
    [ -n "${_slug}" ] || continue
    [ ! -f "otel/orgs/${_slug}.token" ] || continue  # skip already configured
    org_slugs+=("${_slug}")
    org_names+=("${_name}")
  done < <(list_fly_org_pairs)

  if [ "${#org_slugs[@]}" -eq 0 ]; then
    info "All orgs already have Prometheus tokens configured."
    return 0
  fi

  echo ""
  local _i
  for _i in $(seq 0 $((${#org_slugs[@]} - 1))); do
    printf "  [%d] %s  (%s)\n" "$((_i+1))" "${org_names[_i]}" "${org_slugs[_i]}"
  done
  echo ""
  printf "  Select orgs (comma-separated numbers, Enter to skip): "
  local selection; read -r selection || selection=""
  [ -n "${selection}" ] || return 0

  local _any_added=0
  IFS=',' read -ra _indices <<< "${selection}"
  for _idx in "${_indices[@]}"; do
    _idx=$(printf '%s' "${_idx}" | tr -d ' ')
    local _n=$((_idx - 1))
    if [ "${_n}" -ge 0 ] && [ "${_n}" -lt "${#org_slugs[@]}" ]; then
      local _slug="${org_slugs[_n]}"
      info "Generating read-only Prometheus token for '${_slug}'…"
      local _token
      _token=$(fly_cmd tokens create readonly --name "fly-o11y-prometheus" --org "${_slug}") || {
        warn "Failed to generate token for '${_slug}' — skipping."
        continue
      }
      _token="${_token#FlyV1 }"  # strip scheme prefix — Prometheus authorization.type adds it back
      mkdir -p otel/orgs
      printf '%s' "${_token}" > "otel/orgs/${_slug}.token"
      chmod 644 "otel/orgs/${_slug}.token"
      success "Org '${_slug}' added."
      _any_added=1
    else
      warn "Invalid selection '${_idx}' — skipping."
    fi
  done

  if [ "${_any_added}" -eq 1 ]; then
    regen_otel_config
    if docker ps --filter "name=signoz-otel-collector" --filter "status=running" -q 2>/dev/null | grep -q .; then
      info "Restarting otel-collector to apply changes…"
      docker compose restart otel-collector
      success "otel-collector restarted."
    fi
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
  local cmd="${1:-install}"

  case "${cmd}" in
    install)
      printf "\n${BOLD}  ✔  SigNoz × Sprite Installer${NC}\n\n"
      check_sprite
      install_docker
      ensure_tools
      start_dockerd
      clone_or_update_repo
      configure
      start_compose
      print_access_info
      setup_log_shippers
      setup_prometheus_orgs
      ;;
    add-org)
      shift
      section "Add Fly.io org"
      cmd_add_org "$@"
      ;;
    remove-org)
      shift
      section "Remove Fly.io org"
      cmd_remove_org "$@"
      ;;
    list-orgs)
      cmd_list_orgs
      ;;
    regen-config)
      [ -d "${SETUP_DIR}" ] || die "Setup directory not found: ${SETUP_DIR}"
      cd "${SETUP_DIR}"
      section "Regenerate otel config"
      regen_otel_config
      ;;
    add-log-shipper)
      shift
      section "Add Fly.io log shipper"
      cmd_add_log_shipper "$@"
      ;;
    provision-elixir-pipeline)
      local _script="${INSTALL_DIR}/scripts/provision_elixir_pipelines.py"
      [ -f "${_script}" ] || die "Script not found: ${_script}"
      command -v python3 &>/dev/null || die "python3 is required but not installed."
      section "Provision Elixir log pipeline"
      python3 "${_script}"
      ;;
    provision-dashboards)
      local _script="${INSTALL_DIR}/scripts/provision_dashboards.py"
      [ -f "${_script}" ] || die "Script not found: ${_script}"
      command -v python3 &>/dev/null || die "python3 is required but not installed."
      section "Provision dashboards"
      python3 "${_script}"
      ;;
    *)
      die "Unknown command '${cmd}'." \
          "Usage: install.sh [install|add-org|remove-org|list-orgs|regen-config|add-log-shipper|provision-elixir-pipeline]"
      ;;
  esac
}

main "$@"
