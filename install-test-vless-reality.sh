#!/usr/bin/env bash

# Changes the REALITY target on the disposable Joe test server while keeping
# its UUID, X25519 key pair, short ID, address, and port unchanged.
#
# Run as root on the VPS:
#   bash update-test-reality-target.sh

set -Eeuo pipefail
umask 077

readonly XRAY_BIN="/usr/local/bin/xray"
readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"

REALITY_SERVER_NAME="${REALITY_SERVER_NAME:-www.amazon.com}"
REALITY_TARGET="${REALITY_TARGET:-${REALITY_SERVER_NAME}:443}"

CONFIG_TEMP=""
CLIENT_CONFIG_TEMP=""
CLIENT_LOG_TEMP=""
CLIENT_PID=""
BACKUP_CONFIG=""
ROLLBACK_REQUIRED=0

rollback_if_needed() {
    if [[ "${ROLLBACK_REQUIRED}" -ne 1 || -z "${BACKUP_CONFIG}" || ! -r "${BACKUP_CONFIG}" ]]; then
        return
    fi

    printf '\nThe new REALITY target failed verification; restoring the previous configuration...\n' >&2
    cp -a "${BACKUP_CONFIG}" "${XRAY_CONFIG}"
    systemctl restart xray.service
    if systemctl is-active --quiet xray.service; then
        printf 'Previous Xray configuration restored successfully.\n' >&2
    else
        printf 'Warning: the previous configuration was restored, but Xray is not active.\n' >&2
    fi
    ROLLBACK_REQUIRED=0
}

fail() {
    printf '\nError: %s\n' "$*" >&2
    rollback_if_needed
    exit 1
}

cleanup() {
    if [[ -n "${CLIENT_PID}" ]] && kill -0 "${CLIENT_PID}" 2>/dev/null; then
        kill "${CLIENT_PID}" 2>/dev/null || true
        wait "${CLIENT_PID}" 2>/dev/null || true
    fi
    [[ -z "${CONFIG_TEMP}" || ! -e "${CONFIG_TEMP}" ]] || rm -f "${CONFIG_TEMP}"
    [[ -z "${CLIENT_CONFIG_TEMP}" || ! -e "${CLIENT_CONFIG_TEMP}" ]] || rm -f "${CLIENT_CONFIG_TEMP}"
    [[ -z "${CLIENT_LOG_TEMP}" || ! -e "${CLIENT_LOG_TEMP}" ]] || rm -f "${CLIENT_LOG_TEMP}"
}

trap cleanup EXIT
trap 'fail "The update was interrupted."' INT TERM

validate_environment() {
    [[ "$(id -u)" -eq 0 ]] || fail "Run this script as root."
    [[ -x "${XRAY_BIN}" ]] || fail "Xray is not installed at ${XRAY_BIN}."
    [[ -r "${XRAY_CONFIG}" ]] || fail "Cannot read ${XRAY_CONFIG}."
    command -v jq >/dev/null 2>&1 || fail "jq is required."
    command -v curl >/dev/null 2>&1 || fail "curl is required."
    command -v openssl >/dev/null 2>&1 || fail "openssl is required."
    [[ "${REALITY_SERVER_NAME}" =~ ^[A-Za-z0-9.-]+$ ]] || fail "REALITY_SERVER_NAME is invalid."
    [[ "${REALITY_TARGET}" =~ ^[A-Za-z0-9.-]+:[0-9]+$ ]] || fail "REALITY_TARGET is invalid."

    jq -e '[.inbounds[] | select(.protocol == "vless" and .streamSettings.security == "reality")] | length == 1' \
        "${XRAY_CONFIG}" >/dev/null \
        || fail "Expected exactly one VLESS + REALITY inbound."
}

check_target_tls() {
    local target_host="${REALITY_TARGET%:*}"
    local target_port="${REALITY_TARGET##*:}"
    local output

    printf 'Checking %s TLS shape...\n' "${REALITY_TARGET}"
    output="$(timeout 15 openssl s_client \
        -connect "${target_host}:${target_port}" \
        -servername "${REALITY_SERVER_NAME}" \
        -tls1_3 \
        -alpn h2 </dev/null 2>&1)" \
        || fail "Cannot complete a TLS 1.3 handshake with ${REALITY_TARGET}."

    grep -Eq 'Protocol version: TLSv1\.3|Protocol[[:space:]]*: TLSv1\.3|New, TLSv1\.3' <<<"${output}" \
        || fail "${REALITY_TARGET} did not negotiate TLS 1.3."
    grep -Eq 'Negotiated protocol: h2|ALPN protocol: h2' <<<"${output}" \
        || fail "${REALITY_TARGET} did not negotiate HTTP/2."
}

