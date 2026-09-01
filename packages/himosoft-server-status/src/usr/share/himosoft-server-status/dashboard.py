#!/usr/bin/env python3
"""Himosoft Server Status — live human-readable system dashboard."""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import select
import signal
import subprocess
import sys
import termios
import threading
import time
import tty
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional, Tuple

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


def stop_running() -> None:
    global running
    running = False


def handle_sigint(_signum, _frame) -> None:
    stop_running()


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
    ifaces: Dict[str, Tuple[int, int]] = field(default_factory=dict)


@dataclass
class DiskIoSnapshot:
    sectors: Dict[str, Tuple[int, int]] = field(default_factory=dict)


@dataclass
class ProcessRow:
    pid: str
    user: str
    cpu: str
    mem: str
    swap_kb: int
    cmd: str


@dataclass
class CertInfo:
    name: str
    expires: str
    days_left: int


# ── helpers ──────────────────────────────────────────────────────────────


def run_quiet(cmd: List[str]) -> str:
    try:
        return subprocess.check_output(cmd, stderr=subprocess.DEVNULL, text=True).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return ""


def bytes_human(num: float) -> str:
    if num <= 0:
        return "0 B"
    units = ["B", "KB", "MB", "GB", "TB"]
    size = float(num)
    for unit in units:
        if size < 1024 or unit == units[-1]:
            return f"{int(size)} B" if unit == "B" else f"{size:.1f} {unit}"
        size /= 1024
    return f"{size:.1f} TB"


def kb_human(kb: int) -> str:
    return bytes_human(kb * 1024)


def bar(pct: float, width: int = 28) -> Text:
    pct = max(0.0, min(100.0, pct))
    filled = int(round(width * pct / 100.0))
    color = "red" if pct >= 85 else ("yellow" if pct >= 65 else "green")
    t = Text()
    t.append("█" * filled, style=color)
    t.append("░" * (width - filled), style="dim")
    return t


def format_rate(bps: float) -> str:
    return bytes_human(max(0.0, bps)) + "/s"


def human_uptime(seconds: float) -> str:
    td = timedelta(seconds=int(seconds))
    parts = []
    if td.days:
        parts.append(f"{td.days}d")
    hours, rem = divmod(td.seconds, 3600)
    if hours:
        parts.append(f"{hours}h")
    parts.append(f"{rem // 60}m")
    return " ".join(parts)


# ── system info ──────────────────────────────────────────────────────────


def read_os_pretty() -> str:
    try:
        with open("/etc/os-release", encoding="utf-8") as f:
            for line in f:
                if line.startswith("PRETTY_NAME="):
                    return line.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    return "Linux"


def read_cpu_model() -> str:
    try:
        with open("/proc/cpuinfo", encoding="utf-8") as f:
            for line in f:
                if line.startswith("model name"):
                    return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return os.uname().machine


def read_primary_ip() -> str:
    out = run_quiet(["hostname", "-I"])
    return out.split()[0] if out else "—"


def read_system_info() -> Dict[str, str]:
    u = os.uname()
    return {
        "hostname": u.nodename,
        "os": read_os_pretty(),
        "kernel": u.release,
        "arch": u.machine,
        "cpu_model": read_cpu_model(),
        "cpu_cores": str(os.cpu_count() or 1),
        "ip": read_primary_ip(),
    }


def read_cpu_temps() -> List[Tuple[str, float]]:
    temps: List[Tuple[str, float]] = []
    for path in sorted(glob.glob("/sys/class/thermal/thermal_zone*")):
        temp_file = os.path.join(path, "temp")
        type_file = os.path.join(path, "type")
        try:
            with open(temp_file, encoding="utf-8") as f:
                millideg = int(f.read().strip())
            label = os.path.basename(path)
            if os.path.isfile(type_file):
                with open(type_file, encoding="utf-8") as f:
                    label = f.read().strip()
            temps.append((label, millideg / 1000.0))
        except (OSError, ValueError):
            continue
    return temps[:4]


# ── cpu / mem / load ─────────────────────────────────────────────────────


def read_uptime() -> float:
    with open("/proc/uptime", encoding="utf-8") as f:
        return float(f.read().split()[0])


