#!/usr/bin/env python3
"""Bounded standalone package validation; optional exact local Git mirrors avoid downloads."""
import argparse
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
BASE = ROOT / ".build/validation"
TOTAL_CAP = 2 * 1024**3
ALLOWANCE = 256 * 1024**2  # Runtime metadata outside a read-only Linux proof mount.
RESERVE = 10 * 1024**3


def capacity():
    fs = os.statvfs(ROOT)
    if fs.f_frsize <= 0:
        raise RuntimeError("filesystem capacity unavailable")
    available = fs.f_bavail * fs.f_frsize
    allocated = 0
    seen = set()
    for directory, _, names in os.walk(ROOT, followlinks=False):
        for name in names:
            try:
                info = (Path(directory) / name).lstat()
            except FileNotFoundError:
                continue  # A compiler removed a transient file before this inventory step.
            if (info.st_dev, info.st_ino) not in seen:
                seen.add((info.st_dev, info.st_ino))
                allocated += info.st_blocks * 512
    if available < RESERVE or allocated >= TOTAL_CAP - ALLOWANCE:
        raise RuntimeError(f"capacity rejected: available={available} allocated={allocated}")
    return dict(available=available, allocated=allocated, totalCap=TOTAL_CAP,
                runtimeAllowance=ALLOWANCE, reserve=RESERVE)


def run(command, label, environment, timeout=900):
    capacity()
    logs = BASE / "logs"
    logs.mkdir(parents=True, exist_ok=True)
    state = logs / (label + ".status.json")
    result = dict(command=list(map(str, command)), running=True, initial=capacity())
    state.write_text(json.dumps(result, indent=2) + "\n")
    process = None
    started = time.monotonic()
    try:
        with (logs / (label + ".log")).open("wb") as output:
            process = subprocess.Popen(command, cwd=ROOT, env=environment,
                                       stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
            result["pid"] = process.pid
            state.write_text(json.dumps(result, indent=2) + "\n")
            while process.poll() is None:
                capacity()
                if time.monotonic() - started > timeout:
                    raise RuntimeError("validation child timeout")
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    pass
            result["exit"] = process.returncode
            result["final"] = capacity()
    except BaseException as error:
        result["failure"] = str(error)
        result["exit"] = 125
        if process is not None and process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
    finally:
        result["running"] = False
        result["seconds"] = round(time.monotonic() - started, 2)
        state.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"label": label, "exit": result["exit"], "seconds": result["seconds"],
                      "capacity": result.get("final", result["initial"])}), flush=True)
    if result["exit"]:
        raise RuntimeError("validation child failed: " + label)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cached-checkouts", type=Path)
    parser.add_argument("--label")
    parser.add_argument("--operation-timeout-seconds", type=int, default=86400,
                        help="Finite Swift build/test budget; short probes/cleanup keep their own limits")
    parser.add_argument("--linux-cached", action="store_true", help="Run only in the already cached project ARM64 image")
    args = parser.parse_args()
    if args.operation_timeout_seconds <= 0:
        parser.error("--operation-timeout-seconds must be positive")
    name = "macos" if platform.system() == "Darwin" else "linux"
    label = args.label or name
    env = os.environ.copy()
    env.pop("SWIFTCI_USE_LOCAL_DEPS", None)
    for entry in ("scratch", "cache", "config", "security", "tmp", "module-cache"):
        (BASE / (entry + "-" + name)).mkdir(parents=True, exist_ok=True)
    env.update(TMPDIR=str(BASE / ("tmp-" + name)),
               CLANG_MODULE_CACHE_PATH=str(BASE / ("module-cache-" + name)),
               SWIFTPM_MODULECACHE_OVERRIDE=str(BASE / ("module-cache-" + name)))
    if args.linux_cached:
        image = "tractanda-test:swift6.4.0-trixie-validation-20261002"
        details = json.loads(subprocess.check_output(["/usr/local/bin/container", "image", "inspect", image]))
        if details[0]["configuration"]["descriptor"]["digest"] != "sha256:12de0505417a967a9a2fe3036e501c1eb6ee92960fd7461a2a0e6a5783951d65":
            raise RuntimeError("cached image digest mismatch; no pull is authorized by this runner")
        container_name = "tractanda-peer-tls-package-20261014"
        command = ["/usr/local/bin/container", "run", "--rm", "--progress", "none", "--name", container_name,
                   "--read-only", "--uid", str(os.getuid()), "--gid", str(os.getgid()), "--cpus", "2", "--memory", "3G", "--no-dns",
                   "--mount", f"type=bind,source={ROOT},target=/proof", "--workdir", "/proof", "--entrypoint", "/usr/bin/python3",
                   image, "/proof/Scripts/validate.py", "--label", label,
                   "--operation-timeout-seconds", str(args.operation_timeout_seconds)]
        run(command, label + "-host", env, args.operation_timeout_seconds + 3600)
        return
    common = ["--package-path", str(ROOT), "--disable-sandbox"]
    for entry in ("scratch", "cache", "config", "security"):
        common += ["--" + entry + "-path", str(BASE / (entry + "-" + name))]
    run(["python3", str(ROOT / "Vendor/regenerate.py")], label + "-vendor", env, 60)
    pins = json.loads((ROOT / "Package.resolved").read_text())["pins"]
    mirrors = BASE / "mirrors"
    mirrors.mkdir(exist_ok=True)
    for pin in pins:
        target = mirrors / (pin["identity"] + ".git")
        if args.cached_checkouts and not (target / "HEAD").exists():
            original = args.cached_checkouts.resolve() / pin["identity"]
            run(["git", "init", "--bare", str(target)], label + "-init-" + pin["identity"], env, 30)
            run(["git", "-C", str(target), "fetch", "--depth=1", "--no-tags", str(original), pin["state"]["revision"]],
                label + "-fetch-" + pin["identity"], env, 60)
            run(["git", "-C", str(target), "update-ref", "refs/tags/" + pin["state"]["version"], pin["state"]["revision"]],
                label + "-tag-" + pin["identity"], env, 30)
        if (target / "HEAD").exists():
            run(["swift", "package", *common, "config", "set-mirror", "--original", pin["location"], "--mirror", target.as_uri()],
                label + "-mirror-" + pin["identity"], env, 60)
    run(["swift", "--version"], label + "-toolchain", env, 30)
    # Linux's current default xcbuild backend overrides TMPDIR for assembler work.
    # Native SwiftPM preserves the explicit writable /proof scratch on a read-only guest root.
    backend = ["--build-system", "native"] if name == "linux" else []
    # Native Linux test discovery requires compiler index records in Swift 6.4.
    index = [] if name == "linux" else ["--disable-index-store"]
    run(["swift", "test", *common, *backend, "--jobs", "2", *index], label + "-tests", env,
        args.operation_timeout_seconds)
    for pin in json.loads((ROOT / "Package.resolved").read_text())["pins"]:
        if not pin["location"].startswith("https://github.com/apple/"):
            raise RuntimeError("nonportable location in public Package.resolved")
    (BASE / "logs" / (label + "-platform.json")).write_text(json.dumps({
        "system": platform.platform(), "architecture": platform.machine(), "capacity": capacity()}, indent=2) + "\n")


if __name__ == "__main__":
    main()
