# lib-clean-env.sh — the `env -i` allowlist both delegate launchers use.
# shellcheck shell=bash
# Sourced, not run: callers set `set -euo pipefail` and DIR (this directory).
# Bash 3.2: no associative arrays, no mapfile, no ${var,,}.

# --- clean environment: delegated CLIs run under `env -i` + an allowlist ---
# AGY_CLI_DISABLE_AUTO_UPDATE is a non-secret updater switch (other CLIs ignore it).
# The proxy and CA names are network config needed behind a proxy or a
# TLS-inspecting CA; passed only when set. --print shows names only: values can
# embed proxy credentials. They live here, not in a registry authEnv, because
# a user override replaces that array (jq `*`) and would drop them.
ENV_BASE_NAMES="HOME PATH USER LOGNAME SHELL TERM LANG LC_ALL LC_CTYPE TMPDIR XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME NIX_PATH NIX_PROFILES NIX_SSL_CERT_FILE SSL_CERT_FILE __CF_USER_TEXT_ENCODING AGY_CLI_DISABLE_AUTO_UPDATE HTTPS_PROXY HTTP_PROXY NO_PROXY ALL_PROXY https_proxy http_proxy no_proxy all_proxy NODE_EXTRA_CA_CERTS REQUESTS_CA_BUNDLE CURL_CA_BUNDLE GIT_SSL_CAINFO"

env_name_ok() {
  [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

# Names the registry lists as authEnv for <tool>; tiers.sh owns the
# shipped-plus-override merge. An unknown tool or bad registry returns non-zero.
# "$BASH", not `bash`: the launcher may run under a PATH without bash.
registry_auth_env() {
  "$BASH" "$DIR/tiers.sh" authenv "$1"
}

# Names from DELEGATE_ENV_ALLOW (comma-separated); a bad name is a usage error.
extra_allow_env() {
  local list=${DELEGATE_ENV_ALLOW:-}
  [[ -n "$list" ]] || return 0
  [[ "$list" =~ ^[A-Za-z_][A-Za-z0-9_]*(,[A-Za-z_][A-Za-z0-9_]*)*$ ]] || return 1
  printf '%s\n' "${list//,/$'\n'}"
}

# add_env_name <name>: validates one whole name, then records it once.
# Uses seen, env_names and cleanenv from build_clean_env.
add_env_name() {
  local name=$1
  env_name_ok "$name" || return 1
  case "$seen" in *" $name "*) return 0 ;; esac
  seen+="$name "
  if [[ -n "${!name+x}" ]]; then
    env_names+=("$name")
    cleanenv+=("$name=${!name}")
  fi
}

# add_env_lines <text>: one name per line,
# read without word-splitting or globbing; a bad line returns 1.
add_env_lines() {
  local lines=$1 name
  [[ -n "$lines" ]] || return 0
  while IFS= read -r name; do
    add_env_name "$name" || return 1
  done <<<"$lines"
}

# build_clean_env <tool>: sets env_names (allowed names that are set) and
# cleanenv (`env -i NAME=value ...`). Returns 1 on an empty tool, a bad
# DELEGATE_ENV_ALLOW or authEnv name, or a registry error.
build_clean_env() {
  local tool=$1 extra auth seen=" "
  [[ -n "$tool" ]] || return 1
  env_names=()
  cleanenv=(env -i)
  extra=$(extra_allow_env) || return 1
  auth=$(registry_auth_env "$tool") || return 1
  add_env_lines "${ENV_BASE_NAMES// /$'\n'}" || return 1
  add_env_lines "$auth" || return 1
  add_env_lines "$extra" || return 1
}

# Names only, never values, so run logs cannot leak a token.
print_clean_env() {
  local name
  printf '%s\n' env -i
  for name in ${env_names[@]+"${env_names[@]}"}; do
    printf '%s=<set>\n' "$name"
  done
}
