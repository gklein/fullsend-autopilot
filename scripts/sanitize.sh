#!/usr/bin/env bash
set -euo pipefail

# Sanitize text for GitHub — strips local PII, paths, and secrets from stdin.
#
# Usage: sanitize.sh < input.txt
#    or: echo "text" | sanitize.sh
#
# Masks: home-dir paths, hostnames, IPv4 addresses, known token patterns
#        (GitHub, AWS, GCP, Slack, OpenAI, JWTs), env-var secret assignments,
#        database connection strings, and HTTP auth headers.
#
# Exit codes:  0 — always (sanitized text on stdout)

# Escape a string for use as a literal match in an extended-regex sed pattern.
escape_regex() {
  # shellcheck disable=SC2016
  printf '%s' "$1" | sed 's/[.[\*^$()+?{|\\]/\\&/g'
}

LOCAL_USER="${USER:-$(whoami 2>/dev/null || echo '')}"
LOCAL_HOME="${HOME:-}"
LOCAL_HOSTNAME="${HOSTNAME:-$(hostname -s 2>/dev/null || echo '')}"
LOCAL_FQDN="$(hostname -f 2>/dev/null || echo '')"

SED_ARGS=()

# Home directory → ~
if [[ -n "$LOCAL_HOME" ]]; then
  SED_ARGS+=(-e "s|$(escape_regex "$LOCAL_HOME")|~|g")
fi

# User-specific path variants that may differ from $HOME
if [[ -n "$LOCAL_USER" ]]; then
  ESCAPED_USER="$(escape_regex "$LOCAL_USER")"
  SED_ARGS+=(-e "s|/Users/${ESCAPED_USER}|~|g")
  SED_ARGS+=(-e "s|/home/${ESCAPED_USER}|~|g")
fi

# macOS temp/cache paths
SED_ARGS+=(
  -e 's|/private/var/folders/[^ "]*|<tmp-path>|g'
  -e 's|/var/folders/[^ "]*|<tmp-path>|g'
)

# FQDN first (contains the short hostname, so must run before it)
if [[ -n "$LOCAL_FQDN" && ${#LOCAL_FQDN} -ge 4 && "$LOCAL_FQDN" != "$LOCAL_HOSTNAME" ]]; then
  SED_ARGS+=(-e "s/$(escape_regex "$LOCAL_FQDN")/<host>/g")
fi

# Short hostname (skip if <4 chars to avoid false positives)
if [[ -n "$LOCAL_HOSTNAME" && ${#LOCAL_HOSTNAME} -ge 4 ]]; then
  SED_ARGS+=(-e "s/$(escape_regex "$LOCAL_HOSTNAME")/<host>/g")
fi

# Static token/secret patterns.
# IPv4 regex also matches version-like strings (e.g. 1.2.3.4) — acceptable
# trade-off since over-masking is safer than under-masking.
SED_ARGS+=(
  -e 's/([0-9]{1,3}\.){3}[0-9]{1,3}/<ip-addr>/g'
  -e 's/(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{20,}/<github-token-redacted>/g'
  -e 's/AKIA[A-Z0-9]{16}/<aws-key-redacted>/g'
  -e 's/AIza[A-Za-z0-9_-]{35}/<gcp-key-redacted>/g'
  -e 's/xox[bpras]-[A-Za-z0-9-]+/<slack-token-redacted>/g'
  -e 's/sk-[A-Za-z0-9]{20,}/<api-key-redacted>/g'
  -e 's/eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/<jwt-redacted>/g'
  -e 's/(postgres|mysql|redis|mongodb|amqp)s?:\/\/[^@ ]*@/<db-credentials-redacted>@/g'
  -e 's/Bearer [A-Za-z0-9._-]+/Bearer <token-redacted>/g'
  -e 's/Basic [A-Za-z0-9+/=]+/Basic <auth-redacted>/g'
  -e 's/([A-Z_]*(SECRET|TOKEN|PASSWORD|PASSWD|PRIVATE_KEY|CREDENTIAL|API_KEY|ACCESS_KEY)[A-Z_]*)=[^ ]*/\1=<redacted>/g'
  -e 's/([a-z_]*(secret|token|password|passwd|private_key|credential|api_key|access_key)[a-z_]*)=[^ ]*/\1=<redacted>/g'
)

sed -E "${SED_ARGS[@]}"