def parse_cpu_line(line: str) -> Tuple[int, ...]:
    nums = [int(x) for x in line.split()[1:]]
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
            else:
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
    per = [pct(prev.per_cpu[i] if i < len(prev.per_cpu) else (0,) * 8, c)
           for i, c in enumerate(cur.per_cpu)]
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
        p = f.read().split()
    return float(p[0]), float(p[1]), float(p[2])


# ── disk usage & I/O ─────────────────────────────────────────────────────


def read_disks() -> List[Tuple[str, str, str, str, str]]:
    rows: List[Tuple[str, str, str, str, str]] = []
    seen: set[str] = set()
    skip_types = {
        "proc", "sysfs", "devtmpfs", "tmpfs", "cgroup", "cgroup2", "squashfs",
        "overlay", "securityfs", "pstore", "bpf", "tracefs", "debugfs",
        "configfs", "fusectl", "mqueue", "hugetlbfs",
    }
    try:
        with open("/proc/mounts", encoding="utf-8") as f:
            mounts = []
            for line in f:
                parts = line.split()
                if len(parts) < 3:
                    continue
                mount, fstype = parts[1], parts[2]
                if mount in seen or mount.startswith("/snap") or fstype in skip_types:
                    continue
                seen.add(mount)
                mounts.append(mount)
    except OSError:
        return rows

    for mount in mounts:
        try:
            st = os.statvfs(mount)
        except OSError:
            continue
        total = st.f_blocks * st.f_frsize
        free = st.f_bavail * st.f_frsize
        if total <= 0:
            continue
        used = total - free
        pct = 100.0 * used / total
        rows.append((mount, bytes_human(total), bytes_human(used), bytes_human(free), f"{pct:.0f}%"))
        if len(rows) >= 5:
            break
    return rows


def read_disk_io() -> DiskIoSnapshot:
    snap = DiskIoSnapshot()
    try:
        with open("/proc/diskstats", encoding="utf-8") as f:
            for line in f:
                parts = line.split()
                if len(parts) < 14:
                    continue
                name = parts[2]
                if name.startswith(("loop", "ram", "dm-")):
                    continue
                snap.sectors[name] = (int(parts[5]), int(parts[9]))
    except OSError:
        pass
    return snap


def disk_io_rates(prev: DiskIoSnapshot, cur: DiskIoSnapshot, dt: float) -> List[Tuple[str, float, float]]:
    if dt <= 0:
        return []
    rates: List[Tuple[str, float, float]] = []
    for name, (rs, ws) in cur.sectors.items():
        prs, pws = prev.sectors.get(name, (rs, ws))
        read_bps = (rs - prs) * 512 / dt
        write_bps = (ws - pws) * 512 / dt
        rates.append((name, max(0.0, read_bps), max(0.0, write_bps)))
    rates.sort(key=lambda x: x[1] + x[2], reverse=True)
    return rates[:5]


# ── network ──────────────────────────────────────────────────────────────


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
                rx, tx = int(cols[0]), int(cols[8])
                snap.rx += rx
                snap.tx += tx
                snap.ifaces[iface] = (rx, tx)
    return snap


def net_rate(prev: NetSnapshot, cur: NetSnapshot, dt: float) -> Tuple[float, float]:
    if dt <= 0:
        return 0.0, 0.0
    return (cur.rx - prev.rx) / dt, (cur.tx - prev.tx) / dt


def iface_rates(prev: NetSnapshot, cur: NetSnapshot, dt: float) -> List[Tuple[str, float, float]]:
    if dt <= 0:
        return []
    rates = []
    for iface, (rx, tx) in cur.ifaces.items():
        prx, ptx = prev.ifaces.get(iface, (rx, tx))
        rates.append((iface, (rx - prx) / dt, (tx - ptx) / dt))
    rates.sort(key=lambda x: x[1] + x[2], reverse=True)
    return rates[:4]


# ── processes & health signals ───────────────────────────────────────────


def read_proc_swap_kb(pid: str) -> int:
    try:
        with open(f"/proc/{pid}/status", encoding="utf-8") as f:
            for line in f:
                if line.startswith("VmSwap:"):
                    return int(line.split()[1])
    except (OSError, ValueError):
        pass
    return 0


