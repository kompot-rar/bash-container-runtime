#!/bin/bash
#  ____   ____ ____
# | __ ) / ___|  _ \
# |  _ | |   | |_) |
# | |_) | |___|  _ <
# |____/ \____|_| \_\  BASH CONTAINER RUNTIME
#
# ==============================================================================
# AUTHOR:  God Mode AI
# LICENSE: MIT
# PURPOSE: Manual Container Runtime implementation for educational purposes.
#          Demonstrates how Docker works under the hood using raw Kernel APIs.
#          Zero Docker. Zero Containerd. Pure Linux primitives.
#
# CONCEPTS DEMONSTRATED:
#   1. chroot     -> Filesystem Isolation (Jail)
#   2. namespaces -> Process/Network/Mount Isolation (unshare)
#   3. cgroups v2 -> Resource Limitation (Memory)
#
# USAGE:   sudo ./bcr.sh <container_name> [cmd]
# EXAMPLE: sudo ./bcr.sh test1 /bin/sh
# ==============================================================================

# --- SAFETY SETTINGS ---
# set -e: Exit immediately if a command exits with a non-zero status.
# set -u: Treat unset variables as an error when substituting.
# set -o pipefail: The return value of a pipeline is the status of the last command to exit with a non-zero status.
set -euo pipefail

# --- CONFIGURATION VARIABLES ---
# We use Alpine Linux because it's extremely small (approx 3MB) and easy to fetch.
ALPINE_VERSION="3.19.1"
ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/x86_64/alpine-minirootfs-${ALPINE_VERSION}-x86_64.tar.gz"

# The directory on the HOST where container filesystems will live.
# Each container gets a subdirectory here, e.g., /var/lib/bcr/my-container
CONTAINER_ROOT="/var/lib/bcr"

# The location of the Cgroup v2 filesystem.
CGROUP_ROOT="/sys/fs/cgroup/bcr"

# --- PRE-FLIGHT CHECKS ---

# Check if the script is running as root (EUID 0).
# This is mandatory because:
# 1. 'chroot' requires root.
# 2. 'unshare' (creating namespaces) usually requires root.
# 3. Writing to /sys/fs/cgroup requires root.
if [[ $EUID -ne 0 ]]; then
   echo "[ERROR] This script requires root privileges (namespaces, cgroups, chroot)."
   echo "USAGE: sudo $0 $@"
   exit 1
fi

# Check if the user provided a container name argument.
if [ -z "${1:-}" ]; then
    echo "[ERROR] Container name required."
    echo "USAGE: $0 <name> [command]"
    exit 1
fi

# Parse arguments
NAME="$1"                # First arg: Container Name
CMD="${2:-/bin/sh}"      # Second arg: Command to run (default: /bin/sh)
TARGET_DIR="${CONTAINER_ROOT}/${NAME}" # Full path to the container's root filesystem

echo "[INIT] Initializing container: ${NAME}"

# --- PHASE 1: FILESYSTEM PROVISIONING (RootFS) ---
# Before we can isolate a process, it needs a place to live.
# We download a minimal Linux distribution (Alpine) and extract it.

if [ ! -d "$TARGET_DIR" ]; then
    echo "[FS] Downloading Alpine Linux Mini RootFS..."
    mkdir -p "$TARGET_DIR"
    
    # curl: Download the tarball.
    # tar xz: Extract (x) Gzip (z) archive.
    # -C: Change directory to TARGET_DIR before extracting.
    curl -sL "$ALPINE_URL" | tar xz -C "$TARGET_DIR"
    
    echo "[FS] RootFS ready at: $TARGET_DIR"
else
    echo "[FS] Container filesystem already exists. Skipping download."
fi

# --- PHASE 2: INTERNAL ENVIRONMENT SETUP ---
# We modify the container's filesystem BEFORE we enter it.

# DNS Configuration:
# Without this, the container wouldn't know how to resolve domain names (like google.com).
# We inject Google's public DNS into /etc/resolv.conf inside the container's FS.
echo "nameserver 8.8.8.8" > "$TARGET_DIR/etc/resolv.conf"

# --- PHASE 3: CGROUPS V2 (RESOURCE LIMITATION) ---
# Cgroups (Control Groups) allow us to limit how much CPU/RAM a process can use.
# Docker uses this to implement limits like '--memory="100m"'.

echo "[CGROUPS] Configuring resource limits..."

# Create the parent cgroup directory for our runtime.
mkdir -p "$CGROUP_ROOT"

