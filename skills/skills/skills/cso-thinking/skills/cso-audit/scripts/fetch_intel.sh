#!/usr/bin/env bash
# fetch_intel.sh — orchestrate free threat-intel APIs for a single CVE/GHSA id.
#
# Usage:   ./fetch_intel.sh <CVE-XXXX-YYYY | GHSA-xxxx-xxxx-xxxx>
# Returns: single JSON object with keys: cve, ghsa, nvd, osv, epss, kev, hn, fetched_at
# Exits:   0 if at least one source succeeded; 2 if all sources failed.
#
# Caches:
#   ~/.cache/cso-audit/kev.json           (24h TTL)
#   ~/.cache/cso-audit/cves/<id>.json     (6h TTL — full enrichment per id)
#
# No paid APIs. No auth required (gh used opportunistically if available).

set -uo pipefail

ID="${1:-}"
if [[ -z "$ID" ]]; then
  echo "usage: $0 <CVE-XXXX-YYYY | GHSA-xxxx-xxxx-xxxx>" >&2
  exit 64
fi

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/cso-audit"
KEV_PATH="$CACHE_DIR/kev.json"
CVE_CACHE_DIR="$CACHE_DIR/cves"
mkdir -p "$CVE_CACHE_DIR"

CVE_CACHE="$CVE_CACHE_DIR/${ID}.json"
NOW=$(date -u +%s)

# Per-CVE cache: 6h TTL
if [[ -f "$CVE_CACHE" ]]; then
  MTIME=$(stat -f %m "$CVE_CACHE" 2>/dev/null || stat -c %Y "$CVE_CACHE" 2>/dev/null || echo 0)
  AGE=$((NOW - MTIME))
  if (( AGE < 21600 )); then
    cat "$CVE_CACHE"
    exit 0
  fi
fi

CURL_OPTS=(--silent --show-error --max-time 12 --user-agent "cso-audit/0.2.0 (+https://github.com/verzth/skills)")
SUCCESS=0
TMPDIR_NEW=$(mktemp -d)
trap 'rm -rf "$TMPDIR_NEW"' EXIT

# Decide CVE vs GHSA shape
CVE=""
GHSA=""
if [[ "$ID" =~ ^CVE- ]]; then
  CVE="$ID"
elif [[ "$ID" =~ ^GHSA- ]]; then
  GHSA="$ID"
else
  CVE="$ID"  # best-effort fallback
fi

# ---- OSV.dev ----
if [[ -n "$GHSA" || -n "$CVE" ]]; then
  OSV_ID="${GHSA:-$CVE}"
  if curl "${CURL_OPTS[@]}" "https://api.osv.dev/v1/vulns/${OSV_ID}" -o "$TMPDIR_NEW/osv.json" 2>/dev/null \
     && [[ -s "$TMPDIR_NEW/osv.json" ]] \
     && python3 -c "import json,sys; d=json.load(open('$TMPDIR_NEW/osv.json')); sys.exit(0 if d.get('id') else 1)" 2>/dev/null; then
    SUCCESS=$((SUCCESS+1))
    # If we hit OSV with a GHSA, harvest the CVE alias for downstream lookups
    if [[ -z "$CVE" ]]; then
      CVE=$(python3 -c "import json; d=json.load(open('$TMPDIR_NEW/osv.json')); print(next((a for a in d.get('aliases',[]) if a.startswith('CVE-')), ''))" 2>/dev/null || echo "")
    fi
  else
    echo '{"error":"unreachable"}' > "$TMPDIR_NEW/osv.json"
  fi
fi

# ---- EPSS ----
if [[ -n "$CVE" ]]; then
  if curl "${CURL_OPTS[@]}" "https://api.first.org/data/v1/epss?cve=${CVE}" -o "$TMPDIR_NEW/epss.json" 2>/dev/null \
     && python3 -c "import json,sys; d=json.load(open('$TMPDIR_NEW/epss.json')); sys.exit(0 if d.get('data') else 1)" 2>/dev/null; then
    SUCCESS=$((SUCCESS+1))
  else
    echo '{"error":"unreachable"}' > "$TMPDIR_NEW/epss.json"
  fi
else
  echo '{"error":"no-cve-id-available"}' > "$TMPDIR_NEW/epss.json"
fi

