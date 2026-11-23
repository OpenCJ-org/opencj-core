"""Capacity log summaries and bounded sampling of owned test containers."""

import json
import math
import re
from pathlib import Path
import statistics
import subprocess
import threading
import time


def quantiles(values):
    if not values:
        return {}
    sorted_values = sorted(values)
    return {
        "count": len(sorted_values),
        "median": statistics.median(sorted_values),
        "p95": sorted_values[math.ceil(0.95 * len(sorted_values)) - 1],
        "p99": sorted_values[math.ceil(0.99 * len(sorted_values)) - 1],
        "max": max(sorted_values),
    }


def workload_metrics(log):
    """Decode the fixed log fields used by both capacity profiles."""
    result = {}
    phases = {}
    for name in ("record32", "mixed16", "finish32_watch32", "shared32"):
        metrics = {}
        sql = [
            tuple(map(int, m))
            for m in re.findall(r"CAP SQL " + name + r" (\d+) (\d+) (\d+) (\d+) (\d+)", log)
        ]
        for policy, label in (
            (0, "progress"),
            (1, "read"),
            (2, "upload"),
            (3, "menu"),
            (4, "write"),
            (5, "synchronous"),
        ):
            values = [x for x in sql if x[0] == policy]
            if values:
                metrics[label] = {
                    "completionMs": quantiles([x[1] for x in values]),
                    "queueMs": quantiles([x[3] for x in values]),
                    "executionMs": quantiles([x[4] for x in values]),
                    "outcomes": {
                        str(o): sum(x[2] == o for x in values) for o in set(x[2] for x in values)
                    },
                }
        metrics["demoLoadMs"] = quantiles(
            [int(m) for m in re.findall(r"CAP LOAD " + name + r" \d+ (\d+)", log)]
        )
        metrics["demoUploadMs"] = quantiles(
            [int(m) for m in re.findall(r"CAP UPLOAD " + name + r" \d+ (\d+)", log)]
        )
        end = re.search(r"CAP END " + name + r" (\d+) (\d+) (\d+) (\d+)", log)
        if end:
            metrics.update(
                dict(zip(("wallMs", "ticks", "peakJobs", "peakQueryBytes"), map(int, end.groups())))
            )
        phases[name] = metrics
    result["frameIntervals"] = {
        name: dict(zip(("samples", "p95Ms", "p99Ms", "maxMs", "over75Ms"), map(int, m[1:])))
        for m in re.findall(r"CAP TICKS (\d+) (\d+) (\d+) (\d+) (\d+) (\d+)", log)
        for name in [("setup", "record32", "mixed16", "finish32_watch32", "shared32")[int(m[0])]]
    }
    result["hitches"] = [
        dict(zip(("stage", "endedAtMs", "intervalMs"), map(int, m)))
        for m in re.findall(r"CAP HITCH (\d+) (\d+) (\d+)", log)
    ]
    sync = [
        (stage, int(start), int(duration))
        for stage, start, duration in re.findall(r"CAP SYNC (\w+) (\d+) (\d+)", log)
    ]
    for hitch in result["hitches"]:
        start = hitch["endedAtMs"] - hitch["intervalMs"]
        end = hitch["endedAtMs"]
        calls = [duration for _, at, duration in sync if start <= at < end]
        hitch.update(synchronousCalls=len(calls), synchronousMs=sum(calls))
    result["phases"] = phases
    return result


class ResourceMonitor:
    """Sample only explicitly registered fixture containers; stop before returning."""

    def __init__(self, profile):
        self.report = {"profile": profile, "containers": {}, "samples": []}
        self.paths = {}
        self.lock = threading.Lock()
        self.stop_event = threading.Event()
        self.thread = None

    def add(self, container):
        result = subprocess.run(
            ["docker", "inspect", container],
            capture_output=True,
            text=True,
            check=True,
            timeout=30,
        )
        metadata = json.loads(result.stdout)[0]
        process_id = metadata["State"]["Pid"]
        cgroups = (Path("/proc") / str(process_id) / "cgroup").read_text().splitlines()
        unified = next((line[3:] for line in cgroups if line.startswith("0::")), None)
        if unified is None:
            raise RuntimeError("Capacity resource measurements require cgroup v2")
        path = Path("/sys/fs/cgroup") / unified.lstrip("/")
        configuration = metadata["HostConfig"]
        with self.lock:
            self.paths[container] = path
            self.report["containers"][container] = {
                "memoryLimit": configuration["Memory"],
                "memorySwapLimit": configuration["MemorySwap"],
                "cpuset": configuration["CpusetCpus"],
                "nanoCpus": configuration["NanoCpus"],
            }
        self.sample()

    def sample(self):
        row = {"at": round(time.monotonic(), 3)}
        with self.lock:
            paths = list(self.paths.items())
        for container, path in paths:
            try:
                memory = dict(
                    line.split() for line in (path / "memory.stat").read_text().splitlines()
                )
                row[container] = {
                    "current": int((path / "memory.current").read_text()),
                    "peak": int((path / "memory.peak").read_text()),
                    "anon": int(memory["anon"]),
                    "file": int(memory["file"]),
                    "events": (path / "memory.events").read_text().strip(),
                    "cpu": (path / "cpu.stat").read_text().strip(),
                }
            except (OSError, ValueError, KeyError):
                # The owned container may disappear between sampling and cleanup.
                continue
        if len(row) > 1:
            with self.lock:
                self.report["samples"].append(row)

    def monitor(self):
        while not self.stop_event.wait(0.5):
            self.sample()

    def start(self):
        self.thread = threading.Thread(target=self.monitor, daemon=True)
        self.thread.start()

    def finish(self, home):
        self.stop_event.set()
        if self.thread is not None:
            self.thread.join(timeout=2)
            if self.thread.is_alive():
                raise RuntimeError("Capacity sampler did not stop")
        self.sample()
        (home / "hosting-resources.json").write_text(json.dumps(self.report, indent=2) + "\n")