def read_top_processes(sort_by: str = "cpu", limit: int = 6) -> List[ProcessRow]:
    sort_key = "pcpu" if sort_by == "cpu" else "pmem"
    out = run_quiet(["ps", "-eo", "pid,user,pcpu,pmem,comm", f"--sort=-{sort_key}"])
    if not out:
        return []
    rows: List[ProcessRow] = []
    for line in out.splitlines()[1 : limit + 1]:
        parts = line.split(None, 4)
        if len(parts) < 5:
            continue
        pid, user, cpu, mem, cmd = parts
        rows.append(ProcessRow(pid, user, cpu, mem, read_proc_swap_kb(pid), cmd[:36]))
    return rows


def zombie_count() -> int:
    out = run_quiet(["ps", "-eo", "stat"])
    if not out:
        return 0
    return sum(1 for line in out.splitlines()[1:] if "Z" in line.split()[0])


def failed_systemd_units() -> List[str]:
    out = run_quiet(["systemctl", "--failed", "--no-legend", "--plain"])
    if not out:
        return []
    units = []
    for line in out.splitlines():
        parts = line.split()
        if parts:
            units.append(parts[0])
    return units


# ── services / k3s / docker ──────────────────────────────────────────────


def service_state(unit: str) -> str:
    out = run_quiet(["systemctl", "is-active", unit])
    return out if out else "n/a"


def status_style(state: str) -> str:
    if state == "active":
        return "bold green"
    if state in ("inactive", "failed"):
        return "bold red"
    return "dim"


def docker_container_count() -> str:
    if service_state("docker") != "active":
        return "—"
    out = run_quiet(["docker", "ps", "-q"])
    return f"{len(out.splitlines())} running" if out else "0 running"


def k3s_summary() -> str:
    if service_state("k3s") != "active":
        return "—"
    nodes = run_quiet(["k3s", "kubectl", "get", "nodes", "--no-headers"])
    pods = run_quiet(["k3s", "kubectl", "get", "pods", "-A", "--no-headers"])
    n = len(nodes.splitlines()) if nodes else 0
    p = len(pods.splitlines()) if pods else 0
    return f"{n} node(s) · {p} pods"


def k3s_crashloop_count() -> int:
    if service_state("k3s") != "active":
        return 0
    out = run_quiet(["k3s", "kubectl", "get", "pods", "-A", "--no-headers"])
    if not out:
        return 0
    return sum(1 for line in out.splitlines() if "CrashLoopBackOff" in line)


# ── TLS certificates ─────────────────────────────────────────────────────


def _cert_expiry(path: str) -> Optional[CertInfo]:
    out = run_quiet(["openssl", "x509", "-enddate", "-noout", "-in", path])
    if not out.startswith("notAfter="):
        return None
    date_str = out.split("=", 1)[1].strip()
    try:
        expires = datetime.strptime(date_str, "%b %d %H:%M:%S %Y %Z")
        expires = expires.replace(tzinfo=timezone.utc)
    except ValueError:
        return None
    days = (expires - datetime.now(timezone.utc)).days
    name = os.path.basename(os.path.dirname(path)) or os.path.basename(path)
    return CertInfo(name=name, expires=expires.strftime("%Y-%m-%d"), days_left=days)


def find_tls_certs() -> List[CertInfo]:
    paths: List[str] = []
    paths.extend(glob.glob("/etc/letsencrypt/live/*/cert.pem"))
    paths.extend(glob.glob("/var/lib/docker/volumes/*/_data/acme.json"))
    paths.extend(glob.glob("/var/lib/docker/volumes/*/acme.json"))
    for acme in glob.glob("/var/lib/docker/volumes/**/acme.json", recursive=True):
        if acme not in paths:
            paths.append(acme)

    certs: List[CertInfo] = []
    seen: set[str] = set()
    for path in paths:
        if path.endswith("acme.json"):
            continue
        info = _cert_expiry(path)
        if info and info.name not in seen:
            seen.add(info.name)
            certs.append(info)

    # Traefik acme.json — extract domain certs via openssl store if cert.pem symlinks exist
    for acme_path in glob.glob("/var/lib/docker/volumes/**/acme.json", recursive=True):
        label = os.path.basename(os.path.dirname(os.path.dirname(acme_path)))
        # Try companion fullchain in same dir
        for candidate in glob.glob(os.path.join(os.path.dirname(acme_path), "*.pem")):
            info = _cert_expiry(candidate)
            if info:
                info.name = f"traefik/{label}"
                if info.name not in seen:
                    seen.add(info.name)
                    certs.append(info)

    certs.sort(key=lambda c: c.days_left)
    return certs[:5]


# ── UI panels ────────────────────────────────────────────────────────────


