# Bash Container Runtime (BCR)

A minimal container runtime implementation written in pure Bash.

This project explores the internal mechanisms of containerization technologies (like Docker, Podman, and runc) by implementing them from scratch using Linux Kernel primitives. It serves as an educational tool to understand Namespaces, Cgroups, and Chroot isolation without the abstraction layer of high-level languages.

## Overview

BCR (Bash Container Runtime) provides a lightweight, dependency-free environment to run isolated Linux systems.

**Key Features:**
*   **Process Isolation:** Uses `unshare` to create private Namespaces (PID, UTS, IPC, MOUNT).
*   **Resource Management:** Implements Cgroups v2 for memory limitation.
*   **Filesystem:** Automates the fetching and extraction of Alpine Linux RootFS.
*   **Zero Dependencies:** Requires only standard Linux utilities (`util-linux`, `curl`, `tar`).

## Scope & Disclaimer

This is a proof-of-concept implementation created as part of a DevOps learning roadmap.

*   **Version 0.1.0:** Implements core isolation and resource limits. Networking uses the host stack for simplicity.
*   **Intended Use:** Educational research, kernel experimentation. **Not for production use.**

## Usage

### Prerequisites
*   Linux Kernel with Cgroups v2 enabled.
*   Root privileges (required for namespace creation).

### Installation

```bash
git clone https://github.com/kompot-rar/bash-container-runtime.git
cd bash-container-runtime
chmod +x bcr.sh
```

### Running a Container

To start a new container named "test-01" limited to 100MB RAM:

```bash
sudo ./bcr.sh test-01
```

You will be dropped into a shell inside the isolated environment.

## Technical Architecture

BCR operates by orchestrating the following kernel features:

1.  **Filesystem (RootFS):** Downloads Alpine Mini RootFS to `/var/lib/bcr/<name>`.
2.  **Cgroups v2:** Creates a dedicated control group at `/sys/fs/cgroup/bcr/<name>` and enforces a `memory.max` limit.
3.  **Namespaces:** Executes the target process within a new namespace context:
    *   PID: Process ID 1 inside the container.
    *   UTS: Isolated hostname.
    *   MOUNT: Private mount points (e.g., `/proc`).
4.  **Chroot:** Pivots the root directory to the container's RootFS.



---
*Part of my DevOps Journey 2026. Built to learn, not to replace docker.*
