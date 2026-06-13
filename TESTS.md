# Lab Tests & Use Cases

Run either script first, then use this guide to verify the lab is working and explore break-and-fix scenarios.

> All commands assume **single-Pi mode** (default). For dual-Pi mode, replace `ip netns exec lab-client` with a plain shell on the client Pi, and `veth-client` with your physical interface name.

---

## Lab 101 — SLAAC, radvd, NDP

### Prerequisites

```bash
sudo ./ipv6lab-101.sh   # must be running before these tests
```

---

### Verification Tests

#### 1. SLAAC address was assigned

```bash
ip netns exec lab-client ip -6 addr show dev veth-client
```

Expected: a `scope global` address in `fd00:cafe:1::/64`, plus a `fe80::` link-local.

```
2: veth-client: <...>
    inet6 fd00:cafe:1::XXXX:XXXX:XXXX:XXXX/64 scope global dynamic mngtmpaddr
    inet6 fe80::XXXX:XXXX:XXXX:XXXX/64 scope link
```

#### 2. Default route installed via Router Advertisement

```bash
ip netns exec lab-client ip -6 route show
```

Expected: a `default via fe80::1 dev veth-client` route — installed by radvd's RA.

#### 3. NDP neighbour cache is populated

```bash
# Router's view of the client
ip -6 neigh show dev veth-rtr

# Client's view of the router
ip netns exec lab-client ip -6 neigh show dev veth-client
```

Expected: at least one entry per side in `REACHABLE` or `STALE` state.

#### 4. Inspect RA contents (what radvd is actually sending)

```bash
# rdisc6 sends a Router Solicitation and prints the reply
ip netns exec lab-client rdisc6 veth-client
```

Expected output shows: prefix `fd00:cafe:1::/64`, valid/preferred lifetimes, router's link-local source address `fe80::1`.

#### 5. Link-local reachability

```bash
# Scope identifier (%veth-client) is mandatory for link-local pings
ip netns exec lab-client ping6 -c 3 fe80::1%veth-client
```

#### 6. ULA reachability

```bash
ip netns exec lab-client ping6 -c 3 fd00:cafe:1::1
```

#### 7. Bidirectional — ping client from router side

```bash
# Get the client's SLAAC address
CLIENT=$(ip netns exec lab-client ip -6 addr show dev veth-client scope global \
  | grep -oP '(?<=inet6 )[^/]+' | head -1)
ping6 -c 3 "$CLIENT"
```

#### 8. NDP NS/NA exchange — manual resolution

```bash
# Force a Neighbour Solicitation and print the Neighbour Advertisement
ip netns exec lab-client ndisc6 fd00:cafe:1::1 veth-client
```

Expected: the router's MAC address and link-layer address.

---

### Break-and-Fix Scenarios

#### Scenario A — Kill radvd: watch the address deprecate and disappear

**Concept:** SLAAC addresses have a lifetime. Without periodic RAs, they expire.

```bash
# 1. Watch the client address in real time (run in a separate terminal)
watch -n 2 'ip netns exec lab-client ip -6 addr show dev veth-client'

# 2. Kill radvd
kill "$(cat /tmp/ipv6lab-radvd.pid)"
```

**Observe:** after `AdvPreferredLifetime` (3600s by default) the address transitions to `DEPRECATED`. After `AdvValidLifetime` (7200s) it disappears entirely. New connections refuse to use a deprecated address.

```bash
# Fix: restart radvd
radvd -C /tmp/ipv6lab-radvd.conf -p /tmp/ipv6lab-radvd.pid -n &

# A new RA is sent within MaxRtrAdvInterval (10s); address renews
```

---

#### Scenario B — RA Guard: block Router Advertisements on the client

**Concept:** a rogue router can hijack traffic by sending unsolicited RAs. RA Guard (RFC 6105) drops them at the switch. Here we simulate it with ip6tables.

```bash
# 1. Block ICMPv6 type 134 (Router Advertisement) arriving at the client
ip netns exec lab-client ip6tables -A INPUT -p icmpv6 --icmpv6-type 134 -j DROP

# 2. Force radvd to send an immediate RA
kill -HUP "$(cat /tmp/ipv6lab-radvd.pid)"
sleep 5

# 3. Check: default route should NOT be updated (timestamp won't change)
ip netns exec lab-client ip -6 route show
```

