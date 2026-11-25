# Diagnostic Methodology

## 1. Why Sequential Testing Is Non-Negotiable

Running ping, DNS lookups, and a speed test at the same time destroys your baseline:

- Bulk downloads/uploads fill router queues (bufferbloat), inflating ping latency from 5 ms to 60–300 ms.
- High packet rates on Wi-Fi increase contention and retransmissions, making idle jitter look worse than it is.
- Always run **RF/link inspection → idle ping & traceroute → DNS benchmark → loaded throughput & bufferbloat** in strict order, with cooldown pauses between directions.

## 2. Reading a Wi-Fi RF Scan Correctly

### 2.4 GHz (Only Channels 1, 6, and 11 at 20 MHz)
- Each 20 MHz channel spans ~22 MHz (±2 channels). Choosing channels like 3, 4, or 8 creates **adjacent-channel interference (ACI)** — neighboring APs can't decode each other's preambles to politely take turns (CSMA/CA), causing collisions instead of clean sharing.
- Never use `40 MHz` width on 2.4 GHz in apartments or dense neighborhoods; it consumes two-thirds of the entire band and increases interference.
- Don't just count APs — weigh **signal strength (dBm)**! One neighbor at `-48 dBm` carries **~500× more RF power** than a neighbor at `-75 dBm` (every 3 dB doubles power; every 10 dB is 10×).

### 5 GHz (80 MHz Width & DFS vs. Non-DFS)
- **80 MHz** is the sweet spot for Wi-Fi 5 (802.11ac) and Wi-Fi 6 (802.11ax) home networks — fast throughput without the radar/overlap headaches of 160 MHz.
- **Non-DFS blocks** (UNII-1 `36–48`, and where permitted UNII-3 `149–161`) do not require radar Channel Availability Checks (CAC).
- **DFS blocks** (`52–64`, `100–144`) allow radar detection events that force APs to jump channels or go silent temporarily; many laptops also passive-scan DFS channels more slowly, causing them to settle on 2.4 GHz instead.
- If a non-DFS 80 MHz block (`36–48` or `149–161`) is empty or quieter than DFS, lock the router there manually instead of trusting `Auto`.

## 3. Why Band Steering / "Smart Connect" Often Backfires

Sharing one SSID across 2.4 GHz and 5 GHz relies on router heuristics (RSSI thresholds and deauth/probe-suppression tricks) to steer clients. Common failure modes:

- **Sticky 2.4 GHz trap**: A laptop temporarily dips below the steering threshold (e.g., `-75 dBm`), gets pushed to 2.4 GHz, and stays pinned there for hours.
- **Sticky weak 5 GHz trap**: A phone clings to 5 GHz at `-84 dBm` (near the noise floor) with 40–50% packet retransmissions instead of switching cleanly.
- **Fix**: Split the SSIDs (`HomeWiFi` for 2.4 GHz, `HomeWiFi-5G` for 5 GHz) so stationary/dual-band devices stay locked to 5 GHz while IoT and far-room devices use 2.4 GHz intentionally.

## 4. DNS: Reliability Matters More Than 2 ms of Speed

Many ISP gateways run tiny built-in DNS relays (sometimes only 100 cache entries) and hand out only their own LAN IP via DHCP with no fallback. When the relay drops a packet or times out:

- Browsers stall for 1–5 seconds waiting for DNS retry timeouts.
- OS logs record intermittent name-resolution timeout warnings (e.g., Windows Event ID `1014`).
- Benchmarking **success rate + p95/max tail latency** against `1.1.1.1` (Cloudflare) and `8.8.8.8` (Google) reveals flaky relays immediately.

## 5. Bufferbloat & Drop-Tail Queues

When an upstream link is much slower than LAN speed (e.g., 100 Mbps fiber upload behind a 1 Gbps Ethernet port), packets queue up inside the router/ONT whenever an upload saturates the link.

- Standard ISP gateways use deep **Drop-Tail (FIFO)** queues (e.g., 500–1000 packets) without Active Queue Management (**AQM**).
- A 768-packet FIFO of 1500-byte frames on a 100 Mbps uplink holds up to **~92 ms of standing delay** (`768 × 12,000 bits / 100 Mbps`).
- **Grades** (added latency under load):
  - `A+`: `< 5 ms` | `A`: `< 30 ms` | `B`: `< 60 ms` | `C`: `< 200 ms` | `D`: `< 400 ms` | `F`: `≥ 400 ms`
- **Mitigations**: Cap heavy uploaders to ~80–85% of uplink speed (free), or deploy an SQM-capable router running **CAKE** or **fq_codel** (hardware fix).
