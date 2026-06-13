#!/usr/bin/env bash
# IPv6 Lab — 201 (Experienced)
# Concepts: DHCPv6, Prefix Delegation, ip6tables, RA Guard, PMTU, 6in4 tunnel, AAAA DNS
# Usage: sudo ./ipv6lab-201.sh [--mode single|dual] [--role router|client] [--teardown]
#
# Optional HE tunnel env vars (201 only):
#   HE_SERVER=<tunnel server IPv4>
#   HE_LOCAL_V4=<your Pi's public IPv4>
#   HE_CLIENT_V6=<your HE /128, e.g. 2001:db8:1::/128>

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
DNSMASQ_CONF=/tmp/ipv6lab-dnsmasq.conf
DNSMASQ_PID=/tmp/ipv6lab-dnsmasq.pid
IP6TABLES_BACKUP=/tmp/ipv6lab-ip6tables.bak
LAB_NS=lab-client
VETH_RTR=veth-rtr
VETH_CLIENT=veth-client
ULA_PREFIX="fd00:cafe:1::/64"
ULA_PD_POOL="fd00:cafe:1:0100::/56"
ROUTER_ADDR="fd00:cafe:1::1"
ROUTER_LL="fe80::1"
LAB_DOMAIN="ipv6lab.local"

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
${BOLD}IPv6 Lab 201${RESET} — DHCPv6, ip6tables, RA Guard, PMTU, 6in4

Usage:
  sudo $0                              # single-Pi mode
  sudo $0 --mode dual --role router    # two-Pi: run on router Pi first
  sudo $0 --mode dual --role client    # two-Pi: run on client Pi after
  sudo $0 --teardown                   # undo everything

Optional HE tunnel:
  export HE_SERVER=216.66.80.90
  export HE_LOCAL_V4=<your Pi's public IPv4>
  export HE_CLIENT_V6=<your /128 from HE>
  sudo $0
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

# Raspberry Pi OS Bookworm uses nftables backend; detect and alias
detect_ip6tables() {
    if ip6tables --version 2>/dev/null | grep -q nft; then
        IP6TABLES=ip6tables-legacy
        IP6TABLES_SAVE=ip6tables-legacy-save
        IP6TABLES_RESTORE=ip6tables-legacy-restore
        warn "Detected nftables backend — using ip6tables-legacy"
    else
        IP6TABLES=ip6tables
        IP6TABLES_SAVE=ip6tables-save
        IP6TABLES_RESTORE=ip6tables-restore
    fi
    export IP6TABLES IP6TABLES_SAVE IP6TABLES_RESTORE
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
    sysctl -qw net.ipv6.conf.all.accept_ra=2
    sysctl -qw "net.ipv6.conf.${iface}.forwarding=1" 2>/dev/null || true
    log "IPv6 forwarding enabled"
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
        log "veth pair: $VETH_RTR ↔ $VETH_CLIENT"
    else
        warn "veth $VETH_RTR exists — skipping"
    fi

    ip link set "$VETH_RTR" up
    ip netns exec "$LAB_NS" ip link set "$VETH_CLIENT" up
    ip netns exec "$LAB_NS" ip link set lo up

    state_write LAB_NS "$LAB_NS"
    state_write LAB_VETH_RTR "$VETH_RTR"
    state_write LAB_VETH_CLIENT "$VETH_CLIENT"
}

assign_router_address() {
    ip addr add "${ROUTER_ADDR}/64" dev "$VETH_RTR" 2>/dev/null || true
    ip addr add "${ROUTER_LL}/64" dev "$VETH_RTR" 2>/dev/null || true
    log "Router: ${ROUTER_ADDR}/64 and ${ROUTER_LL}/64 on $VETH_RTR"
}

# ─── Dual-Mode ────────────────────────────────────────────────────────────────
detect_primary_iface() {
    if [[ -n "${LAB_IFACE:-}" ]]; then
        echo "$LAB_IFACE"; return
    fi
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
    log "Router address ${ROUTER_ADDR}/64 on $iface"
    info "Now run '$0 --mode dual --role client' on the second Pi"
    read -r -p "Press Enter when client Pi is ready..."
}

setup_dual_client() {
    local iface=$1
    sysctl -qw "net.ipv6.conf.${iface}.accept_ra=1"
    sysctl -qw "net.ipv6.conf.${iface}.autoconf=1"
    state_write LAB_IFACE "$iface"
    log "Client $iface configured for SLAAC + DHCPv6"
}

