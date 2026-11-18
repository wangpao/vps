#!/bin/sh
# check-gemini-antigravity.sh
# Check whether the current VPS / proxy egress IP supports Google Gemini (Web & API)
# and Google Antigravity, across IPv4, IPv6, and default dual-stack preference.
#
# POSIX sh compatible (works on Debian/Ubuntu/Alpine/CentOS/macOS with curl).

set -u

UA_BROWSER="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
TIMEOUT=10
PROXY_URL=""
FORCE_DIRECT=0
TEST_MODE="both" # both | v4 | v6
GEMINI_KEY="${GEMINI_API_KEY:-}"
AG_TOKEN="${ANTIGRAVITY_TOKEN:-}"
NO_PROMPT=0
USE_COLOR=1

if [ ! -t 1 ] || [ -n "${NO_COLOR:-}" ]; then
    USE_COLOR=0
fi

set_colors() {
    if [ "$USE_COLOR" -eq 1 ]; then
        C_RED='\033[0;31m'
        C_GREEN='\033[0;32m'
        C_YELLOW='\033[0;33m'
        C_BLUE='\033[0;34m'
        C_CYAN='\033[0;36m'
        C_BOLD='\033[1m'
        C_RESET='\033[0m'
    else
        C_RED=''
        C_GREEN=''
        C_YELLOW=''
        C_BLUE=''
        C_CYAN=''
        C_BOLD=''
        C_RESET=''
    fi
}

usage() {
    cat <<'EOF'
Usage: check-gemini-antigravity.sh [options]

Options:
  -4                 Test IPv4 only
  -6                 Test IPv6 only
  -x, --proxy URL    Use curl proxy (e.g. socks5h://127.0.0.1:7890 or http://127.0.0.1:7890)
      --direct       Ignore HTTP_PROXY / HTTPS_PROXY / ALL_PROXY environment variables
  -k, --gemini-key K Optional Gemini API key (or set GEMINI_API_KEY) for live API location test
  -t, --ag-token T   Optional Antigravity OAuth access token (or set ANTIGRAVITY_TOKEN) for live loadCodeAssist test
  -n, --no-prompt    Do not prompt for an API key interactively
      --timeout SEC  Curl max-time in seconds (default: 10)
      --no-color     Disable ANSI colors
  -h, --help         Show this help message

Notes:
  * When run interactively without -k / -t (or env vars), the script prompts
    once for an optional Gemini API Key (or ya29... OAuth token). Press Enter
    to skip and run in zero-credential mode.
  * Without -k / -t, Google's API gateways (cloudcode-pa.googleapis.com /
    generativelanguage.googleapis.com) check auth before region, so the script
    evaluates Google's IP geolocation via unauthenticated Google endpoints,
    dual-stack routing checks, and the official Antigravity/Gemini country rules.
  * Passing -k or -t triggers an actual authenticated request to catch server-side
    "User location is not supported for the API use." directly.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -4) TEST_MODE="v4"; shift ;;
        -6) TEST_MODE="v6"; shift ;;
        -x|--proxy)
            [ $# -lt 2 ] && { echo "Missing value for $1" >&2; exit 2; }
            PROXY_URL="$2"; shift 2 ;;
        --direct) FORCE_DIRECT=1; shift ;;
        -k|--gemini-key)
            [ $# -lt 2 ] && { echo "Missing value for $1" >&2; exit 2; }
            GEMINI_KEY="$2"; shift 2 ;;
        -t|--ag-token)
            [ $# -lt 2 ] && { echo "Missing value for $1" >&2; exit 2; }
            AG_TOKEN="$2"; shift 2 ;;
        -n|--no-prompt|--non-interactive) NO_PROMPT=1; shift ;;
        --timeout)
            [ $# -lt 2 ] && { echo "Missing value for $1" >&2; exit 2; }
            TIMEOUT="$2"; shift 2 ;;
        --no-color) USE_COLOR=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

set_colors

if ! command -v curl >/dev/null 2>&1; then
    printf "%bError: curl is required but not installed.%b\n" "$C_RED" "$C_RESET" >&2
    exit 1
fi

TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t 'agcheck')"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

