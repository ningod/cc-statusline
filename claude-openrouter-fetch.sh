#!/usr/bin/env bash
# Fetches the OpenRouter API KEY's own spend/budget from openrouter.ai and
# writes it into the per-key OpenRouter cache the statusline reads. Called by
# the statusline in the background when the cache holds no fresh snapshot
# (see the OR block in statusline.sh).
#
# Why this exists: in an OpenRouter session (claude pointed at openrouter.ai
# via ANTHROPIC_BASE_URL + an sk-or-* ANTHROPIC_AUTH_TOKEN) the claude.ai
# 5h/7d usage the statusline would otherwise show belongs to whichever claude.ai
# account is logged in locally — a different account billed differently. The
# OpenRouter key's own budget (/api/v1/key: spend_usd, limit_usd, resets_at,
# usage_daily) is the account these sessions actually bill, and OpenRouter
# credits are USD 1:1 (verified against the budgets[] block), so the numbers
# below are real dollars.
#
# Per-SESSION OpenRouter cost is NOT fetchable here: the Anthropic-compat
# endpoint returns Anthropic-style msg_* ids (no gen-* to look up via
# /api/v1/generation), and /api/v1/activity answers 403 for a regular API
# key, so key-level aggregates are the only authoritative spend data.
#
# Credential: read from STDIN (never argv or env, so it cannot leak through
# ps/procargs). The statusline pipes the session's own key
# (ANTHROPIC_AUTH_TOKEN > ANTHROPIC_API_KEY > OPENROUTER_API_KEY, all sk-or-*).
# It is only ever sent to openrouter.ai over HTTPS via a curl config on
# stdin, and is never logged or written to disk.
#
# Cache line format (all integers; money in cents, reset as epoch seconds):
#   SPEND_CENT|LIMIT_CENT|RESET_EPOCH|DAILY_CENT|FETCHED_EPOCH
# LIMIT_CENT 0 means no key cap set. On any failure (no credential, network,
# HTTP error, parse) the cache is left untouched; an HTTP error (not a
# transport failure) drops a .backoff marker so the statusline stops
# hammering a refusing endpoint.
#
# Env seams (mirror claude-usage-fetch.sh):
#   CC_STATUSLINE_OR_CACHE    destination cache file (passed by the spawner)
#   CC_STATUSLINE_OR_DATA     JSON fixture instead of the network (tests)
#   CC_STATUSLINE_NOW         pinned clock for the FETCHED_EPOCH stamp (tests)

set -uo pipefail

_state_dir() {
    local base="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"
    local uid d
    uid=$(id -u 2>/dev/null || echo 0)
    d="${base%/}/cc-statusline-${uid}"
    mkdir -p "$d" 2>/dev/null && chmod 700 "$d" 2>/dev/null
    printf '%s' "$d"
}
_cc_version() {
    local d
    d="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    { cat "$d/VERSION" "$d/../VERSION"; } 2>/dev/null | head -1
}
VERSION="$(_cc_version)"; VERSION="${VERSION:-dev}"

CACHE_FILE="${CC_STATUSLINE_OR_CACHE:-$(_state_dir)/openrouter}"
BACKOFF_FILE="${CACHE_FILE}.backoff"
TMP_FILE=""; BODY_FILE=""
trap 'rm -f "$TMP_FILE" "$BODY_FILE"' EXIT

# Refuse a state directory that is not ours: when the per-user directory is
# pre-created by someone else (the /tmp fallback on a shared host) the chmod in
# _state_dir fails silently and its contents are attacker-controlled. Scratch
# files are mktemp-created (0600, unpredictable names, O_EXCL) so a planted
# symlink at a guessable path is never followed by curl -o or the cache write.
CACHE_DIR="$(dirname "$CACHE_FILE")"
[ -d "$CACHE_DIR" ] && [ ! -L "$CACHE_DIR" ] && [ -O "$CACHE_DIR" ] || exit 0
TMP_FILE=$(mktemp "${CACHE_FILE}.fetch.XXXXXX" 2>/dev/null) || exit 0
BODY_FILE=$(mktemp "${CACHE_FILE}.body.XXXXXX" 2>/dev/null) || exit 0

# Key from stdin (the spawner pipes it). Size-capped, whitespace-stripped.
KEY=$(timeout 2 head -c 4096 2>/dev/null | tr -d '[:space:]') || KEY=""
# Guard: an OpenRouter key has the sk-or- vendor prefix; anything else
# (an Anthropic OAuth token, garbage) is not sent anywhere.
case "$KEY" in sk-or-*) : ;; *) exit 0 ;; esac

if [ -n "${CC_STATUSLINE_OR_DATA:-}" ]; then
    # Test seam: fixture body, with the HTTP status the transport "returned".
    data=$(cat "$CC_STATUSLINE_OR_DATA" 2>/dev/null) || exit 0
    http="${CC_STATUSLINE_OR_HTTP:-200}"
else
    # The Authorization header travels via `--config -` on stdin, NOT argv.
    http=$(printf 'header = "Authorization: Bearer %s"\n' "$KEY" \
        | curl -s --max-time 8 --config - \
            -H "Accept: application/json" \
            -H "User-Agent: cc-statusline/${VERSION}" \
            -o "$BODY_FILE" -w '%{http_code}' \
            "https://openrouter.ai/api/v1/key" 2>/dev/null) || http=""
    data=$(cat "$BODY_FILE" 2>/dev/null)
fi
# HTTP error (not transport failure): back off and leave the cache alone.
case "${http:-}" in
    200|"") : ;;
    *) [ -L "$BACKOFF_FILE" ] || touch "$BACKOFF_FILE" 2>/dev/null || true; exit 0 ;;
esac
[ -z "$data" ] && exit 0

# Parse + validate in one jq pass, straight to the 5-field cache shape.
# effective_budget is the budget that blocks requests first; its USD fields
# are the key's own spend/limit/reset. usage_daily is the day's spend.
# Non-numeric or missing fields make jq fail and leave the cache untouched
# (fail closed, like the claude.ai fetcher).
parsed=$(echo "$data" | jq -r '
    def iso2epoch: tostring | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601;
    (.data.effective_budget) as $b
  | (($b.spend_usd    // .data.usage_monthly // 0) * 100 | round) as $sp
  | (($b.limit_usd    // .data.limit         // 0) * 100 | round) as $li
  | (($b.resets_at    // "") | iso2epoch)                 as $re
  | ((.data.usage_daily // 0) * 100 | round)             as $da
  | "\($sp)|\($li)|\($re)|\($da)"
' 2>/dev/null) || exit 0
# Belt-and-braces shape check: cents caps (limit <= $10k), epoch cap.
[[ "$parsed" =~ ^[0-9]{1,7}\|[0-9]{1,7}\|[0-9]{1,12}\|[0-9]{1,7}$ ]] || exit 0

NOW="${CC_STATUSLINE_NOW:-$(date +%s)}"
[[ "$NOW" =~ ^[0-9]{1,12}$ ]] || exit 0

if printf '%s|%s\n' "$parsed" "$NOW" > "$TMP_FILE" 2>/dev/null; then
    chmod 600 "$TMP_FILE" 2>/dev/null || true
    if mv -f "$TMP_FILE" "$CACHE_FILE" 2>/dev/null; then
        rm -f "$BACKOFF_FILE" 2>/dev/null || true  # recovered
    else
        rm -f "$TMP_FILE" 2>/dev/null || true
    fi
fi
rm -f "$BODY_FILE" 2>/dev/null || true
trap - EXIT