def build_header(interval: float, sysinfo: Dict[str, str], temps: List[Tuple[str, float]]) -> Panel:
    l1, l5, l15 = read_loadavg()
    uptime_s = read_uptime()
    temp_txt = " · ".join(f"{z}: {t:.0f}°C" for z, t in temps[:2]) if temps else "n/a"

    grid = Table.grid(expand=True)
    grid.add_column(ratio=1)
    grid.add_column(ratio=1)
    grid.add_row(
        Text(f"Host   {sysinfo['hostname']}", style="bold cyan"),
        Text(f"IP     {sysinfo['ip']}", style="dim"),
    )
    grid.add_row(
        Text(f"OS     {sysinfo['os']}", style="bold"),
        Text(f"Kernel {sysinfo['kernel']} ({sysinfo['arch']})", style="dim"),
    )
    grid.add_row(
        Text(f"CPU    {sysinfo['cpu_model']}", style="dim"),
        Text(f"Cores  {sysinfo['cpu_cores']}  ·  Temp  {temp_txt}", style="dim"),
    )
    grid.add_row(
        Text(f"Up     {human_uptime(uptime_s)}  ·  Load {l1:.2f} {l5:.2f} {l15:.2f}", style="bold"),
        Text(f"Refresh {interval:g}s  ·  [q] quit  ·  Ctrl+C", style="dim"),
    )
    return Panel(grid, title="[bold]Himosoft Server Status[/bold]", border_style="cyan", box=box.ROUNDED)


def build_alerts_panel(
    failed: List[str], zombies: int, crashloops: int, certs: List[CertInfo]
) -> Panel:
    items: List[Text] = []
    if failed:
        items.append(Text(f"⚠ {len(failed)} failed systemd unit(s): {', '.join(failed[:3])}", style="bold red"))
    else:
        items.append(Text("✓ No failed systemd units", style="green"))
    items.append(Text(f"  Zombies: {zombies}", style="yellow" if zombies else "dim"))
    items.append(Text(f"  K3s CrashLoopBackOff: {crashloops}", style="bold red" if crashloops else "dim"))
    expiring = [c for c in certs if c.days_left <= 30]
    if expiring:
        for c in expiring[:2]:
            style = "bold red" if c.days_left <= 7 else "yellow"
            items.append(Text(f"  TLS {c.name} expires in {c.days_left}d ({c.expires})", style=style))
    elif certs:
        items.append(Text(f"  TLS: {certs[0].name} OK ({certs[0].days_left}d left)", style="green"))
    else:
        items.append(Text("  TLS: no certs found (check /etc/letsencrypt)", style="dim"))

    body = Text("\n").join(items)
    border = "red" if failed or crashloops or any(c.days_left <= 7 for c in certs) else "yellow"
    return Panel(body, title="[bold]Alerts[/bold]", border_style=border, box=box.ROUNDED)


def build_cpu_panel(overall: float, per_core: List[float]) -> Panel:
    t = Table(show_header=False, box=None, padding=(0, 1), expand=True)
    t.add_column("Label", style="bold")
    t.add_column("Bar", ratio=1)
    t.add_column("Pct", justify="right", width=7)
    style = "red" if overall >= 85 else ("yellow" if overall >= 65 else "green")
    t.add_row("Overall", bar(overall), Text(f"{overall:5.1f}%", style=style))
    for i, p in enumerate(per_core[:8]):
        t.add_row(f"Core {i}", bar(p, width=20), f"{p:5.1f}%")
    return Panel(t, title="[bold]CPU[/bold]", border_style="green", box=box.ROUNDED)


def build_memory_panel(mem: Dict[str, int]) -> Panel:
    total = mem.get("MemTotal", 1)
    avail = mem.get("MemAvailable", mem.get("MemFree", 0))
    used = total - avail
    swap_total = mem.get("SwapTotal", 0)
    swap_free = mem.get("SwapFree", 0)
    swap_used = swap_total - swap_free
    used_pct = 100.0 * used / total if total else 0
    swap_pct = 100.0 * swap_used / swap_total if swap_total else 0.0

    t = Table(show_header=False, box=None, padding=(0, 1), expand=True)
    t.add_column("Label", style="bold", width=8)
    t.add_column("Bar", ratio=1)
    t.add_column("Detail", justify="right")
    mem_style = "red" if used_pct >= 85 else ("yellow" if used_pct >= 65 else "green")
    t.add_row("RAM", bar(used_pct), Text(f"{kb_human(used)} / {kb_human(total)} ({used_pct:.0f}%)", style=mem_style))
    if swap_total:
        swap_style = "red" if swap_pct >= 50 else ("yellow" if swap_pct >= 25 else "cyan")
        t.add_row("Swap", bar(swap_pct), Text(f"{kb_human(swap_used)} / {kb_human(swap_total)} ({swap_pct:.0f}%)", style=swap_style))
    else:
        t.add_row("Swap", Text("—", style="dim"), Text("not configured", style="dim"))
    return Panel(t, title="[bold]Memory & Swap[/bold]", border_style="magenta", box=box.ROUNDED)