**Observe:** the existing default route's expiry stops refreshing. If you wait long enough it disappears — the host can no longer reach the router.

```bash
# Fix: remove the RA Guard rule
ip netns exec lab-client ip6tables -D INPUT -p icmpv6 --icmpv6-type 134 -j DROP
kill -HUP "$(cat /tmp/ipv6lab-radvd.pid)"
```

---

#### Scenario C — Break NDP: block Neighbour Solicitation (type 135)

**Concept:** ICMPv6 NS/NA is the ARP replacement. Blocking type 135 silently breaks connectivity even though addresses are still configured.

```bash
# 1. Confirm ping works
ip netns exec lab-client ping6 -c 2 fd00:cafe:1::1

# 2. Block NS on the router side (drop what arrives from client)
ip6tables -A INPUT -p icmpv6 --icmpv6-type 135 -j DROP

# 3. Flush the NDP cache so a new resolution is needed
ip -6 neigh flush dev veth-rtr

# 4. Try to ping again — should fail or hang
ip netns exec lab-client ping6 -c 3 -W 2 fd00:cafe:1::1
```

**Observe:** ping fails even though the address `fd00:cafe:1::1` is locally assigned — NDP can't resolve the link-layer address.

```bash
# Fix:
ip6tables -D INPUT -p icmpv6 --icmpv6-type 135 -j DROP
```

---

#### Scenario D — Prefix change: force re-SLAAC

**Concept:** when a router changes its advertised prefix, hosts deprecate the old address and autoconfigure a new one.

```bash
# 1. Edit the radvd config to advertise a different /64
sed -i 's|fd00:cafe:1::|fd00:cafe:2::|g' /tmp/ipv6lab-radvd.conf

# 2. Reload radvd (sends RA with old prefix preferred-lifetime=0 + new prefix)
kill -HUP "$(cat /tmp/ipv6lab-radvd.pid)"

# 3. Watch the address transition
watch -n 2 'ip netns exec lab-client ip -6 addr show dev veth-client'
```

**Observe:** the `fd00:cafe:1::` address becomes `DEPRECATED`; a new `fd00:cafe:2::` address appears. Both coexist briefly — existing connections use the old address until it expires.

```bash
# Restore original prefix
sed -i 's|fd00:cafe:2::|fd00:cafe:1::|g' /tmp/ipv6lab-radvd.conf
kill -HUP "$(cat /tmp/ipv6lab-radvd.pid)"
```

---

---

## Lab 201 — DHCPv6, ip6tables, RA Guard, PMTU

### Prerequisites

```bash
sudo ./ipv6lab-201.sh   # must be running before these tests
```

---

### Verification Tests

#### 1. Two addresses on the client: SLAAC + DHCPv6

```bash
ip netns exec lab-client ip -6 addr show dev veth-client scope global
```

Expected: two `scope global` addresses — one with `mngtmpaddr` (SLAAC privacy), one with a fixed suffix in `::100-::1ff` (DHCPv6 stateful).

#### 2. DHCPv6 lease log

```bash
tail -20 /tmp/ipv6lab-dnsmasq.log
```

Look for `DHCPSOLICIT`, `DHCPADVERTISE`, `DHCPREQUEST`, `DHCPREPLY` exchanges and the leased address.

#### 3. ip6tables rules are active

```bash
ip6tables -L -n --line-numbers
```

Confirm: `INPUT` chain policy is `DROP`; ICMPv6 types 133–136, 128–129, and UDP/547 are `ACCEPT`.

#### 4. DNS AAAA record resolution

```bash
ip netns exec lab-client dig +short AAAA router.ipv6lab.local @fd00:cafe:1::1
```

Expected: `fd00:cafe:1::1`

#### 5. Prefix Delegation — downstream LAN interface

```bash
ip netns exec lab-client ip -6 addr show dev dummy0
```

Expected: `fd00:cafe:1:0100::1/64` — simulating a delegated /64 carved from the /56 pool.

#### 6. Default route present

```bash
ip netns exec lab-client ip -6 route show default
```

Expected: `default via fe80::1 dev veth-client` — installed by dnsmasq's RA.

#### 7. RDNSS pushed to client

```bash
ip netns exec lab-client resolvectl dns 2>/dev/null || \
  ip netns exec lab-client cat /run/systemd/resolve/resolv.conf 2>/dev/null || \
  ip netns exec lab-client cat /etc/resolv.conf
```

