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
from concurrent.futures import ThreadPoolExecutor, as_completed
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
    cpu_f: float = 0.0
    mem_f: float = 0.0


@dataclass
class CertInfo:
    name: str
    expires: str
    days_left: int


@dataclass
class PodRow:
    namespace: str
    name: str
    status: str
    cpu: str
    memory: str
    cpu_sort: float = 0.0
    mem_sort: float = 0.0


@dataclass
class K3sSnapshot:
    summary: str = "—"
    crashloops: int = 0
    pods: List[PodRow] = field(default_factory=list)
    metrics_available: bool = False


@dataclass
class ServicesSnapshot:
    k3s_state: str = "n/a"
    docker_state: str = "n/a"
    ufw_state: str = "n/a"
    node_exporter_state: str = "n/a"
    k3s_summary: str = "—"
    docker_containers: str = "—"
    k3s_crashloops: int = 0
    k3s_pods: List[PodRow] = field(default_factory=list)
    k3s_metrics_available: bool = False


@dataclass
class SlowMetrics:
    failed_units: List[str] = field(default_factory=list)
    zombies: int = 0
    crashloops: int = 0
    certs: List[CertInfo] = field(default_factory=list)
    top_cpu: List[ProcessRow] = field(default_factory=list)
    top_mem: List[ProcessRow] = field(default_factory=list)
    services: ServicesSnapshot = field(default_factory=ServicesSnapshot)
    k3s_pods: List[PodRow] = field(default_factory=list)
    k3s_metrics_available: bool = False
    temps: List[Tuple[str, float]] = field(default_factory=list)
    disks: List[Tuple[str, str, str, str, str]] = field(default_factory=list)


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


def read_processes_snapshot() -> Tuple[List[ProcessRow], int]:
    """Single ps call for process list + zombie count (avoids repeated ps spawns)."""
    out = run_quiet(["ps", "-eo", "pid,user,pcpu,pmem,stat,comm", "--no-headers"])
    if not out:
        return [], 0
    rows: List[ProcessRow] = []
    zombies = 0
    for line in out.splitlines():
        parts = line.split(None, 5)
        if len(parts) < 6:
            continue
        pid, user, cpu, mem, stat, cmd = parts
        if "Z" in stat:
            zombies += 1
        try:
            cpu_f, mem_f = float(cpu), float(mem)
        except ValueError:
            continue
        rows.append(ProcessRow(pid, user, cpu, mem, 0, cmd[:36], cpu_f, mem_f))
    return rows, zombies


def _attach_swap(rows: List[ProcessRow], limit: int = 5) -> List[ProcessRow]:
    out: List[ProcessRow] = []
    for row in rows[:limit]:
        out.append(ProcessRow(
            row.pid, row.user, row.cpu, row.mem,
            read_proc_swap_kb(row.pid), row.cmd, row.cpu_f, row.mem_f,
        ))
    return out


def top_processes(rows: List[ProcessRow], sort_by: str, limit: int = 5) -> List[ProcessRow]:
    key = "cpu_f" if sort_by == "cpu" else "mem_f"
    ranked = sorted(rows, key=lambda r: getattr(r, key, 0.0), reverse=True)
    return _attach_swap(ranked, limit)


def zombie_count() -> int:
    _, zombies = read_processes_snapshot()
    return zombies


def read_top_processes(sort_by: str = "cpu", limit: int = 6) -> List[ProcessRow]:
    rows, _ = read_processes_snapshot()
    return top_processes(rows, sort_by, limit)


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


def parse_k8s_cpu(value: str) -> float:
    value = value.strip()
    if not value or value in ("<unknown>", "—"):
        return 0.0
    if value.endswith("m"):
        return float(value[:-1]) / 1000.0
    return float(value)


def parse_k8s_memory(value: str) -> float:
    value = value.strip()
    if not value or value in ("<unknown>", "—"):
        return 0.0
    binary = {"Ki": 1024, "Mi": 1024**2, "Gi": 1024**3, "Ti": 1024**4}
    for suffix, mult in binary.items():
        if value.endswith(suffix):
            return float(value[: -len(suffix)]) * mult
    decimal = {"K": 1000, "M": 1000**2, "G": 1000**3}
    for suffix, mult in decimal.items():
        if value.endswith(suffix):
            return float(value[: -len(suffix)]) * mult
    try:
        return float(value)
    except ValueError:
        return 0.0