# Build common curl proxy args via positional function wrapper
run_curl() {
    # $1 = ip flag ("-4", "-6", or "")
    # rest = curl args
    _ip_flag="$1"
    shift
    if [ "$FORCE_DIRECT" -eq 1 ]; then
        if [ -n "$_ip_flag" ]; then
            curl --noproxy '*' "$_ip_flag" --max-time "$TIMEOUT" "$@"
        else
            curl --noproxy '*' --max-time "$TIMEOUT" "$@"
        fi
    elif [ -n "$PROXY_URL" ]; then
        if [ -n "$_ip_flag" ]; then
            curl --proxy "$PROXY_URL" "$_ip_flag" --max-time "$TIMEOUT" "$@"
        else
            curl --proxy "$PROXY_URL" --max-time "$TIMEOUT" "$@"
        fi
    else
        if [ -n "$_ip_flag" ]; then
            curl "$_ip_flag" --max-time "$TIMEOUT" "$@"
        else
            curl --max-time "$TIMEOUT" "$@"
        fi
    fi
}

# Check if a 2-letter or 3-letter country code is explicitly unsupported by Gemini API / Antigravity
# Based on official lists:
#   - https://ai.google.dev/gemini-api/docs/available-regions
#   - https://antigravity.google/docs/faq
is_blocked_country_code() {
    _code="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
    case "$_code" in
        CN|CHN|HK|HKG|MO|MAC|RU|RUS|BY|BLR|IR|IRN|KP|PRK|CU|CUB|SY|SYR|AF|AFG|MM|MMR)
            return 0 ;;
        *)
            return 1 ;;
    esac
}

is_blocked_location_name() {
    _loc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$_loc" in
        *china*|*"hong kong"*|*macau*|*macao*|*russia*|*belarus*|*iran*|*"north korea"*|*cuba*|*syria*|*afghanistan*|*myanmar*|*burma*)
            return 0 ;;
        *)
            return 1 ;;
    esac
}

alpha3_to_alpha2() {
    case "$1" in
        USA) echo "US" ;; SGP) echo "SG" ;; JPN) echo "JP" ;; TWN) echo "TW" ;;
        KOR) echo "KR" ;; GBR) echo "GB" ;; DEU) echo "DE" ;; FRA) echo "FR" ;;
        NLD) echo "NL" ;; CAN) echo "CA" ;; AUS) echo "AU" ;; IND) echo "IN" ;;
        IDN) echo "ID" ;; MYS) echo "MY" ;; THA) echo "TH" ;; VNM) echo "VN" ;;
        PHL) echo "PH" ;; BRA) echo "BR" ;; ARG) echo "AR" ;; MEX) echo "MX" ;;
        IRL) echo "IE" ;; ITA) echo "IT" ;; ESP) echo "ES" ;; POL) echo "PL" ;;
        SWE) echo "SE" ;; NOR) echo "NO" ;; FIN) echo "FI" ;; DNK) echo "DK" ;;
        CHE) echo "CH" ;; AUT) echo "AT" ;; BEL) echo "BE" ;; PRT) echo "PT" ;;
        TUR) echo "TR" ;; ARE) echo "AE" ;; SAU) echo "SA" ;; ISR) echo "IL" ;;
        ZAF) echo "ZA" ;; NZL) echo "NZ" ;; UKR) echo "UA" ;; ROU) echo "RO" ;;
        CZE) echo "CZ" ;; HUN) echo "HU" ;; GRC) echo "GR" ;; CHL) echo "CL" ;;
        COL) echo "CO" ;; PER) echo "PE" ;; KAZ) echo "KZ" ;; PAK) echo "PK" ;;
        BGD) echo "BD" ;; LKA) echo "LK" ;; NPL) echo "NP" ;; KHM) echo "KH" ;;
        LAO) echo "LA" ;; MNG) echo "MN" ;;
        CHN) echo "CN" ;; HKG) echo "HK" ;; MAC) echo "MO" ;; RUS) echo "RU" ;;
        BLR) echo "BY" ;; IRN) echo "IR" ;; PRK) echo "KP" ;; CUB) echo "CU" ;;
        SYR) echo "SY" ;; AFG) echo "AF" ;; MMR) echo "MM" ;;
        *) echo "" ;;
    esac
}

