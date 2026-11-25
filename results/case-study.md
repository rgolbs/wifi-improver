# Case Study: Gigabit Fiber Home Network Optimization

*All personal identifiers (SSIDs, hostnames, MAC addresses, IPs, and ISP details) have been removed.*

## Environment

- **Internet Tier**: ~1000 Mbps down / 100 Mbps up GPON fiber
- **Gateway**: Dual-band Wi-Fi 5 (802.11ac Wave 2 4×4 on 5 GHz, 802.11n 3×3 on 2.4 GHz) fiber ONT/router, 4× 1 Gbps LAN ports
- **Test Devices**:
  - Wired desktop (2.5GbE NIC linked at 1 Gbps Full Duplex to router LAN port)
  - Dual-band Windows laptop (previously stuck on 2.4 GHz)
  - Dual-band Android smartphone (Wi-Fi 5 capable)

---

## Baseline Findings (Before Any Changes)

### 1. Local RF Congestion Scan (From Router Radios)

| Band | Channel / Block | Competing BSSIDs | Strongest Neighbor | Assessment |
|---|---|---:|---:|---|
| **5 GHz (80 MHz)** | **Ch 36–48 (Non-DFS)** | **0** | — | **Empty (Best)** |
| **5 GHz (80 MHz)** | Ch 52–64 (DFS — *Active Ch 60*) | 8 | -85 dBm | Congested + DFS (-86 dBm noise floor) |
| **2.4 GHz (20 MHz)** | Ch 1 | 5 | -48 dBm | Severely congested — avoid |
| **2.4 GHz (20 MHz)** | Ch 3–4 (Overlapping) | 4 | -61 dBm | Strong adjacent-channel interference |
| **2.4 GHz (20 MHz)** | Ch 6 | 1 (+4 ACI) | -61 dBm (ACI) | Polluted by Ch 3–4 overlap |
| **2.4 GHz (20 MHz)** | **Ch 11** | 4 weak (+2 @ -83 dBm) | -75 dBm | **Cleanest 2.4 GHz option** |

### 2. Root Causes Identified

1. **DFS 5 GHz Collision**: `Auto` channel selection placed 5 GHz on DFS Channel 60 (`52–64`) right on top of 8 neighbor BSSIDs, leaving the non-DFS `36–48` block completely empty.
2. **Aggressive Band Steering (`SmartHandover`) on Shared SSID**:
   - Both bands broadcast the same SSID with aggressive steering enabled (`-75 dBm` threshold, 6-hour sticky timer).
   - Dual-band laptops were being pushed onto congested 2.4 GHz (`130 Mbps` link rate).
   - A smartphone on 5 GHz Ch 60 was clinging at `-84 dBm` (2 dB SNR) with **45.9% frame retransmissions** (`438,025 / 954,012` packets).
3. **Unreliable Router DNS Relay**:
   - The gateway's 100-entry DNS relay was the sole DNS server handed out over DHCP.
   - It dropped **1 out of 10** real-domain lookups during benchmarking (with `284 ms` uncached spikes) and triggered Windows Event ID `1014` DNS timeouts.
4. **Upstream Drop-Tail FIFO Bufferbloat**:
   - Router optical QoS used a **768-packet Drop-Tail queue** with no SQM/fq_codel/CAKE, causing `+66 ms` latency spikes under full 100 Mbps wired upload saturation (Grade C).

---

## Changes Applied ($0 Hardware Cost)

1. **Split 5 GHz SSID** (`<WiFi>-5G`) to cleanly disable Aggressive Band Steering while keeping IoT devices undisturbed on `<WiFi>` (2.4 GHz).
2. **Locked 5 GHz Channel** from `Auto` (DFS Ch 60) → **Ch 36** (empty non-DFS `36–48` block, 80 MHz width).
3. **Locked 2.4 GHz Channel** from `Auto` → **Ch 11** (20 MHz width).
4. **Moved Laptop & Phone** onto `<WiFi>-5G` (with auto-connect disabled on 2.4 GHz).
5. **Switched Desktop & Laptop DNS** from router relay → **`1.1.1.1` (primary) + `8.8.8.8` (backup)** with DNS over HTTPS.

---

## Before vs. After Results

### Mobile Wi-Fi (Cloudflare Speed Test)

| Metric | Before | After | Delta |
|---|---:|---:|---:|
| Download | 98.5 Mbps | **376 Mbps** | **+282% (3.8×)** |
| Upload | 64.9 Mbps | **101 Mbps** | **+56%** |
| Idle Latency | 12.9 ms | **12.2 ms** | -5% |
| Download Loaded Latency | 52.1 ms | **23.3 ms** | **-55%** |
| Upload Loaded Latency | 57.6 ms | **17.9 ms** | **-69%** |
| Idle Jitter | 18.1 ms | **12.4 ms** | -31% |
| Download Jitter | 43 ms | **13.7 ms** | **-68%** |
| Upload Jitter | 213 ms | **22.2 ms** | **-90%** |
| Packet Loss | 0% | 0% | — |

### Laptop Wi-Fi (Far Room, ~30% 5 GHz Signal)

| Metric | Before (2.4 GHz) | After (5 GHz Ch 36) | Delta |
|---|---:|---:|---:|
| PHY Link Rate | 130 Mbps | **325 Mbps** | **+150% (2.5×)** |
| Ping to Router (30 pkts) | avg 5 ms, **max 65 ms** | avg 5 ms, **max 30 ms** | **-54% max spike** |
| Download (Avg / Peak) | 42 / 55 Mbps | **90 / 120 Mbps** | **+114% / +118%** |
| Upload (Avg / Peak) | 31 / 50 Mbps | **33 / 56 Mbps** | +6% / +12% |
| Latency During Download | 67 ms | **47 ms** | **-30%** |
| Latency During Upload | 27 ms | **11 ms** | **-59%** |
| Average Latency (Whole Test) | 34 ms | **8 ms** | **-76%** |

### Wired Desktop (1 Gbps Ethernet)

| Metric | Before | After | Delta |
|---|---:|---:|---:|
| Ping to Router (30 pkts) | avg 2.0 ms, max 13.0 ms | **avg <1 ms, max 5 ms** | Cleaner tail |
| Ping to `1.1.1.1` (30 pkts) | avg 7.4 ms, max 11.5 ms | avg 6 ms, max 12 ms | Consistent |
| DNS Server | Router relay only | **`1.1.1.1` + `8.8.8.8`** | Redundant |
| DNS Lookup Failures (10 queries) | 1 / 10 (10%) | **0 / 10 (0%)** | Eliminated |
| Wired Downlink / Uplink | 917.8 / 103.9 Mbps | ~1 Gbps / 101.7 Mbps | Line rate |

## Remaining Physical Limits

- The laptop's room has ~30% 5 GHz signal due to wall attenuation; further throughput gains require moving the router higher/out of enclosures or adding a wired Access Point closer to that room.
- Full-saturation wired upload bufferbloat is a firmware limitation of the ISP gateway's Drop-Tail queue; eliminating it completely requires either client-side upload caps (~80–85 Mbps) or an SQM-capable router (CAKE / fq_codel).
