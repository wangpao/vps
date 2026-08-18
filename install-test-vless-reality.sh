#!/usr/bin/env bash

# Installs a disposable Xray VLESS + Vision + RAW + REALITY test server.
#
# Supported host: Ubuntu 26.04 with systemd (amd64 or arm64).
# Run as root:
#   bash install-test-vless-reality.sh
#
# Optional environment overrides:
#   PORT=443
#   XRAY_VERSION=v26.3.27
#   REALITY_SERVER_NAME=www.microsoft.com
#   REALITY_TARGET=www.microsoft.com:443
#   SERVER_ADDRESS=203.0.113.10
#
# Primary references:
#   https://github.com/XTLS/Xray-install
#   https://xtls.github.io/config/transports/reality.html
#   https://xtls.github.io/config/inbounds/vless.html

set -Eeuo pipefail
umask 077

readonly XRAY_INSTALL_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
readonly XRAY_BIN="/usr/local/bin/xray"
readonly XRAY_CONFIG_DIR="/usr/local/etc/xray"
readonly XRAY_CONFIG="${XRAY_CONFIG_DIR}/config.json"
readonly RESULT_FILE="/root/joe-vless-reality.txt"

PORT="${PORT:-443}"
REALITY_SERVER_NAME="${REALITY_SERVER_NAME:-www.microsoft.com}"
REALITY_TARGET="${REALITY_TARGET:-${REALITY_SERVER_NAME}:443}"
SERVER_ADDRESS="${SERVER_ADDRESS:-}"
XRAY_VERSION="${XRAY_VERSION:-v26.3.27}"

INSTALLER_FILE=""
CONFIG_TEMP=""

info() {
    printf '\n==> %s\n' "$*"
}

fail() {
    printf '\nError: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    [[ -z "${INSTALLER_FILE}" || ! -e "${INSTALLER_FILE}" ]] || rm -f "${INSTALLER_FILE}"
    [[ -z "${CONFIG_TEMP}" || ! -e "${CONFIG_TEMP}" ]] || rm -f "${CONFIG_TEMP}"
}

on_error() {
    local exit_code=$?
    printf '\nInstallation failed (exit code %s).\n' "${exit_code}" >&2
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files xray.service >/dev/null 2>&1; then
        journalctl -u xray.service --no-pager -n 40 >&2 || true
    fi
    exit "${exit_code}"
}

trap cleanup EXIT
trap on_error ERR

