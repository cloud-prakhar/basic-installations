# kubeadm — Single-Node Cluster in One Ubuntu VM on macOS

Build a one-node Kubernetes cluster inside **one** Ubuntu virtual machine running on your Mac. The VM is control plane **and** worker.

> [!IMPORTANT]
> **kubeadm cannot run on native macOS.** macOS has no Linux cgroups, no systemd, and no Linux netfilter. `kubeadm` configures all three. The only way to practise kubeadm on a Mac is inside a Linux VM.
>
> If you just want a working local cluster, **[Minikube](../minikube/macos.md)** or **[Kind](../kind/macos.md)** is far simpler on macOS. Use this page only if you specifically want to learn how Kubernetes bootstraps itself.

**One VM only.** This is not a multi-VM lab.

Commands are marked:

- `# macOS Terminal` — on your Mac
- `# Ubuntu VM` — inside the VM (after `multipass shell` or `ssh`)

Validated **2026-08-05** on macOS 15 (Apple Silicon and Intel), Multipass, Ubuntu 24.04 LTS, Kubernetes **1.36**, containerd **2.3.x**, Calico **v3.32.1**. Time: 30–45 minutes.

---

## Contents

1. [Requirements](#1-requirements)
2. [Choose a VM tool](#2-choose-a-vm-tool)
3. [Create the Ubuntu VM](#3-create-the-ubuntu-vm)
4. [Connect to the VM](#4-connect-to-the-vm)
5. [Prepare the host](#5-prepare-the-host-inside-the-vm)
6. [Install containerd](#6-install-containerd)
7. [Install kubeadm, kubelet, kubectl](#7-install-kubeadm-kubelet-kubectl)
8. [Initialize the cluster](#8-initialize-the-cluster)
9. [Configure kubectl](#9-configure-kubectl-for-your-regular-user)
10. [Install the CNI plugin](#10-install-the-cni-plugin-calico)
11. [Remove the control-plane taint](#11-remove-the-control-plane-taint)
12. [Verify the cluster](#12-verify-the-cluster)
13. [Deploy the sample application](#13-deploy-the-sample-application)
14. [Access the application from macOS](#14-access-the-application-from-macos)
15. [Troubleshooting](#15-troubleshooting)
16. [Reset and cleanup](#16-reset-and-cleanup)

---

## 1. Requirements

| Resource | Minimum (give to the VM) | Recommended |
|----------|--------:|------------:|
| CPU | 2 cores | 4 cores |
| Memory | 4 GB | 6–8 GB |
| Disk | 25 GB | 40 GB |
| Nodes | 1 | 1 |

Your Mac needs those resources **on top of** what macOS uses. A 16 GB Mac is comfortable; an 8 GB Mac can run the 4 GB minimum but will feel slow.

The single node runs the Kubernetes system components **and** your workloads — budget ~1 vCPU and 1.5–2 GB for the control plane, etcd, CoreDNS, kube-proxy, and Calico before your own Pods.

**Check your Mac:**

```bash
# macOS Terminal
sysctl -n hw.ncpu
sysctl -n hw.memsize | awk '{print $1/1024/1024/1024 " GB"}'
df -h / | tail -1
uname -m          # arm64 = Apple Silicon, x86_64 = Intel
```

> [!NOTE]
> On **Apple Silicon** your VM is `arm64`. Everything in this guide is arm64-native: the Kubernetes packages, containerd, Calico, and the `nginx:1.30-alpine` sample image all publish arm64 builds. You only hit trouble with third-party images that are amd64-only.

---

## 2. Choose a VM tool

| Tool | Cost | Apple Silicon | Best for | Notes |
|---|---|---|---|---|
| **Multipass** ⭐ | Free | ✅ Native | This guide | Canonical's Ubuntu VM tool. One command to a running Ubuntu. Handles networking and SSH automatically. **Recommended.** |
| **UTM** | Free | ✅ Native | GUI users | QEMU front-end. Good if you want a desktop VM window. More manual setup. |
| **VMware Fusion** | Free for personal use | ✅ Native | People already using it | Mature, good performance, GUI. |
| **Parallels Desktop** | Paid | ✅ Native | Best performance/UX | Fastest and smoothest, but a paid licence. |
| **VirtualBox** | Free | ⚠️ Intel only (arm64 builds are developer previews) | Intel Macs | Do not use on Apple Silicon for real work. |

**This page uses Multipass.** If you prefer another tool, create an Ubuntu 24.04 VM with the resources from §1, make sure you can SSH into it, then jump to §5 — everything from there is identical.

### Install Multipass

```bash
# macOS Terminal
brew install --cask multipass
multipass version
```

Without Homebrew, download the installer from <https://multipass.run/install>.

**Expected output:**

```text
multipass   1.16.0+mac
multipassd  1.16.0+mac
```

---

## 3. Create the Ubuntu VM

**What:** launch one Ubuntu 24.04 VM with dedicated CPU, memory, and disk.
**Why:** `kubeadm init` hard-fails with fewer than 2 CPUs, and the control plane alone needs ~2 GB.

```bash
# macOS Terminal
multipass launch 24.04 \
  --name k8s-single \
  --cpus 4 \
  --memory 6G \
  --disk 40G
```

| Flag | Meaning |
|---|---|
| `24.04` | Ubuntu 24.04 LTS image |
| `--name k8s-single` | VM name; also becomes the hostname and hence the Kubernetes node name |
| `--cpus 4` | 2 is the hard minimum |
| `--memory 6G` | 4G is the hard minimum |
| `--disk 40G` | 25G minimum; images and etcd grow |

First launch downloads the image (~600 MB), so it takes a few minutes.

✅ **Verify:**

```bash
# macOS Terminal
multipass list
multipass info k8s-single
```

**Expected output:**

```text
Name          State      IPv4             Image
k8s-single    Running    192.168.64.12    Ubuntu 24.04 LTS
```

### Networking notes

Multipass gives the VM an address on a **host-only / NAT network** (`192.168.64.x` on macOS). What that means:

- ✅ Your Mac can reach the VM directly at that IP — no port forwarding needed.
- ✅ The VM can reach the internet.
- ❌ Other devices on your LAN **cannot** reach the VM. That is fine and safer for a lab.
- ⚠️ The VM IP can change if you delete and recreate the VM. It is stable across stop/start.

> [!IMPORTANT]
> Multipass uses `192.168.64.x`. That collides with Calico's default Pod CIDR of `192.168.0.0/16`. **This page therefore uses `10.244.0.0/16` as the Pod CIDR.** Do not change it back.

If you use **VMware Fusion, Parallels, UTM, or VirtualBox** instead:

- **NAT networking** (default) — VM reaches the internet; to reach the VM from macOS you configure **port forwarding** (map macOS `:8080` → VM `:30080`) or use SSH port forwarding (§14).
- **Bridged networking** — the VM gets an IP on your real LAN, directly reachable from macOS and other devices. Simpler for access, but exposes the VM to your network. Check what your LAN subnet is and pick a non-overlapping Pod CIDR.

---

## 4. Connect to the VM

```bash
# macOS Terminal
multipass shell k8s-single
```

Your prompt changes to `ubuntu@k8s-single:~$`. **Everything from §5 to §13 runs inside the VM.**

To exit back to macOS: `exit`.

### Optional — plain SSH access

Handy for SSH port forwarding later (§14).

```bash
# macOS Terminal
# 1. Create a key if you do not have one
ls ~/.ssh/id_ed25519.pub || ssh-keygen -t ed25519 -C "k8s-lab"

# 2. Install it in the VM
multipass exec k8s-single -- bash -c \
  "mkdir -p ~/.ssh && echo '$(cat ~/.ssh/id_ed25519.pub)' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"

# 3. Get the IP and connect
VM_IP=$(multipass info k8s-single --format json | python3 -c 'import sys,json; print(json.load(sys.stdin)["info"]["k8s-single"]["ipv4"][0])')
echo "VM_IP=$VM_IP"
ssh ubuntu@"$VM_IP"
```

✅ **Verify:** you get an `ubuntu@k8s-single` prompt without a password.

---

## 5. Prepare the host (inside the VM)

### 5.1 Update packages

```bash
# Ubuntu VM (root)
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get install -y ca-certificates curl gnupg apt-transport-https
```

### 5.2 Hostname and `/etc/hosts`

**Why:** the Kubernetes node object is named after the hostname and that name is baked into TLS certificates. It must be lowercase, stable, and resolvable.

Multipass already set the hostname to `k8s-single`. Confirm and add the hosts entry:

```bash
# Ubuntu VM (root)
hostnamectl --static
echo "127.0.1.1 k8s-single" | sudo tee -a /etc/hosts
getent hosts k8s-single
```

**Expected output:**

```text
k8s-single
127.0.1.1       k8s-single
```

If your VM tool gave a different hostname: `sudo hostnamectl set-hostname k8s-single`.

### 5.3 Disable swap

**Why:** the kubelet's memory accounting and eviction logic assume RAM is the hard limit. With swap on, a Pod exceeding its memory limit swaps instead of being evicted, and the node degrades silently. The kubelet refuses to start with swap enabled.

```bash
# Ubuntu VM (root)
# Temporarily — immediate, lost on reboot
sudo swapoff -a

# Permanently — comment out swap entries in fstab
sudo sed -i.bak -E 's|^([^#].*\sswap\s.*)$|#\1|' /etc/fstab

# Ubuntu cloud images may use a swapfile unit instead
systemctl list-units --type swap --no-legend
# if any are listed:
#   sudo systemctl mask <unit-name>
```

✅ **Verify:**

```bash
# Ubuntu VM
swapon --show
free -h | grep -i swap
```

**Expected output** — `swapon --show` prints nothing:

```text
Swap:            0B          0B          0B
```

### 5.4 Kernel modules

**Why:** `overlay` is the filesystem containerd's snapshotter uses to layer container images. `br_netfilter` makes traffic crossing a Linux bridge visible to iptables/nftables — without it, kube-proxy's Service rules are never evaluated and Services silently do nothing.

```bash
# Ubuntu VM (root)
cat <<'EOF' | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter
lsmod | grep -E '^(overlay|br_netfilter)'
```

**Expected output:**

```text
br_netfilter           32768  0
overlay               212992  0
```

### 5.5 sysctl — forwarding and bridge netfilter

**Why:** `ip_forward` lets the node route packets between Pod interfaces and the outside world (off by default). The bridge settings make netfilter process bridged frames so Service NAT applies.

```bash
# Ubuntu VM (root)
cat <<'EOF' | sudo tee /etc/sysctl.d/99-kubernetes.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
```

✅ **Verify:**

```bash
# Ubuntu VM
sysctl net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables
```

**Expected output:**

```text
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
```

**Common error:** `cannot stat /proc/sys/net/bridge/bridge-nf-call-iptables` → `br_netfilter` not loaded. `sudo modprobe br_netfilter`, then re-run `sudo sysctl --system`.

### 5.6 Set the Pod CIDR

**Why:** the Pod IP range must not overlap the VM's own network, or Pod traffic gets routed out of the cluster.

```bash
# Ubuntu VM
ip -4 addr show | grep inet
export POD_NETWORK_CIDR=10.244.0.0/16
echo "$POD_NETWORK_CIDR"
```

`10.244.0.0/16` avoids Multipass's `192.168.64.x`. If your VM tool puts the VM on a `10.x.x.x` network instead, use `192.168.0.0/16` and substitute it everywhere below.

### 5.7 Full host-prep check

```bash
# Ubuntu VM
echo "--- hostname ---"; hostnamectl --static
echo "--- swap ---";     swapon --show || echo "none (correct)"
echo "--- modules ---";  lsmod | grep -E '^(overlay|br_netfilter)'
echo "--- sysctl ---";   sysctl -n net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables
echo "--- cpu/mem ---";  nproc; free -h | head -2
```

---

## 6. Install containerd

### 6.1 Why containerd, not Docker

Kubernetes talks to a container runtime over the **CRI** (Container Runtime Interface). containerd implements CRI natively via a built-in plugin; Docker Engine does not, and kubelet support for Docker was removed in Kubernetes 1.24. Installing containerd directly means one less moving part.

### 6.2 Install

```bash
# Ubuntu VM (root)
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

`$(dpkg --print-architecture)` resolves to `arm64` on Apple Silicon and `amd64` on Intel — the same command works on both.

**Expected output:**

```text
containerd containerd.io 2.3.3 <commit-sha>
```

### 6.3 Configure and enable SystemdCgroup

**Why:** on a systemd host, systemd is the single owner of the cgroup hierarchy. The kubelet defaults to the `systemd` cgroup driver. If containerd uses `cgroupfs` instead, two components write to one hierarchy — wrong resource accounting, Pods killed unpredictably under memory pressure. **They must match.**

```bash
# Ubuntu VM (root)
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
grep -n 'SystemdCgroup' /etc/containerd/config.toml
```

**Expected output:**

```text
<line>:            SystemdCgroup = true
```

**Ensure the CRI plugin is enabled** — Docker's package has historically shipped `disabled_plugins = ["cri"]`, which makes containerd invisible to the kubelet:

```bash
# Ubuntu VM (root)
grep -n 'disabled_plugins' /etc/containerd/config.toml
sudo sed -i 's/disabled_plugins = \["cri"\]/disabled_plugins = []/' /etc/containerd/config.toml
```

**Expected output:** `disabled_plugins = []`

### 6.4 Start and verify

```bash
# Ubuntu VM (root)
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

**On failure:**

```bash
# Ubuntu VM (root)
sudo journalctl -u containerd -n 50 --no-pager
```

A TOML syntax error from a bad `sed` is the usual cause — regenerate the config and redo §6.3.

---

## 7. Install kubeadm, kubelet, kubectl

| Component | Role |
|---|---|
| **kubeadm** | Bootstrapper. Runs once (`init`) to generate certificates and start the control plane. Not a daemon. |
| **kubelet** | The node agent — a permanent systemd service. Talks to containerd over CRI and to the API server. |
| **kubectl** | The CLI for the API server. |

### 7.1 Repository

> [!WARNING]
> 🔴 Do **not** use `apt.kubernetes.io` or `packages.cloud.google.com/apt`. Retired and no longer served. `pkgs.k8s.io` is versioned per minor release — the version is part of the URL.

```bash
# Ubuntu VM (root)
export KUBERNETES_VERSION=v1.36     # minor version only, leading "v"

sudo mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/Release.key" \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
sudo chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo chmod 644 /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
```

Check the current version at <https://kubernetes.io/releases/>.

### 7.2 Install, hold, enable

**Why hold:** Kubernetes upgrades are an ordered procedure (`kubeadm upgrade`, then kubelet). An unattended `apt upgrade` bumping the kubelet under a running control plane breaks the cluster.

```bash
# Ubuntu VM (root)
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet
```

> [!NOTE]
> The kubelet now crash-loops every few seconds. **Expected** — it has no config until `kubeadm init` runs.

✅ **Verify:**

```bash
# Ubuntu VM
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

**Version skew:** the kubelet must never be newer than the API server (may be up to three minor versions older); `kubectl` may be one minor either side. Installing all three together makes this automatic.

---

## 8. Initialize the cluster

### 8.1 Node IP

```bash
# Ubuntu VM
export NODE_IP=$(ip route get 1.1.1.1 | awk '{print $7; exit}')
echo "NODE_IP=$NODE_IP  POD_NETWORK_CIDR=$POD_NETWORK_CIDR"
```

**Expected output:**

```text
NODE_IP=192.168.64.12  POD_NETWORK_CIDR=10.244.0.0/16
```

> [!WARNING]
> `NODE_IP` must **not** fall inside `POD_NETWORK_CIDR`. With Multipass (`192.168.64.x`) and Pod CIDR `10.244.0.0/16` they are safely separate.

### 8.2 Run `kubeadm init`

| Flag | Meaning |
|---|---|
| `--apiserver-advertise-address` | IP the API server listens on and writes into certificates and kubeconfig |
| `--pod-network-cidr` | Range Pods get addresses from; read by the CNI and the controller-manager |
| `--cri-socket` | Which runtime the kubelet uses |
| `--node-name` | Name of the Node object |

```bash
# Ubuntu VM (root)
sudo kubeadm init \
  --apiserver-advertise-address="${NODE_IP}" \
  --pod-network-cidr="${POD_NETWORK_CIDR}" \
  --cri-socket="unix:///run/containerd/containerd.sock" \
  --node-name="k8s-single"
```

2–8 minutes on first run (image pulls; slower on emulated storage).

**Expected output** (tail):

```text
Your Kubernetes control-plane has initialized successfully!
...
kubeadm join 192.168.64.12:6443 --token abcdef.0123456789abcdef ...
```

> [!NOTE]
> **Ignore the `kubeadm join` line.** There is no second machine and no second VM.

**What was created:** certificates in `/etc/kubernetes/pki/` (component certs valid 1 year, CA 10 years — check with `sudo kubeadm certs check-expiration`); static Pod manifests for `kube-apiserver`, `etcd`, `kube-scheduler`, and `kube-controller-manager` in `/etc/kubernetes/manifests/`, which the kubelet watches and runs — that is how the control plane starts without a control plane; the admin kubeconfig at `/etc/kubernetes/admin.conf`; kubelet config at `/var/lib/kubelet/config.yaml`; etcd data in `/var/lib/etcd/`.

---

## 9. Configure kubectl for your regular user

```bash
# Ubuntu VM (ubuntu user, NOT root)
mkdir -p "$HOME/.kube"
sudo cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"
```

✅ **Verify:**

```bash
# Ubuntu VM
kubectl cluster-info
kubectl get nodes
```

**Expected output:**

```text
Kubernetes control plane is running at https://192.168.64.12:6443

NAME         STATUS     ROLES           AGE   VERSION
k8s-single   NotReady   control-plane   45s   v1.36.1
```

`NotReady` is correct — no CNI yet.

> [!WARNING]
> 🔴 This file holds **cluster-admin credentials**. Do not commit it or share it.

**Optional — use `kubectl` from macOS instead of inside the VM:**

```bash
# macOS Terminal
brew install kubectl
multipass exec k8s-single -- sudo cat /etc/kubernetes/admin.conf > ~/.kube/config-vm
export KUBECONFIG=~/.kube/config-vm
kubectl get nodes
```

This works because Multipass's network is directly reachable from macOS. With a NAT-only VM tool, use SSH port forwarding instead (§14).

---

## 10. Install the CNI plugin (Calico)

### 10.1 Why the node is `NotReady`

The kubelet only reports `Ready` once a network plugin is initialized. With no `/etc/cni/net.d/` config the node carries `NetworkReady=false` / `NetworkPluginNotReady`, and CoreDNS stays `Pending` because it needs Pod networking. Everything else in `kube-system` runs because it uses host networking.

```bash
# Ubuntu VM
kubectl describe node k8s-single | grep -A5 Conditions
kubectl get pods -n kube-system
```

### 10.2 Install Calico with the `10.244.0.0/16` Pod CIDR

Calico normally auto-detects the Pod CIDR that kubeadm configured. Because this page uses a non-default CIDR, download the manifest and set it explicitly — it is one uncomment plus one value.

```bash
# Ubuntu VM
curl -fsSLO https://raw.githubusercontent.com/projectcalico/calico/v3.32.1/manifests/calico.yaml

# Uncomment CALICO_IPV4POOL_CIDR and set it to 10.244.0.0/16
sed -i 's|# - name: CALICO_IPV4POOL_CIDR|- name: CALICO_IPV4POOL_CIDR|; s|#   value: "192.168.0.0/16"|  value: "10.244.0.0/16"|' calico.yaml

grep -A2 'CALICO_IPV4POOL_CIDR' calico.yaml
kubectl apply -f calico.yaml
```

**Expected output from the `grep`:**

```text
            - name: CALICO_IPV4POOL_CIDR
              value: "10.244.0.0/16"
```

If the `sed` does not match (manifest formatting changed), edit `calico.yaml` by hand: find the commented `CALICO_IPV4POOL_CIDR` block in the `calico-node` DaemonSet, uncomment both lines, and set the value.

**Wait for it:**

```bash
# Ubuntu VM
kubectl -n kube-system rollout status daemonset/calico-node --timeout=300s
```

✅ **Verify:**

```bash
# Ubuntu VM
kubectl get nodes
kubectl get pods -n kube-system
```

**Expected output:**

```text
NAME         STATUS   ROLES           AGE   VERSION
k8s-single   Ready    control-plane   6m    v1.36.1
```

with `calico-node`, `calico-kube-controllers`, both `coredns` Pods, and all control-plane Pods `Running`.

### 10.3 Alternatives

| CNI | Notes |
|---|---|
| **Cilium** (`cilium install --version 1.20.0`) | eBPF-based, great observability, can replace kube-proxy. Needs kernel 5.10+. Heavier on a 4 GB VM. |
| **Flannel** | Lightest. Hard-codes `10.244.0.0/16` — which happens to match this page, so it needs no edit — but has no NetworkPolicy support. |

Install **exactly one**.

---

## 11. Remove the control-plane taint

A **taint** repels Pods that do not carry a matching **toleration**. `kubeadm` applies `node-role.kubernetes.io/control-plane:NoSchedule` so ordinary workloads cannot starve etcd and the API server. With exactly one node, your app has nowhere else to go — so it must be removed.

```bash
# Ubuntu VM
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
> Correct **only** on a single-node learning cluster. In production you add worker nodes instead. Restore with: `kubectl taint nodes k8s-single node-role.kubernetes.io/control-plane=:NoSchedule`

✅ **Confirm scheduling works:**

```bash
# Ubuntu VM
kubectl run scheduling-test --image=nginx:1.30-alpine --restart=Never
kubectl wait --for=condition=Ready pod/scheduling-test --timeout=120s
kubectl get pod scheduling-test -o wide
kubectl delete pod scheduling-test
```

**Expected output:** `Running`, with a Pod IP in `10.244.x.x` — proof the CNI is working.

---

## 12. Verify the cluster

```bash
# Ubuntu VM
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
# Ubuntu VM
kubectl run net-a --image=nginx:1.30-alpine
kubectl run net-b --image=busybox:1.37 --restart=Never --command -- sleep 3600
kubectl wait --for=condition=Ready pod/net-a pod/net-b --timeout=120s

POD_A_IP=$(kubectl get pod net-a -o jsonpath='{.status.podIP}')
kubectl exec net-b -- wget -qO- --timeout=5 "http://${POD_A_IP}" | head -4

kubectl expose pod net-a --name=net-a-svc --port=80
kubectl exec net-b -- nslookup net-a-svc.default.svc.cluster.local
kubectl exec net-b -- wget -qO- --timeout=5 http://net-a-svc | head -4

kubectl delete pod net-a net-b; kubectl delete svc net-a-svc
```

Both must succeed before you continue.

---

## 13. Deploy the sample application

The manifests are in [`manifests/`](./manifests/). Get them into the VM either by cloning the repo or by writing them directly.

```bash
# Ubuntu VM
git clone <REPO_URL> && cd basic-installations/kubernetes-cluster-setup/kubeadm
kubectl apply -f manifests/
```

Or copy from macOS:

```bash
# macOS Terminal
multipass transfer -r kubernetes-cluster-setup/kubeadm/manifests k8s-single:/home/ubuntu/manifests
```

```bash
# Ubuntu VM
kubectl apply -f ~/manifests/
kubectl -n demo rollout status deployment/web --timeout=180s
kubectl -n demo get all -o wide
```

**Expected output:**

```text
namespace/demo created
deployment.apps/web created
service/web created
service/web-nodeport created

NAME                      READY   STATUS    RESTARTS   AGE   IP            NODE
pod/web-6c9d8f7b4-abcde   1/1     Running   0          40s   10.244.0.5    k8s-single
pod/web-6c9d8f7b4-fghij   1/1     Running   0          40s   10.244.0.6    k8s-single

NAME                   TYPE        CLUSTER-IP     PORT(S)        AGE
service/web            ClusterIP   10.96.171.22   80/TCP         40s
service/web-nodeport   NodePort    10.96.203.11   80:30080/TCP   40s

NAME                  READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/web   2/2     2            2           40s
```

**Both replicas on one node is expected.** `replicas: 2` means two Pods, not two machines. You get genuine ReplicaSet behaviour — rolling updates, self-healing, load-balanced Service endpoints — but no node-failure tolerance, because there is one node.

Prove self-healing:

```bash
# Ubuntu VM
kubectl -n demo delete pod -l app.kubernetes.io/name=web --wait=false
kubectl -n demo get pods -w      # Ctrl+C when both are Running again
```

---

## 14. Access the application from macOS

### Method 1 — direct to the VM IP (Multipass, bridged, or host-only networking)

```bash
# macOS Terminal
VM_IP=$(multipass info k8s-single --format json | python3 -c 'import sys,json; print(json.load(sys.stdin)["info"]["k8s-single"]["ipv4"][0])')
curl -s "http://${VM_IP}:30080" | head -5
open "http://${VM_IP}:30080"
```

**Expected output:** the nginx welcome page.

This works with Multipass because macOS routes to the host-only network directly. It also works with bridged networking in Fusion/Parallels/UTM.

### Method 2 — SSH local port forwarding (works with any VM tool, including NAT-only)

```bash
# macOS Terminal — leave running
ssh -N -L 8080:localhost:30080 ubuntu@"${VM_IP}"
```

`-L 8080:localhost:30080` means: listen on macOS `:8080`, forward through SSH, deliver to `localhost:30080` **inside the VM**. `-N` means do not open a shell.

In a second terminal:

```bash
# macOS Terminal
curl -s http://localhost:8080 | head -5
open http://localhost:8080
```

Stop with `Ctrl+C`.

### Method 3 — `kubectl port-forward` inside the VM, plus SSH forwarding

Safest: nothing is exposed on the node at all.

```bash
# Ubuntu VM — leave running
kubectl -n demo port-forward --address 0.0.0.0 svc/web 8080:80
```

```bash
# macOS Terminal
curl -s "http://${VM_IP}:8080" | head -5
```

### Method 4 — VM-tool port forwarding (VMware / Parallels / UTM with NAT)

In your VM tool's network settings, add a forwarding rule mapping host port `8080` → guest port `30080` (TCP). Then:

```bash
# macOS Terminal
curl -s http://localhost:8080 | head -5
```

Consult your VM tool's documentation for where that setting lives; each one differs.

### Comparison

| Method | Works with NAT-only VMs | Needs VM config | Exposure |
|---|---|---|---|
| Direct VM IP + NodePort | ❌ No | No | VM's host-only network |
| SSH `-L` forwarding | ✅ Yes | No | macOS `localhost` only |
| `port-forward` in VM | ✅ (combine with SSH) | No | Nothing on the node |
| VM tool port forwarding | ✅ Yes | Yes | macOS `localhost` |

---

## 15. Troubleshooting

Full matrix in **[troubleshooting.md](./troubleshooting.md)**. macOS/VM-specific issues:

| Symptom | Cause | Diagnostic | Fix |
|---|---|---|---|
| `multipass launch` fails on Apple Silicon | Old Multipass, or virtualization framework issue | `multipass version` | `brew upgrade --cask multipass`, restart the Multipass daemon |
| `kubeadm init` → `[ERROR NumCPU]` | VM has <2 CPUs | `nproc` inside the VM | Recreate with `--cpus 4`, or `multipass set local.k8s-single.cpus=4` (VM must be stopped) |
| `kubeadm init` → `[ERROR Mem]` | VM has <1700 MB | `free -h` | Recreate with `--memory 6G` |
| Pods have IPs that clash with your Mac's network | Pod CIDR overlaps the VM/host network | `ip -4 addr`, `kubectl get pods -o wide` | Reset (§16) and re-init with a non-overlapping CIDR |
| Cannot reach the app from macOS | VM tool uses NAT without forwarding | `curl` from inside the VM first | Use SSH `-L` forwarding (§14 Method 2) |
| VM IP changed after recreating the VM | New DHCP lease | `multipass list` | Update your `KUBECONFIG` server address, or use `kubectl` inside the VM |
| An image fails with `exec format error` | amd64-only image on Apple Silicon | `kubectl describe pod <n>` | Use a multi-arch image; `nginx:1.30-alpine` is multi-arch |
| Very slow image pulls / disk | Emulated storage | — | Give the VM more disk; use a native-virtualization tool (Multipass, Fusion, Parallels) rather than emulation |
| `kubectl` from macOS says connection refused | VM stopped, or wrong server IP | `multipass list` | `multipass start k8s-single`, then re-copy kubeconfig |

**Diagnostics inside the VM:**

```bash
# Ubuntu VM
sudo journalctl -u kubelet -n 100 --no-pager
sudo journalctl -u containerd -n 100 --no-pager
kubectl get events -A --sort-by=.lastTimestamp | tail -30
sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps -a
```

---

## 16. Reset and cleanup

### 16.1 Delete only the application

```bash
# Ubuntu VM
kubectl delete namespace demo
```

### 16.2 Full cluster reset (keep the VM)

> [!CAUTION]
> 🔴 **DESTRUCTIVE.** Permanently destroys the cluster and all etcd data.

```bash
# Ubuntu VM (root)  🔴 DESTRUCTIVE
kubectl delete namespace demo --ignore-not-found

sudo kubeadm reset -f --cri-socket=unix:///run/containerd/containerd.sock

sudo rm -rf /etc/cni/net.d /var/lib/cni/
sudo rm -rf /opt/cni/bin/calico*
rm -rf "$HOME/.kube"

# Remove Kubernetes network interfaces
ip link show | grep -E 'cali|tunl|vxlan|cni0'
# for each one found:
#   sudo ip link delete <INTERFACE_NAME>

sudo systemctl restart containerd
```

**Networking rules** — safest is to reboot the VM, since Kubernetes iptables rules do not persist:

```bash
# Ubuntu VM (root)
sudo reboot
```

Or flush manually (review first):

```bash
# Ubuntu VM (root)  🔴 DESTRUCTIVE — review first
sudo iptables-save | grep -E 'KUBE-|CALI-' | head
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X
```

### 16.3 Recreate the cluster

```bash
# Ubuntu VM (root)
export NODE_IP=$(ip route get 1.1.1.1 | awk '{print $7; exit}')
sudo swapoff -a
sudo kubeadm init \
  --apiserver-advertise-address="${NODE_IP}" \
  --pod-network-cidr=10.244.0.0/16 \
  --cri-socket=unix:///run/containerd/containerd.sock

mkdir -p "$HOME/.kube"
sudo cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

kubectl apply -f calico.yaml     # your edited copy from §10.2
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

### 16.4 Delete the whole VM (cleanest option)

The simplest way to undo everything on a Mac: throw away the VM.

```bash
# macOS Terminal
multipass stop k8s-single          # keeps the VM, frees CPU/RAM
```

```bash
# macOS Terminal  🔴 DESTRUCTIVE — deletes the VM and everything inside it
multipass delete k8s-single
multipass purge
multipass list
```

**Expected output:** `No instances found.`

Reclaim disk from cached images too:

```bash
# macOS Terminal
multipass find                     # what images are available
du -sh ~/Library/Application\ Support/multipassd 2>/dev/null || true
```

Uninstall Multipass entirely:

```bash
# macOS Terminal  🔴 DESTRUCTIVE
brew uninstall --cask multipass
```

### 16.5 macOS-side cleanup checklist

- [ ] SSH port-forward sessions closed (`Ctrl+C` in those terminals)
- [ ] `~/.kube/config-vm` removed if you created it
- [ ] VM stopped or deleted (`multipass list` shows nothing)
- [ ] VM-tool port-forwarding rules removed (Fusion/Parallels/UTM users)
- [ ] `~/.ssh/known_hosts` entry for the VM IP removed if it will be reused

---

## Official documentation

- Multipass — <https://multipass.run/docs>
- Installing kubeadm — <https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/>
- Creating a cluster with kubeadm — <https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/>
- Container runtimes — <https://kubernetes.io/docs/setup/production-environment/container-runtimes/>
- `kubeadm reset` — <https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-reset/>
- Calico quickstart — <https://docs.tigera.io/calico/latest/getting-started/kubernetes/quickstart>
- UTM — <https://docs.getutm.app/>