json_extract_str() {
    # Extract simple JSON string value for key $1 from stdin
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1
}

check_default_stack() {
    printf "%b=== Default Egress Stack (No -4/-6 Forced) ===%b\n" "$C_BOLD$C_CYAN" "$C_RESET"
    _remote_ip="$(run_curl "" -s -o /dev/null -w '%{remote_ip}' "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist" 2>/dev/null || true)"
    if [ -z "$_remote_ip" ]; then
        printf "  cloudcode-pa.googleapis.com : %bUnreachable / Connection Failed%b\n" "$C_RED" "$C_RESET"
    else
        case "$_remote_ip" in
            *:*)
                printf "  cloudcode-pa.googleapis.com : %bIPv6 preferred%b (%s)\n" "$C_YELLOW" "$C_RESET" "$_remote_ip"
                DEFAULT_STACK="v6"
                ;;
            *)
                printf "  cloudcode-pa.googleapis.com : %bIPv4 preferred%b (%s)\n" "$C_GREEN" "$C_RESET" "$_remote_ip"
                DEFAULT_STACK="v4"
                ;;
        esac
    fi
    echo ""
}

run_stack_suite() {
    _ver="$1"     # 4 or 6
    _flag="-$_ver"
    _label="IPv$_ver"

    printf "%b=== %s Diagnostics ===%b\n" "$C_BOLD$C_CYAN" "$_label" "$C_RESET"

    # 1. Verify actual stack connectivity & Public IP / GeoIP
    _pub_ip=""
    _geo_country=""
    _geo_org=""
    _remote_check="$(run_curl "$_flag" -s -o /dev/null -w '%{remote_ip}' "https://www.google.com/generate_204" 2>/dev/null || true)"
    if [ -z "$_remote_check" ]; then
        printf "  Egress IP (%s)            : %bUnavailable (no %s connectivity to Google)%b\n\n" "$_label" "$C_YELLOW" "$_label" "$C_RESET"
        eval "STACK_${_ver}_AVAIL=0"
        return 0
    fi
    if [ "$_ver" = "6" ]; then
        case "$_remote_check" in
            *:*) ;;
            *)
                printf "  Egress IP (%s)            : %bSkipped (curl -6 routed via IPv4/proxy: %s)%b\n\n" "$_label" "$C_YELLOW" "$_remote_check" "$C_RESET"
                eval "STACK_${_ver}_AVAIL=0"
                return 0
                ;;
        esac
        _pub_ip="$(run_curl "$_flag" -sS "https://api6.ipify.org" 2>/dev/null || true)"
        [ -z "$_pub_ip" ] && _pub_ip="$(run_curl "$_flag" -sS "https://v6.ident.me" 2>/dev/null || true)"
        case "$_pub_ip" in
            *:*) ;;
            *) _pub_ip="" ;;
        esac
        if [ -n "$_pub_ip" ]; then
            _ipinfo_file="$TMP_DIR/ipinfo_${_ver}.json"
            if run_curl "$_flag" -sS "https://api.ip.sb/geoip/${_pub_ip}" >"$_ipinfo_file" 2>/dev/null; then
                _geo_country="$(json_extract_str "country_code" <"$_ipinfo_file")"
                _geo_org="$(json_extract_str "organization" <"$_ipinfo_file")"
            fi
        fi
    else
        _ipinfo_file="$TMP_DIR/ipinfo_${_ver}.json"
        if run_curl "$_flag" -sS "https://ipinfo.io/json" >"$_ipinfo_file" 2>/dev/null; then
            _pub_ip="$(json_extract_str "ip" <"$_ipinfo_file")"
            _geo_country="$(json_extract_str "country" <"$_ipinfo_file")"
            _geo_org="$(json_extract_str "org" <"$_ipinfo_file")"
        fi
        if [ -z "$_pub_ip" ]; then
            _cf_trace="$TMP_DIR/cf_${_ver}.txt"
            if run_curl "$_flag" -sS "https://1.1.1.1/cdn-cgi/trace" >"$_cf_trace" 2>/dev/null; then
                _pub_ip="$(sed -n 's/^ip=//p' "$_cf_trace" | head -n 1)"
                _geo_country="$(sed -n 's/^loc=//p' "$_cf_trace" | head -n 1)"
            fi
        fi
    fi

    if [ -z "$_pub_ip" ]; then
        printf "  Egress IP (%s)            : %bUnavailable (no %s egress IP)%b\n\n" "$_label" "$C_YELLOW" "$_label" "$C_RESET"
        eval "STACK_${_ver}_AVAIL=0"
        return 0
    fi
    eval "STACK_${_ver}_AVAIL=1"

    printf "  Egress IP                   : %s (GeoIP: %s | %s)\n" "$_pub_ip" "${_geo_country:-unknown}" "${_geo_org:-unknown}"

    # 2. Gemini Web Check (https://gemini.google.com/?hl=en)
    _gem_file="$TMP_DIR/gemini_${_ver}.html"
    _gem_code="$(run_curl "$_flag" -sL -A "$UA_BROWSER" -o "$_gem_file" -w '%{http_code}' "https://gemini.google.com/?hl=en" 2>/dev/null || echo "000")"
    _gem_flag=0
    _gem_cc3=""
    _gem_cc2=""
    _gem_web_ok=0

    if [ "$_gem_code" = "200" ]; then
        if grep -qE '45631641,null,true|45617354,null,true' "$_gem_file" 2>/dev/null; then
            _gem_flag=1
        fi
        _gem_cc3="$(grep -Eo ',2,1,200,"[A-Z]{3}"' "$_gem_file" 2>/dev/null | head -n 1 | sed 's/,2,1,200,"//;s/"//')"
        if [ -n "$_gem_cc3" ]; then
            _gem_cc2="$(alpha3_to_alpha2 "$_gem_cc3")"
        fi
        if [ -n "$_gem_cc3" ] && is_blocked_country_code "$_gem_cc3"; then
            printf "  Gemini Web                  : %bNo%b (Google Country: %s%s - Unsupported)%b\n" "$C_RED" "$C_RESET" "$_gem_cc3" "${_gem_cc2:+/$_gem_cc2}" "$C_RESET"
        elif [ -n "$_gem_cc3" ]; then
            _gem_web_ok=1
            printf "  Gemini Web                  : %bYes%b (Google Country: %s%s)\n" "$C_GREEN" "$C_RESET" "$_gem_cc3" "${_gem_cc2:+/$_gem_cc2}"
        elif [ "$_gem_flag" -eq 1 ]; then
            _gem_web_ok=1
            printf "  Gemini Web                  : %bYes%b (Feature flag active; country marker missing)\n" "$C_GREEN" "$C_RESET"
        else
            printf "  Gemini Web                  : %bNo%b (No region or feature marker found)\n" "$C_RED" "$C_RESET"
        fi
    elif [ "$_gem_code" = "403" ] || [ "$_gem_code" = "451" ]; then
        printf "  Gemini Web                  : %bBlocked (HTTP %s)%b\n" "$C_RED" "$_gem_code" "$C_RESET"
    else
        printf "  Gemini Web                  : %bFailed (HTTP %s)%b\n" "$C_RED" "$_gem_code" "$C_RESET"
    fi

    # 3. Google IP-inferred location via K4WWud batchexecute
    _rpc_file="$TMP_DIR/rpc_${_ver}.txt"
    _k4_loc=""
    if run_curl "$_flag" -sL -A "$UA_BROWSER" \
        -H 'accept-language: en-US' \
        --data-raw 'f.req=[[["K4WWud","[[0],[\"en-US\"]]",null,"generic"]]]' \
        "https://gemini.google.com/_/BardChatUi/data/batchexecute" >"$_rpc_file" 2>/dev/null; then
        _k4_loc="$(grep 'K4WWud' "$_rpc_file" 2>/dev/null | sed -n 's/.*\[\\"\([^\\"]*\)\\",\\"SWML_DESCRIPTION_FROM_YOUR_INTERNET_ADDRESS.*/\1/p' | head -n 1)"
    fi
    if [ -n "$_k4_loc" ]; then
        if is_blocked_location_name "$_k4_loc"; then
            printf "  Google IP Geo (K4WWud)      : %b%s (UNSUPPORTED REGION)%b\n" "$C_RED" "$_k4_loc" "$C_RESET"
        else
            printf "  Google IP Geo (K4WWud)      : %b%s%b\n" "$C_GREEN" "$_k4_loc" "$C_RESET"
        fi
    else
        printf "  Google IP Geo (K4WWud)      : %bUnavailable%b\n" "$C_YELLOW" "$C_RESET"
    fi

    # 4. Google Search IP reputation / language region check
    _gs_hdr="$TMP_DIR/gs_${_ver}.hdr"
    _gs_body="$TMP_DIR/gs_${_ver}.html"
    _gs_code="$(run_curl "$_flag" -sL -A "$UA_BROWSER" -D "$_gs_hdr" -o "$_gs_body" -w '%{http_code}' "https://www.google.com/search?q=test&hl=en" 2>/dev/null || echo "000")"
    if [ "$_gs_code" = "429" ] || grep -qi "sorry/index" "$_gs_hdr" "$_gs_body" 2>/dev/null; then
        printf "  Google Search Reputation    : %bCAPTCHA / Rate-Limited (HTTP %s - dirty/datacenter IP risk)%b\n" "$C_YELLOW" "$_gs_code" "$C_RESET"
    elif [ "$_gs_code" = "200" ]; then
        _gs_lang="$(grep -Eo '<html[^>]*lang="[^"]+"' "$_gs_body" 2>/dev/null | head -n 1 | sed 's/.*lang="//;s/"//')"
        printf "  Google Search Reputation    : %bClean (HTTP 200%s)%b\n" "$C_GREEN" "${_gs_lang:+, lang=$_gs_lang}" "$C_RESET"
    else
        printf "  Google Search Reputation    : %bUnexpected (HTTP %s)%b\n" "$C_YELLOW" "$_gs_code" "$C_RESET"
    fi

    # 5. Antigravity Website & Cloud Code Assist API Reachability
    _ag_web_code="$(run_curl "$_flag" -s -o /dev/null -w '%{http_code}' "https://antigravity.google/" 2>/dev/null || echo "000")"
    if [ "$_ag_web_code" = "200" ] || [ "$_ag_web_code" = "301" ] || [ "$_ag_web_code" = "302" ]; then
        printf "  antigravity.google          : %bReachable (HTTP %s)%b\n" "$C_GREEN" "$_ag_web_code" "$C_RESET"
    else
        printf "  antigravity.google          : %bFailed (HTTP %s)%b\n" "$C_RED" "$_ag_web_code" "$C_RESET"
    fi

    _cc_prod_body="$TMP_DIR/cc_prod_${_ver}.json"
    _cc_prod_code="$(run_curl "$_flag" -s -H 'Content-Type: application/json' -d '{}' -o "$_cc_prod_body" -w '%{http_code}' "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist" 2>/dev/null || echo "000")"
    if [ "$_cc_prod_code" = "401" ]; then
        printf "  cloudcode-pa (prod)         : %bReachable (HTTP 401 auth-gated)%b\n" "$C_GREEN" "$C_RESET"
    elif grep -qi "User location is not supported" "$_cc_prod_body" 2>/dev/null; then
        printf "  cloudcode-pa (prod)         : %bBLOCKED (User location is not supported)%b\n" "$C_RED" "$C_RESET"
    else
        printf "  cloudcode-pa (prod)         : %bHTTP %s%b\n" "$C_YELLOW" "$_cc_prod_code" "$C_RESET"
    fi

    _cc_daily_body="$TMP_DIR/cc_daily_${_ver}.json"
    _cc_daily_code="$(run_curl "$_flag" -s -H 'Content-Type: application/json' -d '{}' -o "$_cc_daily_body" -w '%{http_code}' "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist" 2>/dev/null || echo "000")"
    if [ "$_cc_daily_code" = "401" ]; then
        printf "  daily-cloudcode-pa          : %bReachable (HTTP 401 auth-gated)%b\n" "$C_GREEN" "$C_RESET"
    elif grep -qi "User location is not supported" "$_cc_daily_body" 2>/dev/null; then
        printf "  daily-cloudcode-pa          : %bBLOCKED (User location is not supported)%b\n" "$C_RED" "$C_RESET"
    else
        printf "  daily-cloudcode-pa          : %bHTTP %s%b\n" "$C_YELLOW" "$_cc_daily_code" "$C_RESET"
    fi

    # 6. Optional Live Authenticated API Probes
    _live_gem_status="skipped"
    if [ -n "$GEMINI_KEY" ]; then
        _gapi_body="$TMP_DIR/gapi_${_ver}.json"
        _gapi_code="$(run_curl "$_flag" -s -H 'Content-Type: application/json' \
            -d '{"contents":[{"parts":[{"text":"hi"}]}],"generationConfig":{"maxOutputTokens":1}}' \
            -o "$_gapi_body" -w '%{http_code}' \
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${GEMINI_KEY}" 2>/dev/null || echo "000")"
        if [ "$_gapi_code" = "200" ]; then
            _live_gem_status="ok"
            printf "  Gemini API (Live Key)       : %bPASS (HTTP 200)%b\n" "$C_GREEN" "$C_RESET"
        elif grep -qi "User location is not supported" "$_gapi_body" 2>/dev/null; then
            _live_gem_status="blocked"
            printf "  Gemini API (Live Key)       : %bFAIL (400 User location is not supported for the API use)%b\n" "$C_RED" "$C_RESET"
        else
            _live_gem_status="error"
            _err_msg="$(json_extract_str "message" <"$_gapi_body")"
            printf "  Gemini API (Live Key)       : %bHTTP %s (%s)%b\n" "$C_YELLOW" "$_gapi_code" "${_err_msg:-unknown}" "$C_RESET"
        fi
    fi

    _live_ag_status="skipped"
    if [ -n "$AG_TOKEN" ]; then
        _ag_body="$TMP_DIR/ag_live_${_ver}.json"
        _ag_code="$(run_curl "$_flag" -s \
            -H "Authorization: Bearer ${AG_TOKEN}" \
            -H 'Content-Type: application/json' \
            -H 'User-Agent: antigravity/2.23.0' \
            -d '{"metadata":{"ideType":"ANTIGRAVITY","ideName":"antigravity","ideVersion":"2.23.0"}}' \
            -o "$_ag_body" -w '%{http_code}' \
            "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist" 2>/dev/null || echo "000")"
        if [ "$_ag_code" = "200" ]; then
            if grep -qiE "ineligibleTiers|INELIGIBLE|UNSUPPORTED_LOCATION" "$_ag_body" 2>/dev/null && ! grep -q "cloudaicompanionProject" "$_ag_body" 2>/dev/null; then
                _live_ag_status="ineligible"
                printf "  Antigravity (Live Token)    : %bINELIGIBLE (Account/Region ineligible in loadCodeAssist)%b\n" "$C_RED" "$C_RESET"
            else
                _live_ag_status="ok"
                _proj="$(json_extract_str "cloudaicompanionProject" <"$_ag_body")"
                printf "  Antigravity (Live Token)    : %bPASS (HTTP 200%s)%b\n" "$C_GREEN" "${_proj:+, project=$_proj}" "$C_RESET"
            fi
        elif grep -qi "User location is not supported" "$_ag_body" 2>/dev/null; then
            _live_ag_status="blocked"
            printf "  Antigravity (Live Token)    : %bFAIL (User location is not supported for the API use)%b\n" "$C_RED" "$C_RESET"
        elif [ "$_ag_code" = "401" ]; then
            _live_ag_status="auth_error"
            printf "  Antigravity (Live Token)    : %bToken expired or invalid (HTTP 401)%b\n" "$C_YELLOW" "$C_RESET"
        else
            _live_ag_status="error"
            _err_msg="$(json_extract_str "message" <"$_ag_body")"
            printf "  Antigravity (Live Token)    : %bHTTP %s (%s)%b\n" "$C_YELLOW" "$_ag_code" "${_err_msg:-unknown}" "$C_RESET"
        fi
    fi

    # 7. Per-stack Eligibility Summary
    _region_blocked=0
    if [ -n "$_gem_cc3" ] && is_blocked_country_code "$_gem_cc3"; then
        _region_blocked=1
    elif [ -n "$_k4_loc" ] && is_blocked_location_name "$_k4_loc"; then
        _region_blocked=1
    elif [ -n "$_geo_country" ] && is_blocked_country_code "$_geo_country" && [ -z "$_gem_cc3" ] && [ -z "$_k4_loc" ]; then
        _region_blocked=1
    fi

    # Detect GeoIP mismatch ("送中" / IPv4 vs GeoIP discrepancy)
    if [ -n "$_geo_country" ] && [ -n "$_gem_cc2" ] && [ "$_geo_country" != "$_gem_cc2" ]; then
        printf "  GeoIP vs Google Mismatch    : %bWarning: ipinfo=%s, Google=%s%b\n" "$C_YELLOW" "$_geo_country" "$_gem_cc2" "$C_RESET"
    fi

    # Store results for overall summary
    eval "RES_${_ver}_CC3='$_gem_cc3'"
    eval "RES_${_ver}_K4='$_k4_loc'"
    eval "RES_${_ver}_GEM_WEB='$_gem_web_ok'"
    eval "RES_${_ver}_BLOCKED='$_region_blocked'"
    eval "RES_${_ver}_LIVE_GEM='$_live_gem_status'"
    eval "RES_${_ver}_LIVE_AG='$_live_ag_status'"
    echo ""
}

prompt_credentials() {
    if [ "$NO_PROMPT" -eq 1 ] || [ -n "$GEMINI_KEY" ] || [ -n "$AG_TOKEN" ]; then
        return 0
    fi
    if [ ! -t 0 ] && [ ! -t 1 ]; then
        return 0
    fi
    if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
        return 0
    fi

    printf "Optional Gemini API Key (or ya29... OAuth token; press Enter to skip): " >/dev/tty
    _cred_input=""
    IFS= read -r _cred_input </dev/tty || _cred_input=""

    _cred_input="$(printf '%s' "$_cred_input" | tr -d '[:space:]')"
    if [ -z "$_cred_input" ]; then
        printf "  -> No key provided; running unauthenticated checks.\n\n" >/dev/tty
        return 0
    fi

    case "$_cred_input" in
        ya29.*)
            AG_TOKEN="$_cred_input"
            printf "  -> Detected OAuth token (ya29...); will run live Antigravity loadCodeAssist check.\n\n" >/dev/tty
            ;;
        *)
            GEMINI_KEY="$_cred_input"
            printf "  -> Gemini API Key received; will run live Gemini API check.\n\n" >/dev/tty
            ;;
    esac
}