# ─── dnsmasq (DHCPv6 + RA) ───────────────────────────────────────────────────
fix_systemd_resolved() {
    # Disable systemd-resolved stub listener if it's occupying port 53
    if ss -ulnp 2>/dev/null | grep -q ':53 ' && systemctl is-active systemd-resolved &>/dev/null; then
        warn "systemd-resolved is occupying port 53 — stopping stub listener"
        mkdir -p /etc/systemd/resolved.conf.d
        cat > /etc/systemd/resolved.conf.d/no-stub.conf <<'EOF'
[Resolve]
DNSStubListener=no
EOF
        systemctl restart systemd-resolved
        state_write RESOLVED_STUB_FIXED 1
        log "systemd-resolved stub listener disabled"
    fi
}

write_dnsmasq_conf() {
    local iface=$1
    cat > "$DNSMASQ_CONF" <<EOF
# dnsmasq config — IPv6 Lab 201
# Handles DHCPv6 stateful + RA emission (replaces radvd)

interface=${iface}
bind-interfaces
except-interface=lo

# DHCPv6 stateful: hand out addresses in ::100-::1ff range
dhcp-range=::100,::1ff,constructor:${iface},slaac,64,1h

# Send RAs (replaces radvd in 201)
enable-ra

# RDNSS: point clients to this router for DNS
dhcp-option=option6:dns-server,[${ROUTER_ADDR}]
dhcp-option=option6:domain-search,${LAB_DOMAIN}

# AAAA records
address=/router.${LAB_DOMAIN}/${ROUTER_ADDR}

# Log DHCPv6 activity
log-dhcp
log-facility=/tmp/ipv6lab-dnsmasq.log
EOF
    state_write DNSMASQ_CONF "$DNSMASQ_CONF"
    log "dnsmasq config written (DHCPv6 stateful + RA + AAAA)"
}

start_dnsmasq() {
    # Kill previous instance
    if [[ -f "$DNSMASQ_PID" ]]; then
        local pid; pid=$(cat "$DNSMASQ_PID" 2>/dev/null || echo "")
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
        rm -f "$DNSMASQ_PID"
    fi
    pkill -f "dnsmasq.*$DNSMASQ_CONF" 2>/dev/null || true
    sleep 1

    fix_systemd_resolved

    dnsmasq -C "$DNSMASQ_CONF" --pid-file="$DNSMASQ_PID" --keep-in-foreground &
    state_write DNSMASQ_PID "$DNSMASQ_PID"
    sleep 2

    if kill -0 "$(cat $DNSMASQ_PID 2>/dev/null)" 2>/dev/null; then
        log "dnsmasq running (PID $(cat $DNSMASQ_PID)) — DHCPv6 + RA on $VETH_RTR"
    else
        warn "dnsmasq may have failed — check: dnsmasq -C $DNSMASQ_CONF --test"
        die "dnsmasq failed to start"
    fi
}

# ─── SLAAC + DHCPv6 Verification ──────────────────────────────────────────────
wait_for_slaac() {
    local ns=$1 iface=$2 timeout=$3
    local elapsed=0
    info "Waiting for SLAAC/DHCPv6 address on ${iface} (up to ${timeout}s)..."
    while [[ $elapsed -lt $timeout ]]; do
        local addr
        if [[ -n "$ns" ]]; then
            addr=$(ip netns exec "$ns" ip -6 addr show dev "$iface" scope global 2>/dev/null | grep -oP '(?<=inet6 )[^/]+' | head -1)
        else
            addr=$(ip -6 addr show dev "$iface" scope global 2>/dev/null | grep -oP '(?<=inet6 )[^/]+' | head -1)
        fi
        if [[ -n "$addr" ]]; then
            log "Address acquired: $addr"
            CLIENT_SLAAC_ADDR="$addr"
            return 0
        fi
        sleep 2; ((elapsed+=2)); echo -n "."
    done
    echo ""; return 1
}

