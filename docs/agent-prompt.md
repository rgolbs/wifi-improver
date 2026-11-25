# Reusable AI Agent Prompt

Paste this prompt into any terminal-capable AI coding agent (Claude Code, Antigravity, Codex, etc.) to run the exact same **sequential diagnose → fix → re-measure** workflow on your own home network:

---

> **Note on Router Login & AI Guardrails:**
> - **Where credentials are needed:** Inspecting internal router radio/RF neighbor telemetry or changing Wi-Fi settings requires logging into your gateway IP (e.g., `192.168.1.1`, `192.168.0.1`, or `10.x.x.x`) with your router admin username and password.
> - **Why some models refuse:** Many hosted models have strict security guardrails that block accessing local router IPs or using login credentials, even when you own the hardware and provide them explicitly.
> - **Workarounds:**
>   1. **Do the router part manually (safest):** Open the router admin page yourself in a browser, take screenshots of the **Wireless / Wi-Fi Settings** and **Channel / Neighbor Scan** pages, and paste those screenshots to the agent—no passwords needed.
>   2. **Use an open-source / local model (or less-restricted model):** If you want an agent to log into your router directly for automated telemetry reads, consider running an open-source model or one without strict local-network guardrails.
>   3. **Rotate credentials:** If you ever share your router password in a cloud model session, change the password afterward.

```text
Diagnose my Wi-Fi and home network, identify the real bottlenecks behind slow speeds or instability, and guide me through fixing them.

Adapt commands to my OS (Windows / macOS / Linux) and skip anything irrelevant to my setup (e.g., if I'm on wired Ethernet vs. Wi-Fi).

Run these checks strictly SEQUENTIALLY (do NOT run ping in parallel with throughput tests, so idle latency isn't polluted by load):

1. Link & RF congestion:
   - Inspect my active interface (Ethernet or Wi-Fi: PHY mode 802.11ac/ax/be, band, channel, channel width, signal/noise/SNR, link speed / TX rate, and packet errors/discards).
   - Scan nearby Wi-Fi networks and count competing APs + signal strength per channel/band to find the cleanest channels in my environment.

2. Hop-by-hop latency & stability (while idle):
   - Sample idle traffic and check for local bandwidth hogs, VPNs, proxies, or recent link/DNS failure events.
   - Ping my default gateway (30 packets) and 1.1.1.1 (30 packets, plus IPv6 if active), and run a 5-hop traceroute to separate LAN/Wi-Fi jitter from ISP latency.

3. DNS latency & reliability:
   - Check my current DNS servers and compare lookup latency and failure rate against 1.1.1.1, 8.8.8.8, and my router.

4. Throughput & bufferbloat under load:
   - Run macOS `networkQuality -v` or an equivalent sequential load + latency benchmark (e.g., `node scripts/netbench.mjs`) to measure downlink, uplink, idle latency, loaded latency / responsiveness (RPM), and ECN status.

Then give me:
- A concise baseline summary with exact measurements.
- The top real bottlenecks ranked by impact (skip placebo OS tweaks).
- Safe local quick wins (e.g., reliable DNS with failover + DoH) vs. router/modem fixes:
  - Optimal 5/6 GHz width (80/160 MHz where supported), WMM/Wi-Fi 6 settings, and disabling Band Steering / Smart Connect if it degrades stability.
  - Exact cleanest 5 GHz (preferring non-DFS if clean) and 2.4 GHz (1/6/11 only, 20 MHz) channels based on my local RF scan.
  - Unused guest SSIDs, optical/cable modem signal health, and SQM / upload-cap options for bufferbloat.
- Ask for my router model (and/or Wireless Settings screenshot) if needed for exact click-by-click instructions.

After I apply the changes, re-run the exact same sequential benchmark and output a Before vs. After comparison table.
```
