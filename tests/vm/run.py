#!/usr/bin/env python3
"""Automated Up Linux VM cases: install, then one or more desktop suites.

Suites (each boots the installed disk, then shuts the guest down):
  smoke       Super+Return opens Alacritty, type systemctl poweroff
  appearance  CLI + system-menu theme/font/wallpaper, menu shutdown
  apps        Open main apps, move workspaces, split/fullscreen, shutdown

After a successful OS install the runner freezes the disk as a qcow2
backing file (uefi-virtio.base.qcow2).

Run on the development host (Omarchy/Arch). Never executes bootstrap.sh on the host.
"""
from __future__ import annotations

import argparse
import json
import os
import select
import shutil
import socket
import struct
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CASE_ID = "uefi-virtio"
DEFAULT_WORK = REPO / "tests" / "vm" / "work"
DEFAULT_CACHE = Path.home() / ".cache" / "up-vm"
ISO_NAME = "archlinux-x86_64.iso"
ISO_URL = "https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso"
SSH_USER = "tester"
INSTALL_TIMEOUT = 5400
BOOT_TIMEOUT = 300
DESKTOP_TIMEOUT = 180
SUITE_TIMEOUT = 600
KNOWN_SUITES = ("smoke", "appearance", "apps")

OVMF_CODE_CANDIDATES = [
    Path("/usr/share/edk2/x64/OVMF_CODE.4m.fd"),
    Path("/usr/share/edk2/x64/OVMF_CODE.fd"),
    Path("/usr/share/edk2-ovmf/x64/OVMF_CODE.4m.fd"),
    Path("/usr/share/edk2-ovmf/x64/OVMF_CODE.fd"),
    Path("/usr/share/ovmf/x64/OVMF_CODE.fd"),
]
OVMF_VARS_CANDIDATES = [
    Path("/usr/share/edk2/x64/OVMF_VARS.4m.fd"),
    Path("/usr/share/edk2/x64/OVMF_VARS.fd"),
    Path("/usr/share/edk2-ovmf/x64/OVMF_VARS.4m.fd"),
    Path("/usr/share/edk2-ovmf/x64/OVMF_VARS.fd"),
    Path("/usr/share/ovmf/x64/OVMF_VARS.fd"),
]


class Check:
    def __init__(self, name: str) -> None:
        self.name = name
        self.ok = False
        self.detail = ""

    def as_dict(self) -> dict:
        return {"name": self.name, "ok": self.ok, "detail": self.detail}


class Report:
    def __init__(self, case_id: str) -> None:
        self.case_id = case_id
        self.started = datetime.now(timezone.utc)
        self.checks: list[Check] = []
        self.result = "fail"
        self.commit = git_commit()
        self.log_paths: dict[str, str] = {}

    def add(self, name: str, ok: bool, detail: str = "") -> Check:
        c = Check(name)
        c.ok = ok
        c.detail = detail
        self.checks.append(c)
        print(f"  [{'OK' if ok else 'FAIL'}] {name}" + (f" — {detail}" if detail else ""))
        return c

    def write(self, path: Path) -> None:
        ended = datetime.now(timezone.utc)
        payload = {
            "id": self.case_id,
            "result": self.result,
            "commit": self.commit,
            "started": self.started.isoformat(),
            "ended": ended.isoformat(),
            "duration_s": int((ended - self.started).total_seconds()),
            "checks": [c.as_dict() for c in self.checks],
            "logs": self.log_paths,
        }
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload, indent=2) + "\n")
        summary = path.with_name("latest.txt")
        lines = [
            f"case: {self.case_id}",
            f"result: {self.result}",
            f"commit: {self.commit}",
            f"duration_s: {payload['duration_s']}",
            "",
        ]
        for c in self.checks:
            mark = "OK" if c.ok else "FAIL"
            lines.append(f"[{mark}] {c.name}" + (f" — {c.detail}" if c.detail else ""))
        summary.write_text("\n".join(lines) + "\n")
        print(f"\nReport: {path}")
        print(summary.read_text())


def git_commit() -> str:
    try:
        return subprocess.check_output(
            ["git", "-C", str(REPO), "rev-parse", "--short", "HEAD"],
            text=True,
        ).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return "unknown"


def which_or_die(name: str) -> str:
    path = shutil.which(name)
    if not path:
        raise SystemExit(f"Required command not on PATH: {name}")
    return path


def iso_volume_label(iso: Path) -> str:
    with iso.open("rb") as fh:
        fh.seek(16 * 2048)
        pvd = fh.read(2048)
    if pvd[1:6] != b"CD001":
        raise SystemExit(f"Not an ISO 9660 image: {iso}")
    return pvd[40:72].decode("ascii", errors="replace").strip()


