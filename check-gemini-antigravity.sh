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
VERBOSE=0
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
  -v, --verbose      Show detailed per-endpoint HTTP status lines
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
        -v|--verbose) VERBOSE=1; shift ;;
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
    _remote_ip="$(run_curl "" -s -o /dev/null -w '%{remote_ip}' "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist" 2>/dev/null || true)"
    DEFAULT_REMOTE_IP="$_remote_ip"
    if [ -z "$_remote_ip" ]; then
        DEFAULT_STACK="err"
    else
        case "$_remote_ip" in
            *:*) DEFAULT_STACK="v6" ;;
            *) DEFAULT_STACK="v4" ;;
        esac
    fi
}

run_stack_suite() {
    _ver="$1"     # 4 or 6
    _flag="-$_ver"
    _label="IPv$_ver"

    # 1. Verify actual stack connectivity & Public IP / GeoIP
    _pub_ip=""
    _geo_country=""
    _geo_org=""
    _remote_check="$(run_curl "$_flag" -s -o /dev/null -w '%{remote_ip}' "https://www.google.com/generate_204" 2>/dev/null || true)"
    if [ -z "$_remote_check" ]; then
        eval "STACK_${_ver}_AVAIL=0"
        eval "STACK_${_ver}_REASON='Unavailable'"
        return 0
    fi
    if [ "$_ver" = "6" ]; then
        case "$_remote_check" in
            *:*) ;;
            *)
                eval "STACK_${_ver}_AVAIL=0"
                eval "STACK_${_ver}_REASON='Proxied via IPv4 (${_remote_check})'"
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
        eval "STACK_${_ver}_AVAIL=0"
        eval "STACK_${_ver}_REASON='No egress IP'"
        return 0
    fi
    eval "STACK_${_ver}_AVAIL=1"

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
        [ -n "$_gem_cc3" ] && _gem_cc2="$(alpha3_to_alpha2 "$_gem_cc3")"
        if [ -n "$_gem_cc3" ] && ! is_blocked_country_code "$_gem_cc3"; then
            _gem_web_ok=1
        elif [ -z "$_gem_cc3" ] && [ "$_gem_flag" -eq 1 ]; then
            _gem_web_ok=1
        fi
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

    # 4. Google Search IP reputation / language region check
    _gs_hdr="$TMP_DIR/gs_${_ver}.hdr"
    _gs_body="$TMP_DIR/gs_${_ver}.html"
    _gs_code="$(run_curl "$_flag" -sL -A "$UA_BROWSER" -D "$_gs_hdr" -o "$_gs_body" -w '%{http_code}' "https://www.google.com/search?q=test&hl=en" 2>/dev/null || echo "000")"
    _gs_lang=""
    _gs_status="unexpected"
    if [ "$_gs_code" = "429" ] || grep -qi "sorry/index" "$_gs_hdr" "$_gs_body" 2>/dev/null; then
        _gs_status="captcha"
    elif [ "$_gs_code" = "200" ]; then
        _gs_status="clean"
        _gs_lang="$(grep -Eo '<html[^>]*lang="[^"]+"' "$_gs_body" 2>/dev/null | head -n 1 | sed 's/.*lang="//;s/"//')"
    fi

    # 5. Antigravity Website & Cloud Code Assist API Reachability
    _ag_web_code="$(run_curl "$_flag" -s -o /dev/null -w '%{http_code}' "https://antigravity.google/" 2>/dev/null || echo "000")"
    _cc_prod_body="$TMP_DIR/cc_prod_${_ver}.json"
    _cc_prod_code="$(run_curl "$_flag" -s -H 'Content-Type: application/json' -d '{}' -o "$_cc_prod_body" -w '%{http_code}' "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist" 2>/dev/null || echo "000")"
    _cc_daily_body="$TMP_DIR/cc_daily_${_ver}.json"
    _cc_daily_code="$(run_curl "$_flag" -s -H 'Content-Type: application/json' -d '{}' -o "$_cc_daily_body" -w '%{http_code}' "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist" 2>/dev/null || echo "000")"

    _ag_ep_issue=""
    if grep -qi "User location is not supported" "$_cc_prod_body" "$_cc_daily_body" 2>/dev/null; then
        _ag_ep_issue="blocked"
    else
        [ "$_ag_web_code" != "200" ] && [ "$_ag_web_code" != "301" ] && [ "$_ag_web_code" != "302" ] && _ag_ep_issue="antigravity.google=$_ag_web_code"
        [ "$_cc_prod_code" != "401" ] && _ag_ep_issue="${_ag_ep_issue:+$_ag_ep_issue, }cloudcode-pa=$_cc_prod_code"
        [ "$_cc_daily_code" != "401" ] && _ag_ep_issue="${_ag_ep_issue:+$_ag_ep_issue, }daily-cloudcode-pa=$_cc_daily_code"
    fi

    # 6. Optional Live Authenticated API Probes
    _live_gem_status="skipped"
    _live_gem_detail=""
    if [ -n "$GEMINI_KEY" ]; then
        _gapi_body="$TMP_DIR/gapi_${_ver}.json"
        _gapi_code="$(run_curl "$_flag" -s -H 'Content-Type: application/json' \
            -d '{"contents":[{"parts":[{"text":"hi"}]}],"generationConfig":{"maxOutputTokens":1}}' \
            -o "$_gapi_body" -w '%{http_code}' \
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${GEMINI_KEY}" 2>/dev/null || echo "000")"
        if [ "$_gapi_code" = "200" ]; then
            _live_gem_status="ok"
        elif grep -qi "User location is not supported" "$_gapi_body" 2>/dev/null; then
            _live_gem_status="blocked"
        else
            _live_gem_status="error"
            _err_msg="$(json_extract_str "message" <"$_gapi_body")"
            _live_gem_detail="HTTP $_gapi_code${_err_msg:+ ($_err_msg)}"
        fi
    fi

    _live_ag_status="skipped"
    _live_ag_detail=""
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
            else
                _live_ag_status="ok"
                _live_ag_detail="$(json_extract_str "cloudaicompanionProject" <"$_ag_body")"
            fi
        elif grep -qi "User location is not supported" "$_ag_body" 2>/dev/null; then
            _live_ag_status="blocked"
        elif [ "$_ag_code" = "401" ]; then
            _live_ag_status="auth_error"
        else
            _live_ag_status="error"
            _err_msg="$(json_extract_str "message" <"$_ag_body")"
            _live_ag_detail="HTTP $_ag_code${_err_msg:+ ($_err_msg)}"
        fi
    fi

    # 7. Region & Verdict Calculation
    _region_blocked=0
    if [ -n "$_gem_cc3" ] && is_blocked_country_code "$_gem_cc3"; then
        _region_blocked=1
    elif [ -n "$_k4_loc" ] && is_blocked_location_name "$_k4_loc"; then
        _region_blocked=1
    elif [ -n "$_geo_country" ] && is_blocked_country_code "$_geo_country" && [ -z "$_gem_cc3" ] && [ -z "$_k4_loc" ]; then
        _region_blocked=1
    fi

    _g_region="${_gem_cc2:-$_gem_cc3}"
    _loc_label=""
    if [ -n "$_g_region" ] && [ -n "$_k4_loc" ]; then
        _loc_label="$_g_region / $_k4_loc"
    elif [ -n "$_g_region" ]; then
        _loc_label="$_g_region"
    elif [ -n "$_k4_loc" ]; then
        _loc_label="$_k4_loc"
    else
        _loc_label="unknown"
    fi

    _mismatch_note=""
    if [ -n "$_geo_country" ] && [ -n "$_gem_cc2" ] && [ "$_geo_country" != "$_gem_cc2" ]; then
        _mismatch_note="GeoIP=$_geo_country != Google=$_gem_cc2"
    fi

    # Print Clean Section
    printf "%b[%s Result]%b\n" "$C_BOLD$C_CYAN" "$_label" "$C_RESET"
    printf "  Egress IP   : %s  (GeoIP: %s | %s)\n" "$_pub_ip" "${_geo_country:-unknown}" "${_geo_org:-unknown}"

    if [ "$_gem_web_ok" -eq 1 ]; then
        printf "  Gemini Web  : %bYES%b (%s)" "$C_GREEN" "$C_RESET" "$_loc_label"
    elif [ "$_gem_code" = "403" ] || [ "$_gem_code" = "451" ]; then
        printf "  Gemini Web  : %bBLOCKED%b (HTTP %s)" "$C_RED" "$C_RESET" "$_gem_code"
    else
        printf "  Gemini Web  : %bNO%b (%s)" "$C_RED" "$C_RESET" "$_loc_label"
    fi
    if [ -n "$_mismatch_note" ]; then
        printf "  %b[%s]%b\n" "$C_YELLOW" "$_mismatch_note" "$C_RESET"
    else
        printf "\n"
    fi

    case "$_live_gem_status" in
        ok)      printf "  Gemini API  : %bPASS%b (HTTP 200)\n" "$C_GREEN" "$C_RESET" ;;
        blocked) printf "  Gemini API  : %bFAIL%b (400 User location is not supported for the API use)\n" "$C_RED" "$C_RESET" ;;
        error)   printf "  Gemini API  : %bWARN%b (%s)\n" "$C_YELLOW" "$C_RESET" "$_live_gem_detail" ;;
        *)       printf "  Gemini API  : %bSKIP%b (no API key)\n" "$C_YELLOW" "$C_RESET" ;;
    esac

    if [ "$_live_ag_status" = "ok" ]; then
        printf "  Antigravity : %bPASS%b (OAuth verified%s)\n" "$C_GREEN" "$C_RESET" "${_live_ag_detail:+, project=$_live_ag_detail}"
    elif [ "$_live_ag_status" = "blocked" ]; then
        printf "  Antigravity : %bFAIL%b (User location is not supported for the API use)\n" "$C_RED" "$C_RESET"
    elif [ "$_live_ag_status" = "ineligible" ]; then
        printf "  Antigravity : %bFAIL%b (Account/Region ineligible in loadCodeAssist)\n" "$C_RED" "$C_RESET"
    elif [ "$_live_ag_status" = "auth_error" ]; then
        printf "  Antigravity : %bWARN%b (OAuth token expired/invalid - HTTP 401)\n" "$C_YELLOW" "$C_RESET"
    elif [ "$_live_ag_status" = "error" ]; then
        printf "  Antigravity : %bWARN%b (%s)\n" "$C_YELLOW" "$C_RESET" "$_live_ag_detail"
    elif [ "$_ag_ep_issue" = "blocked" ]; then
        printf "  Antigravity : %bFAIL%b (Endpoint blocked: User location is not supported)\n" "$C_RED" "$C_RESET"
    elif [ "$_region_blocked" -eq 1 ] && [ "$_live_gem_status" = "ok" ]; then
        printf "  Antigravity : %bUNCERTAIN%b (Web=%s but Gemini API=OK; verify with ya29... OAuth token)\n" "$C_YELLOW" "$C_RESET" "${_g_region:-$_k4_loc}"
    elif [ "$_region_blocked" -eq 1 ]; then
        printf "  Antigravity : %bFAIL%b (Unsupported region: %s)\n" "$C_RED" "$C_RESET" "$_loc_label"
    elif [ -n "$_ag_ep_issue" ]; then
        printf "  Antigravity : %bWARN%b (Endpoint issue: %s)\n" "$C_YELLOW" "$C_RESET" "$_ag_ep_issue"
    elif [ "$_live_gem_status" = "blocked" ]; then
        printf "  Antigravity : %bLIKELY FAIL%b (Gemini API blocked on this IP)\n" "$C_RED" "$C_RESET"
    elif [ "$_live_gem_status" = "ok" ]; then
        printf "  Antigravity : %bPASS%b (Gemini API + Antigravity endpoints OK; region: %s)\n" "$C_GREEN" "$C_RESET" "${_g_region:-$_k4_loc}"
    elif [ "$_gem_web_ok" -eq 1 ]; then
        printf "  Antigravity : %bLIKELY OK%b (Endpoints OK; Google region: %s)\n" "$C_GREEN" "$C_RESET" "${_g_region:-$_k4_loc}"
    else
        printf "  Antigravity : %bUNCERTAIN%b (Could not confirm Google region)\n" "$C_YELLOW" "$C_RESET"
    fi

    case "$_gs_status" in
        clean)   printf "  Search Risk : %bClean%b%s\n" "$C_GREEN" "$C_RESET" "${_gs_lang:+ (lang=$_gs_lang)}" ;;
        captcha) printf "  Search Risk : %bCAPTCHA / Rate-Limited%b (HTTP %s - dirty/datacenter IP)\n" "$C_YELLOW" "$C_RESET" "$_gs_code" ;;
        *)       printf "  Search Risk : %bUnexpected%b (HTTP %s)\n" "$C_YELLOW" "$C_RESET" "$_gs_code" ;;
    esac

    if [ "$VERBOSE" -eq 1 ]; then
        printf "  [Verbose]   : gemini.google.com=%s (%s) | K4WWud=%s | antigravity.google=%s | cloudcode-pa=%s | daily=%s\n" \
            "$_gem_code" "${_gem_cc3:-none}" "${_k4_loc:-none}" "$_ag_web_code" "$_cc_prod_code" "$_cc_daily_code"
    fi
    echo ""

    # Store results for overall summary
    eval "RES_${_ver}_CC3='${_g_region:-$_gem_cc3}'"
    eval "RES_${_ver}_K4='$_k4_loc'"
    eval "RES_${_ver}_GEM_WEB='$_gem_web_ok'"
    eval "RES_${_ver}_BLOCKED='$_region_blocked'"
    eval "RES_${_ver}_EP_ISSUE='$_ag_ep_issue'"
    eval "RES_${_ver}_LIVE_GEM='$_live_gem_status'"
    eval "RES_${_ver}_LIVE_AG='$_live_ag_status'"
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