def build_disk_panel(disks: List[Tuple[str, ...]]) -> Panel:
    t = Table(show_header=True, box=box.SIMPLE_HEAD, expand=True, padding=(0, 1))
    t.add_column("Mount", style="cyan")
    t.add_column("Use", ratio=1)
    t.add_column("Used", justify="right")
    t.add_column("Free", justify="right")
    for row in disks:
        mount, size, used, free, pct_str = row
        try:
            pct = float(str(pct_str).rstrip("%"))
        except ValueError:
            pct = 0.0
        t.add_row(mount, bar(pct, width=16), used, free)
    if not disks:
        t.add_row("—", "no data", "", "")
    return Panel(t, title="[bold]Disk space[/bold]", border_style="yellow", box=box.ROUNDED)


def build_disk_io_panel(rates: List[Tuple[str, float, float]]) -> Panel:
    t = Table(show_header=True, box=box.SIMPLE_HEAD, expand=True, padding=(0, 1))
    t.add_column("Disk", style="cyan")
    t.add_column("Read", justify="right")
    t.add_column("Write", justify="right")
    for name, read_bps, write_bps in rates:
        t.add_row(name, format_rate(read_bps), format_rate(write_bps))
    if not rates:
        t.add_row("—", "0 B/s", "0 B/s")
    return Panel(t, title="[bold]Disk I/O[/bold]", border_style="yellow", box=box.ROUNDED)


def build_network_panel(rx_rate: float, tx_rate: float, ifaces: List[Tuple[str, float, float]]) -> Panel:
    t = Table(show_header=False, box=None, padding=(0, 1), expand=True)
    t.add_column("Iface", style="bold")
    t.add_column("Down", justify="right")
    t.add_column("Up", justify="right")
    t.add_row(Text("Total", style="bold green"), format_rate(rx_rate), format_rate(tx_rate))
    for iface, down, up in ifaces:
        t.add_row(iface, format_rate(down), format_rate(up))
    return Panel(t, title="[bold]Network[/bold]", border_style="blue", box=box.ROUNDED)


def build_services_panel() -> Panel:
    services = [
        ("k3s", "K3s", k3s_summary()),
        ("docker", "Docker", docker_container_count()),
        ("ufw", "Firewall", ""),
        ("prometheus-node-exporter", "Node exporter", ""),
    ]
    t = Table(show_header=False, box=None, padding=(0, 1), expand=True)
    t.add_column("Service")
    t.add_column("State")
    t.add_column("Detail", justify="right", style="dim")
    for unit, label, detail in services:
        t.add_row(label, Text(service_state(unit), style=status_style(service_state(unit))), detail)
    return Panel(t, title="[bold]Services[/bold]", border_style="white", box=box.ROUNDED)


def build_certs_panel(certs: List[CertInfo]) -> Panel:
    t = Table(show_header=True, box=box.SIMPLE_HEAD, expand=True, padding=(0, 1))
    t.add_column("Certificate")
    t.add_column("Expires", justify="right")
    t.add_column("Days", justify="right")
    for c in certs:
        style = "red" if c.days_left <= 7 else ("yellow" if c.days_left <= 30 else "green")
        t.add_row(c.name, c.expires, Text(str(c.days_left), style=style))
    if not certs:
        t.add_row("—", "not found", "—")
    return Panel(t, title="[bold]TLS certs[/bold]", border_style="cyan", box=box.ROUNDED)