def _kubectl(args: List[str]) -> str:
    return run_quiet(["k3s", "kubectl", *args])


def collect_k3s_metrics(pod_limit: int = 8) -> K3sSnapshot:
    """Nodes, pod counts, crashloops, and pod CPU/RAM via kubectl top."""
    snap = K3sSnapshot()
    if service_state("k3s") != "active":
        return snap

    with ThreadPoolExecutor(max_workers=3) as pool:
        nodes_f = pool.submit(_kubectl, ["get", "nodes", "--no-headers"])
        pods_f = pool.submit(_kubectl, ["get", "pods", "-A", "--no-headers"])
        top_f = pool.submit(_kubectl, ["top", "pods", "-A", "--no-headers"])

    nodes = nodes_f.result()
    pods_out = pods_f.result()
    top_out = top_f.result()

    n_nodes = len(nodes.splitlines()) if nodes else 0
    pod_lines = pods_out.splitlines() if pods_out else []
    snap.summary = f"{n_nodes} node(s) · {len(pod_lines)} pods"
    snap.crashloops = sum(1 for line in pod_lines if "CrashLoopBackOff" in line)

    status_map: Dict[Tuple[str, str], str] = {}
    for line in pod_lines:
        parts = line.split()
        if len(parts) < 4:
            continue
        ns, name, status = parts[0], parts[1], parts[3]
        status_map[(ns, name)] = status

    top_rows: List[PodRow] = []
    if top_out:
        snap.metrics_available = True
        for line in top_out.splitlines():
            parts = line.split()
            if len(parts) < 4:
                continue
            ns, name, cpu, mem = parts[0], parts[1], parts[2], parts[3]
            top_rows.append(PodRow(
                namespace=ns,
                name=name[:28],
                status=status_map.get((ns, name), "Running"),
                cpu=cpu,
                memory=mem,
                cpu_sort=parse_k8s_cpu(cpu),
                mem_sort=parse_k8s_memory(mem),
            ))
        top_rows.sort(key=lambda p: p.cpu_sort + p.mem_sort / (1024 * 1024), reverse=True)
        snap.pods = top_rows[:pod_limit]
        return snap

    # metrics-server unavailable — list running pods without usage
    running = []
    for line in pod_lines:
        parts = line.split()
        if len(parts) < 4:
            continue
        ns, name, status = parts[0], parts[1], parts[3]
        if status != "Running":
            continue
        running.append(PodRow(
            namespace=ns,
            name=name[:28],
            status=status,
            cpu="—",
            memory="—",
        ))
    snap.pods = running[:pod_limit]
    return snap


def k3s_pod_stats() -> Tuple[str, int]:
    """Single kubectl pods call for summary + CrashLoopBackOff count."""
    k3s = collect_k3s_metrics(pod_limit=0)
    return k3s.summary, k3s.crashloops


def docker_container_count() -> str:
    if service_state("docker") != "active":
        return "—"
    out = run_quiet(["docker", "ps", "-q"])
    return f"{len(out.splitlines())} running" if out else "0 running"


def collect_services_snapshot() -> ServicesSnapshot:
    snap = ServicesSnapshot()
    units = ["k3s", "docker", "ufw", "prometheus-node-exporter"]
    with ThreadPoolExecutor(max_workers=4) as pool:
        states = list(pool.map(service_state, units))
    snap.k3s_state, snap.docker_state, snap.ufw_state, snap.node_exporter_state = states

    def docker_detail() -> str:
        if snap.docker_state != "active":
            return "—"
        out = run_quiet(["docker", "ps", "-q"])
        return f"{len(out.splitlines())} running" if out else "0 running"

    with ThreadPoolExecutor(max_workers=2) as pool:
        k3s_f = pool.submit(collect_k3s_metrics, 8)
        docker_f = pool.submit(docker_detail)
        k3s = k3s_f.result()
        snap.docker_containers = docker_f.result()

    snap.k3s_summary = k3s.summary
    snap.k3s_crashloops = k3s.crashloops
    snap.k3s_pods = k3s.pods
    snap.k3s_metrics_available = k3s.metrics_available
    return snap


def k3s_summary() -> str:
    summary, _ = k3s_pod_stats()
    return summary