printf "============================================================\n"
printf " %bGemini & Antigravity Node Check%b\n" "$C_BOLD" "$C_RESET"
printf "============================================================\n"
if [ -n "$PROXY_URL" ]; then
    _mode_str="Proxy ($PROXY_URL)"
elif [ "$FORCE_DIRECT" -eq 1 ]; then
    _mode_str="Direct (--direct)"
else
    _mode_str="Default"
fi

prompt_credentials

DEFAULT_STACK=""
DEFAULT_REMOTE_IP=""
STACK_4_AVAIL=0; STACK_4_REASON=""
STACK_6_AVAIL=0; STACK_6_REASON=""
RES_4_CC3=""; RES_4_K4=""; RES_4_GEM_WEB=0; RES_4_BLOCKED=0; RES_4_EP_ISSUE=""; RES_4_LIVE_GEM="skipped"; RES_4_LIVE_AG="skipped"
RES_6_CC3=""; RES_6_K4=""; RES_6_GEM_WEB=0; RES_6_BLOCKED=0; RES_6_EP_ISSUE=""; RES_6_LIVE_GEM="skipped"; RES_6_LIVE_AG="skipped"

printf "%b[Network]%b\n" "$C_BOLD$C_CYAN" "$C_RESET"
printf "  Mode        : %s\n" "$_mode_str"
if [ "$TEST_MODE" = "both" ]; then
    check_default_stack
    case "$DEFAULT_STACK" in
        v4)  printf "  Default     : %bIPv4%b (%s)\n" "$C_GREEN" "$C_RESET" "$DEFAULT_REMOTE_IP" ;;
        v6)  printf "  Default     : %bIPv6%b (%s)\n" "$C_YELLOW" "$C_RESET" "$DEFAULT_REMOTE_IP" ;;
        *)   printf "  Default     : %bUnreachable%b\n" "$C_RED" "$C_RESET" ;;
    esac
