# kubeadm — Troubleshooting

Every issue below has **symptoms**, **cause**, a **diagnostic command**, and a **resolution**.

Jump to: [First-response commands](#first-response-commands) · [Environment issues](#a-environment-issues) · [Runtime and kubelet](#b-container-runtime-and-kubelet) · [Cluster init](#c-cluster-initialization) · [Node not ready / networking](#d-node-not-ready-and-networking) · [Scheduling](#e-scheduling) · [Access and kubeconfig](#f-access-and-kubeconfig) · [Platform-specific](#g-platform-specific) · [Certificates](#h-certificates)

---

## First-response commands

Run these before anything else. They resolve or explain most problems.

```bash
# 1. Is the node up and what does it think is wrong?
kubectl get nodes -o wide
kubectl describe node "$(hostname)" | sed -n '/Conditions/,/Addresses/p'

# 2. What is the control plane doing?
kubectl get pods -n kube-system -o wide

# 3. What has the cluster complained about recently?
kubectl get events -A --sort-by=.lastTimestamp | tail -30

# 4. The two host services
systemctl is-active kubelet containerd
sudo journalctl -u kubelet -n 100 --no-pager
sudo journalctl -u containerd -n 100 --no-pager

# 5. What containers exist at the runtime level (works even when the API server is down)
sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps -a

# 6. Host resources
nproc; free -h; df -h /; swapon --show
```

> [!TIP]
> When the API server is down, `kubectl` tells you nothing. `crictl` and `journalctl -u kubelet` are your only windows — the control plane runs as containers the kubelet manages, so the kubelet log is where its failures appear.

---

## A. Environment issues

### A1. WSL2: systemd is not running

**Symptoms**

```text
System has not been booted with systemd as init system (PID 1). Can't operate.
Failed to connect to bus: Host is down
```

**Cause** — systemd is off by default in WSL2. The kubelet and containerd are systemd services; `kubeadm` writes systemd drop-ins.

**Diagnostic**

```bash
# WSL Ubuntu
ps -p 1 -o comm=
cat /etc/wsl.conf 2>/dev/null
```

**Resolution**

```bash
# WSL Ubuntu (root)
sudo tee /etc/wsl.conf > /dev/null <<'EOF'
[boot]
systemd=true
EOF
```

```powershell
# PowerShell — a full shutdown is required; closing the window is not enough
wsl --shutdown
```

Reopen Ubuntu and confirm `ps -p 1 -o comm=` prints `systemd`. If it still does not, run `wsl --update` in PowerShell (Administrator) — systemd support needs WSL 0.67.6+.

---

### A2. Swap is still enabled

**Symptoms**

```text
[ERROR Swap]: swap is supported for cgroup v2 only; the NodeSwap feature gate of the kubelet is beta but disabled by default
```

or, after init, the kubelet refuses to start.

**Cause** — the kubelet's eviction logic treats RAM as the hard limit. With swap on, an over-limit Pod swaps instead of being evicted.

**Diagnostic**

```bash
swapon --show
free -h | grep -i swap
cat /etc/fstab | grep -i swap
systemctl list-units --type swap --no-legend
```

**Resolution**

```bash
# Linux / WSL / VM / EC2 (root)
sudo swapoff -a
sudo sed -i.bak -E 's|^([^#].*\sswap\s.*)$|#\1|' /etc/fstab

# If a systemd swap unit exists:
sudo systemctl mask <swap-unit-name>
```

On **WSL2**, also add `swap=0` to `%USERPROFILE%\.wslconfig` under `[wsl2]`, then `wsl --shutdown`. Otherwise WSL recreates the swap file on every start.

Verify after a reboot, not just immediately.

---

### A3. Insufficient CPU or memory

**Symptoms**

```text
[ERROR NumCPU]: the number of available CPUs 1 is less than the required 2
[ERROR Mem]: the system RAM (1700 MB) is less than the minimum 1700 MB
```

Or, later: Pods `Pending` with `Insufficient cpu` / `Insufficient memory`.

**Cause** — `kubeadm init` enforces ≥2 CPUs and ~1700 MB as preflight checks. Beyond that, the control plane itself consumes roughly 1 vCPU and 1.5–2 GB before your workloads get anything.

**Diagnostic**

```bash
nproc
free -h
kubectl describe node "$(hostname)" | grep -A10 "Allocated resources"
kubectl top nodes            # requires metrics-server
```

**Resolution**

| Environment | Fix |
|---|---|
| Native Linux | Nothing to allocate — you need a bigger machine |
| WSL2 | `processors=4` and `memory=6GB` in `%USERPROFILE%\.wslconfig`, then `wsl --shutdown` |
| macOS VM | Recreate with `multipass launch --cpus 4 --memory 6G`, or resize in your VM tool (VM must be stopped) |
| EC2 | Stop the instance → **Actions → Instance settings → Change instance type** → start |

> [!WARNING]
> Do **not** work around this with `--ignore-preflight-errors=NumCPU`. The cluster will start and then be unusably slow, with API server timeouts that look like unrelated bugs.

If the node itself is big enough but Pods are `Pending` on `Insufficient cpu`, your manifests' `resources.requests` are too high — lower them. Requests are *reservations*, not usage.

---

### A4. Kernel modules missing

**Symptoms**

```text
modprobe: FATAL: Module br_netfilter not found
sysctl: cannot stat /proc/sys/net/bridge/bridge-nf-call-iptables: No such file or directory
```

**Cause** — the module is not loaded (or the kernel does not ship it).

**Diagnostic**

```bash
uname -r
lsmod | grep -E 'overlay|br_netfilter'
ls /lib/modules/$(uname -r)/kernel/net/bridge/ 2>/dev/null
```

**Resolution**

```bash
# (root)
sudo modprobe overlay
sudo modprobe br_netfilter
sudo sysctl --system
```

Make it persistent:

```bash
# (root)
printf 'overlay\nbr_netfilter\n' | sudo tee /etc/modules-load.d/k8s.conf
```

On **WSL2**, if `modprobe` genuinely cannot find the module, your WSL kernel is out of date — run `wsl --update` in PowerShell (Administrator).

---

## B. Container runtime and kubelet

### B1. containerd runtime unavailable

**Symptoms**

```text
[ERROR CRI]: container runtime is not running: output: ... connect: connection refused
```

or `kubectl get nodes` shows the node `NotReady` with `ContainerRuntimeNotReady`.

**Cause** — containerd is stopped, its socket is missing, or its config has a syntax error.

**Diagnostic**

```bash
systemctl status containerd --no-pager
ls -l /run/containerd/containerd.sock
sudo journalctl -u containerd -n 50 --no-pager
sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock version
```

**Resolution**

```bash
# (root)
sudo systemctl restart containerd
systemctl is-active containerd
```

If it will not start, the config is almost always the problem — regenerate it:

```bash
# (root)
sudo containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
```

---

### B2. CRI plugin disabled

**Symptoms** — containerd is `active`, but the kubelet cannot use it. `kubeadm init` fails the CRI preflight check.

**Cause** — Docker's `containerd.io` package has historically shipped `/etc/containerd/config.toml` containing `disabled_plugins = ["cri"]`. containerd runs fine for `ctr`/Docker, but is invisible to Kubernetes.

**Diagnostic**

```bash
grep -n 'disabled_plugins' /etc/containerd/config.toml
sudo ctr plugin ls | grep cri
```

The CRI plugin rows must show `STATUS: ok`.

**Resolution**

```bash
# (root)
sudo sed -i 's/disabled_plugins = \["cri"\]/disabled_plugins = []/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo ctr plugin ls | grep cri
```

---

### B3. Wrong cgroup configuration

**Symptoms**

```text
misconfiguration: kubelet cgroup driver: "systemd" is different from docker cgroup driver: "cgroupfs"
failed to get cgroup stats for "/kubepods"
```

Pods start and then get killed for no obvious reason; memory limits are not enforced.

**Cause** — the kubelet and containerd disagree on the cgroup driver. On a systemd host, systemd owns the cgroup hierarchy; two writers means duplicated cgroups and wrong accounting.

**Diagnostic**

```bash
grep -n 'SystemdCgroup' /etc/containerd/config.toml
grep -n 'cgroupDriver' /var/lib/kubelet/config.yaml
sudo journalctl -u kubelet -n 50 --no-pager | grep -i cgroup
stat -fc %T /sys/fs/cgroup/          # cgroup2fs = cgroup v2
```

**Resolution** — set **both** to `systemd`:

```bash
# (root)
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
grep -n 'SystemdCgroup' /etc/containerd/config.toml     # must be true

grep -n 'cgroupDriver' /var/lib/kubelet/config.yaml     # must be systemd
# if it says cgroupfs, edit it to: cgroupDriver: systemd

sudo systemctl restart containerd
sudo systemctl restart kubelet
```

Kubernetes 1.36 defaults the kubelet to `systemd`, so in practice the containerd side is the one that is wrong.

---

### B4. kubelet restart loop

**Symptoms**

```text
kubelet.service: Scheduled restart job, restart counter is at 47.
Active: activating (auto-restart) (Result: exit-code)
```

**Cause** — depends on when it happens:

- **Before `kubeadm init`** — completely normal. The kubelet has no config yet. Ignore it.
- **After `kubeadm init`** — a real problem: cgroup mismatch, swap on, missing config, or a broken runtime.

**Diagnostic**

```bash
sudo systemctl status kubelet --no-pager
sudo journalctl -u kubelet -n 100 --no-pager
ls -l /var/lib/kubelet/config.yaml /etc/kubernetes/kubelet.conf
```

**Resolution** by the log line you see:

| Log excerpt | Fix |
|---|---|
| `failed to load Kubelet config file` | `kubeadm init` never completed → re-run it, or `kubeadm reset -f` and start over |
| `cgroup driver` mismatch | See [B3](#b3-wrong-cgroup-configuration) |
| `swap is enabled` | See [A2](#a2-swap-is-still-enabled) |
| `failed to run Kubelet: validate service connection` | containerd down → see [B1](#b1-containerd-runtime-unavailable) |
| `node not found` | API server not up yet — wait 60 s; if it persists, check the API server static Pod |
| `Failed to create sandbox` | CNI missing or broken → see [D2](#d2-cni-pod-failure) |

---

## C. Cluster initialization

### C1. `kubeadm init` preflight failures

**Symptoms** — `[preflight] Some fatal errors occurred:` followed by one or more `[ERROR X]` lines.

**Diagnostic**

```bash
sudo kubeadm init phase preflight --cri-socket=unix:///run/containerd/containerd.sock
```

**Resolution by error:**

| Error | Cause | Fix |
|---|---|---|
| `[ERROR NumCPU]` | <2 CPUs | [A3](#a3-insufficient-cpu-or-memory) |
| `[ERROR Mem]` | <1700 MB | [A3](#a3-insufficient-cpu-or-memory) |
| `[ERROR Swap]` | Swap on | [A2](#a2-swap-is-still-enabled) |
| `[ERROR CRI]` | Runtime not reachable | [B1](#b1-containerd-runtime-unavailable) / [B2](#b2-cri-plugin-disabled) |
| `[ERROR Port-6443]: Port 6443 is in use` | A previous cluster is still running | `sudo kubeadm reset -f` then retry |
| `[ERROR FileAvailable--etc-kubernetes-manifests-kube-apiserver.yaml]` | Leftovers from a previous init | `sudo kubeadm reset -f` |
| `[ERROR FileContent--proc-sys-net-ipv4-ip_forward]` | Forwarding disabled | `sudo sysctl -w net.ipv4.ip_forward=1` and persist it |
| `[ERROR ImagePull]` | No internet / registry blocked | `sudo kubeadm config images pull` to see the real error; check DNS and proxy |

> [!WARNING]
> `--ignore-preflight-errors` exists for experts working around known-safe checks. Using it on `NumCPU`, `Mem`, or `Swap` produces a cluster that appears to work and then fails in confusing ways.

---

### C2. API server unavailable after init

**Symptoms**

```text
The connection to the server <IP>:6443 was refused - did you specify the right host or port?
```

**Cause** — the API server static Pod is not running, its port is blocked, or `kubectl` is pointed at the wrong address.

**Diagnostic**

```bash
# Is anything listening?
sudo ss -tlnp | grep 6443

# Does the runtime have the container?
sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps -a | grep apiserver

# Its logs (API server runs as a container, so use crictl, not kubectl)
API_ID=$(sudo crictl ps -a --name kube-apiserver -q | head -1)
sudo crictl logs --tail 50 "$API_ID"

# What the kubelet thinks
sudo journalctl -u kubelet -n 100 --no-pager | grep -i apiserver

# Where kubectl is pointed
grep server "$HOME/.kube/config"
```

**Resolution**

| Finding | Fix |
|---|---|
| No apiserver container at all | The kubelet is not reading static manifests — check `ls /etc/kubernetes/manifests/` and `sudo systemctl restart kubelet` |
| Container exits immediately | Read `crictl logs`. Common: etcd unreachable, cert problem, or **disk full** (`df -h /`) |
| Listening, but `kubectl` refused | Wrong server address in kubeconfig — see [F2](#f2-wrong-node-ip-or-address-in-kubeconfig) |
| etcd unhealthy | `sudo crictl logs $(sudo crictl ps -a --name etcd -q \| head -1) --tail 50` — usually disk or a corrupted data dir |

Wait 60–90 seconds after `kubeadm init` or a reboot before concluding anything — static Pods take time to come up.

---

## D. Node NotReady and networking

### D1. Node remains `NotReady`

**Symptoms**

```text
NAME         STATUS     ROLES           AGE   VERSION
k8s-single   NotReady   control-plane   3m    v1.36.1
```

**Cause** — in order of likelihood: (1) no CNI installed, (2) the CNI is installed but its Pods are failing, (3) the kubelet cannot reach the runtime.

**Diagnostic**

```bash
kubectl describe node "$(hostname)" | sed -n '/Conditions/,/Addresses/p'
```

Look at the `Ready` condition's `Reason` and `Message`:

| Reason | Meaning |
|---|---|
| `KubeletNotReady` + `network plugin is not ready: cni config uninitialized` | No CNI → [D2](#d2-cni-pod-failure) |
| `KubeletNotReady` + `container runtime is down` | Runtime → [B1](#b1-containerd-runtime-unavailable) |
| `KubeletNotReady` + `PLEG is not healthy` | Runtime overwhelmed or hung — restart containerd, check resources |
| `NodeStatusUnknown` | The kubelet stopped reporting → check `systemctl status kubelet` |

```bash
ls -l /etc/cni/net.d/           # should contain a CNI config after the CNI is installed
kubectl get pods -n kube-system
```

**Resolution** — if there is no CNI, install one:

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.32.1/manifests/calico.yaml
kubectl -n kube-system rollout status daemonset/calico-node --timeout=300s
kubectl get nodes
```

---

### D2. CNI pod failure

**Symptoms** — `calico-node` in `CrashLoopBackOff`, `Init:Error`, or `0/1 Running`.

**Cause** — Pod CIDR mismatch, wrong network interface autodetected, insufficient memory, or two CNIs installed.

**Diagnostic**

```bash
kubectl -n kube-system get pods -l k8s-app=calico-node -o wide
kubectl -n kube-system logs -l k8s-app=calico-node --tail=80
kubectl -n kube-system describe pod -l k8s-app=calico-node | tail -30
ls -l /etc/cni/net.d/
```

**Resolution**

| Log message | Fix |
|---|---|
| `Unable to auto-detect an IPv4 address` | Set the interface explicitly: `kubectl -n kube-system set env daemonset/calico-node IP_AUTODETECTION_METHOD=interface=eth0` (use `ens5` on EC2, `eth0` on WSL2) |
| `CIDR ... is not within the configured pool` | Pod CIDR mismatch → [D3](#d3-pod-cidr-mismatch) |
| `OOMKilled` in `describe` | Not enough memory → [A3](#a3-insufficient-cpu-or-memory) |
| Multiple config files in `/etc/cni/net.d/` | Two CNIs installed. Delete one CNI's resources, remove its file from `/etc/cni/net.d/`, and restart the kubelet |

---

### D3. Pod CIDR mismatch

**Symptoms** — Pods get no IP, or an IP outside the expected range; Calico logs complain about pools; Pod-to-Pod traffic fails.

**Cause** — the `--pod-network-cidr` passed to `kubeadm init` does not match the CNI's configured pool. Flannel is the classic case: it hard-codes `10.244.0.0/16`.

**Diagnostic**

```bash
# What kubeadm configured
kubectl cluster-info dump | grep -m1 cluster-cidr

# What the controller-manager was told
grep cluster-cidr /etc/kubernetes/manifests/kube-controller-manager.yaml

# What Calico is using
kubectl get ippools -o custom-columns=NAME:.metadata.name,CIDR:.spec.cidr 2>/dev/null

# What Pods actually got
kubectl get pods -A -o wide | head
```

**Resolution** — the two must match. The reliable fix is to reset and re-init with matching values:

```bash
# (root)  🔴 DESTRUCTIVE
sudo kubeadm reset -f --cri-socket=unix:///run/containerd/containerd.sock
sudo rm -rf /etc/cni/net.d /var/lib/cni/
sudo kubeadm init --pod-network-cidr=<POD_NETWORK_CIDR> \
  --apiserver-advertise-address=<NODE_IP> \
  --cri-socket=unix:///run/containerd/containerd.sock
```

Then install the CNI configured for the **same** CIDR.

> [!IMPORTANT]
> Also check the Pod CIDR does not overlap your host network, LAN, or VPC. Overlap produces a cluster that starts cleanly and then routes Pod traffic to the wrong place.

---

### D4. CoreDNS remains `Pending`

**Symptoms**

```text
coredns-668d6bf9bc-abcde   0/1   Pending   0   5m
```

**Cause** — CoreDNS needs Pod networking (it is not host-networked) **and** a schedulable node. So: no CNI, or the control-plane taint is still there, or not enough resources.

**Diagnostic**

```bash
kubectl -n kube-system describe pod -l k8s-app=kube-dns | tail -20
```

Read the `Events` section:

| Event | Fix |
|---|---|
| `node(s) had untolerated taint {node-role.kubernetes.io/control-plane}` | Remove the taint → [E1](#e1-pods-remain-pending-due-to-the-control-plane-taint) |
| `network plugin is not ready` | Install the CNI → [D1](#d1-node-remains-notready) |
| `Insufficient cpu` / `Insufficient memory` | [A3](#a3-insufficient-cpu-or-memory) |

**Resolution** once the cause is fixed — CoreDNS schedules itself; no manual action needed. To force it:

```bash
kubectl -n kube-system rollout restart deployment coredns
```

---

### D5. DNS resolution fails inside Pods

**Symptoms** — `nslookup kubernetes.default` inside a Pod times out; applications cannot resolve Service names.

**Cause** — CoreDNS not running, kube-proxy rules missing, or `br_netfilter` / bridge sysctls not set.

**Diagnostic**

```bash
kubectl -n kube-system get pods -l k8s-app=kube-dns
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=50
kubectl get svc kube-dns -n kube-system

kubectl run dnstest --image=busybox:1.37 --rm -it --restart=Never -- \
  nslookup kubernetes.default.svc.cluster.local

sysctl net.bridge.bridge-nf-call-iptables      # must be 1
sudo iptables-save | grep -c KUBE-             # must be > 0
```

**Resolution**

```bash
# (root)
sudo modprobe br_netfilter
sudo sysctl -w net.bridge.bridge-nf-call-iptables=1
sudo sysctl --system

kubectl -n kube-system rollout restart deployment coredns
kubectl -n kube-system rollout restart daemonset kube-proxy
```

---

## E. Scheduling

### E1. Pods remain `Pending` due to the control-plane taint

**Symptoms**

```text
NAME                    READY   STATUS    RESTARTS   AGE
web-6c9d8f7b4-abcde     0/1     Pending   0          3m
```

`kubectl describe pod` shows:

```text
Warning  FailedScheduling  0/1 nodes are available: 1 node(s) had untolerated taint
{node-role.kubernetes.io/control-plane: }. preemption: 0/1 nodes are available.
```

**Cause** — `kubeadm` taints the control-plane node so ordinary workloads cannot compete with etcd and the API server. On a single-node cluster there is nowhere else for Pods to go.

**Diagnostic**

```bash
kubectl describe node "$(hostname)" | grep -i -A3 taints
kubectl describe pod <POD_NAME> -n <NAMESPACE> | tail -10
```

**Resolution**

```bash
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
kubectl describe node "$(hostname)" | grep -i -A2 taints    # expect: Taints: <none>
```

Pending Pods schedule within seconds. To restore the taint later:

```bash
kubectl taint nodes "$(hostname)" node-role.kubernetes.io/control-plane=:NoSchedule
```

---

### E2. Pods `Pending` for other reasons

**Diagnostic**

```bash
kubectl describe pod <POD_NAME> -n <NAMESPACE> | sed -n '/Events/,$p'
kubectl describe node "$(hostname)" | grep -A10 "Allocated resources"
```

| Message | Cause | Fix |
|---|---|---|
| `Insufficient cpu` / `Insufficient memory` | Requests exceed remaining capacity | Lower `resources.requests`, or use a bigger machine. Remember the control plane already reserves ~1 vCPU / 1.5 GB. |
| `pod has unbound immediate PersistentVolumeClaims` | No storage class / provisioner | A vanilla kubeadm cluster has **no** default StorageClass. Use `emptyDir`, or install one (e.g. local-path-provisioner). |
| `node(s) didn't match Pod's node affinity` | Affinity rules with no matching node | Remove or relax the affinity — a one-node cluster satisfies very few rules |
| `0/1 nodes are available: 1 node(s) had volume node affinity conflict` | PV bound to a different node | Delete the PV/PVC and recreate |

---

### E3. Pods `ImagePullBackOff` / `ErrImagePull`

**Diagnostic**

```bash
kubectl describe pod <POD_NAME> -n <NAMESPACE> | grep -A5 -i "failed to pull"
sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock pull <IMAGE>
```

| Message | Fix |
|---|---|
| `no such host` | DNS broken on the node — check `/etc/resolv.conf` and `ping registry-1.docker.io` |
| `toomanyrequests` | Docker Hub anonymous rate limit — wait, or authenticate |
| `not found` | Image name/tag typo |
| `no match for platform in manifest` | amd64-only image on arm64 (Apple Silicon, Graviton) — use a multi-arch image |
| Times out behind a corporate network | Proxy needed — configure `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` in a containerd systemd drop-in, then restart containerd |

---

## F. Access and kubeconfig

### F1. `kubectl` cannot locate kubeconfig

**Symptoms**

```text
The connection to the server localhost:8080 was refused - did you specify the right host or port?
error: no configuration has been provided, try setting KUBERNETES_MASTER environment variable
```

`localhost:8080` is the giveaway: that is `kubectl`'s hard-coded fallback when it has no config at all.

**Cause** — `~/.kube/config` missing, unreadable, or you are a different user (commonly: you ran `sudo kubectl`, and root has no config).

**Diagnostic**

```bash
whoami
ls -l "$HOME/.kube/config"
echo "KUBECONFIG=$KUBECONFIG"
kubectl config view --minify
```

**Resolution**

```bash
# As your normal user, NOT root
mkdir -p "$HOME/.kube"
sudo cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"
kubectl get nodes
```

If you must run as root: `sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes`.

---

### F2. Wrong node IP or address in kubeconfig

**Symptoms**

```text
The connection to the server 172.28.114.53:6443 was refused
Unable to connect to the server: dial tcp <old-ip>:6443: i/o timeout
```

**Cause** — the machine's IP changed (WSL2 restart, VM recreated, EC2 restarted without an Elastic IP), or `kubeadm` auto-selected the wrong interface at init time.

**Diagnostic**

```bash
ip route get 1.1.1.1 | awk '{print $7; exit}'      # current IP
grep server "$HOME/.kube/config"                    # what kubectl targets
sudo ss -tlnp | grep 6443                           # what the API server binds to
```

**Resolution** — for local access, point kubeconfig at loopback. The API server also listens there and its certificate already includes `127.0.0.1`:

```bash
kubectl config set-cluster kubernetes --server=https://127.0.0.1:6443
kubectl get nodes
```

That survives all future IP changes. For remote access, see [H1](#h1-certificate-errors).

---

### F3. Certificate expired

**Symptoms**

```text
Unable to connect to the server: x509: certificate has expired or is not yet valid
```

**Cause** — kubeadm component certificates are valid for **one year**. A cluster left running (or restarted) past that date stops authenticating.

**Diagnostic**

```bash
sudo kubeadm certs check-expiration
```

**Resolution**

```bash
# (root)
sudo kubeadm certs renew all
sudo systemctl restart kubelet

# refresh your admin kubeconfig too
sudo cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
kubectl get nodes
```

Static Pods pick up renewed certs when the kubelet restarts them; give it a minute.

---

## G. Platform-specific

### G1. WSL2 IP changed

**Symptoms** — after a Windows reboot or `wsl --shutdown`, `kubectl` reports connection refused to the old `172.x.x.x` address.

**Cause** — the WSL2 virtual machine gets a new IP on every start. The API server certificate was issued for the old one.

**Diagnostic**

```bash
# WSL Ubuntu
ip route get 1.1.1.1 | awk '{print $7; exit}'
grep server "$HOME/.kube/config"
```

**Resolution** — permanent fix:

```bash
# WSL Ubuntu
kubectl config set-cluster kubernetes --server=https://127.0.0.1:6443
kubectl get nodes
```

If you also get `x509: certificate is valid for ..., not <new-ip>`, regenerate the API server cert:

```bash
# WSL Ubuntu (root)
NEW_IP=$(ip route get 1.1.1.1 | awk '{print $7; exit}')
sudo rm -f /etc/kubernetes/pki/apiserver.crt /etc/kubernetes/pki/apiserver.key
sudo kubeadm init phase certs apiserver --apiserver-advertise-address="${NEW_IP}"
sudo systemctl restart kubelet
sudo kubeadm init phase kubeconfig admin
sudo cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
```

Cluster data (etcd) is untouched — workloads survive.

---

### G2. Windows cannot access NodePort

**Symptoms** — `curl http://localhost:30080` works inside WSL, but the Windows browser or PowerShell cannot reach it.

**Cause** — WSL localhost forwarding is disabled, the service is bound to `127.0.0.1` only, or Windows Firewall is blocking.

**Diagnostic**

```bash
# WSL Ubuntu
curl -s http://localhost:30080 | head -3        # works? then it is a Windows-side issue
ss -tlnp | grep 30080                            # check the bind address
```

```powershell
# PowerShell
Get-Content "$env:USERPROFILE\.wslconfig"
wsl hostname -I
```

**Resolution**

1. Ensure `.wslconfig` has `localhostForwarding=true` under `[wsl2]`, then `wsl --shutdown`.
2. Use `kubectl port-forward --address 0.0.0.0 svc/web 8080:80` — the `--address 0.0.0.0` matters; bound to the default `127.0.0.1` it will not be forwarded.
3. Or address the WSL IP directly:

```powershell
# PowerShell
$wslIp = (wsl hostname -I).Trim().Split()[0]
curl.exe "http://${wslIp}:30080"
```

4. To reach it from another device on your LAN, add a port proxy (needs re-adding after each WSL restart):

```powershell
# PowerShell (Administrator)
$wslIp = (wsl hostname -I).Trim().Split()[0]
netsh interface portproxy add v4tov4 listenport=30080 listenaddress=0.0.0.0 connectport=30080 connectaddress=$wslIp
New-NetFirewallRule -DisplayName "WSL k8s NodePort 30080" -Direction Inbound -LocalPort 30080 -Protocol TCP -Action Allow
```

---

### G3. VM port inaccessible from macOS

**Symptoms** — `curl http://<VM_IP>:30080` from macOS times out, though it works inside the VM.

**Cause** — the VM tool uses NAT without port forwarding, or macOS has no route to the VM's network.

**Diagnostic**

```bash
# Ubuntu VM
curl -s http://localhost:30080 | head -3        # confirm the app itself works
ip -4 addr show
```

```bash
# macOS Terminal
multipass list                                   # is it running, and what IP?
ping -c2 <VM_IP>
netstat -rn | grep 192.168.64                    # is there a route?
```

**Resolution**

| VM tool | Fix |
|---|---|
| **Multipass** | The IP should be directly reachable. If not, restart the VM (`multipass restart k8s-single`) or use SSH forwarding below. |
| **VMware Fusion / Parallels / UTM (NAT)** | Add a port-forwarding rule in the tool's network settings: host `8080` → guest `30080` |
| **Any tool** | SSH forwarding always works: `ssh -N -L 8080:localhost:30080 ubuntu@<VM_IP>`, then `curl http://localhost:8080` |
| **Bridged networking** | The VM is on your LAN — use its LAN IP directly |

---

### G4. EC2-specific access problems

| Symptom | Cause | Diagnostic | Fix |
|---|---|---|---|
| SSH times out | Security group missing port 22 for your IP, or your ISP IP changed | `curl -s https://checkip.amazonaws.com` and compare to the SG rule | Update the inbound rule to your current `/32` |
| `kubectl` from laptop times out | No port-6443 rule | Check the SG in the console | Add 6443 from your IP, or use SSH port forwarding instead |
| `x509: certificate is valid for 172.31.x.x, not <PUBLIC_IP>` | Public IP not in the cert SANs | `sudo kubeadm certs check-expiration` | `sudo kubeadm init phase certs apiserver --apiserver-cert-extra-sans=<PUBLIC_IP>` after deleting `apiserver.crt`/`apiserver.key`, then restart the kubelet |
| Everything breaks after an instance restart | Public IP changed (no Elastic IP) | `aws ec2 describe-instances` | Fetch the new IP; or use loopback in kubeconfig and SSH forwarding |
| LoadBalancer Service stuck `<pending>` | No cloud controller manager on a plain kubeadm cluster | `kubectl get svc -A \| grep pending` | Expected. Use NodePort or `port-forward`. `LoadBalancer` only works where a controller fulfils it (EKS, or MetalLB on bare metal). |
| Disk full, Pods evicted | Images and logs filled 30 GB | `df -h /` | `sudo crictl rmi --prune`; grow the EBS volume |

---

### G5. Corporate proxy

**Symptoms** — image pulls and `apt-get` time out; `kubeadm config images pull` hangs.

**Diagnostic**

```bash
env | grep -i proxy
sudo systemctl show containerd --property=Environment
curl -sSI https://registry.k8s.io/v2/ | head -1
```

**Resolution** — containerd needs the proxy in its **systemd** environment; a shell variable is not enough:

```bash
# (root)
sudo mkdir -p /etc/systemd/system/containerd.service.d
cat <<'EOF' | sudo tee /etc/systemd/system/containerd.service.d/http-proxy.conf
[Service]
Environment="HTTP_PROXY=http://<PROXY_HOST>:<PORT>"
Environment="HTTPS_PROXY=http://<PROXY_HOST>:<PORT>"
Environment="NO_PROXY=localhost,127.0.0.1,10.96.0.0/12,192.168.0.0/16,.svc,.cluster.local"
EOF

sudo systemctl daemon-reload
sudo systemctl restart containerd
```

`NO_PROXY` **must** include your Service CIDR (`10.96.0.0/12`), your Pod CIDR, and `.svc,.cluster.local` — otherwise in-cluster traffic gets sent to the proxy and fails.

---

## H. Certificates

### H1. Certificate errors

**Symptoms**

```text
x509: certificate is valid for 10.96.0.1, 172.31.24.118, not 54.12.34.56
x509: certificate signed by unknown authority
x509: certificate has expired or is not yet valid
```

**Cause and fix:**

| Message | Cause | Fix |
|---|---|---|
| `valid for ..., not <IP>` | You are connecting on an address that is not in the certificate's SANs | Regenerate with that address added (below) |
| `signed by unknown authority` | Your kubeconfig has the wrong CA — usually a stale copy from a previous cluster | Re-copy `/etc/kubernetes/admin.conf` |
| `has expired` | Certificates older than a year | [F3](#f3-certificate-expired) |

**Diagnostic**

```bash
sudo kubeadm certs check-expiration
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text | grep -A2 "Subject Alternative Name"
```

**Resolution — add an address to the API server certificate:**

```bash
# (root)
sudo rm -f /etc/kubernetes/pki/apiserver.crt /etc/kubernetes/pki/apiserver.key
sudo kubeadm init phase certs apiserver \
  --apiserver-advertise-address=<NODE_IP> \
  --apiserver-cert-extra-sans=<EXTRA_IP_OR_DNS>

sudo systemctl restart kubelet     # restarts the API server static Pod

sudo kubeadm init phase kubeconfig admin
sudo cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
kubectl get nodes
```

Only the API server certificate is regenerated; the CA and etcd data are untouched, so your workloads survive.

---

## When nothing works — full reset

> [!CAUTION]
> 🔴 **DESTRUCTIVE.** Destroys the cluster and all etcd data. Sometimes it is genuinely faster than debugging.

```bash
# (root)  🔴 DESTRUCTIVE
sudo kubeadm reset -f --cri-socket=unix:///run/containerd/containerd.sock

sudo rm -rf /etc/cni/net.d /var/lib/cni/
sudo rm -rf /opt/cni/bin/calico*
rm -rf "$HOME/.kube"

ip link show | grep -E 'cali|tunl|vxlan|cni0'
# for each interface found:
#   sudo ip link delete <INTERFACE_NAME>

sudo systemctl restart containerd
sudo reboot        # simplest way to clear all iptables rules
```

Then re-run `kubeadm init` from your platform's page:
[local-linux.md](./local-linux.md) · [wsl2.md](./wsl2.md) · [macos-ubuntu-vm.md](./macos-ubuntu-vm.md) · [single-ec2.md](./single-ec2.md)

---

## Official documentation

- kubeadm troubleshooting — <https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/troubleshooting-kubeadm/>
- Debugging Pods — <https://kubernetes.io/docs/tasks/debug/debug-application/debug-pods/>
- Debugging clusters — <https://kubernetes.io/docs/tasks/debug/debug-cluster/>
- Debugging DNS — <https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/>
- Certificate management — <https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/>
- `crictl` user guide — <https://kubernetes.io/docs/tasks/debug/debug-cluster/crictl/>
