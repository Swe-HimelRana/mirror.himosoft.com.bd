#!/usr/bin/env python3
"""Himosoft Server Status — live human-readable system dashboard."""

from __future__ import annotations

import argparse
import os
import re
import signal
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import timedelta
from typing import Dict, List, Tuple

try:
    from rich import box
    from rich.align import Align
    from rich.console import Console
    from rich.layout import Layout
    from rich.live import Live
    from rich.panel import Panel
    from rich.table import Table
    from rich.text import Text
except ImportError:
    print("python3-rich is required: sudo apt install python3-rich", file=sys.stderr)
    sys.exit(1)


console = Console()
running = True


def handle_sigint(_signum, _frame):
    global running
    running = False


signal.signal(signal.SIGINT, handle_sigint)
signal.signal(signal.SIGTERM, handle_sigint)


@dataclass
class CpuSnapshot:
    total: Tuple[int, ...] = (0,) * 8
    per_cpu: List[Tuple[int, ...]] = field(default_factory=list)


@dataclass
class NetSnapshot:
    rx: int = 0
    tx: int = 0


@dataclass
class ProcessRow:
    pid: str
    user: str
    cpu: str
    mem: str
    swap_kb: int
    cmd: str


def read_uptime() -> float:
    with open("/proc/uptime", encoding="utf-8") as f:
        return float(f.read().split()[0])


def human_uptime(seconds: float) -> str:
    td = timedelta(seconds=int(seconds))
    days = td.days
    hours, rem = divmod(td.seconds, 3600)
    minutes, _ = divmod(rem, 60)
    parts = []
    if days:
        parts.append(f"{days}d")
    if hours:
        parts.append(f"{hours}h")
    parts.append(f"{minutes}m")
    return " ".join(parts)


def parse_cpu_line(line: str) -> Tuple[int, ...]:
    parts = line.split()
    nums = [int(x) for x in parts[1:]]
    while len(nums) < 8:
        nums.append(0)
    return tuple(nums[:8])


def read_cpu() -> CpuSnapshot:
    snap = CpuSnapshot()
    with open("/proc/stat", encoding="utf-8") as f:
        for line in f:
            if line.startswith("cpu "):
                snap.total = parse_cpu_line(line)
            elif line.startswith("cpu"):
                snap.per_cpu.append(parse_cpu_line(line))
            elif not line.startswith("cpu"):
                break
    return snap


def cpu_usage(prev: CpuSnapshot, cur: CpuSnapshot) -> Tuple[float, List[float]]:
    def pct(a: Tuple[int, ...], b: Tuple[int, ...]) -> float:
        da = sum(b) - sum(a)
        didle = b[3] - a[3]
        if da <= 0:
            return 0.0
        return max(0.0, min(100.0, 100.0 * (1.0 - didle / da)))

    overall = pct(prev.total, cur.total)
    per = []
    for i, c in enumerate(cur.per_cpu):
        p = prev.per_cpu[i] if i < len(prev.per_cpu) else (0,) * 8
        per.append(pct(p, c))
    return overall, per


def read_meminfo() -> Dict[str, int]:
    info: Dict[str, int] = {}
    with open("/proc/meminfo", encoding="utf-8") as f:
        for line in f:
            m = re.match(r"(\w+):\s+(\d+)", line)
            if m:
                info[m.group(1)] = int(m.group(2))
    return info


def read_loadavg() -> Tuple[float, float, float]:
    with open("/proc/loadavg", encoding="utf-8") as f:
        parts = f.read().split()
    return float(parts[0]), float(parts[1]), float(parts[2])


def cpu_count() -> int:
    try:
        return os.cpu_count() or 1
    except Exception:
        return 1


def read_disks() -> List[Tuple[str, str, str, str, str]]:
    rows: List[Tuple[str, str, str, str, str]] = []
    try:
        out = subprocess.check_output(["df", "-hP", "--output=target,size,used,avail,pcent"], text=True)
    except (subprocess.CalledProcessError, FileNotFoundError):
        return rows
    for line in out.strip().splitlines()[1:]:
        parts = line.split()
        if len(parts) < 5:
            continue
        mount = parts[0]
        if mount.startswith("/snap"):
            continue
        rows.append((mount, parts[1], parts[2], parts[3], parts[4]))
    return rows[:6]


def read_net() -> NetSnapshot:
    snap = NetSnapshot()
    with open("/proc/net/dev", encoding="utf-8") as f:
        for line in f.readlines()[2:]:
            if ":" not in line:
                continue
            iface, data = line.split(":", 1)
            iface = iface.strip()
            if iface == "lo":
                continue
            cols = data.split()
            if len(cols) >= 16:
                snap.rx += int(cols[0])
                snap.tx += int(cols[8])
    return snap