update_server_config() {
    BACKUP_CONFIG="${XRAY_CONFIG}.backup.$(date -u +%Y%m%dT%H%M%SZ)"
    cp -a "${XRAY_CONFIG}" "${BACKUP_CONFIG}"
    ROLLBACK_REQUIRED=1
    CONFIG_TEMP="$(mktemp)"

    jq \
        --arg target "${REALITY_TARGET}" \
        --arg server_name "${REALITY_SERVER_NAME}" \
        '(.inbounds[] | select(.protocol == "vless" and .streamSettings.security == "reality") | .streamSettings.realitySettings) |=
            (.target = $target | .serverNames = [$server_name])' \
        "${XRAY_CONFIG}" >"${CONFIG_TEMP}"

    jq -e . "${CONFIG_TEMP}" >/dev/null
    install -m 640 -o root -g nogroup "${CONFIG_TEMP}" "${XRAY_CONFIG}"
    "${XRAY_BIN}" run -test -config "${XRAY_CONFIG}"
    systemctl restart xray.service
    systemctl is-active --quiet xray.service || fail "Xray did not remain active after restart."
    printf 'Backup saved to %s\n' "${BACKUP_CONFIG}"
}

verify_reality_proxy_path() {
    local uuid port private_key public_key short_id socks_port key_output

    uuid="$(jq -r '.inbounds[] | select(.protocol == "vless" and .streamSettings.security == "reality") | (.settings.users[0].id // .settings.clients[0].id)' "${XRAY_CONFIG}")"
    port="$(jq -r '.inbounds[] | select(.protocol == "vless" and .streamSettings.security == "reality") | .port' "${XRAY_CONFIG}")"
    private_key="$(jq -r '.inbounds[] | select(.protocol == "vless" and .streamSettings.security == "reality") | .streamSettings.realitySettings.privateKey' "${XRAY_CONFIG}")"
    short_id="$(jq -r '.inbounds[] | select(.protocol == "vless" and .streamSettings.security == "reality") | .streamSettings.realitySettings.shortIds[0]' "${XRAY_CONFIG}")"
    key_output="$(${XRAY_BIN} x25519 -i "${private_key}")"
    public_key="$(awk -F': ' '/^Password( \(PublicKey\))?:/ {print $2; exit}' <<<"${key_output}")"
    [[ -n "${public_key}" ]] || public_key="$(awk -F': ' '/^PublicKey:/ {print $2; exit}' <<<"${key_output}")"
    [[ -n "${public_key}" ]] || fail "Could not derive the REALITY client key."

    socks_port=""
    for candidate in {10809..10819}; do
        if ! ss -H -ltn "sport = :${candidate}" 2>/dev/null | grep -q .; then
            socks_port="${candidate}"
            break
        fi
    done
    [[ -n "${socks_port}" ]] || fail "No local port is available for the end-to-end check."

    CLIENT_CONFIG_TEMP="$(mktemp)"
    CLIENT_LOG_TEMP="$(mktemp)"
    jq -n \
        --argjson socks_port "${socks_port}" \
        --argjson server_port "${port}" \
        --arg uuid "${uuid}" \
        --arg server_name "${REALITY_SERVER_NAME}" \
        --arg password "${public_key}" \
        --arg short_id "${short_id}" \
        '{
            log: {loglevel: "warning"},
            inbounds: [{listen: "127.0.0.1", port: $socks_port, protocol: "socks", settings: {udp: false}}],
            outbounds: [{
                tag: "proxy",
                protocol: "vless",
                settings: {
                    address: "127.0.0.1",
                    port: $server_port,
                    id: $uuid,
                    encryption: "none",
                    flow: "xtls-rprx-vision"
                },
                streamSettings: {
                    network: "raw",
                    security: "reality",
                    realitySettings: {
                        fingerprint: "chrome",
                        serverName: $server_name,
                        password: $password,
                        shortId: $short_id
                    }
                }
            }]
        }' >"${CLIENT_CONFIG_TEMP}"

    "${XRAY_BIN}" run -config "${CLIENT_CONFIG_TEMP}" >"${CLIENT_LOG_TEMP}" 2>&1 &
    CLIENT_PID=$!
    sleep 1
    kill -0 "${CLIENT_PID}" 2>/dev/null || {
        sed -n '1,120p' "${CLIENT_LOG_TEMP}" >&2
        fail "The local Xray verification client did not start."
    }

    if ! curl --fail --silent --show-error --max-time 20 \
        --proxy "socks5h://127.0.0.1:${socks_port}" \
        --output /dev/null https://www.gstatic.com/generate_204; then
        sed -n '1,120p' "${CLIENT_LOG_TEMP}" >&2
        journalctl -u xray.service --no-pager -n 60 >&2 || true
        fail "The full VLESS + Vision + RAW + REALITY path did not pass traffic."
    fi

    printf 'End-to-end REALITY proxy check passed.\n'
}

main() {
    validate_environment
    check_target_tls
    update_server_config
    verify_reality_proxy_path
    ROLLBACK_REQUIRED=0
    printf '\nREALITY target updated successfully.\n'
    printf 'serverName: %s\n' "${REALITY_SERVER_NAME}"
    printf 'target:     %s\n' "${REALITY_TARGET}"
    printf 'All other Joe connection values remain unchanged.\n'
}

main "$@"
