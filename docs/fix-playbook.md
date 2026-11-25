# Fix Playbook (Vendor-Agnostic)

Apply changes in order from highest impact to lowest, then re-run `.\scripts\benchmark.ps1` (or `node scripts/netbench.mjs`) to verify real gains.

---

## 1. Router Wireless Settings (Highest Wi-Fi Impact)

Log into your router's admin portal (commonly `http://192.168.1.1`, `http://192.168.0.1`, or your default gateway from `ipconfig`).

1. **Disable Band Steering / Smart Connect (Split SSIDs)**
   - Give 5 GHz a distinct network name (e.g., `<YourWiFi>-5G`) while keeping 2.4 GHz on `<YourWiFi>` so smart-home / IoT devices don't need reconfiguration.
   - If your router has an explicit **Band Steering / Smart Connect / Smart Handover** toggle, turn it **Off**.
2. **Lock 5 GHz to a Clean Non-DFS Channel at 80 MHz**
   - Set **Channel Width** to **`80 MHz`** (or `160 MHz` only if you have Wi-Fi 6/6E hardware and an interference-free DFS band).
   - Change **Channel** from `Auto` to the cleanest non-DFS channel from your RF scan — typically **`36`** (block `36–48`) or **`149`** (block `149–161`, where permitted).
3. **Lock 2.4 GHz to the Cleanest Non-Overlapping Channel at 20 MHz**
   - Set **Channel Width** to **`20 MHz`** (avoid `40 MHz` on 2.4 GHz).
   - Change **Channel** from `Auto` to **`1`**, **`6`**, or **`11`** — pick the one with the lowest combined neighbor signal strength and fewest overlapping channels (`2–5`, `7–10`).
4. **Verify Hygiene Settings**
   - Ensure **WMM (Wi-Fi Multimedia)** is **Enabled** (required for 802.11n/ac/ax speeds).
   - On Wi-Fi 6 routers, ensure **802.11ax / OFDMA** is enabled.
   - Disable unused **Guest SSIDs** to reduce management beacon airtime.

---

## 2. Client Device Quick Wins (Windows / macOS / Mobile)

### A. Connect Dual-Band Devices to the 5 GHz SSID
- On laptops and phones, connect to `<YourWiFi>-5G` and enable **Connect automatically**.
- Uncheck **Connect automatically** on the 2.4 GHz SSID for devices used within 5 GHz range (signal stronger than `-75 dBm`).
- Verify on Windows:
  ```powershell
  netsh wlan show interfaces
  ```

### B. Switch to Fast, Reliable DNS with Failover (+ DoH)

If your router lets you customize DHCP DNS servers, configure them there once for the whole home. If your ISP router locks DNS settings, configure them on each device:

**Windows 11 GUI:**
- **Settings → Network & internet → Ethernet (or Wi-Fi) → DNS server assignment → Edit → Manual → IPv4 ON**
  - Preferred DNS: `1.1.1.1` → DNS over HTTPS: `On (automatic template)`
  - Alternate DNS: `8.8.8.8` *(or `1.0.0.1`)* → DNS over HTTPS: `On (automatic template)`

**Windows PowerShell (Run as Administrator):**
```powershell
# Replace "Ethernet" with "Wi-Fi" on a laptop
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses ("1.1.1.1","8.8.8.8")
Clear-DnsClientCache
```

---

## 3. Upload Bufferbloat Mitigation (Optional)

If your benchmark shows high latency added during full-speed uploads (`+50 ms` or worse, Grade C–F):

- **Free software fix**: Cap upload bandwidth to **~80–85%** of your plan's upload tier in heavy upload apps (cloud backup, Steam, OneDrive, Google Drive, torrent clients).
- **Hardware fix**: Place your ISP modem/ONT in **Bridge Mode** behind an SQM-capable router (OpenWrt, UniFi, ASUS Merlin, MikroTik, etc.) running **CAKE** or **fq_codel** shaped to ~90–95% of your measured speeds.

---

## 4. Physical Placement Check (When 5 GHz Signal Is Weak)

No software tweak beats radio physics. If a laptop or phone sees `< 35%` signal (`worse than -75 dBm`) on 5 GHz:

- Elevate the router out of cabinets/corners and away from concrete walls, mirrors, TVs, and metal desks.
- For multi-room or thick-wall homes, run an Ethernet cable to a secondary wired Access Point (AP) near the dead zone.

---

## Undo / Rollback Commands

If anything misbehaves, every local change is one command away from default:

```powershell
# Restore automatic DHCP-assigned DNS on Windows (Run as Administrator)
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ResetServerAddresses
Set-DnsClientServerAddress -InterfaceAlias "Wi-Fi" -ResetServerAddresses
Clear-DnsClientCache
```

On your router, reverting the 5 GHz SSID back to the 2.4 GHz name and setting Channels back to `Auto` restores factory wireless behavior immediately.
