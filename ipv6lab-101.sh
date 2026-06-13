#!/usr/bin/env bash
# IPv6 Lab — 101 (Beginner)
# Concepts: SLAAC, radvd, NDP, link-local, ULA, network namespaces
# Usage: sudo ./ipv6lab-101.sh [--mode single|dual] [--role router|client] [--teardown]

set -euo pipefail

# ─── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()  { echo -e "${GREEN}[✓]${RESET} $*"; }
info() { echo -e "${CYAN}[→]${RESET} $*"; }
warn() { echo -e "${YELLOW}[!]${RESET} $*"; }
die()  { echo -e "${RED}[✗]${RESET} $*" >&2; exit 1; }
hdr()  { echo -e "\n${BOLD}${CYAN}━━━ $* ━━━${RESET}"; }

# ─── Constants ────────────────────────────────────────────────────────────────
STATE_FILE=/tmp/ipv6lab-state.env
RADVD_CONF=/tmp/ipv6lab-radvd.conf
RADVD_PID=/tmp/ipv6lab-radvd.pid
LAB_NS=lab-client
VETH_RTR=veth-rtr
VETH_CLIENT=veth-client
ULA_PREFIX="fd00:cafe:1::/64"
ROUTER_ADDR="fd00:cafe:1::1"
ROUTER_LL="fe80::1"

# ─── Argument Parsing ─────────────────────────────────────────────────────────
MODE=single
ROLE=router
ACTION=setup

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode)    MODE="$2";   shift 2 ;;
            --role)    ROLE="$2";   shift 2 ;;
            --teardown) ACTION=teardown; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown argument: $1" ;;
        esac
    done
    [[ "$MODE" =~ ^(single|dual)$ ]]  || die "--mode must be single or dual"
    [[ "$ROLE" =~ ^(router|client)$ ]] || die "--role must be router or client"
    [[ "$MODE" == "single" ]] && ROLE=router
}

usage() {
    cat <<EOF
${BOLD}IPv6 Lab 101${RESET} — SLAAC, radvd, NDP fundamentals

Usage:
  sudo $0                              # single-Pi mode
  sudo $0 --mode dual --role router    # two-Pi: run on router Pi first
  sudo $0 --mode dual --role client    # two-Pi: run on client Pi after
  sudo $0 --teardown                   # undo everything

Environment (dual mode):
  LAB_IFACE=eth0   override the detected network interface
EOF
}

# ─── State File ───────────────────────────────────────────────────────────────
state_write() { echo "$1=$2" >> "$STATE_FILE"; }

state_read() {
    [[ -f "$STATE_FILE" ]] || return 1
    # shellcheck source=/dev/null
    source "$STATE_FILE"
    echo "${!1:-}"
}

# ─── Guards ───────────────────────────────────────────────────────────────────
check_root() {
    [[ $EUID -eq 0 ]] || die "Must run as root — use: sudo $0 $*"
}

check_kernel_ipv6() {
    [[ -f /proc/net/if_inet6 ]] || die "IPv6 is disabled in the kernel (ipv6.disable=1?)"
    info "Kernel IPv6 support confirmed"
}

