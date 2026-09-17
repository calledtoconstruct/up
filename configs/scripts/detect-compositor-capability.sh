#!/usr/bin/env bash
# Detect whether this machine is a good candidate for heavy picom effects.
# Prints shell-assignable KEY=value lines (no secrets). Safe to run without X.
#
# Usage:
#   detect-compositor-capability.sh
#   detect-compositor-capability.sh --json     # single-line JSON
#   detect-compositor-capability.sh --id-only  # machine_id only (no glxinfo)
#
# Exit 0 always when detection completes; non-zero only on usage errors.

set -euo pipefail

JSON=false
ID_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --json) JSON=true ;;
        --id-only) ID_ONLY=true ;;
        -h|--help)
            cat <<'EOF'
Usage: detect-compositor-capability.sh [--json] [--id-only]

Probe virtualization, GPU, RAM, and CPU to recommend a compositor profile:
  full  — glx + dual_kawase blur, fade, dim
  lite  — glx (or stable path), fade/dim, no blur
  safe  — xrender, no blur/fade/dim (max compatibility)

  --id-only  Print machine_id only (no glxinfo). Used for compositor cache checks.

Output is KEY=value lines (or JSON with --json).
EOF
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            exit 2
            ;;
    esac
done

# --- helpers -----------------------------------------------------------------

is_truthy() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|y|Y) return 0 ;;
        *) return 1 ;;
    esac
}

# --- virtualization ----------------------------------------------------------

is_virtual=false
virt_type="none"

if command -v systemd-detect-virt >/dev/null 2>&1; then
    if systemd-detect-virt -q 2>/dev/null; then
        is_virtual=true
        virt_type=$(systemd-detect-virt 2>/dev/null || echo "vm")
    fi
fi

if [ "$is_virtual" = false ] && [ -r /proc/cpuinfo ]; then
    if grep -qiE 'hypervisor|QEMU Virtual CPU|KVM|VMware|VirtualBox' /proc/cpuinfo 2>/dev/null; then
        is_virtual=true
        virt_type="cpuflags"
    fi
fi

if [ "$is_virtual" = false ]; then
    for f in /sys/class/dmi/id/product_name /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/board_vendor; do
        [ -r "$f" ] || continue
        val=$(tr -d '\0' <"$f" 2>/dev/null || true)
        if printf '%s' "$val" | grep -qiE 'VirtualBox|VMware|QEMU|KVM|Bochs|Xen|innotek|Parallels|Hyper-V|Virtual Machine|OpenStack|Amazon EC2|Google Compute'; then
            is_virtual=true
            virt_type="dmi"
            break
        fi
    done
fi

# --- GPU / DRM ---------------------------------------------------------------

# vendor hex without 0x, lower-case
gpu_vendors=""
gpu_count=0
has_nvidia=false
has_amd=false
has_intel=false
has_drm=false

for vendor_file in /sys/class/drm/card*/device/vendor; do
    [ -r "$vendor_file" ] || continue
    # skip card*-* connectors; only primary card nodes
    case "$vendor_file" in
        */card*-*) continue ;;
    esac
    has_drm=true
    raw=$(tr -d '\0\n' <"$vendor_file" 2>/dev/null || true)
    # forms: 0x10de or 10de
    v=$(printf '%s' "$raw" | sed 's/^0x//' | tr 'A-F' 'a-f')
    [ -n "$v" ] || continue
    gpu_count=$((gpu_count + 1))
    gpu_vendors="${gpu_vendors}${gpu_vendors:+ }$v"
    case "$v" in
        10de) has_nvidia=true ;;
        1002) has_amd=true ;;
        8086) has_intel=true ;;
    esac
done

# Fallback: lspci if no DRM nodes (early boot / odd setups)
if [ "$has_drm" = false ] && command -v lspci >/dev/null 2>&1; then
    pci=$(lspci -nn 2>/dev/null | grep -iE 'VGA|3D|Display' || true)
    if [ -n "$pci" ]; then
        has_drm=true
        printf '%s\n' "$pci" | grep -qi '10de' && has_nvidia=true
        printf '%s\n' "$pci" | grep -qiE '1002|AMD|ATI' && has_amd=true
        printf '%s\n' "$pci" | grep -qiE '8086|Intel' && has_intel=true
        gpu_count=$(printf '%s\n' "$pci" | wc -l | tr -d ' ')
    fi
fi

# --- software GL (session-only; optional; skipped for --id-only) -------------

software_gl=false
gl_renderer=""
if [ "$ID_ONLY" = false ] && [ -n "${DISPLAY:-}" ] && command -v glxinfo >/dev/null 2>&1; then
    gl_out=$(glxinfo -B 2>/dev/null || glxinfo 2>/dev/null || true)
    gl_renderer=$(printf '%s\n' "$gl_out" | grep -i 'OpenGL renderer' | head -1 | sed 's/.*: *//')
    if printf '%s\n' "$gl_out" | grep -qiE 'llvmpipe|swrast|softpipe|Microsoft Basic Render'; then
        software_gl=true
    fi
fi

# --- resources ---------------------------------------------------------------

ram_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
ram_gb=$(( (ram_kb + 524288) / 1048576 ))  # rounded GiB
[ "$ram_gb" -lt 1 ] && ram_gb=1

cpus=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)
[ -z "$cpus" ] && cpus=1

# --- machine id (cache invalidation) -----------------------------------------