def build_process_table(title: str, sort_by: str, border: str) -> Panel:
    t = Table(show_header=True, box=box.SIMPLE_HEAD, expand=True, padding=(0, 1))
    t.add_column("PID", style="bold cyan", width=8)
    t.add_column("User", width=8)
    t.add_column("CPU%", justify="right", width=6)
    t.add_column("MEM%", justify="right", width=6)
    t.add_column("Swap", justify="right", width=7)
    t.add_column("Application")
    for proc in read_top_processes(sort_by, 5):
        cpu_f, mem_f = float(proc.cpu), float(proc.mem)
        swap_txt = kb_human(proc.swap_kb) if proc.swap_kb else "—"
        t.add_row(
            proc.pid, proc.user,
            Text(proc.cpu, style="bold red" if cpu_f >= 50 and sort_by == "cpu" else ""),
            Text(proc.mem, style="bold red" if mem_f >= 50 and sort_by == "mem" else ""),
            swap_txt, proc.cmd,
        )
    sub = "CPU" if sort_by == "cpu" else "memory"
    return Panel(t, title=f"[bold]Top by {sub}[/bold]", border_style=border, box=box.ROUNDED)


def render_dashboard(
    interval: float,
    sysinfo: Dict[str, str],
    temps: List[Tuple[str, float]],
    overall_cpu: float,
    per_cpu: List[float],
    mem: Dict[str, int],
    disks: List[Tuple[str, ...]],
    disk_io: List[Tuple[str, float, float]],
    rx_rate: float,
    tx_rate: float,
    ifaces: List[Tuple[str, float, float]],
    failed: List[str],
    zombies: int,
    crashloops: int,
    certs: List[CertInfo],
) -> Layout:
    layout = Layout()
    layout.split_column(
        Layout(name="header", size=8),
        Layout(name="alerts", size=5),
        Layout(name="body"),
        Layout(name="processes", size=10),
        Layout(name="footer", size=3),
    )
    layout["body"].split_row(Layout(name="left", ratio=3), Layout(name="right", ratio=2))
    layout["left"].split_column(
        Layout(name="cpu", ratio=2),
        Layout(name="mem", ratio=1),
        Layout(name="disk", ratio=2),
        Layout(name="diskio", ratio=1),
    )
    layout["right"].split_column(
        Layout(name="net", size=7),
        Layout(name="svc", size=7),
        Layout(name="certs"),
    )
    layout["processes"].split_row(Layout(name="top_cpu", ratio=1), Layout(name="top_mem", ratio=1))

    layout["header"].update(build_header(interval, sysinfo, temps))
    layout["alerts"].update(build_alerts_panel(failed, zombies, crashloops, certs))
    layout["cpu"].update(build_cpu_panel(overall_cpu, per_cpu))
    layout["mem"].update(build_memory_panel(mem))
    layout["disk"].update(build_disk_panel(disks))
    layout["diskio"].update(build_disk_io_panel(disk_io))
    layout["net"].update(build_network_panel(rx_rate, tx_rate, ifaces))
    layout["svc"].update(build_services_panel())
    layout["certs"].update(build_certs_panel(certs))
    layout["processes"]["top_cpu"].update(build_process_table("Apps", "cpu", "red"))
    layout["processes"]["top_mem"].update(build_process_table("Apps", "mem", "blue"))

    ts = time.strftime("%H:%M:%S")
    layout["footer"].update(Panel(
        Align.center(Text(f"Live · {ts}  ·  Himosoft Server Status", style="dim")),
        box=box.ROUNDED, border_style="dim",
    ))
    return layout


# ── keyboard listener ────────────────────────────────────────────────────


def start_keyboard_listener() -> threading.Thread:
    def listen() -> None:
        global running
        if not sys.stdin.isatty():
            return
        fd = sys.stdin.fileno()
        try:
            old = termios.tcgetattr(fd)
        except termios.error:
            return
        try:
            tty.setcbreak(fd)
            while running:
                ready, _, _ = select.select([sys.stdin], [], [], 0.2)
                if ready and sys.stdin.read(1).lower() == "q":
                    stop_running()
                    break
        finally:
            try:
                termios.tcsetattr(fd, termios.TCSADRAIN, old)
            except termios.error:
                pass

    t = threading.Thread(target=listen, daemon=True)
    t.start()
    return t


# ── snapshot JSON ────────────────────────────────────────────────────────