verify_dhcpv6_client() {
    hdr "DHCPv6 Stateful Client"
    info "Requesting DHCPv6 lease on client side..."

    if [[ "$MODE" == "single" ]]; then
        # Run dhclient in namespace; timeout after 10s
        ip netns exec "$LAB_NS" timeout 10 dhclient -6 -v "$VETH_CLIENT" 2>&1 | \
            grep -E '(DHCP6|REPLY|T1|T2|iaaddr|DNS)' || true

        # Show resulting addresses
        local addrs
        addrs=$(ip netns exec "$LAB_NS" ip -6 addr show dev "$VETH_CLIENT" scope global 2>/dev/null)
        if [[ -n "$addrs" ]]; then
            log "DHCPv6 addresses on client:"
            echo "$addrs"
        else
            warn "No DHCPv6 address — SLAAC may still be active. Check: ip netns exec $LAB_NS ip -6 addr show"
        fi
    else
        local iface; iface=$(state_read LAB_IFACE)
        timeout 10 dhclient -6 -v "$iface" 2>&1 | \
            grep -E '(DHCP6|REPLY|T1|T2|iaaddr|DNS)' || true
    fi
}

# ─── Prefix Delegation Demo ───────────────────────────────────────────────────
demo_prefix_delegation() {
    hdr "Prefix Delegation (PD) Demo"
    info "Scenario: ISP gives a /56 to the router. Router sub-delegates a /64 to a downstream network."

    echo -e "${CYAN}Pool: $ULA_PD_POOL${RESET}"
    echo ""
    echo "  ISP                     Home Router (this Pi)         LAN (client ns)"
    echo "  ──────────────────────  ─────────────────────────     ──────────────────"
    echo "  delegates /56 →         carves out /64 →              assigns /128 via SLAAC"
    echo "  $ULA_PD_POOL    fd00:cafe:1:0100::/64"
    echo ""

    if [[ "$MODE" == "single" ]]; then
        # Simulate: add a dummy interface in the client ns to represent a downstream LAN
        ip netns exec "$LAB_NS" ip link add dummy0 type dummy 2>/dev/null || true
        ip netns exec "$LAB_NS" ip link set dummy0 up
        ip netns exec "$LAB_NS" ip addr add "fd00:cafe:1:0100::1/64" dev dummy0 2>/dev/null || true
        state_write PD_DUMMY_CREATED 1

        log "Client simulated downstream LAN: fd00:cafe:1:0100::1/64 on dummy0"
        info "This mimics a CPE router delegating a /64 from its /56 to the home LAN"

        echo ""
        echo -e "${BOLD}Client ns interfaces after PD simulation:${RESET}"
        ip netns exec "$LAB_NS" ip -6 addr show
    fi
}

# ─── ip6tables ────────────────────────────────────────────────────────────────
backup_ip6tables() {
    $IP6TABLES_SAVE > "$IP6TABLES_BACKUP"
    state_write IP6TABLES_BACKUP "$IP6TABLES_BACKUP"
    log "ip6tables ruleset backed up to $IP6TABLES_BACKUP"
}

apply_ip6tables_ruleset() {
    hdr "ip6tables Ruleset (RFC 4890 minimum ICMPv6)"

    # Default policies
    $IP6TABLES -P INPUT DROP
    $IP6TABLES -P FORWARD DROP
    $IP6TABLES -P OUTPUT ACCEPT

    # Allow established/related
    $IP6TABLES -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    # ICMPv6 types required by RFC 4890 — NEVER block these on a real device
    local icmp_types=(
        "133:Router Solicitation"
        "134:Router Advertisement"
        "135:Neighbor Solicitation"
        "136:Neighbor Advertisement"
        "128:Echo Request"
        "129:Echo Reply"
        "143:MLD Report v2"
    )
    for entry in "${icmp_types[@]}"; do
        local type="${entry%%:*}" name="${entry##*:}"
        $IP6TABLES -A INPUT  -p icmpv6 --icmpv6-type "$type" -j ACCEPT
        $IP6TABLES -A FORWARD -p icmpv6 --icmpv6-type "$type" -j ACCEPT
        log "ICMPv6 type $type ($name) allowed"
    done

    # DHCPv6 server port
    $IP6TABLES -A INPUT -p udp --dport 547 -j ACCEPT

    # Allow forwarding through namespace link
    if [[ "$MODE" == "single" ]]; then
        $IP6TABLES -A FORWARD -i "$VETH_RTR" -j ACCEPT
        $IP6TABLES -A FORWARD -o "$VETH_RTR" -j ACCEPT
    fi

    # Loopback
    $IP6TABLES -A INPUT -i lo -j ACCEPT

    log "ip6tables applied: DROP-default + ICMPv6 minimum set + DHCPv6"

    echo ""
    echo -e "${BOLD}Current ip6tables INPUT chain:${RESET}"
    $IP6TABLES -L INPUT -n --line-numbers 2>/dev/null
}

