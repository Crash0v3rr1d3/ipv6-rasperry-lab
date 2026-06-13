# Build an IPv6 Lab on a Single Raspberry Pi

Most IPv6 tutorials give you a config snippet and a diagram. You paste the snippet, it works once, and three days later you can't explain why. The only way to build actual intuition for IPv6 is to break things on purpose — kill radvd mid-session, block ICMPv6 type 135, drop Packet Too Big messages and watch large transfers silently hang.

This post walks through a two-script lab that runs on a single Raspberry Pi and covers the full stack: from SLAAC autoconfiguration to ip6tables firewall rules. No cloud account, no second device required.

---

## Why a Pi?

A Raspberry Pi runs a standard Linux kernel with full network namespace support. That's everything you need. With Linux network namespaces and a veth pair, one device can simulate a router and a client on an isolated L2 segment — the same isolation you'd get from two physical machines connected by a cable.

The lab uses `fd00:cafe:1::/64`, a Unique Local Address prefix (RFC 4193). ULA never gets routed on the public internet, so you can experiment freely without touching real infrastructure.

---

## Two Tracks

The lab ships as two standalone Bash scripts:

**`ipv6lab-101.sh`** — for anyone new to IPv6 or coming from an IPv4-only background. It covers the concepts that have no direct IPv4 equivalent: SLAAC, Router Advertisements, Neighbour Discovery Protocol, link-local addresses, and the difference between a /64 and a /128 in practice.

**`ipv6lab-201.sh`** — for engineers who know the basics and want production-relevant topics: DHCPv6 stateful addressing, Prefix Delegation, ip6tables rules that follow RFC 4890, RA Guard, Path MTU Discovery, and an optional 6in4 tunnel to Hurricane Electric for real global IPv6 reachability.

Both scripts detect whether you're running in single-Pi mode or across two Pis, auto-install missing packages, and clean up everything with `--teardown`.

---

## What the 101 Lab Sets Up

When you run `sudo ./ipv6lab-101.sh`, the script builds this topology inside the Pi:

```
Default netns (router)              lab-client netns (client)
┌─────────────────────┐             ┌──────────────────────────┐
│  veth-rtr           │◄───veth────►│  veth-client             │
│  fd00:cafe:1::1/64  │             │  fd00:cafe:1::XXXX/64    │
│  fe80::1/10         │             │  (SLAAC autoconfigured)  │
│  radvd              │             │                          │
└─────────────────────┘             └──────────────────────────┘
```

A network namespace is a fully isolated network stack — its own interfaces, routing table, NDP cache, and firewall rules. The veth pair is a virtual Ethernet cable between the two stacks.

Once radvd starts sending Router Advertisements, the client namespace configures itself automatically:

```bash
ip netns exec lab-client ip -6 addr show dev veth-client
```
```
2: veth-client: <BROADCAST,MULTICAST,UP,LOWER_UP>
    inet6 fd00:cafe:1::8c3a:f2ff:fe1b:4d02/64 scope global dynamic mngtmpaddr
    inet6 fe80::8c3a:f2ff:fe1b:4d02/64 scope link
```

The `fd00:cafe:1::` address came from nowhere. The client never saw a DHCP server. The RA told it the prefix, the client derived the host part from its MAC address (EUI-64) or from a random token (privacy extensions, RFC 8981), and configured the address on its own. That's SLAAC.

The client also installed a default route:

```bash
ip netns exec lab-client ip -6 route show
```
```
fd00:cafe:1::/64 dev veth-client proto kernel metric 256
fe80::/64 dev veth-client proto kernel metric 256
default via fe80::1 dev veth-client proto ra metric 1024 expires 1795sec
```

`fe80::1` is the router's link-local address — statically assigned so it's always predictable. The `proto ra` marker tells you the route came from a Router Advertisement, not a routing protocol or a static config.

---

## The 201 Lab: What Changes

The 201 script replaces radvd with `dnsmasq`, which handles both Router Advertisements and DHCPv6 stateful leases. After it runs, the client holds two global addresses at once:

```bash
ip netns exec lab-client ip -6 addr show dev veth-client scope global
```
```
inet6 fd00:cafe:1::8c3a:f2ff:fe1b:4d02/64 scope global dynamic mngtmpaddr  ← SLAAC
inet6 fd00:cafe:1::142/64 scope global dynamic                               ← DHCPv6
```

The `M` flag in the RA tells clients the network runs a DHCPv6 server. The client contacts it on UDP port 546/547 and gets a lease from the `::100–::1ff` pool. The SLAAC address doesn't go away — both coexist.

