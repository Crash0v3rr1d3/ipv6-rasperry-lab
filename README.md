# IPv6 Raspberry Pi Lab

Two standalone Bash scripts that turn a Raspberry Pi into a hands-on IPv6 lab. Designed for two skill levels:

| Script | Level | Concepts |
|--------|-------|---------|
| `ipv6lab-101.sh` | Beginner | SLAAC, radvd, NDP, link-local, ULA, network namespaces |
| `ipv6lab-201.sh` | Experienced | DHCPv6, Prefix Delegation, ip6tables, RA Guard, PMTU, 6in4 tunnel, AAAA DNS |

Both scripts are **fully self-contained** — no shared libraries, no external dependencies beyond standard Raspberry Pi OS packages. Missing packages are auto-installed via `apt-get`.

---

## Requirements

- Raspberry Pi running **Raspberry Pi OS** (Bullseye or Bookworm)
- Root / `sudo` access
- Single-Pi mode: **one Pi** (uses Linux network namespaces to simulate router + client)
- Dual-Pi mode: **two Pis** on the same L2 network

---

## Quick Start

### Single Pi — 101 (Beginner)

```bash
git clone https://github.com/Crash0v3rr1d3/ipv6-rasperry-lab
cd ipv6-rasperry-lab
chmod +x ipv6lab-101.sh
sudo ./ipv6lab-101.sh
```

What happens:
1. Creates a `lab-client` network namespace connected via a veth pair
2. Assigns `fd00:cafe:1::1/64` (ULA) to the router side
3. Launches `radvd` to send Router Advertisements
4. Waits for SLAAC autoconfiguration in the client namespace
5. Runs ping6 tests and shows the NDP neighbour cache
6. Prints a concept summary mapped to the relevant RFCs

To clean up: `sudo ./ipv6lab-101.sh --teardown`

---

### Single Pi — 201 (Experienced)

```bash
sudo ./ipv6lab-201.sh
```

Steps (8 stages):
1. Namespace + veth pair
2. `dnsmasq` — DHCPv6 stateful + Router Advertisement (replaces radvd)
3. Address acquisition — SLAAC + DHCPv6 lease
4. Prefix Delegation demo — simulates ISP `/56` → CPE `/64` → LAN model
5. `ip6tables` — DROP-default policy + RFC 4890 ICMPv6 minimum set
6. RA Guard demo — blocks ICMPv6 type 134 in client namespace
7. PMTU discovery — MTU 1280 test showing IPv6 no-fragmentation requirement
8. AAAA DNS records — `dig AAAA router.ipv6lab.local` via dnsmasq

To clean up: `sudo ./ipv6lab-201.sh --teardown`

---

## Two-Pi Mode

Run the **router** script on Pi 1 first, then the **client** script on Pi 2:

```bash
# Pi 1 (router)
sudo ./ipv6lab-101.sh --mode dual --role router

# Pi 2 (client) — run after Pi 1 is ready
sudo ./ipv6lab-101.sh --mode dual --role client
```

Override the detected interface if needed:
```bash
LAB_IFACE=eth0 sudo ./ipv6lab-101.sh --mode dual --role router
```

---

## Hurricane Electric 6in4 Tunnel (201 only, optional)

Get a free tunnel at [tunnelbroker.net](https://tunnelbroker.net), then:

```bash
export HE_SERVER=216.66.80.90        # your tunnel server IPv4
export HE_LOCAL_V4=203.0.113.5       # your Pi's public IPv4
export HE_CLIENT_V6=2001:db8:1::/128 # your HE client /128
sudo ./ipv6lab-201.sh
```

---

## Network Topology (single-Pi mode)

```
Default netns (router)              lab-client netns (client)
┌─────────────────────┐             ┌────────────────────────┐
│  veth-rtr           │◄───veth────►│  veth-client           │
│  fd00:cafe:1::1/64  │             │  fd00:cafe:1::XXXX/64  │
│  fe80::1/10         │             │  fe80::auto/10         │
│  radvd / dnsmasq    │             │  SLAAC autoconfigured  │
└─────────────────────┘             └────────────────────────┘
```

State is tracked in `/tmp/ipv6lab-state.env` — always safe to re-run `--teardown`.

---

## Concepts Covered

### 101
| Component | RFC / Concept |
|-----------|---------------|
| `fd00:cafe:1::/64` | ULA prefix — RFC 4193 |
| `fe80::1` | Link-local address — RFC 4291 |
| Router Advertisement (radvd) | NDP RA — RFC 4861 |
| SLAAC | Stateless Address Autoconfiguration — RFC 4862 |
| NDP neighbour cache | Replaces ARP; uses ICMPv6 NS/NA |
| `::1` | IPv6 loopback |

### 201 (adds)
| Component | RFC / Concept |
|-----------|---------------|
| DHCPv6 stateful (dnsmasq) | Managed address assignment — RFC 3315 |
| Prefix Delegation `/56→/64` | ISP→CPE→LAN model — RFC 3633 |
| `ip6tables` DROP-default | Production baseline firewall |
| ICMPv6 types 133–136, 128–129 | Never block these — RFC 4890 |
| ICMPv6 type 2 (Packet Too Big) | Required for PMTU — RFC 8200 |
| RA Guard | Rogue RA prevention — RFC 6105 |
| 6in4 tunnel | IPv6-over-IPv4 transition — RFC 4213 |
| AAAA records | IPv6 DNS — RFC 3596 |

---

## Bookworm / nftables Compatibility

On Raspberry Pi OS Bookworm, `iptables` defaults to the nftables backend. The 201 script auto-detects this and uses `ip6tables-legacy` if needed — no manual intervention required.

---

## License

See [LICENSE](LICENSE).