restore_ip6tables() {
    if [[ -f "${IP6TABLES_BACKUP:-}" ]]; then
        $IP6TABLES_RESTORE < "$IP6TABLES_BACKUP" && log "ip6tables restored" || true
        rm -f "$IP6TABLES_BACKUP"
    fi
}

# ─── RA Guard Demo ────────────────────────────────────────────────────────────
demo_ra_guard() {
    hdr "RA Guard Demo"
    info "RA Guard blocks unsolicited Router Advertisements to prevent rogue router attacks."
    echo ""

    if [[ "$MODE" != "single" ]]; then
        info "RA Guard demo only available in single mode (requires namespace control)"
        return
    fi

    # Ensure ip6_tables module is loaded in client namespace context
    modprobe ip6_tables 2>/dev/null || true

    info "Step 1: Show current default route in client ns (set by RA)"
    ip netns exec "$LAB_NS" ip -6 route show | grep -E 'default|fd00' || echo "  (no routes)"

    info "Step 2: Block ICMPv6 type 134 (Router Advertisement) in client ns"
    ip netns exec "$LAB_NS" ip6tables -A INPUT -p icmpv6 --icmpv6-type 134 -j DROP 2>/dev/null && \
        log "RA Guard rule applied in client namespace" || \
        warn "ip6tables in namespace requires ip6_tables module — skipping RA Guard demo"

    info "Step 3: Force a new RA from router (kill -HUP radvd pid)"
    local radvd_pid
    radvd_pid=$(pgrep -f "radvd -C $DNSMASQ_CONF" 2>/dev/null || pgrep radvd 2>/dev/null || echo "")
    if [[ -n "$radvd_pid" ]]; then
        kill -HUP "$radvd_pid" 2>/dev/null || true
    fi
    # dnsmasq sends RAs periodically; wait a few seconds
    sleep 4

    info "Step 4: Verify routes did NOT update (RA was blocked)"
    echo -e "${BOLD}Routes after blocking RAs:${RESET}"
    ip netns exec "$LAB_NS" ip -6 route show | grep -E 'default|fd00' || echo "  (no routes — RA Guard worked)"

    info "Step 5: Removing RA Guard rule"
    ip netns exec "$LAB_NS" ip6tables -D INPUT -p icmpv6 --icmpv6-type 134 -j DROP 2>/dev/null || true
    log "RA Guard demo complete. In production: this is a switch-level feature (802.1Q / RFC 6105)"
}

# ─── PMTU Demo ────────────────────────────────────────────────────────────────
demo_pmtu() {
    hdr "Path MTU Discovery (PMTU) Demo"
    info "IPv6 does NOT allow routers to fragment packets. PMTU relies on ICMPv6 Packet Too Big (type 2)."
    echo ""

    if [[ "$MODE" != "single" ]]; then
        info "PMTU MTU manipulation demo only available in single mode"
        return
    fi

    local orig_mtu
    orig_mtu=$(ip link show "$VETH_RTR" | grep -oP 'mtu \K[0-9]+' | head -1)

    info "Step 1: Set veth-rtr MTU to 1280 (minimum valid IPv6 MTU per RFC 8200)"
    ip link set "$VETH_RTR" mtu 1280
    ip netns exec "$LAB_NS" ip link set "$VETH_CLIENT" mtu 1280

    info "Step 2: ping6 with 1400-byte payload (exceeds MTU) — expect failure or PTB"
    echo -e "${BOLD}ping6 -s 1400 -c 2 ${ROUTER_ADDR} (should fail):${RESET}"
    ip netns exec "$LAB_NS" ping6 -s 1400 -c 2 -W 3 "$ROUTER_ADDR" 2>&1 || true

    info "Step 3: ping6 with 1232-byte payload (1280 MTU - 48 headers) — expect success"
    echo -e "${BOLD}ping6 -s 1232 -c 3 ${ROUTER_ADDR} (should succeed):${RESET}"
    ip netns exec "$LAB_NS" ping6 -s 1232 -c 3 -W 3 "$ROUTER_ADDR" 2>&1 && log "PASS" || warn "FAIL (unexpected)"

    info "Step 4: Restore MTU to $orig_mtu"
    ip link set "$VETH_RTR" mtu "$orig_mtu"
    ip netns exec "$LAB_NS" ip link set "$VETH_CLIENT" mtu "$orig_mtu"
    log "MTU restored to $orig_mtu"

    echo -e "\n${CYAN}Key: IPv6 hosts discover PMTU via ICMPv6 type 2 (Packet Too Big). Blocking ICMPv6 type 2 breaks large transfers silently.${RESET}"
}