Expected: `fd00:cafe:1::1` listed as a nameserver (pushed via DHCPv6 option 23 / RDNSS).

---

### Break-and-Fix Scenarios

#### Scenario A — Block ICMPv6 type 2 (Packet Too Big): silently break large transfers

**Concept:** IPv6 has no router-level fragmentation. PMTU relies entirely on ICMPv6 type 2. Blocking it creates a "black hole" — small packets work, large ones fail with no error.

```bash
# 1. Confirm large ping works at normal MTU
ip netns exec lab-client ping6 -s 1400 -c 2 fd00:cafe:1::1

# 2. Set a restrictive MTU to force PTB generation
ip link set veth-rtr mtu 1280
ip netns exec lab-client ip link set veth-client mtu 1280

# 3. Block ICMPv6 type 2 (Packet Too Big) so the sender never learns the MTU
ip6tables -A FORWARD -p icmpv6 --icmpv6-type 2 -j DROP

# 4. Try a large ping — it hangs or times out silently
ip netns exec lab-client ping6 -s 1400 -c 3 -W 3 fd00:cafe:1::1
```

**Observe:** no "Message too big" error — the packet is just dropped. This is BHTC (Black-Hole TCP Connection syndrome) and is the most common cause of "works for small files, fails for large files" on IPv6.

```bash
# Fix: allow PTB again
ip6tables -D FORWARD -p icmpv6 --icmpv6-type 2 -j DROP
ip link set veth-rtr mtu 1500
ip netns exec lab-client ip link set veth-client mtu 1500
```

---

#### Scenario B — Drop DHCPv6 port: client falls back to SLAAC only

**Concept:** DHCPv6 uses UDP port 547 (server) and 546 (client). Blocking port 547 forces clients to rely on SLAAC — the `M` (Managed) flag in the RA is advisory, not enforced by the kernel.

```bash
# 1. Note the current addresses (SLAAC + DHCPv6)
ip netns exec lab-client ip -6 addr show dev veth-client scope global

# 2. Block DHCPv6 server port
ip6tables -A INPUT -p udp --dport 547 -j DROP

# 3. Expire the existing DHCPv6 lease (simulate lease timeout)
ip netns exec lab-client timeout 5 dhclient -6 -r veth-client 2>/dev/null || true

# 4. Try to renew — should get no response
ip netns exec lab-client timeout 10 dhclient -6 -v veth-client 2>&1 | grep -E '(SOLICIT|REPLY|timeout)'
```

**Observe:** only the SLAAC address remains. This is why enterprise networks enforce DHCPv6 at the switch level (DHCPv6 Guard / port security) rather than relying on host-side behaviour.

```bash
# Fix:
ip6tables -D INPUT -p udp --dport 547 -j DROP
ip netns exec lab-client timeout 10 dhclient -6 veth-client 2>/dev/null || true
```

---

#### Scenario C — Rogue RA attack + RA Guard response

**Concept:** any host on the segment can send a Router Advertisement and become the default gateway. This is the rogue RA attack (RFC 6104).

```bash
# 1. Simulate a rogue router — send a crafted RA from inside the client namespace
#    (uses radvd in a second namespace; simpler: use fake_radvd.sh pattern)
#    Here we manually assign a rogue address and add a route to demonstrate the effect

# Check current default route
ip netns exec lab-client ip -6 route show default

# 2. Inject a rogue default route (simulates what a rogue RA would install)
ip netns exec lab-client ip -6 route add default via fe80::bad:cafe dev veth-client

# 3. Now the client has two default routes — traffic may go to the rogue router
ip netns exec lab-client ip -6 route show default
```

**Observe:** two `default` routes. The kernel picks one based on metric; an attacker can force preference with a lower metric or by poisoning the NDP cache.

```bash
# 4. Apply RA Guard: block RA arrivals on the client interface
ip netns exec lab-client ip6tables -A INPUT -p icmpv6 --icmpv6-type 134 -j DROP
echo "RA Guard active — rogue RAs will now be silently dropped"

# 5. Remove the rogue route
ip netns exec lab-client ip -6 route del default via fe80::bad:cafe dev veth-client 2>/dev/null || true

# Fix / restore:
ip netns exec lab-client ip6tables -D INPUT -p icmpv6 --icmpv6-type 134 -j DROP
```

