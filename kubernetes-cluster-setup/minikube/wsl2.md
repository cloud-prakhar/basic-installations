# Minikube — Single-Node Cluster on Windows with WSL2

Run one Kubernetes node inside your Ubuntu WSL2 distribution, driven from the WSL shell, reachable from Windows.

Commands are marked:

- `# WSL Ubuntu` — inside your Ubuntu WSL2 distribution
- `# PowerShell` — a normal Windows PowerShell window
- `# PowerShell (Administrator)` — elevated

Validated **2026-08-05** on Windows 11 24H2, Ubuntu 24.04 (WSL2), Minikube **v1.38.1**, Kubernetes **1.36**. Time: 20–25 minutes. Cost: free.

> [!NOTE]
> Minikube in WSL2 is easier than kubeadm in WSL2 — you do **not** need systemd if you use Docker Desktop's WSL integration, and Minikube handles the cluster networking for you. WSL1 is not supported.

---

## Contents

1. [Requirements](#1-requirements)
2. [Choose your Docker setup](#2-choose-your-docker-setup)
3. [Install prerequisites](#3-install-prerequisites)
4. [Start the single-node cluster](#4-start-the-single-node-cluster)
5. [Verify the cluster](#5-verify-the-cluster)
6. [Enable add-ons](#6-enable-add-ons)
7. [Deploy the sample application](#7-deploy-the-sample-application)
8. [Access the application from WSL and Windows](#8-access-the-application-from-wsl-and-windows)
9. [Local image workflow](#9-local-image-workflow)
10. [Cluster lifecycle](#10-cluster-lifecycle)
11. [Troubleshooting](#11-troubleshooting)
12. [Cleanup](#12-cleanup)

---

## 1. Requirements

| Resource | Minimum (available to WSL2) | Recommended |
|----------|--------:|------------:|
| CPU | 2 cores | 4 cores |
| Memory | 4 GB | 6–8 GB |
| Disk on `C:` | 20 GB free | 30–40 GB free |
| Nodes | 1 | 1 |

**Confirm you are on WSL2, not WSL1:**

```powershell
# PowerShell
wsl --list --verbose
wsl --version
```

**Expected output:**

```text
  NAME            STATE           VERSION
* Ubuntu-24.04    Running         2
```

`VERSION` must be `2`. If it is `1`:

```powershell
# PowerShell (Administrator)
wsl --shutdown
wsl --set-version Ubuntu-24.04 2
wsl --set-default-version 2
```

**Allocate resources to WSL2** — create or edit `%USERPROFILE%\.wslconfig`:

```powershell
# PowerShell
notepad "$env:USERPROFILE\.wslconfig"
```

```ini
[wsl2]
memory=6GB
processors=4
localhostForwarding=true
```

`localhostForwarding=true` is what lets Windows reach WSL-bound ports via `localhost` — you want it for §8.

Apply:

```powershell
# PowerShell
wsl --shutdown
```

✅ **Verify inside WSL:**

```bash
# WSL Ubuntu
nproc
free -h
```

`nproc` must be ≥ 2, memory ≥ 4 GB.

---

## 2. Choose your Docker setup

Minikube's `docker` driver needs a Docker daemon reachable from WSL. Two ways:

| Option | How | Choose it when |
|---|---|---|
| **A — Docker Desktop WSL integration** ⭐ | Docker Desktop runs on Windows; WSL gets a `docker` CLI wired to it | You already have (or want) Docker Desktop. Simplest, no systemd needed. |
| **B — Docker Engine inside WSL** | Install `docker-ce` directly in Ubuntu | You do not want Docker Desktop (licensing, preference). Requires systemd in WSL. |

Both work. This page covers A as the default and B in §3.2b.

---

## 3. Install prerequisites

### 3.1a Option A — Docker Desktop with WSL integration

1. Install Docker Desktop from <https://www.docker.com/products/docker-desktop/>
2. Docker Desktop → **Settings → General** → tick **Use the WSL 2 based engine**
3. Docker Desktop → **Settings → Resources → WSL Integration** → tick **Ubuntu-24.04**
4. **Apply & restart**

✅ **Verify from inside WSL:**

```bash
# WSL Ubuntu
docker version
docker run --rm hello-world
```

**Expected output:** both `Client:` and `Server:` sections, then `Hello from Docker!`.

If you get `Cannot connect to the Docker daemon`, the WSL integration toggle for this distro is off, or Docker Desktop is not running.

**Give Docker enough resources:** Docker Desktop → Settings → Resources → **4 CPUs**, **6 GB**.

### 3.2b Option B — Docker Engine inside WSL (no Docker Desktop)

Needs systemd in WSL so `dockerd` runs as a service.

**Enable systemd:**

```bash
# WSL Ubuntu (root)
sudo tee /etc/wsl.conf > /dev/null <<'EOF'
[boot]
systemd=true
EOF
```

```powershell
# PowerShell
wsl --shutdown
```

Reopen Ubuntu and confirm:

```bash
# WSL Ubuntu
ps -p 1 -o comm=
```

**Expected output:** `systemd`

**Install Docker Engine:**

```bash
# WSL Ubuntu (root)
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg

sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin

sudo systemctl enable --now docker
```

**Let your user run Docker without `sudo`:**

**What:** add yourself to the `docker` group.
**Why:** Minikube must talk to the Docker socket as your user. Running `minikube` with `sudo` creates root-owned config that then fails for your normal user.

```bash
# WSL Ubuntu
sudo usermod -aG docker "$USER"
newgrp docker          # apply in this shell without logging out
```

✅ **Verify:**

```bash
# WSL Ubuntu
docker version
docker run --rm hello-world
groups | grep docker
```

> [!CAUTION]
> Membership of the `docker` group is equivalent to root on that machine — any user in it can mount the host filesystem into a container. Acceptable on a personal dev box; do not do it on a shared machine.

### 3.3 Install kubectl

```bash
# WSL Ubuntu
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm kubectl
kubectl version --client
```

**Expected output:**

```text
Client Version: v1.36.1
Kustomize Version: v5.x.x
```

Optionally verify the download first:

```bash
# WSL Ubuntu
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl.sha256"
echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
```

### 3.4 Install Minikube

```bash
# WSL Ubuntu
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube
rm minikube-linux-amd64
minikube version
```

**Expected output:**

```text
minikube version: v1.38.1
commit: <sha>
```

---

## 4. Start the single-node cluster

```bash
# WSL Ubuntu
minikube start \
  --driver=docker \
  --cpus=4 \
  --memory=6g \
  --disk-size=30g \
  --profile=demo
```

| Flag | Meaning |
|---|---|
| `--driver=docker` | The node is a Docker container. The only sensible driver in WSL2 — VM drivers need nested virtualization, which WSL2 does not offer. |
| `--cpus=4` | **Minimum 2.** Cannot exceed what WSL2 has (`nproc`). |
| `--memory=6g` | Minimum ~1.8 GB. Cannot exceed WSL2's allocation. |
| `--disk-size=30g` | Node disk for images and etcd. |
| `--profile=demo` | Names the cluster. Later commands take `-p demo`. |

Useful extras: `--kubernetes-version=v1.36.1` to pin a version, `--addons=ingress,metrics-server` to enable add-ons at start.

> [!WARNING]
> Do **not** use `--nodes=2` or higher — this guide is single-node.
>
> Do **not** run `minikube start` with `sudo`. It writes root-owned files to `~/.minikube` and `~/.kube`, and every later command as your normal user fails with permission errors.

**Expected output:**

```text
* [demo] minikube v1.38.1 on Ubuntu 24.04 (amd64)
* Using the docker driver based on user configuration
* Starting "demo" primary control-plane node in "demo" cluster
* Pulling base image v0.0.48 ...
* Creating docker container (CPUs=4, Memory=6144MB) ...
* Preparing Kubernetes v1.36.1 on Docker 28.x ...
* Configuring bridge CNI (Container Networking Interface) ...
* Verifying Kubernetes components...
* Enabled addons: storage-provisioner, default-storageclass
* Done! kubectl is now configured to use "demo" cluster and "default" namespace by default
```

2–5 minutes on first run; ~30 seconds afterwards.

---

## 5. Verify the cluster

```bash
# WSL Ubuntu
minikube status -p demo
kubectl get nodes -o wide
kubectl get pods -A
kubectl config current-context
minikube ip -p demo
docker ps --filter "name=demo"
kubectl cluster-info
```

**Expected output:**

```text
demo
type: Control Plane
host: Running
kubelet: Running
apiserver: Running
kubeconfig: Configured

NAME   STATUS   ROLES           AGE   VERSION   INTERNAL-IP    CONTAINER-RUNTIME
demo   Ready    control-plane   2m    v1.36.1   192.168.49.2   docker://28.x.x

NAMESPACE     NAME                           READY   STATUS    RESTARTS   AGE
kube-system   coredns-...                    1/1     Running   0          2m
kube-system   etcd-demo                      1/1     Running   0          2m
kube-system   kube-apiserver-demo            1/1     Running   0          2m
kube-system   kube-controller-manager-demo   1/1     Running   0          2m
kube-system   kube-proxy-...                 1/1     Running   0          2m
kube-system   kube-scheduler-demo            1/1     Running   0          2m
kube-system   storage-provisioner            1/1     Running   0          2m

demo
192.168.49.2
```

```text
One Kubernetes node in Ready status
```

> [!IMPORTANT]
> **Check `kubectl config current-context` says `demo`.** If Docker Desktop's Kubernetes is enabled, your context may be `docker-desktop` — a completely different cluster. Fix with `kubectl config use-context demo`.

Minikube does **not** taint the node, so Pods schedule immediately.

---

## 6. Enable add-ons

```bash
# WSL Ubuntu
minikube addons list -p demo
```

`storage-provisioner` and `default-storageclass` are on by default — you get working PersistentVolumeClaims out of the box.

> [!TIP]
> Enable only what you need. Each add-on consumes CPU and memory on your single node.

### Ingress

```bash
# WSL Ubuntu
minikube addons enable ingress -p demo
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=180s
kubectl get pods -n ingress-nginx
```

**Expected output:** `ingress-nginx-controller-...` `1/1 Running`, plus two `Completed` admission Jobs (expected — they install the webhook and exit).

### Metrics Server

```bash
# WSL Ubuntu
minikube addons enable metrics-server -p demo
sleep 45
kubectl top nodes
kubectl top pods -A
```

**Expected output:**

```text
NAME   CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
demo   240m         6%       1420Mi          23%
```

`Metrics API not available` right after enabling just means it has not scraped yet.

### Dashboard

```bash
# WSL Ubuntu
minikube addons enable dashboard -p demo
minikube dashboard --url -p demo
```

Use `--url` in WSL: without it Minikube tries to launch a Linux browser that does not exist. Copy the printed URL — but note it binds to `127.0.0.1` inside WSL, so to open it from Windows use:

```bash
# WSL Ubuntu — leave running
kubectl -n kubernetes-dashboard port-forward --address 0.0.0.0 svc/kubernetes-dashboard 8443:80
```

Then browse <http://localhost:8443> from Windows.

### Storage

```bash
# WSL Ubuntu
kubectl get storageclass
```

**Expected output:**

```text
NAME                 PROVISIONER                RECLAIMPOLICY   VOLUMEBINDINGMODE   AGE
standard (default)   k8s.io/minikube-hostpath   Delete          Immediate           5m
```

### Registry (optional)

```bash
# WSL Ubuntu
minikube addons enable registry -p demo
```

Not needed for the local-image workflow in §9 — `minikube image load` is simpler.

### Disable

```bash
# WSL Ubuntu
minikube addons disable dashboard -p demo
```

---

## 7. Deploy the sample application

```bash
# WSL Ubuntu
cd kubernetes-cluster-setup/minikube
kubectl apply -f manifests/00-namespace.yaml
kubectl apply -f manifests/10-deployment.yaml
kubectl apply -f manifests/20-service.yaml
```

Ingress only if you enabled the add-on:

```bash
# WSL Ubuntu
kubectl apply -f manifests/30-ingress.yaml
```

```bash
# WSL Ubuntu
kubectl -n demo rollout status deployment/web --timeout=180s
kubectl -n demo get all -o wide
```

**Expected output:**

```text
NAME                      READY   STATUS    RESTARTS   AGE   IP           NODE
pod/web-6c9d8f7b4-abcde   1/1     Running   0          30s   10.244.0.5   demo
pod/web-6c9d8f7b4-fghij   1/1     Running   0          30s   10.244.0.6   demo

NAME                   TYPE        CLUSTER-IP      PORT(S)        AGE
service/web            ClusterIP   10.104.22.180   80/TCP         30s
service/web-nodeport   NodePort    10.108.11.4     80:30080/TCP   30s

NAME                  READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/web   2/2     2            2           30s
```

**Both replicas on one node is expected.** `replicas: 2` means two Pods, not two machines — real ReplicaSet behaviour, no node-failure tolerance.

---

## 8. Access the application from WSL and Windows

There are two hops to think about: WSL → the Minikube node, and Windows → WSL.

### Method 1 — `kubectl port-forward` (recommended for WSL2)

```bash
# WSL Ubuntu — leave running
kubectl -n demo port-forward --address 0.0.0.0 svc/web 8080:80
```

> [!IMPORTANT]
> `--address 0.0.0.0` is required. Bound to the default `127.0.0.1`, WSL's localhost forwarding will not relay it and Windows sees nothing.

From WSL:

```bash
# WSL Ubuntu (second shell)
curl -s http://localhost:8080 | head -5
```

From Windows:

```powershell
# PowerShell
curl.exe http://localhost:8080
Start-Process "http://localhost:8080"
```

This works because of `localhostForwarding=true` in `.wslconfig`.

### Method 2 — NodePort from inside WSL

```bash
# WSL Ubuntu
minikube ip -p demo
curl -s "http://$(minikube ip -p demo):30080" | head -5
```

Works **inside WSL** — the Docker bridge network is reachable there. It does **not** work from Windows: `192.168.49.2` lives on WSL's Docker bridge, which Windows has no route to.

### Method 3 — `minikube service`

```bash
# WSL Ubuntu
minikube service web-nodeport -n demo -p demo --url
```

**Expected output:**

```text
http://192.168.49.2:30080
```

Always use `--url` in WSL. Without it, Minikube tries to launch a browser inside Linux, and you get:

```text
X Exiting due to HOST_BROWSER: failed to open browser: exec: "xdg-open": executable file not found in $PATH
```

To open that URL from Windows, use Method 1 instead — or configure WSL to use the Windows browser:

```bash
# WSL Ubuntu
export BROWSER=wslview                    # requires: sudo apt-get install -y wslu
minikube service web-nodeport -n demo -p demo
```

### Method 4 — Ingress

```bash
# WSL Ubuntu
kubectl -n demo get ingress
```

**Expected output:**

```text
NAME   CLASS   HOSTS        ADDRESS        PORTS   AGE
web    nginx   demo.local   192.168.49.2   80      2m
```

**From WSL** — add to the **Linux hosts file, `/etc/hosts`**:

```bash
# WSL Ubuntu (root)
echo "$(minikube ip -p demo) demo.local" | sudo tee -a /etc/hosts
curl -s http://demo.local | head -5
```

> [!NOTE]
> WSL regenerates `/etc/hosts` on every start. To keep the entry, add `[network] generateHosts = false` to `/etc/wsl.conf` and run `wsl --shutdown`.

**From Windows** — the Minikube IP is not routable from Windows, so a **Windows hosts file** entry pointing at `192.168.49.2` will not work. Instead, port-forward the ingress controller and point `demo.local` at `127.0.0.1`:

```bash
# WSL Ubuntu — leave running
kubectl -n ingress-nginx port-forward --address 0.0.0.0 svc/ingress-nginx-controller 8080:80
```

```powershell
# PowerShell (Administrator) — Windows hosts file
Add-Content -Path "$env:WINDIR\System32\drivers\etc\hosts" -Value "127.0.0.1 demo.local"
```

```powershell
# PowerShell
curl.exe http://demo.local:8080
```

For reference, the hosts file path on each platform: Windows `C:\Windows\System32\drivers\etc\hosts` · Linux/WSL `/etc/hosts` · macOS `/etc/hosts`.

### Method 5 — `minikube tunnel`

**What:** routes host traffic into the cluster and assigns external IPs to `LoadBalancer` Services.
**Why:** without it, a `type: LoadBalancer` Service stays `<pending>` forever — there is no cloud provider to fulfil it.

```bash
# WSL Ubuntu — leave running; asks for sudo to create routes
minikube tunnel -p demo
```

```bash
# WSL Ubuntu (second shell)
kubectl -n demo expose deployment web --type=LoadBalancer --name=web-lb --port=80
kubectl -n demo get svc web-lb
curl -s "http://$(kubectl -n demo get svc web-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}')" | head -5
```

The assigned IP is reachable from **WSL only**. For Windows, layer `kubectl port-forward` on top.

Clean up: `kubectl -n demo delete svc web-lb`, then `Ctrl+C` the tunnel.

### Comparison

| Method | Works in WSL | Works from Windows | Notes |
|---|---|---|---|
| `port-forward --address 0.0.0.0` | ✅ | ✅ | **Best for WSL2** |
| NodePort via minikube IP | ✅ | ❌ | Docker bridge is WSL-internal |
| `minikube service --url` | ✅ | ❌ (URL is WSL-only) | Add `port-forward` for Windows |
| Ingress + `/etc/hosts` | ✅ | ⚠️ needs port-forward | |
| `minikube tunnel` | ✅ | ⚠️ needs port-forward | Only way to test LoadBalancer |

---

## 9. Local image workflow

Build in WSL, run in the cluster, no registry needed.

### 9.1 Build

```bash
# WSL Ubuntu
mkdir -p ~/demo-app && cd ~/demo-app

cat > Dockerfile <<'EOF'
FROM nginx:1.30-alpine
RUN echo '<h1>Hello from my local image</h1>' > /usr/share/nginx/html/index.html
EOF

docker build -t my-web:v1 .
docker images my-web
```

**Expected output:**

```text
REPOSITORY   TAG   IMAGE ID       CREATED         SIZE
my-web       v1    a1b2c3d4e5f6   2 seconds ago   52.5MB
```

### 9.2 Load into Minikube

The Minikube node has its **own** image store, separate from your WSL Docker daemon. Being in `docker images` does not make an image visible to the cluster.

```bash
# WSL Ubuntu
minikube image load my-web:v1 -p demo
minikube image ls -p demo | grep my-web
```

**Expected output:**

```text
docker.io/library/my-web:v1
```

### 9.3 Build directly inside Minikube

```bash
# WSL Ubuntu
minikube image build -t my-web:v2 . -p demo
minikube image ls -p demo | grep my-web
```

### 9.4 Point your Docker CLI at Minikube's daemon

```bash
# WSL Ubuntu
eval "$(minikube -p demo docker-env)"
docker build -t my-web:v3 .
docker images | grep my-web
```

Builds land straight in the node's store. Revert with:

```bash
# WSL Ubuntu
eval "$(minikube -p demo docker-env --unset)"
```

Only works when the node's runtime is Docker (Minikube's default).

### 9.5 Use it — `imagePullPolicy` matters

```bash
# WSL Ubuntu
kubectl -n demo set image deployment/web web=my-web:v1
kubectl -n demo rollout status deployment/web
kubectl -n demo port-forward --address 0.0.0.0 svc/web 8080:80
```

Browse <http://localhost:8080> from Windows — you should see *Hello from my local image*.

> [!IMPORTANT]
> The Deployment must use `imagePullPolicy: IfNotPresent` (or `Never`). With `Always`, the kubelet ignores the loaded copy and tries to pull from Docker Hub → `ErrImagePull`.
>
> Kubernetes also **defaults to `Always` for any `:latest` tag**. Never tag local images `:latest`. The provided `manifests/10-deployment.yaml` sets `IfNotPresent` explicitly.

Revert:

```bash
# WSL Ubuntu
kubectl -n demo set image deployment/web web=nginx:1.30-alpine
```

---

## 10. Cluster lifecycle

```bash
# WSL Ubuntu
minikube start -p demo          # start / restart
minikube stop -p demo           # shut down, keep all state
minikube pause -p demo          # freeze Kubernetes processes, free CPU
minikube unpause -p demo
minikube status -p demo

minikube logs -p demo
minikube logs -p demo --problems
minikube logs -p demo -f

minikube ssh -p demo            # shell inside the node
minikube profile list
minikube delete -p demo         # 🔴 destroys this cluster
minikube delete --all           # 🔴 destroys every profile
```

### Stop vs pause vs delete

| Command | Node | Data | Restart | Use when |
|---|---|---|---|---|
| `pause` | Frozen | In memory | Instant | Short break, need CPU back |
| `stop` | Shut down | On disk | ~30 s | End of day |
| `delete` | 🔴 Destroyed | 🔴 Gone | Full recreate | Finished, or starting clean |

> [!IMPORTANT]
> **WSL does not auto-start on Windows login.** After a Windows reboot, open Ubuntu, then `minikube start -p demo`. The cluster does not come back on its own.

---

## 11. Troubleshooting

Full matrix in **[troubleshooting.md](./troubleshooting.md)**. WSL2-specific issues:

| Symptom | Cause | Diagnostic | Fix |
|---|---|---|---|
| `Cannot connect to the Docker daemon at unix:///var/run/docker.sock` | Docker Desktop WSL integration off, or `dockerd` not running | `docker version` | Enable WSL integration for this distro; or Option B: `sudo systemctl start docker` |
| `permission denied while trying to connect to the Docker daemon socket` | Your user is not in the `docker` group | `groups \| grep docker` | `sudo usermod -aG docker $USER; newgrp docker` |
| `Exiting due to RSRC_INSUFFICIENT_CORES` | WSL2 has <2 CPUs | `nproc` | `processors=4` in `%USERPROFILE%\.wslconfig`, then `wsl --shutdown` |
| `Exiting due to RSRC_INSUFFICIENT_MEMORY` | WSL2 memory too low | `free -h` | `memory=6GB` in `.wslconfig`, `wsl --shutdown` |
| `xdg-open: executable file not found` | `minikube service`/`dashboard` trying to open a Linux browser | — | Add `--url`, or `sudo apt-get install -y wslu && export BROWSER=wslview` |
| Windows browser cannot reach the app | `port-forward` bound to `127.0.0.1` | `ss -tlnp \| grep 8080` | Use `--address 0.0.0.0` |
| Windows cannot reach `192.168.49.2` | Docker bridge is internal to WSL | `curl` works in WSL but not Windows | Use `port-forward` — this is by design |
| `localhost` from Windows does not reach WSL | `localhostForwarding` off | Check `.wslconfig` | Set `localhostForwarding=true`, `wsl --shutdown` |
| Cluster gone after Windows reboot | WSL does not auto-start | `minikube status -p demo` | Open Ubuntu, `minikube start -p demo` |
| `/etc/hosts` entry disappears | WSL regenerates it | `cat /etc/hosts` | `[network] generateHosts = false` in `/etc/wsl.conf`, `wsl --shutdown` |
| Wrong `kubectl` context | Docker Desktop Kubernetes also enabled | `kubectl config current-context` | `kubectl config use-context demo` |
| `ErrImagePull` for a local image | Not loaded, or `imagePullPolicy: Always` | `minikube image ls -p demo \| grep <name>` | `minikube image load`; use `IfNotPresent`; avoid `:latest` |
| Everything is root-owned and broken | You ran `minikube start` with `sudo` | `ls -la ~/.minikube ~/.kube` | `sudo rm -rf ~/.minikube ~/.kube` and start again without `sudo` |
| Downloads fail behind a corporate proxy | Proxy not set | `env \| grep -i proxy` | Export `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY`, and pass `--docker-env HTTP_PROXY=...` to `minikube start` |

**Diagnostics:**

```bash
# WSL Ubuntu
minikube status -p demo
minikube logs -p demo --problems
kubectl get events -A --sort-by=.lastTimestamp | tail -20
docker ps -a --filter "name=demo"
kubectl config current-context
nproc; free -h
```

```powershell
# PowerShell
wsl --list --verbose
Get-Content "$env:USERPROFILE\.wslconfig"
```

---

## 12. Cleanup

### Delete just the application

```bash
# WSL Ubuntu
kubectl delete namespace demo
```

### Stop the cluster (keep everything)

```bash
# WSL Ubuntu
minikube stop -p demo
```

### Delete the cluster

> [!CAUTION]
> 🔴 **DESTRUCTIVE** — destroys the node and all cluster data, including PersistentVolumes.

```bash
# WSL Ubuntu
minikube delete -p demo
minikube profile list
docker ps -a --filter "name=demo"      # should be empty
```

### Delete everything Minikube created

```bash
# WSL Ubuntu  🔴 DESTRUCTIVE
minikube delete --all --purge
rm -rf ~/.minikube
```

`--purge` also removes cached base images (often several GB).

### Reclaim Docker space

```bash
# WSL Ubuntu
docker system df
docker system prune -a       # 🔴 removes ALL unused images, not just Minikube's
```

### Remove hosts entries

```bash
# WSL Ubuntu
sudo sed -i '/demo.local/d' /etc/hosts
```

```powershell
# PowerShell (Administrator)
$path = "$env:WINDIR\System32\drivers\etc\hosts"
(Get-Content $path) | Where-Object { $_ -notmatch "demo.local" } | Set-Content $path
```

### Reclaim WSL disk space

The WSL virtual disk grows but never shrinks on its own:

```powershell
# PowerShell (Administrator)
wsl --shutdown
Optimize-VHD -Path "$env:LOCALAPPDATA\Packages\<distro-package>\LocalState\ext4.vhdx" -Mode Full
```

(`Optimize-VHD` requires the Hyper-V module. Newer WSL builds also support `wsl --manage <distro> --resize`.)

---

## Official documentation

- Minikube start — <https://minikube.sigs.k8s.io/docs/start/>
- Drivers — <https://minikube.sigs.k8s.io/docs/drivers/docker/>
- Accessing apps — <https://minikube.sigs.k8s.io/docs/handbook/accessing/>
- Pushing images — <https://minikube.sigs.k8s.io/docs/handbook/pushing/>
- Docker Desktop WSL backend — <https://docs.docker.com/desktop/wsl/>
- WSL configuration — <https://learn.microsoft.com/en-us/windows/wsl/wsl-config>
- Install kubectl on Linux — <https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/>