# ─── Hurricane Electric 6in4 Tunnel ──────────────────────────────────────────
setup_he_tunnel() {
    hdr "Hurricane Electric 6in4 Tunnel (Optional)"

    if [[ -z "${HE_SERVER:-}" || -z "${HE_LOCAL_V4:-}" || -z "${HE_CLIENT_V6:-}" ]]; then
        info "HE tunnel env vars not set — skipping."
        info "To enable: export HE_SERVER=<ip> HE_LOCAL_V4=<your-ipv4> HE_CLIENT_V6=<he-/128>"
        return
    fi

    info "Creating 6in4 tunnel to HE server $HE_SERVER..."
    ip tunnel add he-ipv6 mode sit remote "$HE_SERVER" local "$HE_LOCAL_V4" ttl 255
    ip link set he-ipv6 up
    ip addr add "${HE_CLIENT_V6}" dev he-ipv6
    ip route add ::/0 dev he-ipv6 metric 1

    state_write HE_TUNNEL he-ipv6
    log "6in4 tunnel 'he-ipv6' created"

    info "Testing global IPv6 reachability..."
    if ping6 -c 3 -W 5 2001:4860:4860::8888 &>/dev/null; then
        log "Global IPv6 reachable via HE tunnel (Google DNS 2001:4860:4860::8888)"
    else
        warn "Cannot reach 2001:4860:4860::8888 — check HE credentials and NAT/firewall"
    fi
}

teardown_he_tunnel() {
    if [[ -n "${HE_TUNNEL:-}" ]]; then
        ip route del ::/0 dev "$HE_TUNNEL" 2>/dev/null || true
        ip tunnel del "$HE_TUNNEL" 2>/dev/null && log "HE tunnel removed" || true
    fi
}

# ─── DNS AAAA Demo ────────────────────────────────────────────────────────────
demo_dns_aaaa() {
    hdr "AAAA DNS Record Demo"
    info "dnsmasq is serving AAAA records for $LAB_DOMAIN"

    if [[ "$MODE" == "single" ]]; then
        # Add client's SLAAC addr as AAAA record dynamically
        if [[ -n "${CLIENT_SLAAC_ADDR:-}" ]]; then
            # dnsmasq dynamic address injection via DHCP hostname is complex;
            # demonstrate with a static query to the router's address
            info "Querying router.${LAB_DOMAIN} AAAA from client namespace:"
            ip netns exec "$LAB_NS" \
                dig +short AAAA "router.${LAB_DOMAIN}" "@${ROUTER_ADDR}" 2>/dev/null || \
                warn "dig not available — install dnsutils"

            log "Expected answer: ${ROUTER_ADDR}"
            echo ""
            info "In production: AAAA records work identically to A records — same DNS wire protocol (RFC 1035)"
            info "Dual-stack hosts publish both A and AAAA; DNS64 synthesises AAAA when only A exists (RFC 6147)"
        fi
    fi
}

# ─── Ping Tests ───────────────────────────────────────────────────────────────
run_ping_tests() {
    hdr "Connectivity Tests"
    local pass=0 fail=0

    ping_test() {
        local label=$1 cmd=$2
        info "Testing: $label"
        if eval "$cmd" &>/dev/null; then
            log "PASS — $label"; ((pass++))
        else
            warn "FAIL — $label"; ((fail++))
        fi
    }

    if [[ "$MODE" == "single" ]]; then
        ping_test "Loopback ::1 in client ns" \
            "ip netns exec $LAB_NS ping6 -c 3 -W 2 ::1"
        ping_test "Router link-local from client ns" \
            "ip netns exec $LAB_NS ping6 -c 3 -W 2 -I $VETH_CLIENT ${ROUTER_LL}%${VETH_CLIENT}"
        ping_test "Router ULA ($ROUTER_ADDR) from client ns" \
            "ip netns exec $LAB_NS ping6 -c 3 -W 2 $ROUTER_ADDR"
        if [[ -n "${CLIENT_SLAAC_ADDR:-}" ]]; then
            ping_test "Client addr ($CLIENT_SLAAC_ADDR) from default ns" \
                "ping6 -c 3 -W 2 $CLIENT_SLAAC_ADDR"
        fi
    else
        local iface; iface=$(state_read LAB_IFACE)
        ping_test "Router ULA ($ROUTER_ADDR)" "ping6 -c 3 -W 2 -I $iface $ROUTER_ADDR"
    fi

    echo ""
    log "Results: ${pass} passed, ${fail} failed"
}