def collect_snapshot() -> Dict[str, Any]:
    sysinfo = read_system_info()
    mem = read_meminfo()
    total = mem.get("MemTotal", 1)
    avail = mem.get("MemAvailable", mem.get("MemFree", 0))
    swap_total = mem.get("SwapTotal", 0)
    swap_free = mem.get("SwapFree", 0)
    certs = find_tls_certs()
    failed = failed_systemd_units()
    crashloops = k3s_crashloop_count()
    return {
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "system": sysinfo,
        "uptimeSeconds": read_uptime(),
        "loadavg": list(read_loadavg()),
        "temperatures": [{"zone": z, "celsius": t} for z, t in read_cpu_temps()],
        "memory": {
            "totalKb": total, "usedKb": total - avail, "availableKb": avail,
            "swapTotalKb": swap_total, "swapUsedKb": swap_total - swap_free,
        },
        "disks": [{"mount": r[0], "size": r[1], "used": r[2], "free": r[3], "percent": r[4]} for r in read_disks()],
        "alerts": {
            "failedSystemdUnits": failed,
            "zombieProcesses": zombie_count(),
            "k3sCrashLoopBackOff": crashloops,
        },
        "tlsCertificates": [
            {"name": c.name, "expires": c.expires, "daysLeft": c.days_left} for c in certs
        ],
        "services": {
            "k3s": service_state("k3s"),
            "docker": service_state("docker"),
            "ufw": service_state("ufw"),
            "nodeExporter": service_state("prometheus-node-exporter"),
            "k3sSummary": k3s_summary(),
            "dockerContainers": docker_container_count(),
        },
        "topProcessesByCpu": [
            {"pid": p.pid, "user": p.user, "cpu": p.cpu, "mem": p.mem, "swapKb": p.swap_kb, "command": p.cmd}
            for p in read_top_processes("cpu", 10)
        ],
        "topProcessesByMem": [
            {"pid": p.pid, "user": p.user, "cpu": p.cpu, "mem": p.mem, "swapKb": p.swap_kb, "command": p.cmd}
            for p in read_top_processes("mem", 10)
        ],
    }


def run_snapshot() -> int:
    print(json.dumps(collect_snapshot(), indent=2))
    return 0


def run_live(interval: float) -> int:
    global running
    running = True
    sysinfo = read_system_info()
    prev_cpu = read_cpu()
    prev_net = read_net()
    prev_disk_io = read_disk_io()
    prev_t = time.time()

    time.sleep(0.3)
    cur_cpu = read_cpu()
    overall_cpu, per_cpu = cpu_usage(prev_cpu, cur_cpu)
    prev_cpu = cur_cpu

    start_keyboard_listener()
    use_screen = sys.stdout.isatty()

    with Live(console=console, refresh_per_second=max(1, min(10, int(1.0 / interval))), screen=use_screen) as live:
        while running:
            now = time.time()
            dt = now - prev_t
            cur_cpu = read_cpu()
            cur_net = read_net()
            cur_disk_io = read_disk_io()
            overall_cpu, per_cpu = cpu_usage(prev_cpu, cur_cpu)
            rx_rate, tx_rate = net_rate(prev_net, cur_net, dt)
            ifaces = iface_rates(prev_net, cur_net, dt)
            dio = disk_io_rates(prev_disk_io, cur_disk_io, dt)
            prev_cpu, prev_net, prev_disk_io, prev_t = cur_cpu, cur_net, cur_disk_io, now

            mem = read_meminfo()
            temps = read_cpu_temps()
            failed = failed_systemd_units()
            zombies = zombie_count()
            crashloops = k3s_crashloop_count()
            certs = find_tls_certs()

            live.update(render_dashboard(
                interval, sysinfo, temps, overall_cpu, per_cpu, mem, read_disks(), dio,
                rx_rate, tx_rate, ifaces, failed, zombies, crashloops, certs,
            ))
            time.sleep(interval)

    if use_screen:
        console.clear()
    console.print("[dim]Dashboard stopped.[/dim]")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Himosoft Server Status dashboard")
    parser.add_argument("--interval", type=float, default=2.0, help="Refresh interval in seconds")
    parser.add_argument("--snapshot", action="store_true", help="Output JSON snapshot and exit")
    args = parser.parse_args()

    if args.snapshot:
        return run_snapshot()

    if not sys.stdout.isatty():
        print("Requires interactive terminal. Use: himosoft-server-status snapshot", file=sys.stderr)
        return 1

    try:
        return run_live(max(0.5, args.interval))
    except Exception as exc:
        print(f"himosoft-server-status error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