# ---- CISA KEV (cached 24h) ----
KEV_MTIME=0
[[ -f "$KEV_PATH" ]] && KEV_MTIME=$(stat -f %m "$KEV_PATH" 2>/dev/null || stat -c %Y "$KEV_PATH" 2>/dev/null || echo 0)
KEV_AGE=$((NOW - KEV_MTIME))
if (( KEV_AGE > 86400 )) || [[ ! -s "$KEV_PATH" ]]; then
  if curl "${CURL_OPTS[@]}" "https://raw.githubusercontent.com/cisagov/kev-data/main/known_exploited_vulnerabilities.json" -o "$KEV_PATH.tmp" 2>/dev/null \
     && [[ -s "$KEV_PATH.tmp" ]]; then
    mv "$KEV_PATH.tmp" "$KEV_PATH"
  fi
fi
if [[ -s "$KEV_PATH" && -n "$CVE" ]]; then
  python3 -c "
import json,sys
try:
  d=json.load(open('$KEV_PATH'))
  hit=next((v for v in d.get('vulnerabilities',[]) if v.get('cveID')=='$CVE'), None)
  print(json.dumps(hit) if hit else 'null')
except Exception as e:
  print(json.dumps({'error':str(e)}))
" > "$TMPDIR_NEW/kev.json"
  if [[ "$(cat $TMPDIR_NEW/kev.json)" != "null" ]] && ! grep -q '"error"' "$TMPDIR_NEW/kev.json"; then
    SUCCESS=$((SUCCESS+1))
  fi
else
  echo '{"error":"unreachable-or-no-cve"}' > "$TMPDIR_NEW/kev.json"
fi

# ---- NVD ----
if [[ -n "$CVE" ]]; then
  if curl "${CURL_OPTS[@]}" "https://services.nvd.nist.gov/rest/json/cves/2.0?cveId=${CVE}" -o "$TMPDIR_NEW/nvd.json" 2>/dev/null \
     && python3 -c "import json,sys; d=json.load(open('$TMPDIR_NEW/nvd.json')); sys.exit(0 if d.get('vulnerabilities') else 1)" 2>/dev/null; then
    SUCCESS=$((SUCCESS+1))
  else
    echo '{"error":"unreachable"}' > "$TMPDIR_NEW/nvd.json"
  fi
else
  echo '{"error":"no-cve-id-available"}' > "$TMPDIR_NEW/nvd.json"
fi

# ---- Hacker News (Algolia) ----
QUERY="${CVE:-$GHSA}"
if [[ -n "$QUERY" ]]; then
  if curl "${CURL_OPTS[@]}" "https://hn.algolia.com/api/v1/search?query=${QUERY}&tags=story&hitsPerPage=3" -o "$TMPDIR_NEW/hn.json" 2>/dev/null \
     && python3 -c "import json,sys; d=json.load(open('$TMPDIR_NEW/hn.json')); sys.exit(0 if 'hits' in d else 1)" 2>/dev/null; then
    SUCCESS=$((SUCCESS+1))
  else
    echo '{"error":"unreachable"}' > "$TMPDIR_NEW/hn.json"
  fi
fi

# ---- Assemble + cache ----
FETCHED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
python3 <<PYEOF > "$CVE_CACHE"
import json
out = {
  "id":         "$ID",
  "cve":        "$CVE" or None,
  "ghsa":       "$GHSA" or None,
  "fetched_at": "$FETCHED_AT",
  "sources_ok": $SUCCESS,
  "osv":        json.load(open("$TMPDIR_NEW/osv.json")) if __import__("os").path.exists("$TMPDIR_NEW/osv.json") else None,
  "epss":       json.load(open("$TMPDIR_NEW/epss.json")) if __import__("os").path.exists("$TMPDIR_NEW/epss.json") else None,
  "kev":        json.load(open("$TMPDIR_NEW/kev.json")) if __import__("os").path.exists("$TMPDIR_NEW/kev.json") else None,
  "nvd":        json.load(open("$TMPDIR_NEW/nvd.json")) if __import__("os").path.exists("$TMPDIR_NEW/nvd.json") else None,
  "hn":         json.load(open("$TMPDIR_NEW/hn.json")) if __import__("os").path.exists("$TMPDIR_NEW/hn.json") else None,
}
print(json.dumps(out, indent=2))
PYEOF

cat "$CVE_CACHE"
if (( SUCCESS == 0 )); then
  exit 2
fi
exit 0