The ip6tables section applies a DROP-default policy and then opens up exactly the ICMPv6 types that RFC 4890 says you must never block:

| Type | Name | Why you can't drop it |
|------|------|-----------------------|
| 133 | Router Solicitation | Hosts need to find routers |
| 134 | Router Advertisement | SLAAC breaks without this |
| 135 | Neighbour Solicitation | NDP breaks — no address resolution |
| 136 | Neighbour Advertisement | Same |
| 2 | Packet Too Big | PMTU breaks — large transfers silently fail |

A firewall that blocks type 2 (Packet Too Big) will pass small HTTP requests fine. Send a file over 1280 bytes on a path with a lower MTU and it hangs forever with no error message. This is the most common IPv6 firewall mistake in production.

---

## Breaking Things on Purpose

The lab includes a test guide with verification steps and break/fix scenarios. A few worth trying:

### Kill radvd and watch the address expire

```bash
kill "$(cat /tmp/ipv6lab-radvd.pid)"
watch -n 2 'ip netns exec lab-client ip -6 addr show dev veth-client'
```

The address transitions from `dynamic` to `deprecated` once its preferred lifetime passes. Existing connections continue using the deprecated address. New connections refuse it. After the valid lifetime expires, the address disappears. Restart radvd and a fresh address appears within 10 seconds.

This teaches the SLAAC lifetime model in a way that reading RFC 4862 doesn't.

### Block Neighbour Solicitation and watch ping6 fail silently

```bash
ip6tables -A INPUT -p icmpv6 --icmpv6-type 135 -j DROP
ip -6 neigh flush dev veth-rtr
ip netns exec lab-client ping6 -c 3 -W 2 fd00:cafe:1::1
```

The address `fd00:cafe:1::1` is locally assigned on `veth-rtr`. It exists. But ping fails because the client can't resolve it to a MAC address — NDP is broken. The error looks identical to "host unreachable." This is why "can't ping, must be a routing problem" is usually wrong in IPv6.

### PMTU black hole

```bash
ip link set veth-rtr mtu 1280
ip6tables -A FORWARD -p icmpv6 --icmpv6-type 2 -j DROP
ip netns exec lab-client ping6 -s 1400 -c 3 -W 3 fd00:cafe:1::1
```

No output. No error. The packet gets dropped because it exceeds the MTU, but the router can't send a Packet Too Big back because you blocked type 2. The sender never learns to reduce its packet size. This is BHTC (Black-Hole TCP Connection) and it's invisible to users — they just see a slow or stalled transfer.

---

## Dual-Pi Mode

If you have two Pis, both scripts support `--mode dual`:

```bash
# Pi 1 — runs radvd/dnsmasq, assigns fd00:cafe:1::1/64 to eth0
sudo ./ipv6lab-101.sh --mode dual --role router

# Pi 2 — configures eth0 for SLAAC, waits for address, runs ping tests
sudo ./ipv6lab-101.sh --mode dual --role client
```

The interface is auto-detected (eth0 preferred over wlan0). Override it with `LAB_IFACE=eth1` if needed.

---

## HE Tunnel: Real Global IPv6

The 201 script has an optional 6in4 tunnel to Hurricane Electric. Get a free account at tunnelbroker.net, then:

```bash
export HE_SERVER=216.66.80.90
export HE_LOCAL_V4=<your Pi's public IPv4>
export HE_CLIENT_V6=<your HE /128>
sudo ./ipv6lab-201.sh
```

The script creates a `sit` tunnel interface and adds a `::/0` default route through it. If it works, you can `ping6 ipv6.google.com` from the Pi with a real globally routable address. Useful for testing dual-stack DNS, real PMTU paths, and anything that requires actual internet IPv6.

---

## Get the Scripts

```bash
git clone https://github.com/Crash0v3rr1d3/ipv6-rasperry-lab
cd ipv6-rasperry-lab
chmod +x ipv6lab-101.sh ipv6lab-201.sh

# Start with 101
sudo ./ipv6lab-101.sh

# When you're ready
sudo ./ipv6lab-201.sh

# Clean up either
sudo ./ipv6lab-101.sh --teardown
```

The repo also contains `TESTS.md` with a full set of verification commands and break/fix scenarios for both labs.

Tested on Raspberry Pi OS Bullseye and Bookworm. The 201 script auto-detects if `iptables` maps to the nftables backend (Bookworm default) and uses `ip6tables-legacy` instead.