def find_ovmf() -> tuple[Path, Path]:
    code = next((p for p in OVMF_CODE_CANDIDATES if p.is_file()), None)
    variables = next((p for p in OVMF_VARS_CANDIDATES if p.is_file()), None)
    if not code or not variables:
        raise SystemExit(
            "OVMF firmware not found. Install edk2-ovmf "
            "(looked under /usr/share/edk2 and /usr/share/edk2-ovmf)."
        )
    return code, variables


def _writable_copy(src: Path, dest: Path) -> None:
    """ISO members are mode 0444; copy2 onto an existing dest then EACCES."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        dest.chmod(0o644)
        dest.unlink()
    shutil.copyfile(src, dest)
    dest.chmod(0o644)


def extract_kernel(iso: Path, dest: Path) -> tuple[Path, Path]:
    dest.mkdir(parents=True, exist_ok=True)
    kernel = dest / "vmlinuz-linux"
    initrd = dest / "initramfs-linux.img"
    # Do not compare mtimes: the kernel inside the ISO keeps its build date,
    # which is older than the downloaded ISO file, so every run would re-copy.
    if kernel.is_file() and initrd.is_file() and kernel.stat().st_size > 0:
        kernel.chmod(0o644)
        initrd.chmod(0o644)
        return kernel, initrd
    bsdtar = which_or_die("bsdtar")
    scratch = dest / ".extract"
    if scratch.exists():
        shutil.rmtree(scratch)
    scratch.mkdir()
    subprocess.check_call(
        [
            bsdtar,
            "-xf",
            str(iso),
            "-C",
            str(scratch),
            "arch/boot/x86_64/vmlinuz-linux",
            "arch/boot/x86_64/initramfs-linux.img",
        ]
    )
    _writable_copy(scratch / "arch/boot/x86_64/vmlinuz-linux", kernel)
    _writable_copy(scratch / "arch/boot/x86_64/initramfs-linux.img", initrd)
    shutil.rmtree(scratch, ignore_errors=True)
    return kernel, initrd


def ensure_iso(cache: Path, explicit: Path | None) -> Path:
    if explicit:
        if not explicit.is_file():
            raise SystemExit(f"ISO not found: {explicit}")
        return explicit
    cache.mkdir(parents=True, exist_ok=True)
    iso = cache / ISO_NAME
    if iso.is_file() and iso.stat().st_size > 100_000_000:
        print(f"Using cached ISO {iso}")
        return iso
    print(f"Downloading Arch ISO → {iso}")
    subprocess.check_call(["curl", "-L", "--fail", "-o", str(iso), ISO_URL])
    return iso


def generate_ssh_key(work: Path) -> tuple[Path, Path]:
    key = work / "id_ed25519"
    pub = work / "id_ed25519.pub"
    if key.is_file() and pub.is_file():
        return key, pub
    subprocess.check_call(
        ["ssh-keygen", "-t", "ed25519", "-N", "", "-f", str(key), "-C", "up-vm-test"]
    )
    return key, pub


class Qemu:
    def __init__(self, args: list[str], serial_log: Path, monitor: Path | None = None) -> None:
        self.serial_log = serial_log
        self.monitor = monitor
        self.buf = ""
        self.log_fh = serial_log.open("ab", buffering=0)
        self.proc = subprocess.Popen(
            args,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )

    def monitor_cmd(self, line: str) -> None:
        if not self.monitor or not self.monitor.exists():
            raise RuntimeError("QEMU monitor socket missing")
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(5)
        sock.connect(str(self.monitor))
        sock.sendall((line.strip() + "\n").encode("ascii"))
        time.sleep(0.1)
        sock.close()

    def sendkey(self, keys: str) -> None:
        # QEMU hyphen = keys held together, e.g. super_l-ret
        print(f"    qemu sendkey {keys}")
        self.monitor_cmd(f"sendkey {keys}")

    def powerdown(self) -> None:
        try:
            self.monitor_cmd("system_powerdown")
            return
        except (OSError, RuntimeError):
            pass
        self.terminate()

    def write(self, data: str) -> None:
        assert self.proc.stdin is not None
        self.proc.stdin.write(data.encode("utf-8", errors="replace"))
        self.proc.stdin.flush()
        self.log_fh.write(data.encode("utf-8", errors="replace"))

    def send_line(self, line: str) -> None:
        print(f"    >>> {line}")
        self.write(line + "\n")

    def read_some(self, timeout: float) -> str:
        assert self.proc.stdout is not None
        if timeout <= 0:
            return ""
        ready, _, _ = _select([self.proc.stdout], timeout)
        if not ready:
            return ""
        chunk = os.read(self.proc.stdout.fileno(), 4096)
        if not chunk:
            return ""
        self.log_fh.write(chunk)
        text = chunk.decode("utf-8", errors="replace")
        self.buf += text
        return text

    def wait_for(
        self,
        needles: list[str],
        timeout: float,
        fatal: list[str] | None = None,
    ) -> str:
        deadline = time.time() + timeout
        fatal = fatal or []
        while time.time() < deadline:
            if self.proc.poll() is not None:
                raise RuntimeError(f"QEMU exited early (code {self.proc.returncode})")
            for n in fatal:
                if n in self.buf:
                    preview = self.buf[-400:].replace("\n", "\\n")
                    raise RuntimeError(f"Fatal serial marker {n!r}. Tail: {preview}")
            for n in needles:
                if n in self.buf:
                    return n
            self.read_some(min(1.0, deadline - time.time()))
        preview = self.buf[-400:].replace("\n", "\\n")
        raise TimeoutError(f"Timed out waiting for {needles!r}. Serial tail: {preview}")

    def wait_exit(self, timeout: float) -> int:
        try:
            return int(self.proc.wait(timeout=timeout))
        except subprocess.TimeoutExpired:
            self.terminate()
            raise

    def terminate(self) -> None:
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        self.log_fh.close()


def _select(files: list, timeout: float) -> tuple[list, list, list]:
    import select

    return select.select(files, [], [], timeout)


def qemu_base(
    *,
    ram_mb: int,
    cpus: int,
    disk: Path,
    ovmf_code: Path,
    ovmf_vars: Path,
    ssh_port: int,
    repo: Path,
    work: Path,
    gl: bool = False,
) -> list[str]:
    qemu = which_or_die("qemu-system-x86_64")
    vga = "virtio-vga-gl" if gl else "virtio-vga"
    display = "egl-headless,gl=on" if gl else "none"
    return [
        qemu,
        "-enable-kvm",
        "-machine",
        "q35,smm=off",
        "-cpu",
        "host",
        "-m",
        str(ram_mb),
        "-smp",
        str(cpus),
        "-drive",
        f"if=pflash,format=raw,readonly=on,file={ovmf_code}",
        "-drive",
        f"if=pflash,format=raw,file={ovmf_vars}",
        "-drive",
        f"file={disk},if=virtio,format=qcow2",
        "-netdev",
        f"user,id=net0,hostfwd=tcp:127.0.0.1:{ssh_port}-:22",
        "-device",
        "virtio-net-pci,netdev=net0",
        "-device",
        vga,
        "-display",
        display,
        "-serial",
        "stdio",
        "-monitor",
        f"unix:{work / 'qemu-mon.sock'},server,nowait",
        "-fsdev",
        f"local,id=upsrc,path={repo},security_model=none,readonly=on",
        "-device",
        "virtio-9p-pci,fsdev=upsrc,mount_tag=upsrc",
        "-fsdev",
        f"local,id=upwork,path={work},security_model=none",
        "-device",
        "virtio-9p-pci,fsdev=upwork,mount_tag=upwork",
        "-no-reboot",
    ]


def ssh_cmd(
    key: Path,
    port: int,
    remote: str,
    extra: list[str] | None = None,
    user: str | None = None,
) -> list[str]:
    cmd = [
        "ssh",
        "-i",
        str(key),
        "-p",
        str(port),
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "UserKnownHostsFile=/dev/null",
        "-o",
        "ConnectTimeout=5",
        "-o",
        "LogLevel=ERROR",
        f"{user or SSH_USER}@127.0.0.1",
    ]
    if extra:
        cmd.extend(extra)
    cmd.append(remote)
    return cmd


def wait_ssh(key: Path, port: int, timeout: float) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            out = subprocess.run(
                ssh_cmd(key, port, "echo up-ssh-ok"),
                capture_output=True,
                text=True,
                timeout=10,
            )
            if out.returncode == 0 and "up-ssh-ok" in out.stdout:
                return True
        except (subprocess.TimeoutExpired, OSError):
            pass
        time.sleep(3)
    return False


def ssh_script(
    key: Path,
    port: int,
    script: Path,
    arg: str,
    timeout: int = 90,
    env: dict[str, str] | None = None,
) -> tuple[bool, str]:
    prefix = ""
    if env:
        parts = [f"{k}={_shlex_quote(v)}" for k, v in env.items()]
        prefix = " ".join(parts) + " "
    try:
        with script.open("rb") as fh:
            proc = subprocess.Popen(
                ssh_cmd(key, port, f"{prefix}bash -s {arg}"),
                stdin=fh,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
        chunks: list[bytes] = []
        deadline = time.time() + timeout
        assert proc.stdout is not None
        fd = proc.stdout.fileno()
        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                proc.kill()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.terminate()
                extra = b"".join(chunks)
                return False, extra.decode("utf-8", errors="replace").strip() + "\nTIMEOUT"
            ready, _, _ = select.select([fd], [], [], min(1.0, remaining))
            if not ready:
                continue
            line = proc.stdout.readline()
            if not line:
                break
            chunks.append(line)
            text_line = line.decode("utf-8", errors="replace").rstrip()
            if text_line:
                print(f"    {text_line}", flush=True)
        rc = proc.wait(timeout=10)
        text = b"".join(chunks).decode("utf-8", errors="replace").strip()
        return rc == 0, text
    except (subprocess.TimeoutExpired, OSError) as exc:
        return False, str(exc)


def _shlex_quote(value: str) -> str:
    import shlex

    return shlex.quote(value)


def push_live_tools(key: Path, port: int) -> str:
    """Copy current bin/ + configs/ into the guest so suites test this tree.

    Installed guests may predate --invoke / --font / --image. 9p is not
    always mounted after reboot; a tar over SSH is enough.
    """
    remote = (
        "rm -rf /tmp/upsrc && mkdir -p /tmp/upsrc && "
        "tar -C /tmp/upsrc -xf - && "
        "test -x /tmp/upsrc/bin/up-system-menu && echo OVERLAY_OK"
    )
    try:
        proc = subprocess.run(
            [
                "tar",
                "-C",
                str(REPO),
                "-cf",
                "-",
                "--exclude=.git",
                "bin",
                "configs",
            ],
            stdout=subprocess.PIPE,
            check=True,
        )
        out = subprocess.run(
            ssh_cmd(key, port, remote),
            input=proc.stdout,
            capture_output=True,
            timeout=60,
        )
        text = (out.stdout + out.stderr).decode("utf-8", errors="replace")
        if out.returncode == 0 and "OVERLAY_OK" in text:
            print("    guest overlay /tmp/upsrc (live repo bin+configs)")
            return "/tmp/upsrc"
        print(f"    guest overlay failed: {text[-300:]}")
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError) as exc:
        print(f"    guest overlay error: {exc}")
    return "/usr/local/share/up"


def guest_up_env(key: Path, port: int, extra: dict[str, str] | None = None) -> dict[str, str]:
    ensure_guest_sudo(key, port)
    root = push_live_tools(key, port)
    path = f"{root}/bin:/usr/local/share/up/bin:/usr/local/bin:/usr/bin:/bin"
    env = {"UP_ROOT": root, "PATH": path, "DISPLAY": ":0"}
    if extra:
        env.update(extra)
    return env


def ssh_ok(
    key: Path,
    port: int,
    remote: str,
    timeout: int = 30,
    user: str | None = None,
) -> tuple[bool, str]:
    try:
        out = subprocess.run(
            ssh_cmd(key, port, remote, user=user),
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        text = (out.stdout + out.stderr).strip()
        return out.returncode == 0, text
    except (subprocess.TimeoutExpired, OSError) as exc:
        return False, str(exc)


def ensure_guest_sudo(key: Path, port: int) -> None:
    """Give tester passwordless sudo so the guest can use the same sudo
    re-exec a desktop user would (menu Install).
    The suite itself must still run those commands as tester, not as root."""
    remote = (
        "printf '%s\\n' 'tester ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/zz-up-vm-test && "
        "chmod 440 /etc/sudoers.d/zz-up-vm-test && "
        "grep -q '^@includedir /etc/sudoers.d' /etc/sudoers || "
        "echo '@includedir /etc/sudoers.d' >> /etc/sudoers; "
        "visudo -cf /etc/sudoers.d/zz-up-vm-test >/dev/null && echo SUDOERS_OK"
    )
    ok, out = ssh_ok(key, port, remote, user="root", timeout=20)
    if ok and "SUDOERS_OK" in out:
        print("    guest sudo: NOPASSWD restored")
        return
    print(f"    guest sudo restore skipped: {out[-200:]}")


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def parse_suites(raw: str) -> list[str]:
    parts = [p.strip() for p in raw.split(",") if p.strip()]
    bad = [p for p in parts if p not in KNOWN_SUITES]
    if bad:
        raise SystemExit(
            f"Unknown suite(s): {', '.join(bad)}. Choose from: {', '.join(KNOWN_SUITES)}"
        )
    return parts


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Run the uefi-virtio Up VM install case")
    p.add_argument("--iso", type=Path, help="Existing Arch ISO (skips download)")
    p.add_argument("--work", type=Path, default=DEFAULT_WORK)
    p.add_argument("--cache", type=Path, default=DEFAULT_CACHE)
    p.add_argument("--ram-mb", type=int, default=4096)
    p.add_argument("--cpus", type=int, default=2)
    p.add_argument("--disk-gb", type=int, default=40)
    p.add_argument("--ssh-port", type=int, default=0)
    p.add_argument("--install-timeout", type=int, default=INSTALL_TIMEOUT)
    p.add_argument(
        "--suites",
        default="smoke,appearance,apps",
        help="Comma-separated desktop suites: smoke,appearance,apps",
    )
    p.add_argument(
        "--boot-only",
        action="store_true",
        help="After install (or --skip-install), wait for i3 and power off; skip suites",
    )
    p.add_argument(
        "--skip-install",
        action="store_true",
        help="Reuse an existing tests/vm/work disk (do not reinstall)",
    )
    p.add_argument(
        "--save-base",
        action="store_true",
        help="Snapshot the current disk as the post-OS base (also done automatically after install)",
    )
    p.add_argument(
        "--restore-base",
        action="store_true",
        help="Reset the overlay from the post-OS base before every suite",
    )
    p.add_argument(
        "--no-restore-base",
        action="store_true",
        help="Do not reset the overlay (keep packages/theme changes)",
    )
    p.add_argument("--dry-run", action="store_true", help="Check host tools and ISO extract only")
    return p.parse_args()


def qemu_img_info(path: Path) -> dict:
    raw = subprocess.check_output(
        ["qemu-img", "info", "--output=json", str(path)],
        text=True,
    )
    return json.loads(raw)


def disk_backing(path: Path) -> Path | None:
    if not path.is_file():
        return None
    try:
        info = qemu_img_info(path)
    except (subprocess.CalledProcessError, json.JSONDecodeError, FileNotFoundError):
        return None
    backing = info.get("full-backing-filename") or info.get("backing-filename")
    return Path(backing) if backing else None


def create_overlay(disk: Path, base: Path) -> None:
    if disk.exists():
        disk.unlink()
    subprocess.check_call(
        ["qemu-img", "create", "-f", "qcow2", "-F", "qcow2", "-b", str(base), str(disk)]
    )


def save_installed_base(
    disk: Path,
    base: Path,
    ovmf_vars: Path,
    ovmf_base: Path,
) -> None:
    """Freeze the installed OS as a standalone backing image; disk becomes a thin overlay."""
    which_or_die("qemu-img")
    if disk_backing(disk) is not None:
        tmp = base.with_name(base.name + ".new")
        if tmp.exists():
            tmp.unlink()
        print(f"    flattening {disk.name} → {base.name}")
        subprocess.check_call(["qemu-img", "convert", "-O", "qcow2", str(disk), str(tmp)])
        if base.exists():
            base.unlink()
        tmp.rename(base)
        disk.unlink()
    else:
        if base.exists():
            base.unlink()
        print(f"    promoting {disk.name} → {base.name}")
        disk.rename(base)
    if ovmf_vars.is_file():
        shutil.copy2(ovmf_vars, ovmf_base)
    create_overlay(disk, base)
    print(f"    overlay {disk.name} backing {base.name}")


def restore_installed_base(
    disk: Path,
    base: Path,
    ovmf_vars: Path,
    ovmf_base: Path,
) -> None:
    if not base.is_file() or base.stat().st_size == 0:
        raise RuntimeError(f"no post-OS base disk at {base}")
    print(f"    restoring overlay from {base.name}")
    create_overlay(disk, base)
    if ovmf_base.is_file():
        shutil.copy2(ovmf_base, ovmf_vars)


def should_restore_base(suite: str, args: argparse.Namespace) -> bool:
    if args.no_restore_base:
        return False
    return bool(args.restore_base)


def record_script_checks(report: Report, prefix: str, out: str) -> int:
    """Add CHECK_OK / CHECK_FAIL lines from a guest script. Returns how many were found."""
    n = 0
    for line in out.splitlines():
        if line.startswith("CHECK_OK "):
            report.add(f"{prefix}{line[9:].strip()}", True)
            n += 1
        elif line.startswith("CHECK_FAIL "):
            report.add(f"{prefix}{line[11:].strip()}", False)
            n += 1
    return n


def wait_guest_off(qemu: Qemu, report: Report, name: str = "guest_powered_off") -> None:
    try:
        qemu.wait_exit(timeout=90)
        report.add(name, True, "QEMU exited after shutdown")
    except Exception:
        qemu.powerdown()
        try:
            qemu.wait_exit(timeout=20)
            report.add(name, True, "QEMU monitor system_powerdown")
        except Exception as exc:
            report.add(name, False, str(exc))
            qemu.terminate()


def run_smoke_suite(qemu: Qemu, key: Path, port: int, report: Report) -> bool:
    desktop_sh = REPO / "tests" / "vm" / "guest-desktop.sh"
    ssh_ok(key, port, "pkill -u tester -x alacritty || true")
    time.sleep(0.5)

    def alacritty_up() -> bool:
        alive, text = ssh_ok(
            key,
            port,
            "pgrep -u tester -x alacritty >/dev/null && echo TERM_OK || echo TERM_WAIT",
        )
        return alive and "TERM_OK" in text

    opened = False
    how = "no Super+Return method opened alacritty"
    for chord in ("super_l-ret", "meta_l-ret"):
        try:
            qemu.sendkey(chord)
        except Exception as exc:
            how = f"qemu sendkey {chord} error: {exc}"
            continue
        deadline = time.time() + 8
        while time.time() < deadline:
            if alacritty_up():
                opened = True
                how = f"qemu sendkey {chord}"
                break
            time.sleep(0.4)
        if opened:
            break

    if not opened:
        ok, out = ssh_script(key, port, desktop_sh, "open-term", timeout=60)
        if ok and "TERM_OK" in out:
            opened = True
            how = "xdotool Super_L+Return (qemu sendkey missed)"
        else:
            how = f"{how}\n{out}"

    report.add("send_super_return", opened, how)
    report.add("terminal_opened", opened, how)
    if not opened:
        return False

    ok, out = ssh_script(key, port, desktop_sh, "shutdown", timeout=30)
    report.add("type_shutdown", ok and "TYPED_SHUTDOWN" in out, out[-200:])
    return True


def run_named_suite(
    name: str,
    key: Path,
    port: int,
    report: Report,
    extra_env: dict[str, str] | None = None,
) -> bool:
    script = REPO / "tests" / "vm" / f"guest-{name}.sh"
    env = guest_up_env(key, port, extra=extra_env)
    report.add(f"{name}.up_root", bool(env.get("UP_ROOT")), env.get("UP_ROOT", ""))
    timeout = SUITE_TIMEOUT
    ok, out = ssh_script(key, port, script, "run", timeout=timeout, env=env)
    preview = out[-800:] if out else ""
    n = record_script_checks(report, f"{name}.", out)
    marker_ok = f"SUITE_OK {name}" in out
    shutdown_ok = (
        "MENU_SHUTDOWN_OK" in out
        or "APPS_SHUTDOWN_OK" in out
        or "TYPED_SHUTDOWN" in out
    )
    report.add(
        f"{name}_suite",
        ok or marker_ok or shutdown_ok,
        preview if n else preview or "no CHECK_* lines",
    )
    if name == "appearance":
        report.add("appearance_menu_shutdown", "MENU_SHUTDOWN_OK" in out, preview[-200:])
    if name == "apps":
        report.add("apps_shutdown", "APPS_SHUTDOWN_OK" in out, preview[-200:])
    return marker_ok or (n > 0 and all(
        c.ok for c in report.checks if c.name.startswith(f"{name}.")
    ))


def main() -> int:
    args = parse_args()
    report = Report(CASE_ID)
    work: Path = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    reports = REPO / "tests" / "vm" / "reports"
    reports.mkdir(parents=True, exist_ok=True)
    report_path = reports / f"{CASE_ID}.json"

    try:
        which_or_die("qemu-system-x86_64")
        which_or_die("qemu-img")
        which_or_die("ssh")
        which_or_die("ssh-keygen")
        which_or_die("bsdtar")
        which_or_die("curl")
        ovmf_code, ovmf_vars_src = find_ovmf()
        report.add("host_tools", True, f"ovmf={ovmf_code}")
    except SystemExit as exc:
        report.add("host_tools", False, str(exc))
        report.write(report_path)
        return 1

    if not Path("/dev/kvm").exists():
        report.add("kvm", False, "/dev/kvm missing — enable VT-x/AMD-V")
        report.write(report_path)
        return 1
    report.add("kvm", True)

    if args.dry_run:
        cached = args.iso or (args.cache / ISO_NAME)
        if cached.is_file():
            try:
                label = iso_volume_label(cached)
                report.add("iso", True, f"cached label={label}")
            except Exception as exc:
                report.add("iso", False, str(exc))
        else:
            report.add("iso", True, "skipped (no ISO; pass --iso or run without --dry-run)")
        report.add("dry_run", True, "host checks only; guest not started")
        report.result = "pass" if all(c.ok for c in report.checks) else "fail"
        report.write(report_path)
        return 0 if report.result == "pass" else 1

    try:
        suites = [] if args.boot_only else parse_suites(args.suites)
    except SystemExit as exc:
        report.add("suites", False, str(exc))
        report.write(report_path)
        return 1
    if args.boot_only:
        report.add("suites", True, "boot-only (no desktop suites)")
    else:
        report.add("suites", True, ",".join(suites) if suites else "(none)")

    key, pub = generate_ssh_key(work)
    shutil.copy2(REPO / "tests/vm/fixtures/uefi-virtio.conf", work / "answers.conf")
    disk = work / f"{CASE_ID}.qcow2"
    base_disk = work / f"{CASE_ID}.base.qcow2"
    ovmf_vars = work / f"{CASE_ID}.OVMF_VARS.fd"
    ovmf_base = work / f"{CASE_ID}.base.OVMF_VARS.fd"
    if args.skip_install:
        have_disk = disk.is_file() and disk.stat().st_size > 0
        have_base = base_disk.is_file() and base_disk.stat().st_size > 0
        if not have_disk and not have_base:
            report.add("skip_install", False, f"no existing disk at {disk} or {base_disk}")
            report.write(report_path)
            return 1
        if not ovmf_vars.is_file():
            src = ovmf_base if ovmf_base.is_file() else ovmf_vars_src
            shutil.copy2(src, ovmf_vars)
        if args.save_base:
            if not have_disk:
                report.add("save_base", False, "no overlay to snapshot; restore from base first")
                report.write(report_path)
                return 1
            try:
                save_installed_base(disk, base_disk, ovmf_vars, ovmf_base)
                report.add("save_base", True, str(base_disk))
            except Exception as exc:
                report.add("save_base", False, str(exc))
                report.write(report_path)
                return 1
        elif not have_disk and have_base:
            try:
                restore_installed_base(disk, base_disk, ovmf_vars, ovmf_base)
                report.add("restore_base", True, f"created overlay from {base_disk}")
            except Exception as exc:
                report.add("restore_base", False, str(exc))
                report.write(report_path)
                return 1
        report.add("skip_install", True, str(disk))
        if have_base or base_disk.is_file():
            report.add("base_disk", True, str(base_disk))
        else:
            report.add(
                "base_disk",
                True,
                "none — next full install will create one; "
                "or pass --save-base to snapshot this disk",
            )
    else:
        if disk.exists():
            disk.unlink()
        subprocess.check_call(["qemu-img", "create", "-f", "qcow2", str(disk), f"{args.disk_gb}G"])
        shutil.copy2(ovmf_vars_src, ovmf_vars)
    ssh_port = args.ssh_port or free_port()
    serial_install = work / "serial-install.log"
    serial_boot = work / "serial-boot.log"
    report.log_paths = {
        "install": str(serial_install),
        "boot": str(serial_boot),
    }

    if not args.skip_install:
        try:
            iso = ensure_iso(args.cache, args.iso)
            label = iso_volume_label(iso)
            kernel, initrd = extract_kernel(iso, args.cache / "boot")
            report.add("iso", True, f"label={label}")
        except Exception as exc:
            report.add("iso", False, str(exc))
            report.write(report_path)
            return 1

    mon = work / "qemu-mon.sock"
    desktop_sh = REPO / "tests" / "vm" / "guest-desktop.sh"

    if not args.skip_install:
        install_args = qemu_base(
            ram_mb=args.ram_mb,
            cpus=args.cpus,
            disk=disk,
            ovmf_code=ovmf_code,
            ovmf_vars=ovmf_vars,
            ssh_port=ssh_port,
            repo=REPO,
            work=work,
        ) + [
            "-kernel",
            str(kernel),
            "-initrd",
            str(initrd),
            "-append",
            # Do not pass ip=dhcp: that activates archiso_pxe_common, which then
            # fails in the initramfs (SIOCGIFFLAGS / IP-Config) and drops to
            # [rootfs ~]# instead of the live ISO. Network is configured later
            # by guest-iso.sh via dhcpcd.
            f"archisobasedir=arch archisolabel={label} cow_spacesize=4G "
            "earlymodules=virtio_pci,virtio_blk,virtio_net,virtio_scsi,iso9660,sr_mod "
            "console=ttyS0,115200n8",
            "-cdrom",
            str(iso),
            "-boot",
            "order=dc",
        ]

        if mon.exists():
            mon.unlink()
        print("Starting QEMU (Arch ISO, unattended install)...")
        qemu = Qemu(install_args, serial_install, monitor=mon)
        try:
            try:
                qemu.wait_for(
                    ["root@archiso"],
                    timeout=180,
                    fatal=["[rootfs ~]#", "Failed to configure network"],
                )
            except TimeoutError:
                if "login:" in qemu.buf:
                    qemu.send_line("root")
                    qemu.wait_for(["root@archiso", "# "], timeout=30)
                else:
                    raise
            qemu.send_line("export TERM=dumb")
            qemu.send_line("mkdir -p /upsrc /upwork")
            qemu.send_line("modprobe 9p 9pnet 9pnet_virtio || true")
            qemu.send_line("mount -t 9p -o trans=virtio,version=9p2000.L upsrc /upsrc")
            qemu.send_line("mount -t 9p -o trans=virtio,version=9p2000.L upwork /upwork")
            qemu.send_line("ls /upsrc/install-unattended.sh /upsrc/tests/vm/guest-iso.sh")
            qemu.wait_for(["install-unattended.sh"], timeout=30)
            qemu.send_line("bash /upsrc/tests/vm/guest-iso.sh")
            found = qemu.wait_for(
                ["UNATTENDED_INSTALL_OK", "UNATTENDED_INSTALL_FAIL"],
                timeout=args.install_timeout,
            )
            ok = found == "UNATTENDED_INSTALL_OK"
            report.add("unattended_install", ok, found)
            if not ok:
                qemu.terminate()
                report.write(report_path)
                return 1
        except Exception as exc:
            report.add("unattended_install", False, str(exc))
            qemu.terminate()
            report.write(report_path)
            return 1

        # Power off the live ISO so we can boot the installed disk.
        qemu.send_line("poweroff")
        try:
            qemu.wait_exit(timeout=60)
        except Exception:
            qemu.terminate()

        try:
            save_installed_base(disk, base_disk, ovmf_vars, ovmf_base)
            report.add("save_base", True, str(base_disk))
        except Exception as exc:
            report.add("save_base", False, str(exc))
            report.write(report_path)
            return 1

    sessions = suites if suites else ["boot"]
    boot_args = qemu_base(
        ram_mb=args.ram_mb,
        cpus=args.cpus,
        disk=disk,
        ovmf_code=ovmf_code,
        ovmf_vars=ovmf_vars,
        ssh_port=ssh_port,
        repo=REPO,
        work=work,
        gl=True,
    )

    for idx, suite in enumerate(sessions):
        label = suite if suite != "boot" else "boot-only"
        if should_restore_base(suite, args) and base_disk.is_file():
            try:
                restore_installed_base(disk, base_disk, ovmf_vars, ovmf_base)
                report.add(f"{label}.restore_base", True, str(base_disk))
            except Exception as exc:
                report.add(f"{label}.restore_base", False, str(exc))
                report.write(report_path)
                return 1
        print(f"Booting installed disk for suite: {label} ({idx + 1}/{len(sessions)})...")
        if mon.exists():
            mon.unlink()
        # Later suites append to the same serial log.
        qemu = Qemu(boot_args, serial_boot, monitor=mon)
        try:
            ssh_ready = wait_ssh(key, ssh_port, BOOT_TIMEOUT)
            report.add(f"{label}.ssh", ssh_ready, f"port={ssh_port}")
            if not ssh_ready:
                qemu.powerdown()
                qemu.terminate()
                report.write(report_path)
                return 1

            if idx == 0:
                ok, out = ssh_ok(
                    key,
                    ssh_port,
                    "test -s /usr/local/share/up/version && cat /usr/local/share/up/version",
                )
                report.add("up_version", ok, out)

                ok, out = ssh_ok(
                    key,
                    ssh_port,
                    "test -s /home/tester/.config/i3/keybindings.conf && "
                    "grep -c '^bindsym ' /home/tester/.config/i3/keybindings.conf",
                )
                report.add("keybindings", ok, out)

                ok, out = ssh_ok(key, ssh_port, "systemctl is-active lightdm || true")
                report.add("lightdm", "active" in out, out)

            ok, out = ssh_script(key, ssh_port, desktop_sh, "wait-i3", timeout=DESKTOP_TIMEOUT + 30)
            report.add(f"{label}.graphical_session", ok and "I3_OK" in out, out[-400:])
            if not (ok and "I3_OK" in out):
                qemu.powerdown()
                try:
                    qemu.wait_exit(timeout=30)
                except Exception:
                    qemu.terminate()
                report.write(report_path)
                return 1

            if suite == "boot":
                qemu.powerdown()
                wait_guest_off(qemu, report, f"{label}.powered_off")
                continue

            if suite == "smoke":
                run_smoke_suite(qemu, key, ssh_port, report)
            elif suite in ("appearance", "apps"):
                run_named_suite(suite, key, ssh_port, report)
            else:
                report.add(f"{suite}_suite", False, "unhandled suite")

            wait_guest_off(qemu, report, f"{label}.powered_off")
        except Exception as exc:
            report.add(f"{label}.installed_boot", False, str(exc))
            qemu.powerdown()
            qemu.terminate()
            report.write(report_path)
            return 1

    report.result = "pass" if all(c.ok for c in report.checks) else "fail"
    report.write(report_path)
    return 0 if report.result == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