printf "%bGoogle Gemini & Antigravity Node Checker%b\n" "$C_BOLD" "$C_RESET"
if [ -n "$PROXY_URL" ]; then
    printf "Mode: Proxy (%s)\n\n" "$PROXY_URL"
elif [ "$FORCE_DIRECT" -eq 1 ]; then
    printf "Mode: Direct (--direct, ignoring proxy env)\n\n"
else
    printf "Mode: Default environment\n\n"
fi

prompt_credentials

DEFAULT_STACK=""
STACK_4_AVAIL=0
STACK_6_AVAIL=0
RES_4_CC3=""; RES_4_K4=""; RES_4_GEM_WEB=0; RES_4_BLOCKED=0; RES_4_LIVE_GEM="skipped"; RES_4_LIVE_AG="skipped"
RES_6_CC3=""; RES_6_K4=""; RES_6_GEM_WEB=0; RES_6_BLOCKED=0; RES_6_LIVE_GEM="skipped"; RES_6_LIVE_AG="skipped"

if [ "$TEST_MODE" = "both" ]; then
    check_default_stack
fi
if [ "$TEST_MODE" = "both" ] || [ "$TEST_MODE" = "v4" ]; then
    run_stack_suite 4
fi
if [ "$TEST_MODE" = "both" ] || [ "$TEST_MODE" = "v6" ]; then
    run_stack_suite 6
