# kubeadm — Single-Node Cluster on Native Linux

Build a one-node Kubernetes cluster directly on an Ubuntu or Debian-based laptop/desktop. The same machine is control plane **and** worker.

**Every command in this page runs in your Linux terminal.** Commands with `sudo` need root.

- Validated **2026-08-05** on **Ubuntu 24.04 LTS**, Kubernetes **1.36**, containerd **2.3.x**, Calico **v3.32.1**.
- Time: 20–30 minutes.
- Cost: free.

---

## Contents

1. [Requirements](#1-requirements)
2. [Choose your Pod CIDR](#2-choose-your-pod-cidr)
3. [Prepare the host](#3-prepare-the-host)
4. [Install containerd](#4-install-containerd)
5. [Install kubeadm, kubelet, kubectl](#5-install-kubeadm-kubelet-kubectl)
6. [Initialize the cluster](#6-initialize-the-cluster)
7. [Configure kubectl](#7-configure-kubectl-for-your-regular-user)
8. [Install the CNI plugin](#8-install-the-cni-plugin-calico)
9. [Remove the control-plane taint](#9-remove-the-control-plane-taint)
10. [Verify the cluster](#10-verify-the-cluster)
11. [Deploy the sample application](#11-deploy-the-sample-application)
12. [Access the application](#12-access-the-application)
13. [Troubleshooting](#13-troubleshooting)
14. [Reset and cleanup](#14-reset-and-cleanup)

---

## 1. Requirements

| Resource | Minimum | Recommended |
|----------|--------:|------------:|
| CPU | 2 cores | 4 cores |
| Memory | 4 GB | 6–8 GB |
| Disk | 25 GB free | 40 GB free |
| Nodes | 1 | 1 |

The one node runs the Kubernetes system components **and** your application Pods. Budget roughly 1 vCPU and 1.5–2 GB for the control plane, etcd, CoreDNS, kube-proxy, and Calico before your own workloads get anything.

Supported distributions for the commands below: **Ubuntu 22.04 / 24.04 LTS**, **Debian 12**. Other distros work but use different package managers.

**Check what you have:**

```bash
# Linux terminal
nproc
free -h
df -h /
. /etc/os-release && echo "$PRETTY_NAME"
uname -r
```

**Expected output** (example):

```text
4
               total        used        free
Mem:           7.6Gi       1.2Gi       5.9Gi
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p2  234G   68G  155G  31% /
Ubuntu 24.04.3 LTS
6.8.0-79-generic
```

✅ **Verify:** at least `2` from `nproc`, at least ~4 GB total memory, at least 25 GB available on `/`.

> [!WARNING]
> `kubeadm init` will **refuse to run** with fewer than 2 CPUs. It is a hard preflight check, not a warning.

---

## 2. Choose your Pod CIDR

**What:** the private IP range Kubernetes hands out to Pods.
**Why:** it must not overlap your real network, or Pod traffic will be routed to your LAN instead of inside the cluster.

Check your host's networks:

```bash
# Linux terminal
ip -4 addr show | grep inet
ip route | grep default
```

| If your LAN looks like… | Use this Pod CIDR |
|---|---|
| `192.168.x.x` (most home routers) | `10.244.0.0/16` |
| `10.x.x.x` | `192.168.0.0/16` |
| `172.16–31.x.x` | `192.168.0.0/16` |

The rest of this page uses **`192.168.0.0/16`** (Calico's default). If your LAN is `192.168.x.x`, substitute `10.244.0.0/16` **everywhere** — including the Calico step, which tells you the extra edit needed.

Set it once as a shell variable so you can copy-paste the rest:

```bash
# Linux terminal
export POD_NETWORK_CIDR=192.168.0.0/16    # or 10.244.0.0/16
echo "$POD_NETWORK_CIDR"
```

---

## 3. Prepare the host

### 3.1 Update packages

**What:** refresh the package index and apply pending updates.
**Why:** you are about to add a third-party apt repository; a stale index and old `ca-certificates` cause signature and TLS failures.

```bash
# Linux terminal (root)
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get install -y ca-certificates curl gnupg apt-transport-https
```

### 3.2 Set the hostname

**What:** give the machine a stable, DNS-safe name.
**Why:** the Kubernetes node object is named after the hostname, and it goes into TLS certificates. A hostname that changes later (or contains uppercase/underscores) breaks certificate validation and node registration.

```bash
# Linux terminal (root)
sudo hostnamectl set-hostname k8s-single
hostnamectl --static
```

**Expected output:**

```text
k8s-single
```

Rules: lowercase letters, digits, and hyphens only. No underscores, no uppercase.

### 3.3 Update `/etc/hosts`

**What:** map the hostname to a local address.
**Why:** several components resolve the node's own name. If it does not resolve, the kubelet logs DNS errors and startup is slow.

```bash
# Linux terminal (root)
echo "127.0.1.1 k8s-single" | sudo tee -a /etc/hosts
getent hosts k8s-single
```

**Expected output:**

```text
127.0.1.1       k8s-single
```

### 3.4 Disable swap

**What:** turn swap off, now and across reboots.
**Why:** the kubelet's memory accounting and eviction logic assume RAM is the real limit. With swap on, a Pod over its memory limit gets swapped instead of evicted, so the node silently degrades. The kubelet refuses to start with swap enabled unless you explicitly configure otherwise — and for a learning cluster you should not.

**Temporarily (takes effect immediately, lost on reboot):**

```bash
# Linux terminal (root)
sudo swapoff -a
```

**Permanently (survives reboot):**

```bash
# Linux terminal (root)
sudo sed -i.bak -E 's|^([^#].*\sswap\s.*)$|#\1|' /etc/fstab
```

Ubuntu 24.04 desktop installs often use `systemd-swap` or a `swapfile` unit instead of an `/etc/fstab` entry. Cover that too:

```bash
# Linux terminal (root)
# Only run if the unit exists — check first:
systemctl list-unit-files | grep -i swap
# If you see something like `swap.target` with an active swapfile service:
sudo systemctl mask "$(systemctl list-units --type swap --no-legend | awk '{print $1}')" 2>/dev/null || true
```

✅ **Verify:**

```bash
# Linux terminal
swapon --show
free -h | grep -i swap
```

**Expected output** — `swapon --show` prints **nothing**, and the Swap line is all zeros:

```text
Swap:            0B          0B          0B
```

> [!TIP]
> Reboot and re-run `swapon --show` before you trust the permanent change.

### 3.5 Load required kernel modules

**What:** load `overlay` and `br_netfilter`, and make them load at boot.
**Why:**
- `overlay` — containerd's default snapshotter uses OverlayFS to layer container filesystems.
- `br_netfilter` — makes traffic crossing a Linux bridge visible to `iptables`/`nftables`. Without it, kube-proxy's Service rules are simply never evaluated for Pod-to-Pod traffic, and Services silently fail.

```bash
# Linux terminal (root)
cat <<'EOF' | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter
```

✅ **Verify:**

```bash
lsmod | grep -E '^(overlay|br_netfilter)'
```

**Expected output** (numbers will differ):

```text
br_netfilter           32768  0
overlay               212992  0
```

### 3.6 Configure sysctl — IPv4 forwarding and bridge traffic

**What:** enable packet forwarding and bridge-to-netfilter handoff.
**Why:**
- `net.ipv4.ip_forward=1` — the node routes packets between Pod interfaces and the outside world. Off by default on most distros; without it Pods have no network at all.
- `net.bridge.bridge-nf-call-iptables=1` / `-ip6tables=1` — required so kube-proxy's Service NAT rules apply to bridged Pod traffic.

```bash
# Linux terminal (root)
cat <<'EOF' | sudo tee /etc/sysctl.d/99-kubernetes.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
```

✅ **Verify:**

```bash
sysctl net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables
```

**Expected output:**

```text
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
```

**Common error:** `sysctl: cannot stat /proc/sys/net/bridge/bridge-nf-call-iptables: No such file or directory` → `br_netfilter` is not loaded. Re-run `sudo modprobe br_netfilter`, then `sudo sysctl --system`.

### 3.7 Full host-prep verification

```bash
# Linux terminal
echo "--- hostname ---";  hostnamectl --static
echo "--- swap ---";      swapon --show || echo "swap: none (correct)"
echo "--- modules ---";   lsmod | grep -E '^(overlay|br_netfilter)'
echo "--- sysctl ---";    sysctl -n net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables
echo "--- cpu/mem ---";   nproc; free -h | head -2
```

Do not continue until every line looks right.

---

## 4. Install containerd

### 4.1 Why containerd, not Docker

Kubernetes talks to a container runtime over the **CRI** (Container Runtime Interface). containerd implements CRI natively via a built-in plugin. Docker Engine does not speak CRI — support for it was removed from the kubelet in Kubernetes 1.24, and using Docker now requires an extra shim (`cri-dockerd`). Fewer moving parts is better, so this guide installs containerd directly.

You can still build images with Docker on another machine; the image format is identical.

### 4.2 Install

Ubuntu's own `containerd` package is often older and, on some releases, ships with the CRI plugin disabled. Use Docker's apt repository, which provides a current `containerd.io` package with CRI enabled.

```bash
# Linux terminal (root)
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
```

> **Debian users:** replace both occurrences of `ubuntu` with `debian` in the two URLs above.

✅ **Verify installation:**

```bash
containerd --version
```

**Expected output** (version will differ):

```text
containerd containerd.io 2.3.3 <commit-sha>
```

### 4.3 Create the configuration file

**What:** generate containerd's default config.
**Why:** the shipped `/etc/containerd/config.toml` is a stub with almost everything disabled. Generating the default expands every setting so you can edit the ones that matter.

```bash
# Linux terminal (root)
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
```

### 4.4 Enable `SystemdCgroup`

**What:** tell containerd's runc runtime to use the systemd cgroup driver.
**Why:** on a systemd host, systemd is the single writer of the cgroup hierarchy. The kubelet defaults to the `systemd` driver. If containerd uses the other driver (`cgroupfs`), you get two writers, duplicated cgroups, wrong resource accounting, and Pods that crash-loop or get killed unpredictably. **They must match.**

```bash
# Linux terminal (root)
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
```

✅ **Verify:**

```bash
grep -n 'SystemdCgroup' /etc/containerd/config.toml
```

**Expected output:**

```text
<line>:            SystemdCgroup = true
```

If `grep` finds nothing, your containerd version uses a newer config schema. Check the version line and the runc options block:

```bash
grep -n -E 'version = |io.containerd.cri|runc.options' /etc/containerd/config.toml | head
```

For **containerd 2.x** (config `version = 3`) the setting lives under
`[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]`. Confirm with the query in §4.7 rather than guessing.

### 4.5 Ensure the CRI plugin is enabled

**What:** make sure `cri` is not in containerd's disabled-plugins list.
**Why:** Docker's package historically shipped a config with `disabled_plugins = ["cri"]`. With CRI disabled the kubelet cannot talk to containerd at all, and `kubeadm init` fails at preflight.

```bash
# Linux terminal (root)
grep -n 'disabled_plugins' /etc/containerd/config.toml
```

**Expected output:**

```text
<line>:disabled_plugins = []
```

If it reads `disabled_plugins = ["cri"]`, fix it:

```bash
# Linux terminal (root)
sudo sed -i 's/disabled_plugins = \["cri"\]/disabled_plugins = []/' /etc/containerd/config.toml
```

### 4.6 Restart and enable at boot

```bash
# Linux terminal (root)
sudo systemctl restart containerd
sudo systemctl enable containerd
```

### 4.7 Verify the runtime

```bash
# Linux terminal
systemctl is-active containerd
systemctl is-enabled containerd
ls -l /run/containerd/containerd.sock
sudo ctr version
```

**Expected output:**

```text
active
enabled
srw-rw---- 1 root root 0 Aug  5 10:12 /run/containerd/containerd.sock
Client:
  Version:  2.3.3
  ...
Server:
  Version:  2.3.3
```

**Confirm the CRI plugin is actually running and using systemd cgroups:**

```bash
# Linux terminal (root)
sudo ctr plugin ls | grep -E 'cri|NAME'
```

`STATUS` must be `ok` for the CRI plugin rows.

**Inspect logs if anything is wrong:**

```bash
# Linux terminal (root)
sudo journalctl -u containerd -n 50 --no-pager
```

**Common errors:**

| Symptom | Cause | Fix |
|---|---|---|
| `Job for containerd.service failed` | TOML syntax error from a bad `sed` | `sudo containerd config default \| sudo tee /etc/containerd/config.toml` and redo §4.4 |
| Socket file missing | Service not started | `sudo systemctl restart containerd`, then check `journalctl` |
| CRI plugin `STATUS: error` | Plugin disabled or misconfigured | Redo §4.5, restart |

---

## 5. Install kubeadm, kubelet, kubectl

### 5.1 What each one is

| Component | Role |
|---|---|
| **kubeadm** | The bootstrapper. Runs once (`init`) to generate certificates, write static Pod manifests, and start the control plane. Not a running service. |
| **kubelet** | The node agent. A systemd service running permanently on every node. Talks to containerd via CRI and to the API server. It is the only Kubernetes component that is a normal daemon. |
| **kubectl** | The CLI you use to talk to the API server. Not required on the node, but you want it here. |

### 5.2 Choose the Kubernetes version

The `pkgs.k8s.io` repository is **versioned per minor release**. The repository URL contains the minor version, so you choose the version by choosing the repository.

```bash
# Linux terminal
export KUBERNETES_VERSION=v1.36     # note the leading "v", minor version only
echo "$KUBERNETES_VERSION"
```

Check what is current at <https://kubernetes.io/releases/>. Upgrading later means editing this repository file to the next minor version — you cannot skip minor versions.

### 5.3 Configure the package repository

> [!WARNING]
> 🔴 **Do not use `apt.kubernetes.io` or `packages.cloud.google.com/apt`.** Those repositories are retired and no longer served. Tutorials that still reference them fail with `404` or `NO_PUBKEY`.

```bash
# Linux terminal (root)
sudo mkdir -p /etc/apt/keyrings

curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/Release.key" \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
sudo chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo chmod 644 /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
```

### 5.4 Install

```bash
# Linux terminal (root)
sudo apt-get install -y kubelet kubeadm kubectl
```

### 5.5 Hold the packages

**What:** pin the three packages so `apt upgrade` cannot move them.
**Why:** Kubernetes upgrades are a deliberate, ordered procedure (`kubeadm upgrade` first, then kubelet). An unattended-upgrade that bumps the kubelet under a running control plane breaks the cluster.

```bash
# Linux terminal (root)
sudo apt-mark hold kubelet kubeadm kubectl
```

**Expected output:**

```text
kubelet set on hold.
kubeadm set on hold.
kubectl set on hold.
```

### 5.6 Enable the kubelet

```bash
# Linux terminal (root)
sudo systemctl enable --now kubelet
```

> [!NOTE]
> The kubelet will now **crash-loop every few seconds** and that is expected. It has no configuration until `kubeadm init` writes `/var/lib/kubelet/config.yaml`. `systemctl status kubelet` showing `activating (auto-restart)` at this point is normal. It settles during `kubeadm init`.

### 5.7 Verify versions

```bash
# Linux terminal
kubeadm version -o short
kubelet --version
kubectl version --client
```

**Expected output:**

```text
v1.36.1
Kubernetes v1.36.1
Client Version: v1.36.1
Kustomize Version: v5.x.x
```

### 5.8 Version-skew rules

- `kubelet` must not be **newer** than `kube-apiserver`. It may be up to **three** minor versions older (Kubernetes 1.28+).
- `kubectl` may be one minor version above or below the API server.
- `kubeadm` must match or be one minor above the control plane it upgrades.

On a single-node cluster where everything is installed together this is automatic. It matters when you upgrade.

---

## 6. Initialize the cluster

### 6.1 Determine the node IP

**What:** pick the IP the API server advertises to clients.
**Why:** on a machine with several interfaces (Wi-Fi, Ethernet, Docker bridges, VPN) `kubeadm` may auto-select the wrong one and bake it into the certificates. Be explicit.

```bash
# Linux terminal
ip route get 1.1.1.1 | awk '{print $7; exit}'
```

**Expected output** (example):

```text
192.168.1.42
```

Save it:

```bash
# Linux terminal
export NODE_IP=$(ip route get 1.1.1.1 | awk '{print $7; exit}')
echo "NODE_IP=$NODE_IP  POD_NETWORK_CIDR=$POD_NETWORK_CIDR"
```

> [!WARNING]
> If your `NODE_IP` falls **inside** your chosen `POD_NETWORK_CIDR`, stop and change the Pod CIDR (§2). Overlapping ranges produce a cluster that appears to start and then fails all networking.

### 6.2 Run `kubeadm init`

**What each flag does:**

| Flag | Meaning |
|---|---|
| `--apiserver-advertise-address` | The IP the API server listens on and publishes in kubeconfig and certificates. |
| `--pod-network-cidr` | The range assigned to Pods. Passed to the controller-manager and read by the CNI. |
| `--cri-socket` | Which runtime socket the kubelet uses. Explicit avoids ambiguity if Docker is also installed. |
| `--kubernetes-version` | Pins the control-plane image versions. Omit to let kubeadm choose the latest matching its own version. |
| `--node-name` | The name of the Node object. Defaults to the hostname. |

```bash
# Linux terminal (root)
sudo kubeadm init \
  --apiserver-advertise-address="${NODE_IP}" \
  --pod-network-cidr="${POD_NETWORK_CIDR}" \
  --cri-socket="unix:///run/containerd/containerd.sock" \
  --node-name="k8s-single"
```

Generic form with placeholders:

```bash
sudo kubeadm init \
  --apiserver-advertise-address=<NODE_IP> \
  --pod-network-cidr=<POD_NETWORK_CIDR> \
  --cri-socket=unix:///run/containerd/containerd.sock \
  --kubernetes-version=<KUBERNETES_VERSION>
```

This takes 2–6 minutes on first run (it pulls control-plane images).

**Expected output** (tail):

```text
Your Kubernetes control-plane has initialized successfully!

To start using your cluster, you need to run the following as a regular user:

  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config
...
Then you can join any number of worker nodes by running the following on each as root:

kubeadm join 192.168.1.42:6443 --token abcdef.0123456789abcdef \
        --discovery-token-ca-cert-hash sha256:1234...
```

> [!NOTE]
> **Ignore the `kubeadm join` command.** This is a single-node cluster; there is no second machine. The token expires in 24 hours and that is fine.

### 6.3 What `kubeadm init` just created

| Path | Contents |
|---|---|
| `/etc/kubernetes/pki/` | CA and all component certificates and keys (etcd CA, API server cert, service-account keys) |
| `/etc/kubernetes/manifests/` | Static Pod manifests: `kube-apiserver.yaml`, `etcd.yaml`, `kube-scheduler.yaml`, `kube-controller-manager.yaml`. The kubelet watches this directory and runs whatever is in it — that is how the control plane starts without a control plane. |
| `/etc/kubernetes/admin.conf` | Admin kubeconfig — cluster-admin credentials |
| `/etc/kubernetes/kubelet.conf` | The kubelet's own kubeconfig |
| `/var/lib/kubelet/config.yaml` | Kubelet configuration, including `cgroupDriver: systemd` |
| `/var/lib/etcd/` | The etcd data directory — **all** your cluster state |

**Certificates** are generated by kubeadm with a 1-year validity for component certs and 10 years for the CA. `sudo kubeadm certs check-expiration` shows them.

---

## 7. Configure kubectl for your regular user

**What:** copy the admin kubeconfig into your home directory.
**Why:** `/etc/kubernetes/admin.conf` is root-only. Copying it (rather than symlinking or using `sudo kubectl`) lets you run `kubectl` as yourself and keeps helm/other tools working.

```bash
# Linux terminal (your normal user, NOT root)
mkdir -p "$HOME/.kube"
sudo cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"
```

✅ **Verify:**

```bash
kubectl cluster-info
kubectl get nodes
```

**Expected output:**

```text
Kubernetes control plane is running at https://192.168.1.42:6443
CoreDNS is running at https://192.168.1.42:6443/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy

NAME          STATUS     ROLES           AGE   VERSION
k8s-single    NotReady   control-plane   45s   v1.36.1
```

> [!IMPORTANT]
> **`NotReady` is correct at this point.** There is no CNI yet. Continue to §8.

> [!WARNING]
> 🔴 This kubeconfig contains **cluster-admin credentials**. Do not commit it to git, paste it in chat, or copy it to a shared machine.

---

## 8. Install the CNI plugin (Calico)

### 8.1 Why the node is `NotReady`

The kubelet reports `Ready` only when its network plugin is initialized. Until a CNI is installed there is no `/etc/cni/net.d/` configuration, so the kubelet sets the condition `NetworkReady=false` with reason `NetworkPluginNotReady`. Non-host-network Pods (CoreDNS) stay `Pending` for the same reason.

See it for yourself:

```bash
kubectl describe node k8s-single | grep -A5 Conditions
kubectl get pods -n kube-system
```

CoreDNS will be `Pending`. Everything else (`etcd`, `kube-apiserver`, `kube-controller-manager`, `kube-scheduler`, `kube-proxy`) is `Running` because it uses host networking.

### 8.2 Install Calico

Calico is the primary CNI for this guide: mature, widely used in production, good NetworkPolicy support, and it reads the Pod CIDR that `kubeadm` already configured.

```bash
# Linux terminal
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.32.1/manifests/calico.yaml
```

**Expected output** (abbreviated):

```text
poddisruptionbudget.policy/calico-kube-controllers created
serviceaccount/calico-kube-controllers created
serviceaccount/calico-node created
configmap/calico-config created
customresourcedefinition.apiextensions.k8s.io/... created
daemonset.apps/calico-node created
deployment.apps/calico-kube-controllers created
```

**If you chose `10.244.0.0/16`:** Calico's manifest auto-detects the Pod CIDR from the kubeadm-configured cluster CIDR, so no edit is normally needed. If Pods come up with the wrong addresses, download the manifest, uncomment the `CALICO_IPV4POOL_CIDR` environment variable in the `calico-node` DaemonSet and set it to your CIDR, then apply the edited file:

```bash
# Linux terminal
curl -fsSLO https://raw.githubusercontent.com/projectcalico/calico/v3.32.1/manifests/calico.yaml
# edit calico.yaml: uncomment CALICO_IPV4POOL_CIDR and set value: "10.244.0.0/16"
kubectl apply -f calico.yaml
```

### 8.3 Wait for Calico

```bash
# Linux terminal
kubectl -n kube-system rollout status daemonset/calico-node --timeout=300s
kubectl -n kube-system get pods -w
```

Press `Ctrl+C` when everything is `Running`. First run takes 1–3 minutes (image pulls).

✅ **Verify:**

```bash
kubectl get nodes
kubectl get pods -n kube-system
```

**Expected output:**

```text
NAME          STATUS   ROLES           AGE   VERSION
k8s-single    Ready    control-plane   4m    v1.36.1

NAME                                       READY   STATUS    RESTARTS   AGE
calico-kube-controllers-...                1/1     Running   0          2m
calico-node-...                            1/1     Running   0          2m
coredns-...                                1/1     Running   0          4m
coredns-...                                1/1     Running   0          4m
etcd-k8s-single                            1/1     Running   0          4m
kube-apiserver-k8s-single                  1/1     Running   0          4m
kube-controller-manager-k8s-single         1/1     Running   0          4m
kube-proxy-...                             1/1     Running   0          4m
kube-scheduler-k8s-single                  1/1     Running   0          4m
```

The node is now **`Ready`**.

### 8.4 Alternatives

| CNI | Install | Notes |
|---|---|---|
| **Cilium** | `cilium install --version 1.20.0` (needs the `cilium` CLI) | eBPF-based, can replace kube-proxy, excellent observability. Heavier; needs a recent kernel (5.10+). |
| **Flannel** | `kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml` | Simplest and lightest, but **hard-codes `10.244.0.0/16`** — you must use that Pod CIDR. No NetworkPolicy support. |

Install **exactly one**. Installing two produces a cluster with broken, non-obviously-broken networking.

---

## 9. Remove the control-plane taint

### 9.1 What a taint is

A **taint** on a Node repels Pods. A Pod may only land on a tainted node if it carries a matching **toleration**. `kubeadm` applies:

```text
node-role.kubernetes.io/control-plane:NoSchedule
```

**Why it exists:** on a real cluster, the control-plane node runs etcd and the API server. If a runaway application Pod exhausted its CPU or memory, it would take down the API server and the whole cluster with it. The taint isolates the control plane from ordinary workloads.

**Why you must remove it here:** this cluster has exactly one node. With the taint in place your application Pods have nowhere to go and stay `Pending` forever.

See it first:

```bash
# Linux terminal
kubectl describe node k8s-single | grep -i -A2 taints
```

**Expected output:**

```text
Taints:             node-role.kubernetes.io/control-plane:NoSchedule
```

### 9.2 Remove it

The trailing `-` means "remove this taint".

```bash
# Linux terminal
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

**Expected output:**

```text
node/k8s-single untainted
```

✅ **Verify:**

```bash
kubectl describe node k8s-single | grep -i -A2 taints
```

**Expected output:**

```text
Taints:             <none>
```

> [!WARNING]
> **Never do this on a production cluster.** It is correct only because this is a single-node learning cluster. In production you add worker nodes instead. To put the taint back: `kubectl taint nodes k8s-single node-role.kubernetes.io/control-plane=:NoSchedule`

### 9.3 Confirm Pods can now schedule

```bash
# Linux terminal
kubectl run scheduling-test --image=nginx:1.30-alpine --restart=Never
kubectl wait --for=condition=Ready pod/scheduling-test --timeout=120s
kubectl get pod scheduling-test -o wide
kubectl delete pod scheduling-test
```

**Expected output:**

```text
pod/scheduling-test created
pod/scheduling-test condition met
NAME              READY   STATUS    RESTARTS   AGE   IP               NODE
scheduling-test   1/1     Running   0          20s   192.168.109.65   k8s-single
pod "scheduling-test" deleted
```

The Pod IP comes from your Pod CIDR. That confirms the CNI is doing its job.

---

## 10. Verify the cluster

Run the whole block. Every check should pass.

```bash
# Linux terminal

# --- Node status, roles, IP ---
kubectl get nodes -o wide

# --- Control-plane pods ---
kubectl get pods -n kube-system -o wide

# --- CoreDNS ---
kubectl get deployment coredns -n kube-system
kubectl get svc kube-dns -n kube-system

# --- CNI ---
kubectl get daemonset calico-node -n kube-system

# --- Host services ---
systemctl is-active kubelet containerd

# --- Cluster info ---
kubectl cluster-info

# --- Raw API access ---
kubectl get --raw='/readyz?verbose' | tail -5

# --- Component health ---
kubectl get --raw='/livez?verbose' | grep -E 'etcd|apiserver|ok$'
```

**Expected node output:**

```text
NAME         STATUS   ROLES           AGE   VERSION   INTERNAL-IP     OS-IMAGE             CONTAINER-RUNTIME
k8s-single   Ready    control-plane   8m    v1.36.1   192.168.1.42    Ubuntu 24.04.3 LTS   containerd://2.3.3
```

```text
One node
Status: Ready
Roles: control-plane
```

### Pod networking test

```bash
# Linux terminal
kubectl run net-a --image=nginx:1.30-alpine
kubectl run net-b --image=busybox:1.37 --restart=Never --command -- sleep 3600
kubectl wait --for=condition=Ready pod/net-a pod/net-b --timeout=120s

POD_A_IP=$(kubectl get pod net-a -o jsonpath='{.status.podIP}')
kubectl exec net-b -- wget -qO- --timeout=5 "http://${POD_A_IP}" | head -4
```

**Expected output:** the nginx welcome HTML.

### DNS resolution test

```bash
# Linux terminal
kubectl expose pod net-a --name=net-a-svc --port=80
kubectl exec net-b -- nslookup net-a-svc.default.svc.cluster.local
kubectl exec net-b -- wget -qO- --timeout=5 http://net-a-svc | head -4
```

**Expected output:**

```text
Server:    10.96.0.10
Address:   10.96.0.10:53

Name:      net-a-svc.default.svc.cluster.local
Address:   10.96.44.201
```

Clean up the test resources:

```bash
kubectl delete pod net-a net-b
kubectl delete svc net-a-svc
```

✅ **Checkpoint — you have a working single-node Kubernetes cluster.**

---

## 11. Deploy the sample application

Manifests are in [`manifests/`](./manifests/). Read them — every field is commented.

```bash
# Linux terminal
cd kubernetes-cluster-setup/kubeadm
kubectl apply -f manifests/
```

**Expected output:**

```text
namespace/demo created
deployment.apps/web created
service/web created
service/web-nodeport created
```

**Wait and verify:**

```bash
# Linux terminal
kubectl -n demo rollout status deployment/web --timeout=180s
kubectl -n demo get all -o wide
```

**Expected output:**

```text
NAME                       READY   STATUS    RESTARTS   AGE   IP                NODE
pod/web-6c9d8f7b4-abcde    1/1     Running   0          40s   192.168.109.66    k8s-single
pod/web-6c9d8f7b4-fghij    1/1     Running   0          40s   192.168.109.67    k8s-single

NAME                   TYPE        CLUSTER-IP      PORT(S)        AGE
service/web            ClusterIP   10.96.171.22    80/TCP         40s
service/web-nodeport   NodePort    10.96.203.114   80:30080/TCP   40s

NAME                  READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/web   2/2     2            2           40s
```

### Both replicas are on the same node — is that wrong?

No. A Deployment's `replicas: 2` means "two Pods", not "two machines". The scheduler places them wherever there is capacity, and on a one-node cluster that is the same node. You get genuine ReplicaSet behaviour — rolling updates, self-healing, load-balanced Service endpoints — but **no** protection against node failure, because there is only one node.

Prove self-healing:

```bash
kubectl -n demo delete pod -l app.kubernetes.io/name=web --wait=false
kubectl -n demo get pods -w        # Ctrl+C when both are Running again
```

The ReplicaSet immediately recreates them.

---

## 12. Access the application

### Method 1 — `kubectl port-forward` (always works)

```bash
# Linux terminal
kubectl -n demo port-forward svc/web 8080:80
```

Leave it running, then in a **second terminal**:

```bash
# Linux terminal
curl -s http://localhost:8080 | head -5
```

**Expected output:** the nginx welcome page HTML.

Stop with `Ctrl+C`. This tunnels through the API server — no firewall rules, no NodePort, no exposure beyond `localhost`.

### Method 2 — NodePort

```bash
# Linux terminal
NODE_IP=$(kubectl get node k8s-single -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
curl -s "http://${NODE_IP}:30080" | head -5
curl -s "http://localhost:30080" | head -5
```

Both work on native Linux — the node is your own machine. Other devices on your LAN can also reach `http://<NODE_IP>:30080` unless your host firewall blocks it. If `ufw` is active:

```bash
# Linux terminal (root)
sudo ufw status
sudo ufw allow 30080/tcp        # only if you want LAN access
```

### Method 3 — ClusterIP from inside the cluster

```bash
# Linux terminal
kubectl -n demo run curltest --image=busybox:1.37 --rm -it --restart=Never -- \
  wget -qO- --timeout=5 http://web.demo.svc.cluster.local
```

### Method comparison

| Method | Reachable from | Needs firewall change | Use when |
|---|---|---|---|
| `port-forward` | The machine running the command | No | Default; safest |
| NodePort | Anything that can reach the node IP | Yes, if a host firewall is on | Sharing with other devices on your LAN |
| ClusterIP | Inside the cluster only | No | Service-to-service traffic |

---

## 13. Troubleshooting

Full matrix in **[troubleshooting.md](./troubleshooting.md)**. The five you are most likely to hit on native Linux:

| Symptom | Cause | Diagnose | Fix |
|---|---|---|---|
| `kubeadm init` fails: `[ERROR NumCPU]` | Fewer than 2 CPUs | `nproc` | Add CPUs. Do not use `--ignore-preflight-errors` — the cluster will be unusably slow. |
| `kubeadm init` fails: `[ERROR Swap]` | Swap still on | `swapon --show` | `sudo swapoff -a`, then redo §3.4 |
| Node stuck `NotReady` | No CNI installed | `kubectl describe node \| grep NetworkReady` | Install Calico (§8) |
| kubelet crash-loops after init | cgroup driver mismatch | `sudo journalctl -u kubelet -n 50` | Set `SystemdCgroup = true` (§4.4), `sudo systemctl restart containerd kubelet` |
| Pods stuck `Pending` | Control-plane taint still present | `kubectl describe pod <name> \| tail -5` | `kubectl taint nodes --all node-role.kubernetes.io/control-plane-` |

**Universal diagnostic commands:**

```bash
# Linux terminal
sudo journalctl -u kubelet -n 100 --no-pager       # kubelet log
sudo journalctl -u containerd -n 100 --no-pager    # runtime log
kubectl get events -A --sort-by=.lastTimestamp | tail -30
kubectl describe pod <POD_NAME> -n <NAMESPACE>
sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps -a
```

---

## 14. Reset and cleanup

### 14.1 Delete just the application (keep the cluster)

```bash
# Linux terminal
kubectl delete namespace demo
```

**Expected output:** `namespace "demo" deleted` — this removes the Deployment, both Services, and every Pod in it.

### 14.2 Full cluster reset

> [!CAUTION]
> 🔴 **DESTRUCTIVE.** Everything below permanently destroys the cluster, including all etcd data. There is no undo. It does **not** touch anything outside Kubernetes.

**Step 1 — remove workloads (optional but tidy):**

```bash
# Linux terminal
kubectl delete namespace demo --ignore-not-found
```

**Step 2 — reset kubeadm:**

```bash
# Linux terminal (root)  🔴 DESTRUCTIVE
sudo kubeadm reset -f --cri-socket=unix:///run/containerd/containerd.sock
```

This stops the kubelet, removes static Pod manifests, wipes `/etc/kubernetes/`, and deletes `/var/lib/etcd/`. It prints a reminder that it does not clean up CNI config or iptables rules — that is the next step.

**Step 3 — remove CNI files:**

```bash
# Linux terminal (root)  🔴 DESTRUCTIVE
sudo rm -rf /etc/cni/net.d
sudo rm -rf /var/lib/cni/
sudo rm -rf /opt/cni/bin/calico*
```

**Step 4 — remove kubeconfig:**

```bash
# Linux terminal  🔴 DESTRUCTIVE
rm -rf "$HOME/.kube"
```

**Step 5 — remove Kubernetes network interfaces:**

```bash
# Linux terminal (root)
ip link show | grep -E 'cali|tunl|vxlan|cni0|flannel'
```

For each interface listed:

```bash
# Linux terminal (root)  🔴 DESTRUCTIVE
sudo ip link delete <INTERFACE_NAME>
```

Typically `tunl0`, `cni0`, and several `cali*` interfaces. Deleting a `cali*` interface that no longer has a Pod behind it is harmless.

**Step 6 — clean networking rules (careful):**

> [!CAUTION]
> 🔴 The commands below flush firewall rules. On a laptop with a VPN, Docker, or `ufw` in use they will disrupt **those** too. Review before running. `iptables -F` alone will not remove kube-proxy's NAT rules — you need the `nat` and `mangle` tables as well.

```bash
# Linux terminal (root)  🔴 DESTRUCTIVE — review first
sudo iptables-save | grep -E 'KUBE-|CALI-' | head        # see what exists

sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X
sudo ipvsadm --clear 2>/dev/null || true                  # only if IPVS mode was used
```

Safest alternative: **reboot**. Kubernetes rules are not persisted across reboots unless something like `iptables-persistent` saved them.

**Step 7 — restart containerd:**

```bash
# Linux terminal (root)
sudo systemctl restart containerd
sudo systemctl status containerd --no-pager | head -5
```

Optionally remove leftover containers and images:

```bash
# Linux terminal (root)  🔴 DESTRUCTIVE
sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock rmp -a -f 2>/dev/null || true
sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock rmi --prune
```

### 14.3 Recreate the cluster

The host prep, containerd, and packages are all still in place. Just re-run init:

```bash
# Linux terminal (root)
export NODE_IP=$(ip route get 1.1.1.1 | awk '{print $7; exit}')
export POD_NETWORK_CIDR=192.168.0.0/16

sudo swapoff -a
sudo kubeadm init \
  --apiserver-advertise-address="${NODE_IP}" \
  --pod-network-cidr="${POD_NETWORK_CIDR}" \
  --cri-socket="unix:///run/containerd/containerd.sock"

mkdir -p "$HOME/.kube"
sudo cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.32.1/manifests/calico.yaml
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

### 14.4 Remove Kubernetes packages entirely (optional)

```bash
# Linux terminal (root)  🔴 DESTRUCTIVE
sudo apt-mark unhold kubelet kubeadm kubectl
sudo apt-get purge -y kubelet kubeadm kubectl kubernetes-cni
sudo apt-get autoremove -y
sudo rm -rf /var/lib/kubelet /etc/kubernetes /var/lib/etcd
sudo rm -f /etc/apt/sources.list.d/kubernetes.list
sudo rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
```

Leave containerd installed unless you also want it gone:

```bash
# Linux terminal (root)  🔴 DESTRUCTIVE
sudo apt-get purge -y containerd.io
sudo rm -rf /var/lib/containerd /etc/containerd
```

---

## Official documentation

- Installing kubeadm — <https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/>
- Creating a cluster with kubeadm — <https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/>
- Container runtimes / cgroup drivers — <https://kubernetes.io/docs/setup/production-environment/container-runtimes/>
- `kubeadm init` reference — <https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-init/>
- `kubeadm reset` reference — <https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-reset/>
- Calico quickstart — <https://docs.tigera.io/calico/latest/getting-started/kubernetes/quickstart>
- Taints and tolerations — <https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/>