def k3s_crashloop_count() -> int:
    _, crashloops = k3s_pod_stats()
    return crashloops


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


def build_services_panel(services: ServicesSnapshot) -> Panel:
    rows = [
        ("K3s", services.k3s_state, services.k3s_summary),
        ("Docker", services.docker_state, services.docker_containers),
        ("Firewall", services.ufw_state, ""),
        ("Node exporter", services.node_exporter_state, ""),
    ]
    t = Table(show_header=False, box=None, padding=(0, 1), expand=True)
    t.add_column("Service")
    t.add_column("State")
    t.add_column("Detail", justify="right", style="dim")
    for label, state, detail in rows:
        t.add_row(label, Text(state, style=status_style(state)), detail)
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


def build_k3s_pods_panel(
    pods: List[PodRow], k3s_active: bool, metrics_available: bool,
) -> Panel:
    t = Table(show_header=True, box=box.SIMPLE_HEAD, expand=True, padding=(0, 1))
    t.add_column("Namespace", style="cyan", width=12)
    t.add_column("Pod", width=20)
    t.add_column("Status", width=10)
    t.add_column("CPU", justify="right", width=8)
    t.add_column("RAM", justify="right", width=8)

    if not k3s_active:
        t.add_row("—", "K3s not running", "", "", "")
        title = "[bold]K3s pods[/bold]"
    elif not pods:
        t.add_row("—", "no pods found", "", "", "")
        title = "[bold]K3s pods[/bold]"
    else:
        for pod in pods:
            status_style = "green" if pod.status == "Running" else (
                "red" if pod.status in ("CrashLoopBackOff", "Error", "Failed") else "yellow"
            )
            cpu_style = "bold red" if pod.cpu_sort >= 0.5 else ""
            mem_style = "bold red" if pod.mem_sort >= 512 * 1024 * 1024 else ""
            t.add_row(
                pod.namespace[:12],
                pod.name,
                Text(pod.status, style=status_style),
                Text(pod.cpu, style=cpu_style),
                Text(pod.memory, style=mem_style),
            )
        hint = "kubectl top" if metrics_available else "metrics-server n/a"
        title = f"[bold]K3s pods[/bold] [dim]({hint})[/dim]"

    return Panel(t, title=title, border_style="bright_blue", box=box.ROUNDED)


