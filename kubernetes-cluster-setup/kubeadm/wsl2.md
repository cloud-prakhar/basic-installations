# kubeadm — Single-Node Cluster on Windows 11 with WSL2

Build a one-node Kubernetes cluster inside an Ubuntu WSL2 distribution on Windows 11. The WSL2 distro is control plane **and** worker.

> [!IMPORTANT]
> **kubeadm cannot run on native Windows.** It configures Linux kernel modules, cgroups, netfilter rules, and a systemd-managed kubelet. WSL2 is a real Linux kernel, so it works — but **only WSL2 with systemd enabled**. WSL1 will not work at all.
>
> If you want an easier local cluster on Windows, use **[Minikube](../minikube/windows.md)** or **[Kind](../kind/windows.md)** instead. Use this page only if you specifically want to learn how Kubernetes is bootstrapped.

Two shells are used on this page. **Read the comment above every command block:**

- `# PowerShell` — a normal Windows PowerShell window
- `# PowerShell (Administrator)` — right-click PowerShell → *Run as administrator*
- `# WSL Ubuntu` — inside your Ubuntu WSL2 distribution

Validated **2026-08-05** on Windows 11 24H2, WSL2 with Ubuntu 24.04, Kubernetes **1.36**, containerd **2.3.x**, Calico **v3.32.1**. Time: 30–45 minutes.

---

## Contents