fi
echo ""

if [ "$TEST_MODE" = "both" ] || [ "$TEST_MODE" = "v4" ]; then
    run_stack_suite 4
fi
if [ "$TEST_MODE" = "both" ] || [ "$TEST_MODE" = "v6" ]; then
    run_stack_suite 6
fi

format_stack_verdict() {
    _v="$1"
    eval "_avail=\$STACK_${_v}_AVAIL"
    eval "_reason=\$STACK_${_v}_REASON"
    if [ "$_avail" -eq 0 ]; then
        printf "%b%s%b" "$C_YELLOW" "${_reason:-N/A}" "$C_RESET"
        return 0
    fi

    eval "_cc3=\$RES_${_v}_CC3"
    eval "_k4=\$RES_${_v}_K4"
    eval "_web=\$RES_${_v}_GEM_WEB"
    eval "_blk=\$RES_${_v}_BLOCKED"
    eval "_epi=\$RES_${_v}_EP_ISSUE"
    eval "_lg=\$RES_${_v}_LIVE_GEM"
    eval "_la=\$RES_${_v}_LIVE_AG"

    if [ "$_la" = "ok" ]; then
        printf "%bPASS%b (OAuth verified)" "$C_GREEN" "$C_RESET"
    elif [ "$_la" = "blocked" ] || [ "$_la" = "ineligible" ]; then
        printf "%bFAIL%b (%s)" "$C_RED" "$C_RESET" "$_la"
    elif [ "$_la" = "auth_error" ]; then
        printf "%bWARN%b (OAuth token expired/invalid)" "$C_YELLOW" "$C_RESET"
    elif [ "$_epi" = "blocked" ]; then
        printf "%bFAIL%b (Endpoint blocked)" "$C_RED" "$C_RESET"
    elif [ "$_blk" -eq 1 ] && [ "$_lg" = "ok" ]; then
        printf "%bSPLIT%b (Web=%s, API=OK)" "$C_YELLOW" "$C_RESET" "${_cc3:-$_k4}"
    elif [ "$_blk" -eq 1 ]; then
        printf "%bFAIL%b (Unsupported: %s)" "$C_RED" "$C_RESET" "${_cc3:-$_k4}"
    elif [ -n "$_epi" ]; then
        printf "%bWARN%b (Endpoint: %s)" "$C_YELLOW" "$C_RESET" "$_epi"
    elif [ "$_lg" = "blocked" ]; then
        printf "%bLIKELY FAIL%b (Gemini API blocked)" "$C_RED" "$C_RESET"
    elif [ "$_lg" = "ok" ]; then
        printf "%bPASS%b (API verified, %s)" "$C_GREEN" "$C_RESET" "${_cc3:-$_k4}"
    elif [ "$_web" -eq 1 ]; then
        printf "%bLIKELY OK%b (%s)" "$C_GREEN" "$C_RESET" "${_cc3:-$_k4}"
    else
        printf "%bUNCERTAIN%b" "$C_YELLOW" "$C_RESET"
    fi
}