def build_process_table(title: str, processes: List[ProcessRow], sort_by: str, border: str) -> Panel:
    t = Table(show_header=True, box=box.SIMPLE_HEAD, expand=True, padding=(0, 1))
    t.add_column("PID", style="bold cyan", width=8)
    t.add_column("User", width=8)
    t.add_column("CPU%", justify="right", width=6)
    t.add_column("MEM%", justify="right", width=6)
    t.add_column("Swap", justify="right", width=7)
    t.add_column("Application")
    for proc in processes:
        cpu_f, mem_f = proc.cpu_f, proc.mem_f
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
    slow: SlowMetrics,
    overall_cpu: float,
    per_cpu: List[float],
    mem: Dict[str, int],
    disk_io: List[Tuple[str, float, float]],
    rx_rate: float,
    tx_rate: float,
    ifaces: List[Tuple[str, float, float]],
) -> Layout:
    layout = Layout()
    layout.split_column(
        Layout(name="header", size=8),
        Layout(name="alerts", size=5),
        Layout(name="body"),
        Layout(name="k3s_pods", size=9),
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

    layout["header"].update(build_header(interval, sysinfo, slow.temps))
    layout["alerts"].update(build_alerts_panel(
        slow.failed_units, slow.zombies, slow.crashloops, slow.certs,
    ))
    layout["cpu"].update(build_cpu_panel(overall_cpu, per_cpu))
    layout["mem"].update(build_memory_panel(mem))
    layout["disk"].update(build_disk_panel(slow.disks))
    layout["diskio"].update(build_disk_io_panel(disk_io))
    layout["net"].update(build_network_panel(rx_rate, tx_rate, ifaces))
    layout["svc"].update(build_services_panel(slow.services))
    layout["certs"].update(build_certs_panel(slow.certs))
    layout["k3s_pods"].update(build_k3s_pods_panel(
        slow.k3s_pods,
        slow.services.k3s_state == "active",
        slow.k3s_metrics_available,
    ))
    layout["processes"]["top_cpu"].update(build_process_table("Apps", slow.top_cpu, "cpu", "red"))
    layout["processes"]["top_mem"].update(build_process_table("Apps", slow.top_mem, "mem", "blue"))

    ts = time.strftime("%H:%M:%S")
    layout["footer"].update(Panel(
        Align.center(Text(f"Live · {ts}  ·  Himosoft Server Status", style="dim")),
        box=box.ROUNDED, border_style="dim",
    ))
    return layout


# ── background collector & splash ───────────────────────────────────────


SLOW_REFRESH_SEC = 5.0
CERT_REFRESH_SEC = 60.0
SPLASH_MIN_SEC = 0.8


def collect_slow_metrics(include_certs: bool = True, process_limit: int = 5) -> SlowMetrics:
    """Gather expensive metrics in parallel (subprocess / glob / ps)."""
    slow = SlowMetrics()

    def processes_job() -> Tuple[List[ProcessRow], int]:
        rows, zombies = read_processes_snapshot()
        return rows, zombies

    jobs: Dict[str, Any] = {
        "failed": failed_systemd_units,
        "processes": processes_job,
        "services": collect_services_snapshot,
        "disks": read_disks,
        "temps": read_cpu_temps,
    }
    if include_certs:
        jobs["certs"] = find_tls_certs

    results: Dict[str, Any] = {}
    with ThreadPoolExecutor(max_workers=min(8, len(jobs))) as pool:
        futures = {pool.submit(fn): name for name, fn in jobs.items()}
        for future in as_completed(futures):
            results[futures[future]] = future.result()

    slow.failed_units = results.get("failed", [])
    proc_rows, slow.zombies = results.get("processes", ([], 0))
    slow.top_cpu = top_processes(proc_rows, "cpu", process_limit)
    slow.top_mem = top_processes(proc_rows, "mem", process_limit)
    slow.services = results.get("services", ServicesSnapshot())
    slow.disks = results.get("disks", [])
    slow.temps = results.get("temps", [])
    slow.crashloops = slow.services.k3s_crashloops
    slow.k3s_pods = list(slow.services.k3s_pods)
    slow.k3s_metrics_available = slow.services.k3s_metrics_available
    if include_certs:
        slow.certs = results.get("certs", [])
    return slow


class BackgroundCollector:
    """Refreshes slow metrics on a background thread so the UI loop stays light."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._metrics = SlowMetrics()
        self._ready = threading.Event()
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self._last_cert_refresh = 0.0

    def start(self) -> None:
        self._thread = threading.Thread(target=self._run, name="hs-status-collector", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=2.0)

    def wait_ready(self, timeout: float = 30.0) -> bool:
        return self._ready.wait(timeout=timeout)

    def snapshot(self) -> SlowMetrics:
        with self._lock:
            return SlowMetrics(
                failed_units=list(self._metrics.failed_units),
                zombies=self._metrics.zombies,
                crashloops=self._metrics.crashloops,
                certs=list(self._metrics.certs),
                top_cpu=list(self._metrics.top_cpu),
                top_mem=list(self._metrics.top_mem),
                services=self._metrics.services,
                k3s_pods=list(self._metrics.k3s_pods),
                k3s_metrics_available=self._metrics.k3s_metrics_available,
                temps=list(self._metrics.temps),
                disks=list(self._metrics.disks),
            )

    def _store(self, metrics: SlowMetrics) -> None:
        with self._lock:
            self._metrics = metrics

    def _run(self) -> None:
        self._store(collect_slow_metrics(include_certs=True))
        self._last_cert_refresh = time.time()
        self._ready.set()
        next_refresh = time.time() + SLOW_REFRESH_SEC
        while not self._stop.is_set():
            now = time.time()
            if now >= next_refresh:
                include_certs = (now - self._last_cert_refresh) >= CERT_REFRESH_SEC
                updated = collect_slow_metrics(include_certs=include_certs)
                if not include_certs:
                    updated.certs = self.snapshot().certs
                self._store(updated)
                if include_certs:
                    self._last_cert_refresh = now
                next_refresh = now + SLOW_REFRESH_SEC
            time.sleep(0.25)


def show_splash(message: str = "Loading metrics…") -> None:
    console.clear()
    body = Text()
    body.append("\n\n", style="")
    body.append("HimoSoft Server Status\n\n", style="bold cyan")
    body.append("A tool developed by HimoSoft for monitoring server load\n\n", style="dim")
    body.append("www.himosoft.com.bd\n\n", style="bold link https://www.himosoft.com.bd")
    body.append(f"{message}\n", style="dim italic")
    width = min(console.width or 72, 72)
    splash = Panel(
        Align.center(body),
        border_style="cyan",
        box=box.DOUBLE,
        padding=(1, 6),
        width=width,
    )
    console.print(Align.center(splash))


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

    slow = collect_slow_metrics(include_certs=True, process_limit=10)
    svc = slow.services

    return {
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "system": sysinfo,
        "uptimeSeconds": read_uptime(),
        "loadavg": list(read_loadavg()),
        "temperatures": [{"zone": z, "celsius": t} for z, t in slow.temps],
        "memory": {
            "totalKb": total, "usedKb": total - avail, "availableKb": avail,
            "swapTotalKb": swap_total, "swapUsedKb": swap_total - swap_free,
        },
        "disks": [{"mount": r[0], "size": r[1], "used": r[2], "free": r[3], "percent": r[4]} for r in slow.disks],
        "alerts": {
            "failedSystemdUnits": slow.failed_units,
            "zombieProcesses": slow.zombies,
            "k3sCrashLoopBackOff": slow.crashloops,
        },
        "tlsCertificates": [
            {"name": c.name, "expires": c.expires, "daysLeft": c.days_left} for c in slow.certs
        ],
        "services": {
            "k3s": svc.k3s_state,
            "docker": svc.docker_state,
            "ufw": svc.ufw_state,
            "nodeExporter": svc.node_exporter_state,
            "k3sSummary": svc.k3s_summary,
            "dockerContainers": svc.docker_containers,
        },
        "k3sPods": [
            {
                "namespace": p.namespace,
                "name": p.name,
                "status": p.status,
                "cpu": p.cpu,
                "memory": p.memory,
            }
            for p in slow.k3s_pods
        ],
        "k3sMetricsAvailable": slow.k3s_metrics_available,
        "topProcessesByCpu": [
            {"pid": p.pid, "user": p.user, "cpu": p.cpu, "mem": p.mem, "swapKb": p.swap_kb, "command": p.cmd}
            for p in slow.top_cpu
        ],
        "topProcessesByMem": [
            {"pid": p.pid, "user": p.user, "cpu": p.cpu, "mem": p.mem, "swapKb": p.swap_kb, "command": p.cmd}
            for p in slow.top_mem
        ],
    }


def run_snapshot() -> int:
    print(json.dumps(collect_snapshot(), indent=2))
    return 0


def run_live(interval: float) -> int:
    global running
    running = True
    use_screen = sys.stdout.isatty()

    show_splash("Collecting system metrics…")
    splash_start = time.time()

    collector = BackgroundCollector()
    collector.start()

    sysinfo = read_system_info()
    prev_cpu = read_cpu()
    prev_net = read_net()
    prev_disk_io = read_disk_io()
    prev_t = time.time()

    # Warm up rate counters while slow metrics load in background
    time.sleep(0.3)
    cur_cpu = read_cpu()
    overall_cpu, per_cpu = cpu_usage(prev_cpu, cur_cpu)
    prev_cpu = cur_cpu

    collector.wait_ready(timeout=30.0)
    elapsed = time.time() - splash_start
    if elapsed < SPLASH_MIN_SEC:
        show_splash("Starting dashboard…")
        time.sleep(SPLASH_MIN_SEC - elapsed)

    start_keyboard_listener()

    if use_screen:
        console.clear()

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
            cur_disk_io = read_disk_io()
            overall_cpu, per_cpu = cpu_usage(prev_cpu, cur_cpu)
            rx_rate, tx_rate = net_rate(prev_net, cur_net, dt)
            ifaces = iface_rates(prev_net, cur_net, dt)
            dio = disk_io_rates(prev_disk_io, cur_disk_io, dt)
            prev_cpu, prev_net, prev_disk_io, prev_t = cur_cpu, cur_net, cur_disk_io, now

            mem = read_meminfo()
            slow = collector.snapshot()

            live.update(render_dashboard(
                interval, sysinfo, slow, overall_cpu, per_cpu, mem, dio,
                rx_rate, tx_rate, ifaces,
            ))
            time.sleep(interval)

    collector.stop()
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