fi

printf "%b=== Summary & Verdict ===%b\n" "$C_BOLD$C_CYAN" "$C_RESET"

print_stack_verdict() {
    _v="$1"
    eval "_avail=\$STACK_${_v}_AVAIL"
    [ "$_avail" -eq 0 ] && return 0

    eval "_cc3=\$RES_${_v}_CC3"
    eval "_k4=\$RES_${_v}_K4"
    eval "_web=\$RES_${_v}_GEM_WEB"
    eval "_blk=\$RES_${_v}_BLOCKED"
    eval "_lg=\$RES_${_v}_LIVE_GEM"
    eval "_la=\$RES_${_v}_LIVE_AG"

    if [ "$_la" = "ok" ]; then
        printf "  IPv%s Antigravity : %bPASS (Verified with OAuth token)%b\n" "$_v" "$C_GREEN" "$C_RESET"
    elif [ "$_la" = "blocked" ] || [ "$_la" = "ineligible" ]; then
        printf "  IPv%s Antigravity : %bFAIL (%s)%b\n" "$_v" "$C_RED" "$_la" "$C_RESET"
    elif [ "$_lg" = "blocked" ]; then
        printf "  IPv%s Antigravity : %bLIKELY FAIL (Gemini API blocked on this IP)%b\n" "$_v" "$C_RED" "$C_RESET"
    elif [ "$_lg" = "ok" ]; then
        printf "  IPv%s Antigravity : %bPASS (Gemini API verified on this IP; Google region: %s)%b\n" "$_v" "$C_GREEN" "${_cc3:-$_k4}" "$C_RESET"
    elif [ "$_blk" -eq 1 ]; then
        printf "  IPv%s Antigravity : %bFAIL (Google maps IP to unsupported region: %s)%b\n" "$_v" "$C_RED" "${_cc3:-$_k4}" "$C_RESET"
    elif [ "$_web" -eq 1 ]; then
        printf "  IPv%s Antigravity : %bLIKELY OK (Google region: %s; pass -k/-t for 100%% API verification)%b\n" "$_v" "$C_GREEN" "${_cc3:-$_k4}" "$C_RESET"
    else
        printf "  IPv%s Antigravity : %bUNCERTAIN (Could not confirm Google region eligibility)%b\n" "$_v" "$C_YELLOW" "$C_RESET"
    fi
}