machine_bits="${virt_type}|${gpu_vendors}|ram=${ram_gb}|cpus=${cpus}"
if command -v sha256sum >/dev/null 2>&1; then
    machine_id=$(printf '%s' "$machine_bits" | sha256sum | awk '{print $1}' | cut -c1-16)
elif command -v md5sum >/dev/null 2>&1; then
    machine_id=$(printf '%s' "$machine_bits" | md5sum | awk '{print $1}' | cut -c1-16)
else
    machine_id=$(printf '%s' "$machine_bits" | cksum | awk '{print $1}')
fi

if [ "$ID_ONLY" = true ]; then
    q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
    printf 'machine_id=%s\n' "$(q "$machine_id")"
    exit 0
fi

# --- scoring -----------------------------------------------------------------

score=0
reasons=()

if [ "$software_gl" = true ]; then
    score=0
    reasons+=("software_gl")
else
    if [ "$has_nvidia" = true ]; then
        score=$((score + 3))
        reasons+=("nvidia")
    elif [ "$has_amd" = true ]; then
        # Treat AMD as capable; discrete vs APU not distinguished cheaply
        score=$((score + 3))
        reasons+=("amd_gpu")
    elif [ "$has_intel" = true ]; then
        score=$((score + 2))
        reasons+=("intel_igpu")
    elif [ "$has_drm" = true ]; then
        score=$((score + 1))
        reasons+=("unknown_gpu")
    else
        reasons+=("no_gpu")
    fi

    if [ "$is_virtual" = false ]; then
        score=$((score + 1))
        reasons+=("bare_metal")
    else
        # VMs often share host GPU poorly or use virtio/qxl
        score=$((score - 1))
        reasons+=("virtual:${virt_type}")
        # No discrete-class GPU inside a VM → hard cap later
    fi

    if [ "$ram_gb" -ge 8 ]; then
        score=$((score + 1))
        reasons+=("ram_ge_8g")
    elif [ "$ram_gb" -lt 4 ]; then
        score=$((score - 1))
        reasons+=("ram_lt_4g")
    fi

    if [ "$cpus" -ge 4 ]; then
        score=$((score + 1))
        reasons+=("cpus_ge_4")
    elif [ "$cpus" -lt 2 ]; then
        score=$((score - 1))
        reasons+=("cpus_lt_2")
    fi
fi

# Hard caps
if [ "$software_gl" = true ]; then
    profile="safe"
elif [ "$is_virtual" = true ] && [ "$has_nvidia" = false ] && [ "$has_amd" = false ]; then
    # Typical VM with only virtio/QXL/intel-passthrough-lite
    if [ "$score" -ge 4 ]; then
        profile="lite"
    else
        profile="safe"
    fi
    reasons+=("vm_cap")
elif [ "$ram_gb" -lt 4 ]; then
    if [ "$score" -ge 5 ]; then
        profile="lite"
    else
        profile="safe"
    fi
    reasons+=("low_ram_cap")
elif [ "$score" -ge 4 ]; then
    profile="full"
elif [ "$score" -ge 2 ]; then
    profile="lite"
else
    profile="safe"
fi

# Backend / fence recommendations
backend="glx"
xrender_sync_fence=false
shadow=true
case "$profile" in
    full)
        backend="glx"
        fade=true
        blur=true
        dim=true
        ;;
    lite)
        backend="glx"
        fade=true
        blur=false
        dim=true
        ;;
    safe)
        backend="xrender"
        fade=false
        blur=false
        dim=false
        shadow=false
        ;;
esac

if [ "$has_nvidia" = true ] && [ "$backend" = "glx" ]; then
    xrender_sync_fence=true
    reasons+=("nvidia_fence")
fi

reason=$(IFS=,; echo "${reasons[*]}")

# --- output ------------------------------------------------------------------

if [ "$JSON" = true ]; then
    # Minimal hand-rolled JSON (no jq required)
    esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
    printf '{"profile":"%s","score":%s,"reason":"%s","machine_id":"%s","backend":"%s","fade":%s,"blur":%s,"dim":%s,"shadow":%s,"xrender_sync_fence":%s,"is_virtual":%s,"virt_type":"%s","has_nvidia":%s,"has_amd":%s,"has_intel":%s,"software_gl":%s,"ram_gb":%s,"cpus":%s,"gl_renderer":"%s"}\n' \
        "$(esc "$profile")" "$score" "$(esc "$reason")" "$(esc "$machine_id")" \
        "$(esc "$backend")" "$fade" "$blur" "$dim" "$shadow" "$xrender_sync_fence" \
        "$is_virtual" "$(esc "$virt_type")" "$has_nvidia" "$has_amd" "$has_intel" \
        "$software_gl" "$ram_gb" "$cpus" "$(esc "$gl_renderer")"
    exit 0
fi

# Quote string fields so consumers can safely `eval` this block.
q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

cat <<EOF
profile=$(q "$profile")
score=$score
reason=$(q "$reason")
machine_id=$(q "$machine_id")
backend=$(q "$backend")
fade=$fade
blur=$blur
dim=$dim
shadow=$shadow
xrender_sync_fence=$xrender_sync_fence
is_virtual=$is_virtual
virt_type=$(q "$virt_type")
has_nvidia=$has_nvidia
has_amd=$has_amd
has_intel=$has_intel
software_gl=$software_gl
ram_gb=$ram_gb
cpus=$cpus
gl_renderer=$(q "$gl_renderer")
EOF