validate_environment() {
    [[ "$(id -u)" -eq 0 ]] || fail "Run this script as root (sudo -i, then run it again)."
    [[ -r /etc/os-release ]] || fail "Cannot identify the operating system."

    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" == "ubuntu" ]] || fail "This test installer supports Ubuntu only."
    [[ "${VERSION_ID:-}" == "26.04" ]] || fail "Expected Ubuntu 26.04; found ${PRETTY_NAME:-unknown system}."
    [[ -d /run/systemd/system ]] || fail "systemd is required."

    [[ "${PORT}" =~ ^[0-9]+$ ]] || fail "PORT must be a number."
    ((PORT >= 1 && PORT <= 65535)) || fail "PORT must be between 1 and 65535."
    [[ "${REALITY_SERVER_NAME}" =~ ^[A-Za-z0-9.-]+$ ]] || fail "REALITY_SERVER_NAME is invalid."
    [[ "${REALITY_SERVER_NAME}" == *.* ]] || fail "REALITY_SERVER_NAME must be a domain name."
    [[ "${REALITY_TARGET}" =~ ^[A-Za-z0-9.-]+:[0-9]+$ ]] || fail "REALITY_TARGET must look like domain.example:443."
    [[ "${XRAY_VERSION}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "XRAY_VERSION must look like v26.3.27."

}

install_prerequisites() {
    info "Installing required Ubuntu packages"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends ca-certificates curl jq openssl iproute2
}

check_port_available() {
    if ss -H -ltn "sport = :${PORT}" 2>/dev/null | grep -q .; then
        fail "TCP port ${PORT} is already in use. Stop the existing service or choose another PORT."
    fi
}

check_reality_target() {
    local target_host="${REALITY_TARGET%:*}"
    local target_port="${REALITY_TARGET##*:}"
    local probe_output

    info "Checking that the REALITY target supports TLS 1.3 and HTTP/2"
    probe_output="$(timeout 15 openssl s_client \
        -connect "${target_host}:${target_port}" \
        -servername "${REALITY_SERVER_NAME}" \
        -tls1_3 \
        -alpn h2 </dev/null 2>&1)" || {
        printf '%s\n' "${probe_output}" >&2
        fail "Cannot complete a TLS 1.3 handshake with ${REALITY_TARGET}."
    }

    grep -Eq 'Protocol version: TLSv1\.3|Protocol[[:space:]]*: TLSv1\.3|New, TLSv1\.3' <<<"${probe_output}" \
        || fail "${REALITY_TARGET} did not negotiate TLS 1.3."
    grep -Eq 'Negotiated protocol: h2|ALPN protocol: h2' <<<"${probe_output}" \
        || fail "${REALITY_TARGET} did not negotiate HTTP/2 (h2)."
}

install_xray() {
    info "Installing Xray ${XRAY_VERSION} with the official XTLS installer"
    INSTALLER_FILE="$(mktemp)"
    curl --fail --location --proto '=https' --tlsv1.2 \
        --retry 5 --retry-delay 2 \
        --output "${INSTALLER_FILE}" "${XRAY_INSTALL_URL}"
    chmod 700 "${INSTALLER_FILE}"
    bash "${INSTALLER_FILE}" install --version "${XRAY_VERSION}" --without-geodata --without-logfiles
    [[ -x "${XRAY_BIN}" ]] || fail "The official installer did not create ${XRAY_BIN}."
}

generate_credentials() {
    local key_output

    UUID_VALUE="$(${XRAY_BIN} uuid | tr -d '\r\n')"
    [[ "${UUID_VALUE}" =~ ^[0-9a-fA-F-]{36}$ ]] || fail "Xray returned an invalid UUID."

    key_output="$(${XRAY_BIN} x25519)"
    REALITY_PRIVATE_KEY="$(awk -F': ' '/^PrivateKey:/ {print $2; exit}' <<<"${key_output}")"
    REALITY_PUBLIC_KEY="$(awk -F': ' '/^Password( \(PublicKey\))?:/ {print $2; exit}' <<<"${key_output}")"
    if [[ -z "${REALITY_PUBLIC_KEY}" ]]; then
        REALITY_PUBLIC_KEY="$(awk -F': ' '/^PublicKey:/ {print $2; exit}' <<<"${key_output}")"
    fi

    [[ "${REALITY_PRIVATE_KEY}" =~ ^[A-Za-z0-9_-]{43}$ ]] || fail "Could not parse Xray's REALITY private key."
    [[ "${REALITY_PUBLIC_KEY}" =~ ^[A-Za-z0-9_-]{43}$ ]] || fail "Could not parse Xray's REALITY client key."

    REALITY_SHORT_ID="$(openssl rand -hex 8)"
    [[ "${REALITY_SHORT_ID}" =~ ^[0-9a-f]{16}$ ]] || fail "Could not generate a REALITY short ID."
}

write_xray_config() {
    info "Writing and validating the Xray configuration"
    install -d -m 755 "${XRAY_CONFIG_DIR}"

    if [[ -s "${XRAY_CONFIG}" ]] && ! jq -e 'length == 0' "${XRAY_CONFIG}" >/dev/null 2>&1; then
        cp -a "${XRAY_CONFIG}" "${XRAY_CONFIG}.backup.$(date -u +%Y%m%dT%H%M%SZ)"
    fi

    CONFIG_TEMP="$(mktemp)"
    jq -n \
        --argjson port "${PORT}" \
        --arg uuid "${UUID_VALUE}" \
        --arg target "${REALITY_TARGET}" \
        --arg server_name "${REALITY_SERVER_NAME}" \
        --arg private_key "${REALITY_PRIVATE_KEY}" \
        --arg short_id "${REALITY_SHORT_ID}" \
        '{
            log: {
                loglevel: "warning"
            },
            inbounds: [
                {
                    tag: "vless-reality-in",
                    listen: "0.0.0.0",
                    port: $port,
                    protocol: "vless",
                    settings: {
                        users: [
                            {
                                id: $uuid,
                                flow: "xtls-rprx-vision",
                                email: "joe-test"
                            }
                        ],
                        decryption: "none"
                    },
                    streamSettings: {
                        network: "raw",
                        security: "reality",
                        realitySettings: {
                            show: false,
                            target: $target,
                            xver: 0,
                            serverNames: [$server_name],
                            privateKey: $private_key,
                            minClientVer: "0.0.0",
                            maxClientVer: "",
                            maxTimeDiff: 0,
                            shortIds: [$short_id]
                        }
                    },
                    sniffing: {
                        enabled: true,
                        destOverride: ["http", "tls", "quic"],
                        routeOnly: true
                    }
                }
            ],
            outbounds: [
                {
                    tag: "direct",
                    protocol: "freedom"
                }
            ]
        }' >"${CONFIG_TEMP}"

    jq -e . "${CONFIG_TEMP}" >/dev/null
    install -m 640 -o root -g nogroup "${CONFIG_TEMP}" "${XRAY_CONFIG}"
    "${XRAY_BIN}" run -test -config "${XRAY_CONFIG}"
}

start_xray() {
    info "Starting Xray"
    systemctl daemon-reload
    systemctl enable xray.service >/dev/null
    systemctl restart xray.service
    sleep 1
    systemctl is-active --quiet xray.service || fail "Xray did not remain active."
    ss -H -ltn "sport = :${PORT}" | grep -q . || fail "Xray is active but is not listening on TCP port ${PORT}."
}

detect_server_address() {
    if [[ -n "${SERVER_ADDRESS}" ]]; then
        return
    fi

    # Prefer DigitalOcean's link-local metadata API. The public service is only
    # a fallback, which also keeps the script useful on a non-DigitalOcean VPS.
    SERVER_ADDRESS="$(curl --fail --silent --show-error --max-time 3 \
        http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address 2>/dev/null || true)"
    if [[ -z "${SERVER_ADDRESS}" ]]; then
        SERVER_ADDRESS="$(curl -4 --fail --silent --show-error --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    fi
    if [[ -z "${SERVER_ADDRESS}" ]]; then
        SERVER_ADDRESS="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}')"
    fi
    [[ -n "${SERVER_ADDRESS}" ]] || fail "Could not detect the server address. Re-run with SERVER_ADDRESS set."
    [[ "${SERVER_ADDRESS}" =~ ^[A-Za-z0-9.:-]+$ ]] || fail "The detected SERVER_ADDRESS is invalid."
}

write_result() {
    local uri_host="${SERVER_ADDRESS}"
    local encoded_name
    local xray_version_line

    if [[ "${uri_host}" == *:* && "${uri_host}" != \[*\] ]]; then
        uri_host="[${uri_host}]"
    fi
    encoded_name="Joe-Test"

    # `type=tcp` remains the broadly compatible URI spelling for Xray's RAW
    # transport. Joe consumes the structured fields below, not this URI.
    VLESS_URI="vless://${UUID_VALUE}@${uri_host}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SERVER_NAME}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp#${encoded_name}"
    xray_version_line="$(${XRAY_BIN} -version)"
    xray_version_line="${xray_version_line%%$'\n'*}"

    {
        printf '%s\n' "Joe test server is ready."
        printf '\n%s\n' "Joe configuration"
        printf '%-20s %s\n' "host:" "${SERVER_ADDRESS}"
        printf '%-20s %s\n' "port:" "${PORT}"
        printf '%-20s %s\n' "uuid:" "${UUID_VALUE}"
        printf '%-20s %s\n' "serverName:" "${REALITY_SERVER_NAME}"
        printf '%-20s %s\n' "realityPublicKey:" "${REALITY_PUBLIC_KEY}"
        printf '%-20s %s\n' "realityShortID:" "${REALITY_SHORT_ID}"
        printf '%-20s %s\n' "transport:" "RAW"
        printf '%-20s %s\n' "flow:" "xtls-rprx-vision"
        printf '\n%s\n%s\n' "Compatible VLESS URI" "${VLESS_URI}"
        printf '\n%s\n' "Server status"
        printf '%-20s %s\n' "Xray:" "${xray_version_line}"
        printf '%-20s %s\n' "systemd:" "active and enabled"
        printf '%-20s %s\n' "config:" "${XRAY_CONFIG}"
        printf '%-20s %s\n' "saved result:" "${RESULT_FILE}"
    } | tee "${RESULT_FILE}"
    chmod 600 "${RESULT_FILE}"
}

report_firewall_state() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        printf '\nNote: UFW is active. This script did not change it; ensure TCP %s is already allowed.\n' "${PORT}"
    fi
    printf '%s\n' "DigitalOcean Cloud Firewall settings, if one is attached, must be checked in the DigitalOcean control panel."
}

main() {
    validate_environment
    install_prerequisites
    check_port_available
    check_reality_target
    install_xray
    generate_credentials
    write_xray_config
    start_xray
    detect_server_address
    write_result
    report_firewall_state
}

main "$@"