# ─── NDP Cache ────────────────────────────────────────────────────────────────
show_ndp_cache() {
    hdr "NDP Neighbour Cache"
    echo -e "${BOLD}Default namespace:${RESET}"
    ip -6 neigh show 2>/dev/null || echo "  (empty)"
    if [[ "$MODE" == "single" ]]; then
        echo -e "\n${BOLD}Client namespace:${RESET}"
        ip netns exec "$LAB_NS" ip -6 neigh show 2>/dev/null || echo "  (empty)"
    fi
}

# ─── Summary ──────────────────────────────────────────────────────────────────
print_summary_201() {
    hdr "Lab Summary — 201 Concepts Covered"
    printf "\n${BOLD}%-32s │ %-55s${RESET}\n" "Lab Component" "Real-World Use Case"
    printf "%-32s─┼─%-55s\n" "$(printf '%.0s─' {1..32})" "$(printf '%.0s─' {1..55})"

    row() { printf "%-32s │ %-55s\n" "$1" "$2"; }

    row "Network namespace + veth"     "Simulates router + host on a single device"
    row "fd00:cafe:1::/64 (ULA)"       "RFC 4193: private IPv6, never globally routed"
    row "dnsmasq RA + DHCPv6"          "Enterprise: stateful address assignment + audit trail"
    row "dhcp-range ::100-::1ff"       "Managed pool; devices also get SLAAC address"
    row "Prefix Delegation /56→/64"    "ISP→CPE→LAN model (RFC 3633); all home routers do this"
    row "ip6tables DROP-default"       "Production baseline; NEVER drop ICMPv6 NDP types"
    row "ICMPv6 type 135/136 allowed"  "NS/NA: mandatory for neighbour discovery (RFC 4890)"
    row "ICMPv6 type 2 (PTB)"          "Packet Too Big: required for PMTU — blocking causes BHTC"
    row "RA Guard (type 134 block)"    "Switch feature (RFC 6105) to stop rogue router attacks"
    row "MTU 1280 PMTU test"           "IPv6 min MTU; no router frag — end-to-end MTU signalling"
    row "6in4 tunnel (HE)"             "Transition tech: IPv6 over IPv4-only ISP uplink"
    row "AAAA + dnsmasq local DNS"     "Same DNS wire protocol as A; dual-stack apps query both"
    echo ""
    log "Lab 201 complete. Run with --teardown to clean up."
    info "For attack/defense scenarios, see CyberAcademy L3-AttackDefense."
}