print_stack_verdict 4
print_stack_verdict 6

if [ "$TEST_MODE" = "both" ] && [ "$STACK_4_AVAIL" -eq 1 ] && [ "$STACK_6_AVAIL" -eq 1 ]; then
    if [ "$DEFAULT_STACK" = "v6" ] && [ "$RES_6_BLOCKED" -eq 1 ] && [ "$RES_4_BLOCKED" -eq 0 ]; then
        printf "\n  %b[!] CRITICAL IPv6 LEAK DETECTED:%b\n" "$C_RED" "$C_RESET"
        printf "      Your IPv4 (%s) is supported, but cloudcode-pa.googleapis.com prefers IPv6 (%s) which is BLOCKED!\n" "${RES_4_CC3:-$RES_4_K4}" "${RES_6_CC3:-$RES_6_K4}"
        printf "      Fix: prefer IPv4 in /etc/gai.conf or block Google IPv6 / route IPv6 over clean proxy.\n"
    elif [ "$DEFAULT_STACK" = "v6" ] && [ "$RES_4_CC3" != "$RES_6_CC3" ] && [ -n "$RES_4_CC3" ] && [ -n "$RES_6_CC3" ]; then
        printf "\n  %b[!] IPv4/IPv6 REGION MISMATCH:%b IPv4=%s, IPv6=%s (default stack is IPv6).\n" "$C_YELLOW" "$C_RESET" "$RES_4_CC3" "$RES_6_CC3"
    fi
fi

if [ -z "$GEMINI_KEY" ] && [ -z "$AG_TOKEN" ]; then
    printf "\n  Tip: For definitive server-side API check (catches datacenter/ASN blocks),\n"
    printf "       re-run with GEMINI_API_KEY=... or ANTIGRAVITY_TOKEN=...\n"
fi