printf "%b[Verdict]%b\n" "$C_BOLD$C_CYAN" "$C_RESET"
if [ "$TEST_MODE" = "v4" ]; then
    printf "  IPv4 : "; format_stack_verdict 4; printf "\n"
elif [ "$TEST_MODE" = "v6" ]; then
    printf "  IPv6 : "; format_stack_verdict 6; printf "\n"
else
    printf "  IPv4 : "; format_stack_verdict 4; printf "  |  IPv6 : "; format_stack_verdict 6; printf "\n"
fi

if [ "$TEST_MODE" = "both" ] && [ "$STACK_4_AVAIL" -eq 1 ] && [ "$STACK_6_AVAIL" -eq 1 ]; then
    if [ "$DEFAULT_STACK" = "v6" ] && [ "$RES_6_BLOCKED" -eq 1 ] && [ "$RES_4_BLOCKED" -eq 0 ]; then
        printf "  %b[!] CRITICAL IPv6 LEAK:%b IPv4 (%s) works, but default IPv6 (%s) is BLOCKED.\n" \
            "$C_RED" "$C_RESET" "${RES_4_CC3:-$RES_4_K4}" "${RES_6_CC3:-$RES_6_K4}"
    elif [ "$DEFAULT_STACK" = "v6" ] && [ "$RES_4_CC3" != "$RES_6_CC3" ] && [ -n "$RES_4_CC3" ] && [ -n "$RES_6_CC3" ]; then
        printf "  %b[!] IPv4/IPv6 MISMATCH:%b IPv4=%s, IPv6=%s (default stack is IPv6).\n" \
            "$C_YELLOW" "$C_RESET" "$RES_4_CC3" "$RES_6_CC3"
    fi
fi

if [ -z "$AG_TOKEN" ] && { { [ "$RES_4_BLOCKED" -eq 1 ] && [ "$RES_4_LIVE_GEM" = "ok" ]; } || { [ "$RES_6_BLOCKED" -eq 1 ] && [ "$RES_6_LIVE_GEM" = "ok" ]; }; }; then
    printf "  Note : Web geo is blocked while Gemini API passed. Pass -t ya29... to confirm Antigravity.\n"
elif [ -z "$GEMINI_KEY" ] && [ -z "$AG_TOKEN" ]; then
    printf "  Note : Pass -k/-t (or paste a key) to verify datacenter/ASN blocks.\n"
fi
printf "============================================================\n"