# ─── Package Installation ─────────────────────────────────────────────────────
APT_UPDATED=0
check_and_install() {
    local pkgs_needed=()
    for pkg in "$@"; do
        if ! dpkg -s "$pkg" &>/dev/null 2>&1; then
            pkgs_needed+=("$pkg")
        fi
    done
    if [[ ${#pkgs_needed[@]} -gt 0 ]]; then
        warn "Installing missing packages: ${pkgs_needed[*]}"
        if [[ $APT_UPDATED -eq 0 ]]; then
            apt-get update -qq
            APT_UPDATED=1
        fi
        apt-get install -y -qq "${pkgs_needed[@]}"
        log "Packages installed: ${pkgs_needed[*]}"
    else
        log "All required packages present"
    fi
}

# ─── Forwarding ───────────────────────────────────────────────────────────────
enable_forwarding() {
    local iface=$1
    local orig
    orig=$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo 0)
    state_write SYSCTL_ORIG_FORWARDING "$orig"
    sysctl -qw net.ipv6.conf.all.forwarding=1
    # accept_ra=2 allows RAs even when forwarding is on (needed for dual-mode client detection)
    sysctl -qw net.ipv6.conf.all.accept_ra=2
    sysctl -qw "net.ipv6.conf.${iface}.forwarding=1" 2>/dev/null || true
    log "IPv6 forwarding enabled on all / $iface"
}

# ─── Single-Mode: Namespace + veth ────────────────────────────────────────────
setup_namespace() {
    if ip netns list | grep -q "^${LAB_NS}"; then
        warn "Namespace $LAB_NS already exists — skipping creation"
    else
        ip netns add "$LAB_NS"
        log "Namespace '$LAB_NS' created"
    fi

    if ! ip link show "$VETH_RTR" &>/dev/null; then
        ip link add "$VETH_RTR" type veth peer name "$VETH_CLIENT"
        ip link set "$VETH_CLIENT" netns "$LAB_NS"
        log "veth pair: $VETH_RTR (default ns) ↔ $VETH_CLIENT ($LAB_NS ns)"
    else
        warn "veth $VETH_RTR already exists — skipping"
    fi

    ip link set "$VETH_RTR" up
    ip netns exec "$LAB_NS" ip link set "$VETH_CLIENT" up
    ip netns exec "$LAB_NS" ip link set lo up

    state_write LAB_NS "$LAB_NS"
    state_write LAB_VETH_RTR "$VETH_RTR"
    state_write LAB_VETH_CLIENT "$VETH_CLIENT"
}

assign_router_address() {
    # Suppress error if address already assigned
    ip addr add "${ROUTER_ADDR}/64" dev "$VETH_RTR" 2>/dev/null || true
    # Explicit stable link-local so radvd/clients always know router's LL addr
    ip addr add "${ROUTER_LL}/64" dev "$VETH_RTR" 2>/dev/null || true
    log "Router addresses: ${ROUTER_ADDR}/64, ${ROUTER_LL}/64 on $VETH_RTR"
}

# ─── Dual-Mode: Physical Interface ────────────────────────────────────────────
detect_primary_iface() {
    if [[ -n "${LAB_IFACE:-}" ]]; then
        echo "$LAB_IFACE"; return
    fi
    # Prefer eth over wlan; exclude loopback
    ip -o link show up | awk -F': ' '
        $2 ~ /^eth/ { print $2; exit }
    ' || ip -o link show up | awk -F': ' '
        $2 != "lo" { print $2; exit }
    '
}

setup_dual_router() {
    local iface=$1
    ip addr add "${ROUTER_ADDR}/64" dev "$iface" 2>/dev/null || true
    state_write LAB_IFACE "$iface"
    log "Router address ${ROUTER_ADDR}/64 assigned to $iface"
    info "Now run this script with --mode dual --role client on the second Pi"
    read -r -p "Press Enter when the client Pi is ready..."
}

setup_dual_client() {
    local iface=$1
    sysctl -qw "net.ipv6.conf.${iface}.accept_ra=1"
    sysctl -qw "net.ipv6.conf.${iface}.autoconf=1"
    state_write LAB_IFACE "$iface"
    log "Client interface $iface configured for SLAAC"
}

# ─── radvd ────────────────────────────────────────────────────────────────────
write_radvd_conf() {
    local iface=$1 prefix=$2
    cat > "$RADVD_CONF" <<EOF
interface ${iface} {
    AdvSendAdvert on;
    AdvManagedFlag off;
    AdvOtherConfigFlag off;
    MinRtrAdvInterval 3;
    MaxRtrAdvInterval 10;
    AdvDefaultLifetime 1800;

    prefix ${prefix} {
        AdvOnLink on;
        AdvAutonomous on;
        AdvRouterAddr on;
        AdvPreferredLifetime 3600;
        AdvValidLifetime 7200;
    };
};
EOF
    state_write RADVD_CONF "$RADVD_CONF"
    log "radvd config written for $iface (prefix: $prefix)"
}

start_radvd() {
    # Kill any previous instance
    if [[ -f "$RADVD_PID" ]]; then
        local old_pid
        old_pid=$(cat "$RADVD_PID" 2>/dev/null || echo "")
        [[ -n "$old_pid" ]] && kill "$old_pid" 2>/dev/null || true
        rm -f "$RADVD_PID"
    fi
    pkill -f "radvd -C $RADVD_CONF" 2>/dev/null || true
    sleep 1

    radvd -C "$RADVD_CONF" -p "$RADVD_PID" -n &
    state_write RADVD_PID "$RADVD_PID"
    sleep 2

    if kill -0 "$(cat $RADVD_PID 2>/dev/null)" 2>/dev/null; then
        log "radvd running (PID $(cat $RADVD_PID))"
    else
        die "radvd failed to start — check: radvd -C $RADVD_CONF -d 5"
    fi
}

# ─── SLAAC Verification ───────────────────────────────────────────────────────
wait_for_slaac() {
    local ns=$1 iface=$2 timeout=$3
    local elapsed=0
    info "Waiting for SLAAC address on ${iface} (up to ${timeout}s)..."
    while [[ $elapsed -lt $timeout ]]; do
        local addr
        if [[ -n "$ns" ]]; then
            addr=$(ip netns exec "$ns" ip -6 addr show dev "$iface" scope global 2>/dev/null | grep -oP '(?<=inet6 )[^/]+' | head -1)
        else
            addr=$(ip -6 addr show dev "$iface" scope global 2>/dev/null | grep -oP '(?<=inet6 )[^/]+' | head -1)
        fi
        if [[ -n "$addr" ]]; then
            log "SLAAC address: $addr"
            CLIENT_SLAAC_ADDR="$addr"
            return 0
        fi
        sleep 2; ((elapsed+=2))
        echo -n "."
    done
    echo ""
    return 1
}

# ─── Ping Tests ───────────────────────────────────────────────────────────────
run_ping_tests() {
    hdr "Ping Tests"
    local pass=0 fail=0

    ping_test() {
        local label=$1 cmd=$2
        info "Testing: $label"
        if eval "$cmd" &>/dev/null; then
            log "PASS — $label"
            ((pass++))
        else
            warn "FAIL — $label"
            ((fail++))
        fi
    }

    if [[ "$MODE" == "single" ]]; then
        ping_test "Loopback (::1) in client ns" \
            "ip netns exec $LAB_NS ping6 -c 3 -W 2 ::1"

        ping_test "Router link-local from client ns" \
            "ip netns exec $LAB_NS ping6 -c 3 -W 2 -I $VETH_CLIENT ${ROUTER_LL}%${VETH_CLIENT}"

        ping_test "Router ULA ($ROUTER_ADDR) from client ns" \
            "ip netns exec $LAB_NS ping6 -c 3 -W 2 $ROUTER_ADDR"

        if [[ -n "${CLIENT_SLAAC_ADDR:-}" ]]; then
            ping_test "Client SLAAC addr ($CLIENT_SLAAC_ADDR) from default ns" \
                "ping6 -c 3 -W 2 $CLIENT_SLAAC_ADDR"
        fi
    else
        local iface; iface=$(state_read LAB_IFACE)
        ping_test "Router ULA ($ROUTER_ADDR)" \
            "ping6 -c 3 -W 2 -I $iface $ROUTER_ADDR"
        if [[ -n "${CLIENT_SLAAC_ADDR:-}" ]]; then
            ping_test "Self SLAAC addr ($CLIENT_SLAAC_ADDR)" \
                "ping6 -c 3 -W 2 $CLIENT_SLAAC_ADDR"
        fi
    fi

    echo ""
    log "Ping results: ${pass} passed, ${fail} failed"
}

# ─── NDP Cache ────────────────────────────────────────────────────────────────
show_ndp_cache() {
    hdr "NDP Neighbour Cache (IPv6 equivalent of ARP)"
    echo -e "${BOLD}Default namespace:${RESET}"
    ip -6 neigh show 2>/dev/null || echo "  (empty)"

    if [[ "$MODE" == "single" ]]; then
        echo -e "\n${BOLD}Client namespace ($LAB_NS):${RESET}"
        ip netns exec "$LAB_NS" ip -6 neigh show 2>/dev/null || echo "  (empty)"
    fi

    echo -e "\n${CYAN}NUD states: REACHABLE=confirmed, STALE=unconfirmed but cached, DELAY=probing${RESET}"
}

# ─── Summary ──────────────────────────────────────────────────────────────────
print_summary_101() {
    hdr "Lab Summary — What You Just Configured"
    printf "\n${BOLD}%-30s │ %-50s${RESET}\n" "Lab Component" "IPv6 Concept"
    printf "%-30s─┼─%-50s\n" "$(printf '%.0s─' {1..30})" "$(printf '%.0s─' {1..50})"

    row() { printf "%-30s │ %-50s\n" "$1" "$2"; }

    if [[ "$MODE" == "single" ]]; then
        row "Network namespace" "Simulates a separate router + host on one machine"
        row "veth pair" "Virtual point-to-point Ethernet link between them"
    else
        row "Physical interface" "Real L2 link between two Raspberry Pis"
    fi
    row "fd00:cafe:1::/64" "ULA prefix (RFC 4193) — never routed on the Internet"
    row "fe80::1/64" "Link-local address (RFC 4291) — mandatory, non-routable"
    row "radvd Router Advertisement" "NDP RA (RFC 4861) — tells hosts prefix + gateway"
    row "SLAAC EUI-64/privacy" "Stateless address autoconfiguration (RFC 4862)"
    row "NDP neighbour cache" "Replaces ARP for IPv6 — uses ICMPv6 NS/NA messages"
    row "::1" "IPv6 loopback (equivalent of 127.0.0.1)"
    echo ""
    log "Lab 101 complete. Run with --teardown to clean up."
    info "Next step: try ipv6lab-201.sh for DHCPv6, ip6tables, and RA Guard."
}

# ─── Teardown ─────────────────────────────────────────────────────────────────
teardown() {
    hdr "Teardown"
    [[ -f "$STATE_FILE" ]] || { warn "No state file found at $STATE_FILE — nothing to undo"; return; }
    # shellcheck source=/dev/null
    source "$STATE_FILE"

    # 1. Kill radvd
    if [[ -n "${RADVD_PID:-}" && -f "${RADVD_PID}" ]]; then
        local pid; pid=$(cat "$RADVD_PID" 2>/dev/null || echo "")
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null && log "radvd stopped" || true
        rm -f "$RADVD_PID"
    fi
    pkill -f "radvd -C $RADVD_CONF" 2>/dev/null || true

    # 2. Remove radvd config
    rm -f "${RADVD_CONF:-}" && log "radvd config removed" || true

    # 3. Delete namespace (also removes veth-client inside it)
    if [[ -n "${LAB_NS:-}" ]]; then
        if ip netns list | grep -q "^${LAB_NS}"; then
            ip netns del "$LAB_NS" && log "Namespace $LAB_NS deleted" || true
        fi
    fi

    # 4. Delete veth-rtr (if still present in default ns)
    if [[ -n "${LAB_VETH_RTR:-}" ]]; then
        ip link del "${LAB_VETH_RTR}" 2>/dev/null && log "veth $LAB_VETH_RTR removed" || true
    fi

    # 5. Dual mode: remove router address from physical iface
    if [[ "${MODE:-}" == "dual" && -n "${LAB_IFACE:-}" ]]; then
        ip addr del "${ROUTER_ADDR}/64" dev "$LAB_IFACE" 2>/dev/null && \
            log "Router address removed from $LAB_IFACE" || true
    fi

    # 6. Restore sysctl
    if [[ -n "${SYSCTL_ORIG_FORWARDING:-}" ]]; then
        sysctl -qw "net.ipv6.conf.all.forwarding=${SYSCTL_ORIG_FORWARDING}" && \
            log "IPv6 forwarding restored to ${SYSCTL_ORIG_FORWARDING}" || true
    fi

    # 7. Remove state file
    rm -f "$STATE_FILE"
    log "Teardown complete."
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    parse_args "$@"

    if [[ "$ACTION" == "teardown" ]]; then
        check_root "$@"
        # Source state to get original MODE if set
        [[ -f "$STATE_FILE" ]] && source "$STATE_FILE" || true
        teardown
        exit 0
    fi

    hdr "IPv6 Lab 101 — Mode: $MODE${MODE:+ }${MODE/single/}${MODE/single/}$([ "$MODE" = "dual" ] && echo "/ Role: $ROLE")"

    check_root "$@"
    check_kernel_ipv6
    check_and_install iproute2 radvd iputils-ping ndisc6

    state_write SCRIPT_VERSION 101
    state_write MODE "$MODE"
    state_write ROLE "$ROLE"

    case "$MODE" in
        single)
            hdr "Setting Up Namespace + veth Pair"
            setup_namespace
            assign_router_address
            enable_forwarding "$VETH_RTR"

            hdr "Configuring radvd (Router Advertisement Daemon)"
            write_radvd_conf "$VETH_RTR" "$ULA_PREFIX"
            start_radvd

            hdr "Waiting for SLAAC"
            wait_for_slaac "$LAB_NS" "$VETH_CLIENT" 30 || \
                die "SLAAC timeout — check: ip netns exec $LAB_NS ip -6 addr show"

            run_ping_tests
            show_ndp_cache
            print_summary_101
            ;;

        dual)
            local iface; iface=$(detect_primary_iface)
            [[ -n "$iface" ]] || die "Could not detect network interface — set LAB_IFACE=ethX"
            info "Using interface: $iface"

            case "$ROLE" in
                router)
                    hdr "Router Pi Setup"
                    enable_forwarding "$iface"
                    setup_dual_router "$iface"
                    write_radvd_conf "$iface" "$ULA_PREFIX"
                    start_radvd
                    log "Router is advertising prefix $ULA_PREFIX on $iface"
                    info "Run '$0 --mode dual --role client' on the second Pi now."
                    ;;
                client)
                    hdr "Client Pi Setup"
                    setup_dual_client "$iface"
                    wait_for_slaac "" "$iface" 60 || \
                        die "SLAAC timeout — is the router Pi running? Check: ip -6 addr show $iface"
                    run_ping_tests
                    show_ndp_cache
                    print_summary_101
                    ;;
            esac
            ;;
    esac
}

main "$@"
