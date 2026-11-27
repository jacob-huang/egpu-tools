# Reference benchmarks

Measured results for the same eGPU on different hosts. Use them to check a new host, cable, driver or kernel against a known-good setup. Run [`tools/egpu-bench`](../tools/egpu-bench) to produce comparable numbers. It's read-only, needs no root, and writes `specs.txt`, `bench.txt`, `powerlog.csv` and `summary.txt`.

```bash
egpu-on                     # eGPU online and healthy first
tools/egpu-bench            # about 12 minutes; --quick runs the 1080p part only
```

## eGPU (same for every host)

| | |
|---|---|
| Enclosure | Razer Core X V2, USB4 (Intel JHL9480 Barlow Ridge bridge) |
| GPU | Sapphire NITRO+ RX 7900 XTX Vapor-X, Navi 31 `1002:744c`, 24 GB VRAM, VBIOS `113-4E4710U-T4M` |
| Power limit | 339 W (`power1_cap`; maximum 350 W) |
| GPU link inside the enclosure | PCIe 4.0 x16 (16 GT/s), behind a PCIe 4.0 x4 uplink to the USB4 bridge |
| Resizable BAR | Off (BAR 0 is 256 MB, "Not enough PCI address space") |

## Hosts

| | Host A (reference) | Host B |
|---|---|---|
| Machine | Beelink SER-series mini PC (DMI `AZW SER`) | *pending* |
| CPU | AMD Ryzen 7 255, 8 cores / 16 threads, up to 4.97 GHz | |
| iGPU | Radeon 780M | |
| Memory | 28.6 GiB visible to the OS | |
| USB4 host | AMD USB4/Thunderbolt PCIe tunnel (root port `00:03.1`) | |
| USB4 link | 40 Gb/s (2 lanes × 20 Gb/s) | |
| OS | Ubuntu 26.04.1 LTS, kernel 7.0.0-44, GNOME 50.1 Wayland | |
| Mesa | 26.0.8 (RADV / radeonsi) | |

## Results

### 1080p link-health run

Light scenes. Most hit the CPU and link limit of about 30k fps, so this run confirms the card and link work rather than measuring the GPU's speed. `vertex device-local=false` streams vertex data over the link every frame; a big drop there points to a cable or link problem.

| Benchmark | Host A 2026-11-10 | Host A 2026-11-11 | Host A 2026-11-26 | Host B |
|---|---|---|---|---|
| `vkmark --winsys headless -s 1920x1080` | 27,302 | 27,666 | 27,877 | |
| `glmark2 --off-screen -s 1920x1080` | 10,168 | 9,912 | 9,963 | |
| vkmark `vertex device-local=false` | about 6.2k fps | 6,182 fps | 6,218 fps | |
| GPU power, vkmark (avg / peak) | — | — | 158 W / 284 W, 95% busy | |
| GPU power, glmark2 (avg / peak) | — | — | 39 W / 79 W, 49% busy | |

Host A's 780M iGPU scored 15,685 in vkmark for comparison. A ±2% difference between runs is normal variation. The 2026-11-26 power figures come from a `tools/egpu-bench --quick` run (vkmark 27,664, glmark2 10,191, `device-local=false` 6,179 fps). glmark2 at 1080p barely loads the card: it averages under 40 W at about 1,250 MHz, so **power below 70–100 W in glmark2 is normal**.

### Full-load stress run (Host A, 2026-11-26)

Phases 3–5 of `tools/egpu-bench`, with power logged every 0.5 s from the card's hwmon sensors.

| Phase | Result | Avg power | Load | GPU clock | Hotspot max | Fan max |
|---|---|---|---|---|---|---|
| Idle | — | about 8 W | 0% | idle | 57 °C | 0 rpm |
| 4K glmark2: terrain, refract, jellyfish, phong | score 4,709 (terrain 799 fps) | 65–140 W | 50–80% | about 1,250 MHz | 65 °C | 0 rpm |
| 8K glmark2: terrain, refract | score 899 (terrain 369 fps) | **332–339 W** | 80–88% | 2,700–2,950 MHz | 91 °C | about 1,900 rpm |
| 8K vkmark: blur, phong, texture | score 11,871 | **336–339 W** | 97–100% | 2,500–2,930 MHz | 96 °C | about 2,300 rpm |

What it shows:

- **At 8K the card holds its 339 W power limit** (brief spikes to 361 W) and lowers its clocks from about 2,950 to 2,500 MHz to stay within it. It's limited by power, not temperature: the hotspot peaked at 96 °C, below the roughly 110 °C throttle point.
- **The enclosure's PSU sustains full draw:** about 2½ minutes with no bus drop or driver errors (compare runbook T4).
- **glmark2 at 1080p and 4K keeps the card under 150 W** (under 40 W on average at 1080p) because it waits on the CPU and the link between frames. vkmark at 1080p loads it harder (158 W on average, 284 W peak). Low power in glmark2 is expected, not a fault. Real games and LLM inference fall between the two cases: the more of the work stays in VRAM, the closer the card gets to 339 W.

## Comparing a host

If a host draws much less power than Host A in the **8K** phases, look at `summary.txt` and `specs.txt` in this order:

1. **Power limit:** `power limit` should say 339 W. A lower cap limits power directly.
2. **USB4 link:** `tb link` should be 40 Gb/s x2. A 20 Gb/s link, a Thunderbolt 3 host or a single lane means a cable or port problem.
3. **PCIe chain:** the host root port and the enclosure's first bridge sit inside the USB4 tunnel and show a nominal 2.5 GT/s, which is normal. After them, Host A shows 16 GT/s x4 up to the GPU's switch and 16 GT/s x16 at the GPU.
4. **CPU:** compare the `CPU MHz` column and `cpu governor` / `platform profile`. A slower or power-saving CPU can't feed the GPU at 1080p or 4K, but at 8K the GPU should still be the bottleneck.
5. **Load:** if `busy%` stays well under 90% at 8K, the GPU is waiting on something else (CPU or link).