# --- DELEGATION LOGIC (CRITICAL FOR V2) ---
# In Cgroups v2, a controller (like 'memory') must be enabled in the parent's
# 'cgroup.subtree_control' file before it can be used in child cgroups.
if [[ -f "/sys/fs/cgroup/cgroup.controllers" ]] && grep -q "memory" "/sys/fs/cgroup/cgroup.controllers"; then
    # Check if memory control is already enabled for the subtree
    if ! grep -q "memory" "$CGROUP_ROOT/cgroup.subtree_control"; then
        # Enable it by writing "+memory"
        echo "+memory" > "$CGROUP_ROOT/cgroup.subtree_control" || echo "[WARN] Failed to enable memory controller delegation."
    fi
else
    echo "[WARN] Kernel does not expose 'memory' controller in Cgroups v2."
fi

# Create the specific cgroup for THIS container
mkdir -p "$CGROUP_ROOT/$NAME"

# Apply the Hard Memory Limit (100MB)
# If the process tries to use 101MB, the OOM Killer will terminate it.
if [ -w "$CGROUP_ROOT/$NAME/memory.max" ]; then
    echo "100M" > "$CGROUP_ROOT/$NAME/memory.max"
    echo "[CGROUPS] RAM limit set to 100MB."
else
    echo "[WARN] Could not set memory limit (permission denied or cgroup v1)."
fi

# --- ATTACH PROCESS TO CGROUP ---
# We write the PID of the CURRENT script ($$) to 'cgroup.procs'.
# Because 'unshare' creates a child process, that child will INHERIT this cgroup.
# Therefore, the containerized process will effectively be trapped in this limit.
echo $$ > "$CGROUP_ROOT/$NAME/cgroup.procs"

# --- PHASE 4: KERNEL NAMESPACE ISOLATION & EXECUTION ---
# This is where the magic happens. We use 'unshare' to disassociate parts of the
# execution context from the host system.

echo "[KERNEL] Isolating process (PID, UTS, MOUNT, IPC)..."
echo "--------------------------------------------------------"
echo "ENTERING ISOLATED ENVIRONMENT. YOU ARE ROOT (PID 1)."
echo "Type 'exit' to terminate the container."
echo "--------------------------------------------------------"

# unshare arguments breakdown:
# --fork           : Fork the specified program as a child process of unshare rather than running it directly.
#                    This is crucial for PID namespaces to work correctly (PID 1 must be created).
# --pid            : Unshare the PID namespace. The child process becomes PID 1 in the new namespace.
#                    It won't see host processes in 'ps aux'.
# --uts            : Unshare the UTS namespace. Allows changing hostname without affecting the host.
# --mount          : Unshare the Mount namespace. Allows mounting/unmounting filesystems without affecting the host.
# --ipc            : Unshare the IPC namespace. Isolates System V IPC objects and POSIX message queues.
# --map-root-user  : Maps the current user (root) to the root user inside the namespace.
#                    (Ensures permissions work correctly inside).

# bash -c '...'    : We execute a bash script INSIDE the new namespaces to set up the final environment.
# -- "$NAME" ...   : We pass variables as positional arguments ($1, $2, $3) to the inner bash to avoid quoting hell.

unshare --fork --pid --uts --mount --ipc --map-root-user bash -c '
    # Capture arguments passed from the outer script
    NAME="$1"
    TARGET_DIR="$2"
    CMD="$3"

    # --- INSIDE THE CONTAINER (PRE-CHROOT) ---

    # 1. Hostname Isolation (UTS Namespace)
    # We change the hostname to the container name. Host system is unaffected.
    echo "$NAME" > /proc/sys/kernel/hostname
    
    # 2. Mount /proc (Mount Namespace + PID Namespace)
    # Commands like "ps" or "top" need /proc to list processes.
    # We mount a fresh procfs instance inside the container root.
    # Because we are in a new PID namespace, this /proc will only show container processes.
    mount -t proc proc "$TARGET_DIR/proc"
    
    # 3. Enter the Jail (chroot)
    # chroot changes the apparent root directory for the current running process and its children.
    # A process cannot access files outside the chroot jail.
    
    # "exec" replaces the current bash process with the chroot command.
    # inside chroot, we run /bin/sh.
    # We must explicitly export PATH because the chroot environment is empty/clean.
    exec chroot "$TARGET_DIR" /bin/sh -c "export PATH=/bin:/usr/bin:/sbin:/usr/sbin; exec $CMD"
    
' -- "$NAME" "$TARGET_DIR" "$CMD"

# --- CLEANUP ---
# This runs after the container process exits.
echo "[BCR] Container terminated."

# Remove the cgroup directory.
# Note: The filesystem data in /var/lib/bcr/NAME persists (like a stopped Docker container).
rmdir "$CGROUP_ROOT/$NAME" 2>/dev/null || true