def net_rate(prev: NetSnapshot, cur: NetSnapshot, dt: float) -> Tuple[float, float]:
    if dt <= 0:
        return 0.0, 0.0
    return (cur.rx - prev.rx) / dt, (cur.tx - prev.tx) / dt


def format_rate(bps: float) -> str:
    bps = max(0.0, bps)
    for unit in ("B/s", "KB/s", "MB/s", "GB/s"):
        if bps < 1024 or unit == "GB/s":
            return f"{bps:.1f} {unit}"
        bps /= 1024
    return f"{bps:.1f} GB/s"


def bar(pct: float, width: int = 28) -> Text:
    pct = max(0.0, min(100.0, pct))
    filled = int(round(width * pct / 100.0))
    t = Text()
    if pct >= 85:
        color = "red"
    elif pct >= 65:
        color = "yellow"
    else:
        color = "green"
    t.append("█" * filled, style=color)
    t.append("░" * (width - filled), style="dim")
    return t


def kb_human(kb: int) -> str:
    if kb <= 0:
        return "0 MB"
    gb = kb / (1024 * 1024)
    if gb >= 1:
        return f"{gb:.1f} GB"
    return f"{kb / 1024:.0f} MB"


def read_proc_swap_kb(pid: str) -> int:
    try:
        with open(f"/proc/{pid}/status", encoding="utf-8") as f:
            for line in f:
                if line.startswith("VmSwap:"):
                    return int(line.split()[1])
    except (OSError, ValueError):
        pass
    return 0


