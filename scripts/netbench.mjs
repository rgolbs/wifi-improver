#!/usr/bin/env node
// Cross-platform sequential throughput & bufferbloat benchmark (Node.js 18+, zero deps).
// Equivalent to macOS `networkQuality -v` using Cloudflare's global edge network.

import https from "node:https";
import { performance } from "node:perf_hooks";
import { execFile } from "node:child_process";

const args = process.argv.slice(2);
if (args.includes("-h") || args.includes("--help")) {
    console.log(
        "Usage: node scripts/netbench.mjs [--duration <sec>] [--streams <n>] [--json]\n" +
            "  --duration <sec>  Steady-state measurement window per direction (default: 10)\n" +
            "  --streams <n>     Parallel HTTPS streams (default: 6)\n" +
            "  --json            Emit JSON summary only"
    );
    process.exit(0);
}

function getArg(flag, fallback) {
    const idx = args.indexOf(flag);
    return idx >= 0 && args[idx + 1] ? Number(args[idx + 1]) : fallback;
}

const SPEED_HOST = "speed.cloudflare.com";
const PROBE_HOST = "1.1.1.1";
const WARMUP_MS = 2000;
const MEASURE_MS = Math.max(3, getArg("--duration", 10)) * 1000;
const STREAMS = Math.max(1, getArg("--streams", 6));
const JSON_ONLY = args.includes("--json");
const IS_WIN = process.platform === "win32";

function stats(arr) {
    if (!arr.length) {
        return { count: 0, min: 0, med: 0, avg: 0, p95: 0, max: 0 };
    }
    const s = [...arr].sort((a, b) => a - b);
    const sum = s.reduce((a, b) => a + b, 0);
    const at = (p) => s[Math.min(s.length - 1, Math.floor((s.length - 1) * p))];
    return {
        count: s.length,
        min: +s[0].toFixed(2),
        med: +at(0.5).toFixed(2),
        avg: +(sum / s.length).toFixed(2),
        p95: +at(0.95).toFixed(2),
        max: +s[s.length - 1].toFixed(2),
    };
}

function httpProbe(agent) {
    return new Promise((resolve) => {
        const t0 = performance.now();
        const req = https.request(
            {
                host: PROBE_HOST,
                path: "/cdn-cgi/trace",
                method: "GET",
                agent,
                timeout: 4000,
                servername: "cloudflare.com",
            },
            (res) => {
                res.on("data", () => {});
                res.on("end", () => resolve(performance.now() - t0));
            }
        );
        req.on("error", () => resolve(null));
        req.on("timeout", () => {
            req.destroy();
            resolve(null);
        });
        req.end();
    });
}

function icmpPingOnce(target) {
    return new Promise((resolve) => {
        const pingArgs = IS_WIN
            ? ["-n", "1", "-w", "2000", target]
            : ["-c", "1", "-W", "2", target];
        const t0 = performance.now();
        execFile("ping", pingArgs, { windowsHide: true }, (err, stdout) => {
            if (err) {
                return resolve(null);
            }
            const m = stdout.match(/time[=<]\s*([\d.]+)\s*ms/i);
            if (m) {
                return resolve(Number(m[1]));
            }
            if (/TTL=/i.test(stdout)) {
                return resolve(+(performance.now() - t0).toFixed(1));
            }
            resolve(null);
        });
    });
}

async function runProbeLoop(sig, probeAgent) {
    const httpRtts = [];
    const icmpRtts = [];
    await httpProbe(probeAgent);

    const httpLoop = (async () => {
        while (!sig.stop) {
            const ms = await httpProbe(probeAgent);
            if (sig.collect && ms !== null) {
                httpRtts.push(ms);
            }
            await new Promise((r) => setTimeout(r, 150));
        }
    })();

    const icmpLoop = (async () => {
        while (!sig.stop) {
            const ms = await icmpPingOnce(PROBE_HOST);
            if (sig.collect && ms !== null) {
                icmpRtts.push(ms);
            }
            await new Promise((r) => setTimeout(r, 250));
        }
    })();

    await Promise.all([httpLoop, icmpLoop]);
    return { http: stats(httpRtts), icmp: stats(icmpRtts) };
}

async function runIdle() {
    const probeAgent = new https.Agent({ keepAlive: true, maxSockets: 2 });
    const sig = { stop: false, collect: true };
    const probes = runProbeLoop(sig, probeAgent);
    await new Promise((r) => setTimeout(r, 5000));
    sig.stop = true;
    const res = await probes;
    probeAgent.destroy();
    return res;
}