---

#### Scenario D — Exhaust the DHCPv6 pool

**Concept:** the lab pool is `::100–::1ff` (255 addresses). What happens when it's full?

```bash
# Create 5 extra client namespaces and request leases from each
for i in $(seq 1 5); do
    ip netns add "lab-extra-${i}"
    ip link add "veth-x${i}" type veth peer name "veth-xc${i}"
    ip link set "veth-xc${i}" netns "lab-extra-${i}"
    ip link set "veth-x${i}" up
    ip netns exec "lab-extra-${i}" ip link set "veth-xc${i}" up
    ip netns exec "lab-extra-${i}" ip link set lo up
    ip netns exec "lab-extra-${i}" timeout 5 dhclient -6 "veth-xc${i}" 2>/dev/null || true
    echo -n "ns lab-extra-${i}: "
    ip netns exec "lab-extra-${i}" ip -6 addr show scope global 2>/dev/null | grep inet6 || echo "(no address)"
done
```

**Observe:** leases are granted from the `::100–::1ff` range. All clients also get SLAAC addresses (from the prefix in the RA) — SLAAC has no pool limit.

```bash
# Cleanup extra namespaces
for i in $(seq 1 5); do
    ip netns del "lab-extra-${i}" 2>/dev/null || true
    ip link del "veth-x${i}" 2>/dev/null || true
done
```

---

#### Scenario E — Break RDNSS: DNS stops resolving but connectivity still works

**Concept:** RDNSS (RFC 8106) is how IPv6 hosts learn their DNS server. Blocking DNS port 53 isolates name resolution while leaving L3 connectivity intact — important to distinguish during troubleshooting.

```bash
# 1. Confirm DNS works
ip netns exec lab-client dig +short AAAA router.ipv6lab.local @fd00:cafe:1::1

# 2. Block UDP 53 outbound from the client namespace
ip6tables -A FORWARD -p udp --dport 53 -j DROP
ip6tables -A FORWARD -p tcp --dport 53 -j DROP

# 3. DNS fails — but ping6 by address still works
ip netns exec lab-client dig +short AAAA router.ipv6lab.local @fd00:cafe:1::1
ip netns exec lab-client ping6 -c 2 fd00:cafe:1::1   # still works
```

**Observe:** connectivity works, name resolution doesn't. This is one of the most common real-world misconfiguration patterns — an overly strict firewall blocking DNS while appearing to allow IPv6 traffic.

```bash
# Fix:
ip6tables -D FORWARD -p udp --dport 53 -j DROP
ip6tables -D FORWARD -p tcp --dport 53 -j DROP
```

---

## Quick Reference

### Useful one-liners for both labs

```bash
# Watch addresses in real time
watch -n 2 'ip netns exec lab-client ip -6 addr show'

# Watch routes
watch -n 2 'ip netns exec lab-client ip -6 route show'

# Capture all ICMPv6 traffic on the veth
tcpdump -i veth-rtr -n icmp6

# Capture DHCPv6 traffic only
tcpdump -i veth-rtr -n 'udp port 546 or udp port 547'

# Show ip6tables rules with packet counters
ip6tables -L -n -v --line-numbers

# Show NDP cache both sides
ip -6 neigh show; ip netns exec lab-client ip -6 neigh show

# Flush NDP cache (force re-resolution)
ip -6 neigh flush dev veth-rtr
ip netns exec lab-client ip -6 neigh flush dev veth-client

# Check radvd is running and its config
pgrep -a radvd
cat /tmp/ipv6lab-radvd.conf

# Check dnsmasq log (201 only)
tail -f /tmp/ipv6lab-dnsmasq.log
```

### ICMPv6 type quick reference

| Type | Name | Block? |
|------|------|--------|
| 1 | Destination Unreachable | Never |
| 2 | Packet Too Big (PTB) | Never — breaks PMTU |
| 3 | Time Exceeded | Never |
| 128 | Echo Request | Safe to allow |
| 129 | Echo Reply | Safe to allow |
| 133 | Router Solicitation | Never — breaks SLAAC |
| 134 | Router Advertisement | RA Guard only at switch |
| 135 | Neighbour Solicitation | Never — breaks NDP |
| 136 | Neighbour Advertisement | Never — breaks NDP |
| 143 | MLD Report v2 | Never — breaks multicast |