# ─── Teardown ─────────────────────────────────────────────────────────────────
teardown_201() {
    hdr "Teardown (201)"
    [[ -f "$STATE_FILE" ]] || { warn "No state file found — nothing to undo"; return; }
    # shellcheck source=/dev/null
    source "$STATE_FILE"

    # Kill dnsmasq
    if [[ -n "${DNSMASQ_PID:-}" && -f "${DNSMASQ_PID}" ]]; then
        local pid; pid=$(cat "$DNSMASQ_PID" 2>/dev/null || echo "")
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null && log "dnsmasq stopped" || true
        rm -f "$DNSMASQ_PID"
    fi
    pkill -f "dnsmasq.*$DNSMASQ_CONF" 2>/dev/null || true
    rm -f "${DNSMASQ_CONF:-}" /tmp/ipv6lab-dnsmasq.log 2>/dev/null || true

    # Restore ip6tables
    detect_ip6tables
    restore_ip6tables

    # HE tunnel
    teardown_he_tunnel

    # Remove PD dummy interface from client ns
    if [[ "${PD_DUMMY_CREATED:-}" == "1" ]]; then
        ip netns exec "$LAB_NS" ip link del dummy0 2>/dev/null && log "dummy0 removed from client ns" || true
    fi

    # Remove client namespace + veths
    if [[ -n "${LAB_NS:-}" ]] && ip netns list | grep -q "^${LAB_NS}"; then
        ip netns del "$LAB_NS" && log "Namespace $LAB_NS deleted" || true
    fi
    ip link del "${LAB_VETH_RTR:-$VETH_RTR}" 2>/dev/null && log "veth removed" || true

    # Dual: remove router address
    if [[ "${MODE:-}" == "dual" && -n "${LAB_IFACE:-}" ]]; then
        ip addr del "${ROUTER_ADDR}/64" dev "$LAB_IFACE" 2>/dev/null || true
    fi

    # Restore sysctl forwarding
    if [[ -n "${SYSCTL_ORIG_FORWARDING:-}" ]]; then
        sysctl -qw "net.ipv6.conf.all.forwarding=${SYSCTL_ORIG_FORWARDING}" && \
            log "Forwarding sysctl restored" || true
    fi

    # Restore systemd-resolved stub if we disabled it
    if [[ "${RESOLVED_STUB_FIXED:-}" == "1" ]]; then
        rm -f /etc/systemd/resolved.conf.d/no-stub.conf
        systemctl restart systemd-resolved 2>/dev/null || true
        log "systemd-resolved stub listener re-enabled"
    fi

    rm -f "$STATE_FILE"
    log "Teardown complete."
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    parse_args "$@"

    if [[ "$ACTION" == "teardown" ]]; then
        check_root "$@"
        [[ -f "$STATE_FILE" ]] && source "$STATE_FILE" || true
        detect_ip6tables
        teardown_201
        exit 0
    fi

    hdr "IPv6 Lab 201 — Mode: $MODE$([ "$MODE" = "dual" ] && echo " / Role: $ROLE")"

    check_root "$@"
    check_kernel_ipv6
    detect_ip6tables
    check_and_install iproute2 iputils-ping ndisc6 dnsmasq iptables dhclient dnsutils

    state_write SCRIPT_VERSION 201
    state_write MODE "$MODE"
    state_write ROLE "$ROLE"

    case "$MODE" in
        single)
            hdr "1/8 — Namespace + veth"
            setup_namespace
            assign_router_address
            enable_forwarding "$VETH_RTR"

            hdr "2/8 — dnsmasq (DHCPv6 Stateful + RA)"
            write_dnsmasq_conf "$VETH_RTR"
            start_dnsmasq

            hdr "3/8 — Address Acquisition"
            wait_for_slaac "$LAB_NS" "$VETH_CLIENT" 30 || \
                warn "SLAAC timeout — continuing anyway (DHCPv6 may still work)"
            verify_dhcpv6_client

            hdr "4/8 — Prefix Delegation Demo"
            demo_prefix_delegation

            hdr "5/8 — ip6tables Firewall"
            backup_ip6tables
            apply_ip6tables_ruleset

            run_ping_tests

            hdr "6/8 — RA Guard Demo"
            demo_ra_guard

            hdr "7/8 — PMTU Discovery Demo"
            demo_pmtu

            hdr "8/8 — DNS AAAA Records"
            demo_dns_aaaa

            setup_he_tunnel
            show_ndp_cache
            print_summary_201
            ;;

        dual)
            local iface; iface=$(detect_primary_iface)
            [[ -n "$iface" ]] || die "Could not detect interface — set LAB_IFACE=ethX"
            info "Using interface: $iface"

            case "$ROLE" in
                router)
                    enable_forwarding "$iface"
                    setup_dual_router "$iface"
                    write_dnsmasq_conf "$iface"
                    start_dnsmasq
                    backup_ip6tables
                    apply_ip6tables_ruleset
                    log "Router ready — advertising DHCPv6 + RA on $iface"
                    info "Run '$0 --mode dual --role client' on the second Pi"
                    ;;
                client)
                    setup_dual_client "$iface"
                    wait_for_slaac "" "$iface" 60 || die "SLAAC/DHCPv6 timeout"
                    verify_dhcpv6_client
                    run_ping_tests
                    show_ndp_cache
                    print_summary_201
                    ;;
            esac
            ;;
    esac
}

main "$@"