1. [Requirements](#1-requirements)
2. [Enable WSL2 and install Ubuntu](#2-enable-wsl2-and-install-ubuntu)
3. [Enable systemd](#3-enable-systemd)
4. [Allocate CPU and memory with .wslconfig](#4-allocate-cpu-and-memory-with-wslconfig)
5. [Verify kernel capabilities](#5-verify-kernel-capabilities)
6. [WSL2 limitations you must understand](#6-wsl2-limitations-you-must-understand)
7. [Prepare the host](#7-prepare-the-host)
8. [Install containerd](#8-install-containerd)
9. [Install kubeadm, kubelet, kubectl](#9-install-kubeadm-kubelet-kubectl)
10. [Initialize the cluster](#10-initialize-the-cluster)
11. [Configure kubectl](#11-configure-kubectl-for-your-regular-user)
12. [Install the CNI plugin](#12-install-the-cni-plugin-calico)
13. [Remove the control-plane taint](#13-remove-the-control-plane-taint)
14. [Verify the cluster](#14-verify-the-cluster)
15. [Deploy the sample application](#15-deploy-the-sample-application)
16. [Access the application from Windows](#16-access-the-application-from-windows)
17. [Restarting WSL and what breaks](#17-restarting-wsl-and-what-breaks)
18. [Troubleshooting](#18-troubleshooting)
19. [Reset and cleanup](#19-reset-and-cleanup)

---

## 1. Requirements

| Resource | Minimum | Recommended |
|----------|--------:|------------:|
| CPU (allocated to WSL2) | 2 cores | 4 cores |
| Memory (allocated to WSL2) | 4 GB | 6–8 GB |
| Disk free on `C:` | 25 GB | 40 GB |
| Nodes | 1 | 1 |

Because WSL2 shares your laptop's RAM with Windows, a machine with **8 GB total** is tight — Windows itself wants 4 GB. **16 GB total** is comfortable.

Also required:

- Windows 11 (or Windows 10 build 19044+)
- Virtualization enabled in BIOS/UEFI (Intel VT-x / AMD-V)
- Administrator access for the initial WSL install

**Check virtualization is on:**

```powershell
# PowerShell
Get-ComputerInfo -Property "HyperVRequirementVirtualizationFirmwareEnabled","HyperVisorPresent"
```

**Expected output:**

```text
HyperVRequirementVirtualizationFirmwareEnabled : True
HyperVisorPresent                              : True
```

If `False`, reboot into BIOS/UEFI and enable Intel VT-x or AMD-V (often labelled "SVM Mode" on AMD).

---

## 2. Enable WSL2 and install Ubuntu

### 2.1 Install WSL with Ubuntu

**What:** installs the WSL platform, the WSL2 kernel, and Ubuntu in one step.
**Why:** modern `wsl --install` handles the Windows features, kernel, and default distro together. You no longer need `dism.exe` commands.

```powershell
# PowerShell (Administrator)
wsl --install -d Ubuntu-24.04
```

Reboot when prompted. On first launch Ubuntu asks you to create a UNIX username and password — **remember the password**, you need it for `sudo`.

If WSL is already installed and you just want another distro:

```powershell
# PowerShell
wsl --list --online
wsl --install -d Ubuntu-24.04
```

### 2.2 Confirm the WSL version

**What:** confirm the distro runs on WSL **2**, not WSL 1.
**Why:** WSL1 is a syscall translation layer with no real Linux kernel — no cgroups, no systemd, no netfilter. kubeadm cannot work there.

```powershell
# PowerShell
wsl --list --verbose
```

**Expected output:**

```text
  NAME            STATE           VERSION
* Ubuntu-24.04    Running         2
```

> [!WARNING]
> If `VERSION` is `1`, convert it. This takes several minutes and the distro must be stopped:
>
> ```powershell
> # PowerShell (Administrator)
> wsl --shutdown
> wsl --set-version Ubuntu-24.04 2
> wsl --set-default-version 2
> ```

### 2.3 Update WSL itself

**What:** update the WSL platform and Linux kernel.
**Why:** systemd support and several cgroup v2 fixes require a recent WSL build. Older builds silently misbehave.

```powershell
# PowerShell (Administrator)
wsl --update
wsl --version
```

**Expected output** (versions will differ, but `WSL version` should be 2.x):

```text
WSL version: 2.7.1.0
Kernel version: 6.6.87.2-1
WSLg version: 1.0.66
...
```

✅ **Verify:** kernel version 5.15 or newer.

---

## 3. Enable systemd

**What:** turn on systemd as PID 1 inside the WSL2 distro.
**Why:** the kubelet and containerd are both **systemd services**. kubeadm writes systemd unit drop-ins and expects `systemctl` to work. It also expects the `systemd` cgroup driver. Without systemd, none of this functions and the cluster cannot start.

### 3.1 Edit `/etc/wsl.conf`

```bash
# WSL Ubuntu (root)
sudo tee /etc/wsl.conf > /dev/null <<'EOF'
[boot]
systemd=true

[network]
generateResolvConf = true

[interop]
enabled = true
appendWindowsPath = true
EOF

cat /etc/wsl.conf
```

### 3.2 Restart WSL

**What:** fully shut down the WSL VM so the new boot setting applies.
**Why:** `[boot]` settings are read only when the distro's VM starts. Closing the terminal window is **not** enough.

```powershell
# PowerShell
wsl --shutdown
```

Wait ~10 seconds, then open Ubuntu again.

### 3.3 Verify systemd is running

```bash
# WSL Ubuntu
ps -p 1 -o comm=
systemctl is-system-running
```

**Expected output:**

```text
systemd
running
```

`degraded` is acceptable — it means some unrelated unit failed (common in WSL). `running` or `degraded` both mean systemd is PID 1.

**If you get `System has not been booted with systemd as init system (PID 1)`:**

1. Confirm `/etc/wsl.conf` contains `systemd=true` under `[boot]`.
2. Confirm `wsl --version` reports 2.x (systemd needs WSL 0.67.6+).
3. Run `wsl --shutdown` from PowerShell again — a plain terminal close does not restart the VM.

✅ **Checkpoint — do not continue until `ps -p 1 -o comm=` prints `systemd`.**

---

## 4. Allocate CPU and memory with `.wslconfig`

**What:** set global limits for the WSL2 virtual machine.
**Why:** by default WSL2 takes up to 50% of your RAM (or 8 GB, whichever is less) and all logical processors. kubeadm needs ≥2 CPUs and the cluster needs ~2 GB before your workloads. Setting this explicitly avoids both starvation and Windows itself being starved.

### 4.1 Check current allocation

```bash
# WSL Ubuntu
nproc
free -h
```

If `nproc` is ≥ 2 and total memory is ≥ 4 GB, you can skip to §5.

### 4.2 Create `.wslconfig`

This file lives in your **Windows** user profile, not inside WSL.

```powershell
# PowerShell
notepad "$env:USERPROFILE\.wslconfig"
```

Paste, adjusting to your machine (do not give WSL more than ~60% of physical RAM):

```ini
[wsl2]
memory=6GB
processors=4
swap=0
localhostForwarding=true
```

| Setting | Why |
|---|---|
| `memory=6GB` | Enough for the control plane plus workloads. Use `4GB` minimum. |
| `processors=4` | kubeadm requires ≥2. Four is comfortable. |
| `swap=0` | **Important.** Kubernetes requires swap off. Setting it here means you do not fight WSL's swap file later. |
| `localhostForwarding=true` | Lets Windows reach WSL-bound ports via `localhost`. Essential for §16. |

### 4.3 Apply

```powershell
# PowerShell
wsl --shutdown
```

Reopen Ubuntu.

✅ **Verify:**

```bash
# WSL Ubuntu
nproc
free -h
swapon --show || echo "swap: none (correct)"
```

**Expected output:**

```text
4
               total        used        free
Mem:           5.8Gi       0.4Gi       5.3Gi
Swap:             0B          0B          0B
swap: none (correct)
```

---

## 5. Verify kernel capabilities

**What:** confirm the WSL2 kernel has what Kubernetes needs.
**Why:** WSL2 uses a Microsoft-built kernel. Recent builds include everything required, but older ones may lack modules.

```bash
# WSL Ubuntu
uname -r
echo "--- cgroup version (expect 2) ---"
stat -fc %T /sys/fs/cgroup/
echo "--- required modules ---"
sudo modprobe overlay   && echo "overlay OK"
sudo modprobe br_netfilter && echo "br_netfilter OK"
echo "--- netfilter/iptables ---"
sudo iptables -L -n > /dev/null && echo "iptables OK"
```

**Expected output:**

```text
6.6.87.2-microsoft-standard-WSL2
--- cgroup version (expect 2) ---
cgroup2fs
--- required modules ---
overlay OK
br_netfilter OK
--- netfilter/iptables ---
iptables OK
```

If a `modprobe` fails, run `wsl --update` from PowerShell (Administrator) and retry. If it still fails, your WSL kernel is a custom build without those modules — reinstall the stock kernel via `wsl --update`.

---

## 6. WSL2 limitations you must understand

Read this before you build anything, so nothing surprises you later.

| Limitation | What happens | How you deal with it |
|---|---|---|
| **Reboots** | WSL does not auto-start on Windows login. Your cluster is stopped until you open the Ubuntu terminal. | Open Ubuntu, wait ~60 s for the kubelet and static Pods to come back. |
| **IP address changes** | The WSL2 VM gets a **new IP on every restart** (typically `172.x.x.x`). Your API server certificate was issued for the old IP. | Use `--apiserver-advertise-address` bound to a stable value and prefer `kubectl port-forward` over IP-based access. See §17 for the fix when it does break. |
| **Networking is NAT'd** | WSL2 sits behind a virtual NAT. Windows can reach WSL; WSL reaches Windows via a gateway IP, not `localhost`. | `localhostForwarding=true` handles the common Windows→WSL direction. |
| **systemd** | Off by default; must be enabled in `/etc/wsl.conf` and needs a full `wsl --shutdown`. | §3. |
| **cgroups** | WSL2 uses cgroup v2 (good), but some cgroup controllers are absent. Memory limits work; some exotic accounting does not. | Fine for learning. Do not benchmark resource enforcement here. |
| **Port exposure** | Ports bound inside WSL are reachable from Windows via `localhost` — but **only when bound to `0.0.0.0`**, not `127.0.0.1`. | NodePort binds `0.0.0.0` by design, so it works. |
| **Windows Firewall** | Can block WSL→Windows and LAN→WSL traffic. Reaching your cluster from **another device on your LAN** requires a Windows `netsh portproxy` rule plus a firewall rule. | Out of scope for a learning cluster; use `port-forward`. |
| **Nested virtualization** | WSL2 is itself a VM. Anything requiring nested virtualization (VM-based Minikube drivers, VirtualBox inside WSL) will not work. | Irrelevant here — kubeadm runs directly on the WSL kernel. |
| **Swap** | WSL2 creates a swap file by default. Kubernetes requires swap off. | `swap=0` in `.wslconfig` (§4.2) plus `swapoff -a`. |
| **Disk** | The WSL virtual disk grows but does not shrink automatically. | Only matters after months of use. |

> [!WARNING]
> **Do not use WSL1.** No Linux kernel, no cgroups, no systemd, no netfilter. Nothing on this page works there.

---

## 7. Prepare the host

Everything from here runs **inside WSL Ubuntu**.

### 7.1 Update packages

```bash
# WSL Ubuntu (root)
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get install -y ca-certificates curl gnupg apt-transport-https
```

### 7.2 Set the hostname

**Why:** the Kubernetes node object is named after the hostname and it is baked into TLS certificates. WSL's default hostname is your Windows machine name, which may contain uppercase letters or characters Kubernetes rejects.

```bash
# WSL Ubuntu (root)
sudo hostnamectl set-hostname k8s-single
```

Make it stick across WSL restarts — otherwise WSL resets it to the Windows machine name:

```bash
# WSL Ubuntu (root)
sudo tee -a /etc/wsl.conf > /dev/null <<'EOF'

[network]
hostname = k8s-single
EOF
```

Then from PowerShell: `wsl --shutdown`, and reopen Ubuntu.

✅ **Verify:**

```bash
# WSL Ubuntu
hostname
```

**Expected output:** `k8s-single`

### 7.3 Update `/etc/hosts`

**Why:** components resolve the node's own name. WSL regenerates `/etc/hosts` on every start unless you disable that.

```bash
# WSL Ubuntu (root)
echo "127.0.1.1 k8s-single" | sudo tee -a /etc/hosts
getent hosts k8s-single
```

To stop WSL overwriting it, add to `/etc/wsl.conf`:

```bash
# WSL Ubuntu (root)
sudo tee -a /etc/wsl.conf > /dev/null <<'EOF'

[network]
generateHosts = false
EOF
```

### 7.4 Disable swap

**Why:** the kubelet's eviction logic assumes RAM is the hard limit. With swap on, an over-limit Pod swaps instead of being evicted and the node degrades silently. The kubelet refuses to start with swap enabled.

You already set `swap=0` in `.wslconfig` (§4.2). Belt and braces:

```bash
# WSL Ubuntu (root)
sudo swapoff -a
```

✅ **Verify:**

```bash
# WSL Ubuntu
swapon --show
free -h | grep -i swap
```

**Expected output** — `swapon --show` prints nothing:

```text
Swap:            0B          0B          0B
```

If swap comes back after a restart, `swap=0` is missing or misspelled in `%USERPROFILE%\.wslconfig`, or you did not run `wsl --shutdown` after editing it.

### 7.5 Load kernel modules

**Why:** `overlay` is containerd's snapshotter filesystem; `br_netfilter` makes bridged Pod traffic visible to iptables so kube-proxy's Service rules actually apply.

```bash
# WSL Ubuntu (root)
cat <<'EOF' | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter
lsmod | grep -E '^(overlay|br_netfilter)'
```

> [!NOTE]
> `/etc/modules-load.d/` is honoured by `systemd-modules-load.service`, which only runs because you enabled systemd in §3. If modules are missing after a WSL restart, check `systemctl status systemd-modules-load`.

### 7.6 Configure sysctl

**Why:** `ip_forward` lets the node route Pod traffic; the bridge settings make netfilter process bridged frames so Services work.

```bash
# WSL Ubuntu (root)
cat <<'EOF' | sudo tee /etc/sysctl.d/99-kubernetes.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
```

✅ **Verify:**

```bash
# WSL Ubuntu
sysctl net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables
```

**Expected output:**

```text
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
```

### 7.7 Choose the Pod CIDR

Check the WSL2 network first:

```bash
# WSL Ubuntu
ip -4 addr show eth0 | grep inet
```

WSL2 typically uses `172.16–31.x.x`, so **`192.168.0.0/16`** (Calico's default) is safe and is what this page uses.

```bash
# WSL Ubuntu
export POD_NETWORK_CIDR=192.168.0.0/16
```

If your WSL2 address happens to be in `192.168.x.x`, use `10.244.0.0/16` instead and substitute it everywhere below.

---

## 8. Install containerd

### 8.1 Why containerd, not Docker

Kubernetes talks to runtimes over **CRI**. containerd implements CRI natively; Docker Engine does not (kubelet support for it was removed in Kubernetes 1.24). Installing containerd directly means fewer moving parts.

> [!IMPORTANT]
> If **Docker Desktop's WSL integration** is enabled for this distro, disable it for this distro before continuing (Docker Desktop → Settings → Resources → WSL Integration). Two runtimes competing over `/run/containerd/containerd.sock` and iptables rules causes confusing failures.

### 8.2 Install

```bash
# WSL Ubuntu (root)
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y containerd.io
containerd --version
```

**Expected output:**

```text
containerd containerd.io 2.3.3 <commit-sha>
```

### 8.3 Configure, enable SystemdCgroup, verify CRI

**Why `SystemdCgroup = true`:** on a systemd host, systemd owns the cgroup hierarchy. The kubelet defaults to the `systemd` cgroup driver. If containerd uses `cgroupfs` instead you get two writers to one hierarchy — wrong accounting, unpredictable Pod kills. **They must match.**

```bash
# WSL Ubuntu (root)
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
grep -n 'SystemdCgroup' /etc/containerd/config.toml
```

**Expected output:**

```text
<line>:            SystemdCgroup = true
```

**Ensure the CRI plugin is not disabled** — Docker's package has historically shipped `disabled_plugins = ["cri"]`, which makes containerd invisible to the kubelet:

```bash
# WSL Ubuntu (root)
grep -n 'disabled_plugins' /etc/containerd/config.toml
sudo sed -i 's/disabled_plugins = \["cri"\]/disabled_plugins = []/' /etc/containerd/config.toml
```

**Expected output:** `disabled_plugins = []`

### 8.4 Start and verify

```bash
# WSL Ubuntu (root)
sudo systemctl restart containerd
sudo systemctl enable containerd

systemctl is-active containerd
systemctl is-enabled containerd
ls -l /run/containerd/containerd.sock
sudo ctr plugin ls | grep -E 'NAME|cri'
```

**Expected output:**

```text
active
enabled
srw-rw---- 1 root root 0 Aug  5 10:12 /run/containerd/containerd.sock
```

with the CRI plugin rows showing `STATUS: ok`.

**Inspect logs on failure:**

```bash
# WSL Ubuntu (root)
sudo journalctl -u containerd -n 50 --no-pager
```

---

## 9. Install kubeadm, kubelet, kubectl

| Component | Role |
|---|---|
| **kubeadm** | Bootstrapper. Runs once to generate certificates and start the control plane. Not a daemon. |
| **kubelet** | The node agent — a permanent systemd service. Talks to containerd over CRI and to the API server. |
| **kubectl** | The CLI for talking to the API server. |

### 9.1 Configure the repository

> [!WARNING]
> 🔴 Do **not** use `apt.kubernetes.io` or `packages.cloud.google.com/apt`. Those repositories are retired and no longer served. `pkgs.k8s.io` is versioned per minor release — the version is part of the URL.

```bash
# WSL Ubuntu (root)
export KUBERNETES_VERSION=v1.36     # minor version only, with leading "v"

sudo mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/Release.key" \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
sudo chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo chmod 644 /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
```

Check what is current at <https://kubernetes.io/releases/>.

### 9.2 Install and hold

**Why hold:** Kubernetes upgrades are an ordered procedure. An unattended `apt upgrade` bumping the kubelet under a running control plane breaks the cluster.

```bash
# WSL Ubuntu (root)
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet
```

> [!NOTE]
> The kubelet now crash-loops every few seconds. **This is expected** — it has no config until `kubeadm init` runs. It settles automatically.

✅ **Verify:**

```bash
# WSL Ubuntu
kubeadm version -o short
kubelet --version
kubectl version --client
```

**Expected output:**

```text
v1.36.1
Kubernetes v1.36.1
Client Version: v1.36.1
```

**Version skew:** the kubelet must never be newer than the API server (it may be up to three minor versions older); `kubectl` may be one minor version either side. Installed together as above, this is automatic.

---

## 10. Initialize the cluster

### 10.1 Determine the node IP

```bash
# WSL Ubuntu
export NODE_IP=$(ip route get 1.1.1.1 | awk '{print $7; exit}')
echo "NODE_IP=$NODE_IP  POD_NETWORK_CIDR=$POD_NETWORK_CIDR"
```

**Expected output** (example):

```text
NODE_IP=172.28.114.53  POD_NETWORK_CIDR=192.168.0.0/16
```

> [!IMPORTANT]
> **This IP changes when WSL restarts.** That is the single biggest WSL2 annoyance for kubeadm. The API server certificate includes it. §17 explains what breaks and how to fix it.

### 10.2 Run `kubeadm init`

| Flag | Meaning |
|---|---|
| `--apiserver-advertise-address` | The IP the API server listens on and writes into certificates and kubeconfig. |
| `--pod-network-cidr` | The range Pods get addresses from; read by the CNI. |
| `--cri-socket` | Which runtime the kubelet uses. Explicit avoids ambiguity if Docker is also present. |
| `--node-name` | Name of the Node object. |

```bash
# WSL Ubuntu (root)
sudo kubeadm init \
  --apiserver-advertise-address="${NODE_IP}" \
  --pod-network-cidr="${POD_NETWORK_CIDR}" \
  --cri-socket="unix:///run/containerd/containerd.sock" \
  --node-name="k8s-single"
```

2–6 minutes on first run.

**Expected output** (tail):

```text
Your Kubernetes control-plane has initialized successfully!
...
kubeadm join 172.28.114.53:6443 --token abcdef.0123456789abcdef ...
```

> [!NOTE]
> **Ignore the `kubeadm join` line.** There is no second machine.

**What was created:** certificates in `/etc/kubernetes/pki/`, static Pod manifests (`kube-apiserver`, `etcd`, `kube-scheduler`, `kube-controller-manager`) in `/etc/kubernetes/manifests/` — the kubelet watches that directory and starts them, which is how the control plane bootstraps itself — admin kubeconfig at `/etc/kubernetes/admin.conf`, kubelet config at `/var/lib/kubelet/config.yaml`, and etcd data in `/var/lib/etcd/`.

---

## 11. Configure kubectl for your regular user

```bash
# WSL Ubuntu (your normal user, NOT root)
mkdir -p "$HOME/.kube"
sudo cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"
```

✅ **Verify:**

```bash
# WSL Ubuntu
kubectl cluster-info
kubectl get nodes
```

**Expected output:**

```text
Kubernetes control plane is running at https://172.28.114.53:6443

NAME         STATUS     ROLES           AGE   VERSION
k8s-single   NotReady   control-plane   45s   v1.36.1
```

`NotReady` is correct — no CNI yet.

> [!WARNING]
> 🔴 This file holds **cluster-admin credentials**. Never commit it or share it.

**Optional — use this cluster from Windows `kubectl`:** copy `\\wsl$\Ubuntu-24.04\home\<user>\.kube\config` to `%USERPROFILE%\.kube\config`. It works until the WSL IP changes, at which point you must copy it again. `kubectl port-forward` from inside WSL is less fragile.

---

## 12. Install the CNI plugin (Calico)

### 12.1 Why the node is `NotReady`

The kubelet reports `Ready` only once a network plugin is initialized. With no `/etc/cni/net.d/` config, the node carries `NetworkReady=false` / `NetworkPluginNotReady`, and CoreDNS (which needs Pod networking) stays `Pending`.

```bash
# WSL Ubuntu
kubectl describe node k8s-single | grep -A5 Conditions
kubectl get pods -n kube-system
```

### 12.2 Install Calico

```bash
# WSL Ubuntu
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.32.1/manifests/calico.yaml
kubectl -n kube-system rollout status daemonset/calico-node --timeout=300s
```

✅ **Verify:**

```bash
# WSL Ubuntu
kubectl get nodes
kubectl get pods -n kube-system
```

**Expected output:**

```text
NAME         STATUS   ROLES           AGE   VERSION
k8s-single   Ready    control-plane   5m    v1.36.1
```

with `calico-node`, `calico-kube-controllers`, both `coredns` Pods, `etcd`, `kube-apiserver`, `kube-controller-manager`, `kube-proxy`, and `kube-scheduler` all `Running`.

### 12.3 Alternatives

| CNI | Notes |
|---|---|
| **Cilium** (`cilium install --version 1.20.0`) | eBPF-based, excellent observability. Needs kernel 5.10+ — WSL2's kernel qualifies. Heavier. |
| **Flannel** | Simplest, but hard-codes `10.244.0.0/16` and has no NetworkPolicy support. |

Install **exactly one**.

---

## 13. Remove the control-plane taint

A **taint** repels Pods that lack a matching **toleration**. `kubeadm` applies `node-role.kubernetes.io/control-plane:NoSchedule` so application Pods never compete with etcd and the API server for resources. With one node, that leaves your app nowhere to run.

```bash
# WSL Ubuntu
kubectl describe node k8s-single | grep -i -A2 taints
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
kubectl describe node k8s-single | grep -i -A2 taints
```

**Expected output:**

```text
Taints:             node-role.kubernetes.io/control-plane:NoSchedule
node/k8s-single untainted
Taints:             <none>
```

> [!WARNING]
> Correct here **only** because this is a single-node learning cluster. In production you add worker nodes instead. To restore: `kubectl taint nodes k8s-single node-role.kubernetes.io/control-plane=:NoSchedule`

✅ **Confirm scheduling works:**

```bash
# WSL Ubuntu
kubectl run scheduling-test --image=nginx:1.30-alpine --restart=Never
kubectl wait --for=condition=Ready pod/scheduling-test --timeout=120s
kubectl get pod scheduling-test -o wide
kubectl delete pod scheduling-test
```

The Pod IP must come from your Pod CIDR.

---

## 14. Verify the cluster

```bash
# WSL Ubuntu
kubectl get nodes -o wide
kubectl get pods -n kube-system -o wide
kubectl get deployment coredns -n kube-system
kubectl get svc kube-dns -n kube-system
kubectl get daemonset calico-node -n kube-system
systemctl is-active kubelet containerd
kubectl cluster-info
kubectl get --raw='/readyz?verbose' | tail -5
```

**Expected result:**

```text
One node
Status: Ready
Roles: control-plane
```

**Pod networking and DNS:**

```bash
# WSL Ubuntu
kubectl run net-a --image=nginx:1.30-alpine
kubectl run net-b --image=busybox:1.37 --restart=Never --command -- sleep 3600
kubectl wait --for=condition=Ready pod/net-a pod/net-b --timeout=120s

POD_A_IP=$(kubectl get pod net-a -o jsonpath='{.status.podIP}')
kubectl exec net-b -- wget -qO- --timeout=5 "http://${POD_A_IP}" | head -4

kubectl expose pod net-a --name=net-a-svc --port=80
kubectl exec net-b -- nslookup net-a-svc.default.svc.cluster.local

kubectl delete pod net-a net-b; kubectl delete svc net-a-svc
```

Both should succeed.

---

## 15. Deploy the sample application

Manifests are in [`manifests/`](./manifests/) — fully commented.

```bash
# WSL Ubuntu
cd kubernetes-cluster-setup/kubeadm
kubectl apply -f manifests/
kubectl -n demo rollout status deployment/web --timeout=180s
kubectl -n demo get all -o wide
```

**Expected output:**

```text
namespace/demo created
deployment.apps/web created
service/web created
service/web-nodeport created

NAME                      READY   STATUS    RESTARTS   AGE
pod/web-6c9d8f7b4-abcde   1/1     Running   0          40s
pod/web-6c9d8f7b4-fghij   1/1     Running   0          40s

NAME                   TYPE        CLUSTER-IP     PORT(S)        AGE
service/web            ClusterIP   10.96.171.22   80/TCP         40s
service/web-nodeport   NodePort    10.96.203.11   80:30080/TCP   40s
```

**Both replicas run on the same node — that is expected.** `replicas: 2` means two Pods, not two machines. You get real ReplicaSet behaviour (rolling updates, self-healing, load-balanced endpoints) but no node-failure tolerance, because there is one node.

---

## 16. Access the application from Windows

### Method 1 — `kubectl port-forward` (recommended for WSL2)

The only method immune to the WSL IP changing.

```bash
# WSL Ubuntu — leave running
kubectl -n demo port-forward --address 0.0.0.0 svc/web 8080:80
```

`--address 0.0.0.0` is required. Bound to the default `127.0.0.1`, WSL's localhost forwarding will not pick it up.

Then in Windows:

```powershell
# PowerShell
curl.exe http://localhost:8080
```

Or open <http://localhost:8080> in your Windows browser. This works because `localhostForwarding=true` in `.wslconfig` (§4.2).

**Expected output:** the nginx welcome page.

### Method 2 — NodePort via WSL localhost forwarding

```bash
# WSL Ubuntu
curl -s http://localhost:30080 | head -5
```

Then from Windows:

```powershell
# PowerShell
curl.exe http://localhost:30080
```

WSL's localhost forwarding usually relays this. If it does not, use Method 1 — or address the WSL IP directly:

```powershell
# PowerShell
$wslIp = (wsl hostname -I).Trim().Split()[0]
curl.exe "http://${wslIp}:30080"
```

That works until the next WSL restart changes the IP.

### Method 3 — reaching it from another device on your LAN

Requires a Windows port proxy plus a firewall rule.

```powershell
# PowerShell (Administrator)
$wslIp = (wsl hostname -I).Trim().Split()[0]
netsh interface portproxy add v4tov4 listenport=30080 listenaddress=0.0.0.0 connectport=30080 connectaddress=$wslIp
New-NetFirewallRule -DisplayName "WSL k8s NodePort 30080" -Direction Inbound -LocalPort 30080 -Protocol TCP -Action Allow
```

Remove it when you are done:

```powershell
# PowerShell (Administrator)  🔴 DESTRUCTIVE
netsh interface portproxy delete v4tov4 listenport=30080 listenaddress=0.0.0.0
Remove-NetFirewallRule -DisplayName "WSL k8s NodePort 30080"
```

> [!NOTE]
> The port proxy points at a **fixed** WSL IP. After a WSL restart you must delete and re-add it. This is why `port-forward` is the recommended method.

### Method comparison

| Method | Survives WSL restart | Needs admin | Reachable from |
|---|---|---|---|
| `port-forward --address 0.0.0.0` | ✅ Yes | No | Windows `localhost` |
| NodePort via `localhost` | ✅ Usually | No | Windows `localhost` |
| NodePort via WSL IP | ❌ No | No | Windows |
| `netsh portproxy` | ❌ No (must re-add) | Yes | Your whole LAN |

---

## 17. Restarting WSL and what breaks

### After a Windows reboot or `wsl --shutdown`

1. Open Ubuntu. systemd starts, and the kubelet starts the static control-plane Pods.
2. Wait 30–90 seconds.
3. Check:

```bash
# WSL Ubuntu
kubectl get nodes
kubectl get pods -n kube-system
```

Usually everything comes back on its own.

### If the WSL IP changed

**Symptom:**

```text
The connection to the server 172.28.114.53:6443 was refused - did you specify the right host or port?
```

**Diagnose:**

```bash
# WSL Ubuntu
ip route get 1.1.1.1 | awk '{print $7; exit}'    # current IP
grep server "$HOME/.kube/config"                  # IP in kubeconfig
```

If they differ, the WSL2 VM got a new address.

**Fix — point kubeconfig at the loopback listener** (the API server also listens on `127.0.0.1`, and its certificate already includes it):

```bash
# WSL Ubuntu
kubectl config set-cluster kubernetes --server=https://127.0.0.1:6443
kubectl get nodes
```

That survives every future IP change.

**If the certificate does not cover the new IP** (`x509: certificate is valid for ..., not ...`), regenerate the API server certificate:

```bash
# WSL Ubuntu (root)  🔴 DESTRUCTIVE to certs, not to cluster data
NEW_IP=$(ip route get 1.1.1.1 | awk '{print $7; exit}')
sudo rm -f /etc/kubernetes/pki/apiserver.crt /etc/kubernetes/pki/apiserver.key
sudo kubeadm init phase certs apiserver --apiserver-advertise-address="${NEW_IP}"

# restart the API server static pod by bouncing the kubelet
sudo systemctl restart kubelet

# refresh kubeconfig
sudo kubeadm init phase kubeconfig admin
sudo cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
kubectl get nodes
```

Cluster data (etcd) is untouched — your workloads survive.

### If swap came back

```bash
# WSL Ubuntu
swapon --show
sudo swapoff -a
sudo systemctl restart kubelet
```

Then verify `swap=0` is present in `%USERPROFILE%\.wslconfig` and that you ran `wsl --shutdown` after editing it.

---

## 18. Troubleshooting

Full matrix in **[troubleshooting.md](./troubleshooting.md)**. The WSL2-specific ones:

| Symptom | Cause | Diagnostic | Fix |
|---|---|---|---|
| `System has not been booted with systemd as init system` | systemd not enabled | `ps -p 1 -o comm=` | Add `systemd=true` to `/etc/wsl.conf` `[boot]`, then `wsl --shutdown` from PowerShell (§3) |
| `kubeadm init` → `[ERROR NumCPU]` | WSL2 has <2 CPUs | `nproc` | Set `processors=4` in `%USERPROFILE%\.wslconfig`, `wsl --shutdown` (§4) |
| `kubeadm init` → `[ERROR Swap]` | Swap on | `swapon --show` | `swap=0` in `.wslconfig` + `sudo swapoff -a` |
| kubelet crash-loops with cgroup errors | containerd on `cgroupfs`, kubelet on `systemd` | `sudo journalctl -u kubelet -n 50` | `SystemdCgroup = true` (§8.3), restart containerd and kubelet |
| Node stuck `NotReady` | No CNI | `kubectl describe node \| grep NetworkReady` | Install Calico (§12) |
| Pods `Pending` forever | Control-plane taint | `kubectl describe pod <n> \| tail -5` | `kubectl taint nodes --all node-role.kubernetes.io/control-plane-` |
| `connection refused` on `:6443` after restart | WSL IP changed | Compare `ip route get 1.1.1.1` with `~/.kube/config` | §17 |
| Windows browser cannot reach the app | `port-forward` bound to `127.0.0.1` | `ss -tlnp \| grep 8080` | Use `--address 0.0.0.0` |
| Hostname reverts to the Windows machine name | WSL regenerates it | `hostname` | `[network] hostname = k8s-single` in `/etc/wsl.conf`, then `wsl --shutdown` |
| `modprobe: FATAL: Module not found` | Old WSL kernel | `uname -r` | `wsl --update` in PowerShell (Administrator) |
| containerd socket missing | Docker Desktop WSL integration is fighting it | `docker context ls`; check Docker Desktop settings | Disable WSL integration for this distro |

**Diagnostics:**

```bash
# WSL Ubuntu
sudo journalctl -u kubelet -n 100 --no-pager
sudo journalctl -u containerd -n 100 --no-pager
kubectl get events -A --sort-by=.lastTimestamp | tail -30
sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps -a
```

```powershell
# PowerShell
wsl --list --verbose
wsl --version
```

---

## 19. Reset and cleanup

### 19.1 Delete only the application

```bash
# WSL Ubuntu
kubectl delete namespace demo
```

### 19.2 Full cluster reset

> [!CAUTION]
> 🔴 **DESTRUCTIVE.** Permanently destroys the cluster and all etcd data.

```bash
# WSL Ubuntu (root)  🔴 DESTRUCTIVE
kubectl delete namespace demo --ignore-not-found

sudo kubeadm reset -f --cri-socket=unix:///run/containerd/containerd.sock

sudo rm -rf /etc/cni/net.d /var/lib/cni/
sudo rm -rf /opt/cni/bin/calico*
rm -rf "$HOME/.kube"

# Remove Kubernetes network interfaces
ip link show | grep -E 'cali|tunl|vxlan|cni0'
# then for each interface found:
#   sudo ip link delete <INTERFACE_NAME>

sudo systemctl restart containerd
```

**Networking rules:** in WSL2 the simplest and safest cleanup is to restart the VM — iptables rules do not persist across a WSL restart:

```powershell
# PowerShell
wsl --shutdown
```

If you prefer to flush manually, review first — a VPN or Docker in the same distro will also be affected:

```bash
# WSL Ubuntu (root)  🔴 DESTRUCTIVE — review first
sudo iptables-save | grep -E 'KUBE-|CALI-' | head
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X
```

### 19.3 Recreate the cluster

```bash
# WSL Ubuntu (root)
export NODE_IP=$(ip route get 1.1.1.1 | awk '{print $7; exit}')
sudo swapoff -a
sudo kubeadm init \
  --apiserver-advertise-address="${NODE_IP}" \
  --pod-network-cidr=192.168.0.0/16 \
  --cri-socket=unix:///run/containerd/containerd.sock

mkdir -p "$HOME/.kube"
sudo cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
kubectl config set-cluster kubernetes --server=https://127.0.0.1:6443

kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.32.1/manifests/calico.yaml
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

### 19.4 Remove everything, including the distro

```bash
# WSL Ubuntu (root)  🔴 DESTRUCTIVE
sudo apt-mark unhold kubelet kubeadm kubectl
sudo apt-get purge -y kubelet kubeadm kubectl containerd.io
sudo rm -rf /var/lib/kubelet /etc/kubernetes /var/lib/etcd /var/lib/containerd /etc/containerd
```

Or nuke the whole distro and start fresh:

```powershell
# PowerShell  🔴 DESTRUCTIVE — deletes the entire Ubuntu distro and all files in it
wsl --unregister Ubuntu-24.04
```

Remember to also remove any port proxy rules from §16:

```powershell
# PowerShell (Administrator)
netsh interface portproxy show all
netsh interface portproxy reset
```

---

## Official documentation

- WSL installation — <https://learn.microsoft.com/en-us/windows/wsl/install>
- WSL advanced settings (`.wslconfig`, `wsl.conf`) — <https://learn.microsoft.com/en-us/windows/wsl/wsl-config>
- systemd in WSL — <https://learn.microsoft.com/en-us/windows/wsl/systemd>
- WSL networking — <https://learn.microsoft.com/en-us/windows/wsl/networking>
- Installing kubeadm — <https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/>
- Creating a cluster with kubeadm — <https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/>
- Container runtimes — <https://kubernetes.io/docs/setup/production-environment/container-runtimes/>
- Calico quickstart — <https://docs.tigera.io/calico/latest/getting-started/kubernetes/quickstart>