def read_top_processes(sort_by: str = "pcpu", limit: int = 6) -> List[ProcessRow]:
    sort_key = "pcpu" if sort_by == "cpu" else "pmem"
    try:
        out = subprocess.check_output(
            ["ps", "-eo", "pid,user,pcpu,pmem,comm", f"--sort=-{sort_key}"],
            text=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return []
    rows: List[ProcessRow] = []
    for line in out.strip().splitlines()[1 : limit + 1]:
        parts = line.split(None, 4)
        if len(parts) < 5:
            continue
        pid, user, cpu, mem, cmd = parts
        swap_kb = read_proc_swap_kb(pid)
        rows.append(ProcessRow(pid, user, cpu, mem, swap_kb, cmd[:36]))
    return rows


def service_state(unit: str) -> str:
    try:
        out = subprocess.check_output(
            ["systemctl", "is-active", unit], stderr=subprocess.DEVNULL, text=True
        ).strip()
        return out if out else "unknown"
    except (subprocess.CalledProcessError, FileNotFoundError):
        return "n/a"


def status_style(state: str) -> str:
    if state == "active":
        return "bold green"
    if state in ("inactive", "failed"):
        return "bold red"
    return "dim"


def build_header(interval: float) -> Panel:
    hostname = os.uname().nodename
    uptime_s = read_uptime()
    l1, l5, l15 = read_loadavg()
    ncpu = cpu_count()

    grid = Table.grid(expand=True)
    grid.add_column(ratio=1)
    grid.add_column(ratio=1)
    grid.add_row(
        Text(f"Host  {hostname}", style="bold cyan"),
        Text(f"Refresh  every {interval:g}s  ·  Ctrl+C to quit", style="dim"),
    )
    grid.add_row(
        Text(f"Up    {human_uptime(uptime_s)}"),
        Text(f"Load  {l1:.2f}  {l5:.2f}  {l15:.2f}  ({ncpu} CPUs)", style="bold"),
    )
    return Panel(grid, title="[bold]Himosoft Server Status[/bold]", border_style="cyan", box=box.ROUNDED)


def build_cpu_panel(overall: float, per_core: List[float]) -> Panel:
    t = Table(show_header=False, box=None, padding=(0, 1), expand=True)
    t.add_column("Label", style="bold")
    t.add_column("Bar", ratio=1)
    t.add_column("Pct", justify="right", width=7)

    label = "Overall"
    if overall >= 85:
        style = "red"
    elif overall >= 65:
        style = "yellow"
    else:
        style = "green"
    t.add_row(label, bar(overall), Text(f"{overall:5.1f}%", style=style))

    for i, p in enumerate(per_core[:16]):
        t.add_row(f"Core {i}", bar(p, width=22), f"{p:5.1f}%")

    return Panel(t, title="[bold]CPU[/bold]", border_style="green", box=box.ROUNDED)


def build_memory_panel(mem: Dict[str, int]) -> Panel:
    total = mem.get("MemTotal", 1)
    avail = mem.get("MemAvailable", mem.get("MemFree", 0))
    used = total - avail
    swap_total = mem.get("SwapTotal", 0)
    swap_free = mem.get("SwapFree", 0)
    swap_used = swap_total - swap_free
    swap_cached = mem.get("SwapCached", 0)

    used_pct = 100.0 * used / total if total else 0
    swap_pct = 100.0 * swap_used / swap_total if swap_total else 0.0

    t = Table(show_header=False, box=None, padding=(0, 1), expand=True)
    t.add_column("Label", style="bold", width=10)
    t.add_column("Bar", ratio=1)
    t.add_column("Detail", justify="right", min_width=28)

    mem_style = "red" if used_pct >= 85 else ("yellow" if used_pct >= 65 else "green")
    t.add_row(
        "RAM",
        bar(used_pct),
        Text(f"{kb_human(used)} used · {kb_human(avail)} free · {used_pct:.0f}%", style=mem_style),
    )
    t.add_row(
        "",
        Text(f"Total {kb_human(total)}", style="dim"),
        "",
    )

    if swap_total:
        swap_style = "red" if swap_pct >= 50 else ("yellow" if swap_pct >= 25 else "cyan")
        t.add_row(
            "Swap",
            bar(swap_pct),
            Text(
                f"{kb_human(swap_used)} used · {kb_human(swap_free)} free · {swap_pct:.0f}%",
                style=swap_style,
            ),
        )
        if swap_cached:
            t.add_row(
                "",
                Text(f"Swap cached {kb_human(swap_cached)}", style="dim"),
                "",
            )
    else:
        t.add_row("Swap", Text("not configured", style="dim"), Text("0 MB", style="dim"))

    return Panel(t, title="[bold]Memory & Swap[/bold]", border_style="magenta", box=box.ROUNDED)


def build_disk_panel(disks: List[Tuple[str, ...]]) -> Panel:
    t = Table(show_header=True, box=box.SIMPLE_HEAD, expand=True, padding=(0, 1))
    t.add_column("Mount", style="cyan")
    t.add_column("Use", ratio=1)
    t.add_column("Used", justify="right")
    t.add_column("Size", justify="right")
    t.add_column("Free", justify="right")

    for row in disks:
        mount, size, used, avail, pct_str = row
        try:
            pct = float(str(pct_str).rstrip("%"))
        except ValueError:
            pct = 0.0
        t.add_row(mount, bar(pct, width=20), used, size, avail)

    if not disks:
        t.add_row("—", "no data", "", "", "")

    return Panel(t, title="[bold]Disk[/bold]", border_style="yellow", box=box.ROUNDED)


def build_network_panel(rx_rate: float, tx_rate: float) -> Panel:
    t = Table(show_header=False, box=None, padding=(0, 1), expand=True)
    t.add_column("Dir", style="bold")
    t.add_column("Rate", style="bold green")

    t.add_row("Download ↓", format_rate(rx_rate))
    t.add_row("Upload   ↑", format_rate(tx_rate))
    return Panel(t, title="[bold]Network[/bold] (all interfaces)", border_style="blue", box=box.ROUNDED)


def build_services_panel() -> Panel:
    services = [
        ("k3s", "K3s"),
        ("docker", "Docker"),
        ("ufw", "Firewall (UFW)"),
        ("prometheus-node-exporter", "Node exporter"),
    ]
    t = Table(show_header=False, box=None, padding=(0, 1), expand=True)
    t.add_column("Service")
    t.add_column("State")
    for unit, label in services:
        state = service_state(unit)
        t.add_row(label, Text(state, style=status_style(state)))
    return Panel(t, title="[bold]Services[/bold]", border_style="white", box=box.ROUNDED)


def build_process_table(title: str, sort_by: str, border: str) -> Panel:
    t = Table(show_header=True, box=box.SIMPLE_HEAD, expand=True, padding=(0, 1))
    t.add_column("PID", style="bold cyan", width=8)
    t.add_column("User", width=8)
    t.add_column("CPU%", justify="right", width=6)
    t.add_column("MEM%", justify="right", width=6)
    t.add_column("Swap", justify="right", width=8)
    t.add_column("Application")

    for proc in read_top_processes(sort_by=sort_by, limit=6):
        cpu_f = float(proc.cpu)
        mem_f = float(proc.mem)
        cpu_style = "bold red" if cpu_f >= 50 else ("yellow" if cpu_f >= 20 else "")
        mem_style = "bold red" if mem_f >= 50 else ("yellow" if mem_f >= 25 else "")
        swap_txt = kb_human(proc.swap_kb) if proc.swap_kb else "—"
        swap_style = "red" if proc.swap_kb >= 512 * 1024 else ("yellow" if proc.swap_kb >= 128 * 1024 else "dim")

        t.add_row(
            proc.pid,
            proc.user,
            Text(proc.cpu, style=cpu_style if sort_by == "cpu" else ""),
            Text(proc.mem, style=mem_style if sort_by == "mem" else ""),
            Text(swap_txt, style=swap_style),
            proc.cmd,
        )

    subtitle = "by CPU usage" if sort_by == "cpu" else "by memory usage"
    return Panel(t, title=f"[bold]{title}[/bold] ({subtitle})", border_style=border, box=box.ROUNDED)


def render_dashboard(
    interval: float,
    overall_cpu: float,
    per_cpu: List[float],
    mem: Dict[str, int],
    disks: List[Tuple[str, ...]],
    rx_rate: float,
    tx_rate: float,
) -> Layout:
    layout = Layout()
    layout.split_column(
        Layout(name="header", size=5),
        Layout(name="body"),
        Layout(name="processes", size=11),
        Layout(name="footer", size=3),
    )
    layout["body"].split_row(
        Layout(name="left", ratio=3),
        Layout(name="right", ratio=2),
    )
    layout["left"].split_column(
        Layout(name="cpu", ratio=2),
        Layout(name="mem", ratio=1),
        Layout(name="disk", ratio=2),
    )
    layout["right"].split_column(
        Layout(name="net", size=6),
        Layout(name="svc"),
    )
    layout["processes"].split_row(
        Layout(name="top_cpu", ratio=1),
        Layout(name="top_mem", ratio=1),
    )
    layout["processes"]["top_cpu"].update(build_process_table("Top applications", "cpu", "red"))
    layout["processes"]["top_mem"].update(build_process_table("Top applications", "mem", "blue"))

    layout["header"].update(build_header(interval))
    layout["cpu"].update(build_cpu_panel(overall_cpu, per_cpu))
    layout["mem"].update(build_memory_panel(mem))
    layout["disk"].update(build_disk_panel(disks))
    layout["net"].update(build_network_panel(rx_rate, tx_rate))
    layout["svc"].update(build_services_panel())

    ts = time.strftime("%H:%M:%S")
    layout["footer"].update(
        Panel(
            Align.center(
                Text(f"Live · updated {ts}  ·  Himosoft Server Status", style="dim"),
            ),
            box=box.ROUNDED,
            border_style="dim",
        )
    )
    return layout


def main() -> int:
    if not sys.stdout.isatty():
        print(
            "himosoft-server-status requires an interactive terminal (TTY).\n"
            "Connect with: ssh -t user@host",
            file=sys.stderr,
        )
        return 1

    parser = argparse.ArgumentParser(description="Himosoft Server Status dashboard")
    parser.add_argument("--interval", type=float, default=2.0, help="Refresh interval in seconds")
    args = parser.parse_args()

    interval = max(0.5, args.interval)

    try:
        prev_cpu = read_cpu()
        prev_net = read_net()
        prev_t = time.time()
        overall_cpu = 0.0
        per_cpu: List[float] = []
        rx_rate = tx_rate = 0.0

        time.sleep(0.3)
        cur_cpu = read_cpu()
        overall_cpu, per_cpu = cpu_usage(prev_cpu, cur_cpu)
        prev_cpu = cur_cpu

        use_screen = sys.stdout.isatty()
        with Live(
            console=console,
            refresh_per_second=max(1, min(10, int(1.0 / interval))),
            screen=use_screen,
        ) as live:
            while running:
                now = time.time()
                dt = now - prev_t
                cur_cpu = read_cpu()
                cur_net = read_net()
                overall_cpu, per_cpu = cpu_usage(prev_cpu, cur_cpu)
                rx_rate, tx_rate = net_rate(prev_net, cur_net, dt)
                prev_cpu, prev_net, prev_t = cur_cpu, cur_net, now

                mem = read_meminfo()
                disks = read_disks()

                live.update(
                    render_dashboard(interval, overall_cpu, per_cpu, mem, disks, rx_rate, tx_rate)
                )
                time.sleep(interval)

        if use_screen:
            console.clear()
        console.print("[dim]Dashboard stopped.[/dim]")
    except Exception as exc:
        print(f"himosoft-server-status error: {exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