async function runTransfer(direction) {
    const bulkAgent = new https.Agent({ keepAlive: true, maxSockets: STREAMS + 2 });
    const probeAgent = new https.Agent({ keepAlive: true, maxSockets: 2 });
    const payload = direction === "up" ? Buffer.alloc(2 * 1024 * 1024, 0x61) : null;
    const sig = { stop: false, collect: false };
    let steadyBytes = 0;
    let measuring = false;
    const active = new Set();

    const worker = async () => {
        while (!sig.stop) {
            await new Promise((resolve) => {
                const opts =
                    direction === "down"
                        ? { host: SPEED_HOST, path: "/__down?bytes=50000000", method: "GET", agent: bulkAgent }
                        : {
                              host: SPEED_HOST,
                              path: "/__up",
                              method: "POST",
                              agent: bulkAgent,
                              headers: {
                                  "Content-Type": "application/octet-stream",
                                  "Content-Length": payload.length,
                              },
                          };
                const req = https.request(opts, (res) => {
                    res.on("data", (chunk) => {
                        if (direction === "down" && measuring) {
                            steadyBytes += chunk.length;
                        }
                        if (sig.stop) {
                            req.destroy();
                        }
                    });
                    res.on("end", () => {
                        if (direction === "up" && measuring && res.statusCode === 200) {
                            steadyBytes += payload.length;
                        }
                        resolve();
                    });
                    res.on("error", resolve);
                });
                active.add(req);
                req.on("error", resolve);
                req.on("close", () => active.delete(req));
                if (payload) {
                    req.end(payload);
                } else {
                    req.end();
                }
            });
        }
    };

    const probes = runProbeLoop(sig, probeAgent);
    const workers = Array.from({ length: STREAMS }, () => worker());

    await new Promise((r) => setTimeout(r, WARMUP_MS));
    measuring = true;
    sig.collect = true;
    const t0 = performance.now();
    await new Promise((r) => setTimeout(r, MEASURE_MS));
    const elapsedSec = (performance.now() - t0) / 1000;
    measuring = false;
    sig.collect = false;
    sig.stop = true;
    for (const r of active) {
        r.destroy();
    }
    await Promise.allSettled(workers);
    const latency = await probes;
    bulkAgent.destroy();
    probeAgent.destroy();

    return {
        mbps: +((steadyBytes * 8) / (elapsedSec * 1e6)).toFixed(2),
        transferredMB: +(steadyBytes / 1e6).toFixed(2),
        elapsedSec: +elapsedSec.toFixed(2),
        latency,
    };
}

function gradeBufferbloat(deltaMs) {
    if (deltaMs < 5) return "A+";
    if (deltaMs < 30) return "A";
    if (deltaMs < 60) return "B";
    if (deltaMs < 200) return "C";
    if (deltaMs < 400) return "D";
    return "F";
}

async function main() {
    if (!JSON_ONLY) {
        console.log("Running sequential throughput & bufferbloat benchmark...");
    }
    const idle = await runIdle();
    await new Promise((r) => setTimeout(r, 1000));
    const down = await runTransfer("down");
    await new Promise((r) => setTimeout(r, 2000));
    const up = await runTransfer("up");

    const downDeltaIcmp = +(down.latency.icmp.med - idle.icmp.med).toFixed(2);
    const upDeltaIcmp = +(up.latency.icmp.med - idle.icmp.med).toFixed(2);
    const downDeltaHttp = +(down.latency.http.med - idle.http.med).toFixed(2);
    const upDeltaHttp = +(up.latency.http.med - idle.http.med).toFixed(2);

    const rpm = (ms) => (ms > 0 ? Math.round(60000 / ms) : 0);
    const summary = {
        downlinkMbps: down.mbps,
        uplinkMbps: up.mbps,
        idleIcmpMs: idle.icmp,
        idleHttpMs: idle.http,
        downLoadedIcmpMs: down.latency.icmp,
        downLoadedHttpMs: down.latency.http,
        upLoadedIcmpMs: up.latency.icmp,
        upLoadedHttpMs: up.latency.http,
        bufferbloatDeltaMs: {
            downIcmp: downDeltaIcmp,
            upIcmp: upDeltaIcmp,
            downHttp: downDeltaHttp,
            upHttp: upDeltaHttp,
        },
        responsivenessRpm: {
            idle: rpm(idle.http.med),
            downloadLoaded: rpm(down.latency.http.med),
            uploadLoaded: rpm(up.latency.http.med),
        },
        bufferbloatGrade: {
            download: gradeBufferbloat(Math.max(0, downDeltaIcmp)),
            upload: gradeBufferbloat(Math.max(0, upDeltaIcmp)),
        },
    };

    if (JSON_ONLY) {
        console.log(JSON.stringify(summary, null, 2));
        return;
    }

    console.log("\n=== Throughput & Bufferbloat Summary ===");
    console.log(`Downlink : ${summary.downlinkMbps} Mbps (ICMP ${idle.icmp.med} -> ${down.latency.icmp.med} ms, +${downDeltaIcmp} ms, Grade ${summary.bufferbloatGrade.download})`);
    console.log(`Uplink   : ${summary.uplinkMbps} Mbps (ICMP ${idle.icmp.med} -> ${up.latency.icmp.med} ms, +${upDeltaIcmp} ms, Grade ${summary.bufferbloatGrade.upload})`);
    console.log(`HTTP RPM : Idle ${summary.responsivenessRpm.idle} | Download ${summary.responsivenessRpm.downloadLoaded} | Upload ${summary.responsivenessRpm.uploadLoaded}`);
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});
