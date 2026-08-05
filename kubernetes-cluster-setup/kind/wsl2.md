# Kind — Single-Node Cluster on Windows with WSL2

Run one Kubernetes node — a Docker container — inside your Ubuntu WSL2 distribution.

Commands are marked:

- `# WSL Ubuntu` — inside your Ubuntu WSL2 distribution
- `# PowerShell` — a normal Windows PowerShell window
- `# PowerShell (Administrator)` — elevated

Validated **2026-08-05** on Windows 11 24H2, Ubuntu 24.04 (WSL2), Kind **v0.32.0**, node image `kindest/node:v1.36.1`, Kubernetes **1.36**. Time: 10–15 minutes. Cost: free.

> [!NOTE]
> WSL2 is arguably the **best** Windows environment for Kind: you get Linux tooling, `kind load` is fast, and WSL's localhost forwarding means Windows can reach mapped ports directly. WSL1 will not work.

---

## Contents

1. [Requirements](#1-requirements)
2. [Install prerequisites](#2-install-prerequisites)
3. [Create a basic single-node cluster](#3-create-a-basic-single-node-cluster)
4. [Create a cluster with port mapping](#4-create-a-cluster-with-port-mapping)
5. [Deploy the sample application](#5-deploy-the-sample-application)
6. [Install an ingress controller](#6-install-an-ingress-controller)
7. [Load a local image](#7-load-a-local-image)
8. [Cluster lifecycle](#8-cluster-lifecycle)
9. [Troubleshooting](#9-troubleshooting)
10. [Cleanup](#10-cleanup)

---

## 1. Requirements

| Resource | Minimum (available to WSL2) | Recommended |
|----------|--------:|------------:|
| CPU | 2 cores | 4 cores |
| Memory | 4 GB | 6–8 GB |
| Disk on `C:` | 15 GB free | 25–30 GB free |
| Nodes | 1 | 1 |

**Confirm WSL2, not WSL1:**

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

**Allocate resources** — create or edit `%USERPROFILE%\.wslconfig`:

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

`localhostForwarding=true` is what lets Windows reach WSL-bound ports at `localhost` — essential for §5 and §6.

```powershell
# PowerShell
wsl --shutdown
```

✅ **Verify in WSL:**

```bash
# WSL Ubuntu
nproc
free -h
```

---

## 2. Install prerequisites

### 2.1 Docker — pick one

**Option A — Docker Desktop with WSL integration (simplest):**

1. Install Docker Desktop from <https://www.docker.com/products/docker-desktop/>
2. Settings → **General** → tick **Use the WSL 2 based engine**
3. Settings → **Resources → WSL Integration** → tick **Ubuntu-24.04**
4. **Apply & restart**
5. Settings → **Resources** → at least **4 CPUs**, **6 GB** memory

**Option B — Docker Engine inside WSL (no Docker Desktop):**

Needs systemd:

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

Reopen Ubuntu, confirm `ps -p 1 -o comm=` prints `systemd`, then:

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

sudo usermod -aG docker "$USER"
newgrp docker
```

✅ **Verify (either option):**

```bash
# WSL Ubuntu
docker version
docker run --rm hello-world
```

**Expected output:** both `Client:` and `Server:` sections, then `Hello from Docker!`.

> [!CAUTION]
> The `docker` group is effectively root on that machine. Fine on a personal dev box.

### 2.2 kubectl

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

### 2.3 Kind

```bash
# WSL Ubuntu
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.32.0/kind-linux-amd64
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind
kind version
```

**Expected output:**

```text
kind v0.32.0 go1.25.x linux/amd64
```

Check the current release at <https://github.com/kubernetes-sigs/kind/releases>.

---

## 3. Create a basic single-node cluster

### 3.1 One command

```bash
# WSL Ubuntu
kind create cluster --name demo
```

Kind pulls the node image, starts one container named `demo-control-plane`, runs `kubeadm init` inside it, installs its own CNI (kindnet), **removes the control-plane taint**, and writes a `kind-demo` context into `~/.kube/config`.

**Expected output:**

```text
Creating cluster "demo" ...
 ✓ Ensuring node image (kindest/node:v1.36.1) 🖼
 ✓ Preparing nodes 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing CNI 🔌
 ✓ Installing StorageClass 💾
Set kubectl context to "kind-demo"
```

First run 1–3 minutes; afterwards 30–60 seconds.

### 3.2 Optionally pin the Kubernetes version

```bash
# WSL Ubuntu
kind create cluster --name demo \
  --image kindest/node:v1.36.1@sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5
```

> [!IMPORTANT]
> Node images are built **per Kind release**. Take the `@sha256` digest from the release notes of *your* Kind version. Omitting `--image` and using Kind's default is safest.

### 3.3 Verify

```bash
# WSL Ubuntu
kubectl config current-context
kubectl cluster-info --context kind-demo
kubectl get nodes -o wide
kubectl get pods -A
docker ps --filter "name=demo-control-plane"
kind get clusters
```

**Expected output:**

```text
kind-demo

Kubernetes control plane is running at https://127.0.0.1:41523

NAME                 STATUS   ROLES           AGE   VERSION   INTERNAL-IP   CONTAINER-RUNTIME
demo-control-plane   Ready    control-plane   60s   v1.36.1   172.18.0.2    containerd://2.x.x

NAMESPACE            NAME                                         READY   STATUS    RESTARTS   AGE
kube-system          coredns-...                                  1/1     Running   0          60s
kube-system          etcd-demo-control-plane                      1/1     Running   0          60s
kube-system          kindnet-...                                  1/1     Running   0          60s
kube-system          kube-apiserver-demo-control-plane            1/1     Running   0          60s
kube-system          kube-controller-manager-demo-control-plane   1/1     Running   0          60s
kube-system          kube-proxy-...                               1/1     Running   0          60s
kube-system          kube-scheduler-demo-control-plane            1/1     Running   0          60s
local-path-storage   local-path-provisioner-...                   1/1     Running   0          60s
```

```text
One node named demo-control-plane
Status: Ready
```

**Notice:** `kindnet` (built-in CNI — no installation step) and `local-path-provisioner` (default StorageClass, so PVCs work immediately).

**Confirm the taint is gone:**

```bash
# WSL Ubuntu
kubectl describe node demo-control-plane | grep -i -A2 taints
```

**Expected output:** `Taints: <none>` — Kind removes it for you on a single-node cluster.

### 3.4 Look inside the node container

```bash
# WSL Ubuntu
docker exec -it demo-control-plane bash
```

Inside:

```bash
crictl ps
systemctl status kubelet
ls /etc/kubernetes/manifests/
exit
```

A Kind node really is a kubeadm node — just inside a container.

---

## 4. Create a cluster with port mapping

### 4.1 Why

Kind nodes sit on an internal Docker network. A NodePort listens **inside the container only**. `extraPortMappings` publishes container ports onto the WSL host — and because of `localhostForwarding`, onward to Windows.

> [!IMPORTANT]
> `extraPortMappings` **cannot be added to an existing cluster.** Decide your ports before creating. Recreating costs ~40 seconds.

### 4.2 The config file

Use [`kind-config.yaml`](./kind-config.yaml), or create it:

```bash
# WSL Ubuntu
cat > kind-config.yaml <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: demo
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
      - containerPort: 30080
        hostPort: 30080
        protocol: TCP
networking:
  apiServerAddress: "127.0.0.1"
EOF
```

> [!NOTE]
> `listenAddress` is deliberately **omitted** here (so it defaults to `0.0.0.0`). Inside WSL that is what lets Windows reach the port through localhost forwarding. Setting `listenAddress: "127.0.0.1"` restricts it to WSL only.

### 4.3 Every field explained

| Field | Meaning |
|---|---|
| `kind: Cluster` / `apiVersion: kind.x-k8s.io/v1alpha4` | Config kind and API version; `v1alpha4` is current |
| `name: demo` | Cluster name → container `demo-control-plane`, context `kind-demo` |
| `nodes:` | **One entry, `role: control-plane`.** No `role: worker`. |
| `kubeadmConfigPatches` | Kind bootstraps with kubeadm, so you can patch its config |
| `node-labels: "ingress-ready=true"` | **Required for ingress** — the ingress-nginx Kind manifest selects on this label; without it the controller stays `Pending` |
| `extraPortMappings` | Publishes container ports to the WSL host |
| `containerPort` / `hostPort` | Port inside the node / port on the WSL host |
| `protocol` | TCP or UDP |
| `listenAddress` | Bind address; defaults to `0.0.0.0`. `127.0.0.1` keeps it WSL-only |
| `networking.apiServerAddress` | Where the API server is published — keep it localhost |

### 4.4 Create

```bash
# WSL Ubuntu
kind delete cluster --name demo          # 🔴 removes the §3 cluster
kind create cluster --config kind-config.yaml
```

✅ **Verify:**

```bash
# WSL Ubuntu
docker port demo-control-plane
kubectl get nodes --show-labels | tr ',' '\n' | grep ingress-ready
```

**Expected output:**

```text
80/tcp -> 0.0.0.0:80
443/tcp -> 0.0.0.0:443
30080/tcp -> 0.0.0.0:30080
6443/tcp -> 127.0.0.1:41523
ingress-ready=true
```

---

## 5. Deploy the sample application

```bash
# WSL Ubuntu
cd kubernetes-cluster-setup/kind
kubectl apply -f manifests/00-namespace.yaml
kubectl apply -f manifests/10-deployment.yaml
kubectl apply -f manifests/20-service.yaml

kubectl -n demo rollout status deployment/web --timeout=180s
kubectl -n demo get all -o wide
```

**Expected output:**

```text
NAME                      READY   STATUS    RESTARTS   AGE   IP           NODE
pod/web-6c9d8f7b4-abcde   1/1     Running   0          20s   10.244.0.6   demo-control-plane
pod/web-6c9d8f7b4-fghij   1/1     Running   0          20s   10.244.0.7   demo-control-plane

NAME                   TYPE        CLUSTER-IP      PORT(S)        AGE
service/web            ClusterIP   10.96.140.22    80/TCP         20s
service/web-nodeport   NodePort    10.96.203.114   80:30080/TCP   20s

NAME                  READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/web   2/2     2            2           20s
```

**Both replicas on one node is expected** — `replicas: 2` means two Pods, not two machines.

### Access from WSL

```bash
# WSL Ubuntu
curl -s http://localhost:30080 | head -5
```

### Access from Windows

```powershell
# PowerShell
curl.exe http://localhost:30080
Start-Process "http://localhost:30080"
```

Two hops make this work: Kind publishes container `:30080` → WSL host `:30080` (`extraPortMappings`), then WSL's `localhostForwarding` relays Windows `localhost:30080` → WSL. Without either, you get `connection refused`.

### `kubectl port-forward` (works without any mapping)

```bash
# WSL Ubuntu — leave running
kubectl -n demo port-forward --address 0.0.0.0 svc/web 8080:80
```

> [!IMPORTANT]
> `--address 0.0.0.0` is required for Windows to see it. Bound to the default `127.0.0.1`, WSL's localhost forwarding will not relay it.

```powershell
# PowerShell
curl.exe http://localhost:8080
```

---

## 6. Install an ingress controller

### 6.1 Install

```bash
# WSL Ubuntu
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.15.1/deploy/static/provider/kind/deploy.yaml
```

The **Kind provider** manifest is built for this setup — hostPort binding plus the `ingress-ready` nodeSelector.

### 6.2 Wait

```bash
# WSL Ubuntu
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s

kubectl get pods -n ingress-nginx
```

**Expected output:**

```text
NAME                                        READY   STATUS      RESTARTS   AGE
ingress-nginx-admission-create-xxxxx        0/1     Completed   0          60s
ingress-nginx-admission-patch-xxxxx         0/1     Completed   0          60s
ingress-nginx-controller-xxxxxxxxx-xxxxx    1/1     Running     0          60s
```

The `Completed` Jobs installed the admission webhook and exited — expected.

> [!IMPORTANT]
> Controller `Pending`? Your node is missing `ingress-ready=true`. Check `kubectl get nodes --show-labels`, then recreate the cluster with the `kubeadmConfigPatches` block from §4.2.

### 6.3 Apply the Ingress and verify

```bash
# WSL Ubuntu
kubectl apply -f manifests/30-ingress.yaml
kubectl -n demo get ingress

curl -s -H "Host: demo.local" http://localhost | head -5
```

**Expected output:**

```text
NAME   CLASS   HOSTS        ADDRESS     PORTS   AGE
web    nginx   demo.local   localhost   80      30s
```

followed by the nginx welcome HTML. The `Host:` header trick avoids needing any hosts-file edit.

### 6.4 Hostname mapping

**From WSL — Linux hosts file `/etc/hosts`:**

```bash
# WSL Ubuntu (root)
echo "127.0.0.1 demo.local" | sudo tee -a /etc/hosts
curl -s http://demo.local | head -5
```

> [!NOTE]
> WSL regenerates `/etc/hosts` on every start. To keep it, add to `/etc/wsl.conf`:
> ```ini
> [network]
> generateHosts = false
> ```
> then `wsl --shutdown` from PowerShell.

**From Windows — `C:\Windows\System32\drivers\etc\hosts`** (Administrator):

```powershell
# PowerShell (Administrator)
Add-Content -Path "$env:WINDIR\System32\drivers\etc\hosts" -Value "127.0.0.1 demo.local"
```

```powershell
# PowerShell
curl.exe http://demo.local
Start-Process "http://demo.local"
```

**Hosts file paths:** Windows `C:\Windows\System32\drivers\etc\hosts` (Administrator) · Linux/WSL `/etc/hosts` (sudo) · macOS `/etc/hosts` (sudo).

---

## 7. Load a local image

### 7.1 Build

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

Note the exact `name:tag` — `kind load` matches on it exactly.

### 7.2 Load

```bash
# WSL Ubuntu
kind load docker-image my-web:v1 --name demo
```

Generic form:

```text
kind load docker-image <IMAGE_NAME> --name <CLUSTER_NAME>
```

### 7.3 Verify inside the node

```bash
# WSL Ubuntu
docker exec demo-control-plane crictl images | grep my-web
```

**Expected output:**

```text
docker.io/library/my-web    v1    a1b2c3d4e5f6   52.5MB
```

The node runs **containerd**, so `crictl` is the tool inside — not `docker`.

### 7.4 Redeploy

```bash
# WSL Ubuntu
kubectl -n demo set image deployment/web web=my-web:v1
kubectl -n demo rollout status deployment/web
curl -s http://localhost:30080
```

**Expected output:** `<h1>Hello from my local image</h1>`

> [!IMPORTANT]
> **`imagePullPolicy` must be `IfNotPresent` (or `Never`).** With `Always`, the kubelet ignores the loaded image and tries Docker Hub → `ErrImagePull`. Kubernetes also **defaults to `Always` for `:latest`** — never tag local images `:latest`. `manifests/10-deployment.yaml` sets `IfNotPresent` explicitly.

Revert:

```bash
# WSL Ubuntu
kubectl -n demo set image deployment/web web=nginx:1.30-alpine
```

---

## 8. Cluster lifecycle

```bash
# WSL Ubuntu
kind get clusters                              # list
kubectl config get-contexts                    # see all contexts
kubectl config use-context kind-demo           # switch
kind get kubeconfig --name demo                # print kubeconfig

kind export logs --name demo ./kind-logs       # dump logs for debugging
ls ./kind-logs

docker ps --filter "name=demo-control-plane"
docker exec -it demo-control-plane bash

kind delete cluster --name demo                # 🔴 destroy
kind delete clusters --all                     # 🔴 destroy all
kind create cluster --config kind-config.yaml  # recreate
```

> [!NOTE]
> **Kind has no stop/start.** A cluster is running or deleted. `docker stop`/`docker start` on the node container mostly works but is not a supported workflow — and since creation takes under a minute, delete-and-recreate is the normal pattern.
>
> **After a Windows reboot:** WSL does not auto-start, and Docker may not either. Open Ubuntu, ensure Docker is up, then `docker start demo-control-plane` — or just recreate the cluster.

**Remove unused node images:**

```bash
# WSL Ubuntu
docker images | grep kindest/node
docker ps --format "{{.Image}}"          # what is in use — do not delete this
docker rmi kindest/node:<OLD_VERSION>
```

---

## 9. Troubleshooting

Full matrix in **[troubleshooting.md](./troubleshooting.md)**. WSL2-specific:

| Symptom | Cause | Diagnostic | Fix |
|---|---|---|---|
| `Cannot connect to the Docker daemon` | WSL integration off, or `dockerd` not running | `docker version` | Enable Docker Desktop → Resources → WSL Integration for this distro; or `sudo systemctl start docker` |
| `permission denied ... docker.sock` | Not in the `docker` group | `groups \| grep docker` | `sudo usermod -aG docker $USER; newgrp docker` |
| `port is already allocated` | Host port 80/443/30080 taken in WSL | `ss -tlnp \| grep :80` | Change `hostPort`, or stop the conflicting process |
| Windows cannot reach `localhost:30080` | `listenAddress: 127.0.0.1` in the config, or `localhostForwarding` off | `docker port demo-control-plane`; check `.wslconfig` | Omit `listenAddress` (defaults to `0.0.0.0`); set `localhostForwarding=true`, `wsl --shutdown` |
| Windows cannot reach a `port-forward` | Bound to `127.0.0.1` | `ss -tlnp \| grep 8080` | Use `--address 0.0.0.0` |
| Ingress controller `Pending` | Node missing `ingress-ready=true` | `kubectl get nodes --show-labels` | Recreate with `kubeadmConfigPatches` (§4.2) |
| `/etc/hosts` entry keeps vanishing | WSL regenerates it | `cat /etc/hosts` | `[network] generateHosts = false` in `/etc/wsl.conf`, `wsl --shutdown` |
| Cluster gone after Windows reboot | WSL and/or Docker not started | `kind get clusters`; `docker ps -a` | Open Ubuntu, start Docker, `docker start demo-control-plane` or recreate |
| Cluster creation times out | WSL2 memory too low | `free -h` | `memory=6GB` in `.wslconfig`, `wsl --shutdown` |
| `ErrImagePull` for a local image | Not loaded, or `imagePullPolicy: Always` | `docker exec demo-control-plane crictl images \| grep <name>` | `kind load docker-image`; use `IfNotPresent`; avoid `:latest` |
| Wrong kubectl context | Docker Desktop Kubernetes also enabled | `kubectl config current-context` | `kubectl config use-context kind-demo` |
| Downloads fail behind a corporate proxy | Proxy not configured | `env \| grep -i proxy` | Set proxy vars; configure Docker Desktop → Resources → Proxies |

**Diagnostics:**

```bash
# WSL Ubuntu
kind get clusters
docker ps -a --filter "name=demo"
docker logs demo-control-plane --tail 50
kubectl get nodes
kubectl get pods -A
kubectl get events -A --sort-by=.lastTimestamp | tail -20
kind export logs --name demo ./kind-logs
nproc; free -h
```

---

## 10. Cleanup

### Delete just the application

```bash
# WSL Ubuntu
kubectl delete namespace demo
```

### Delete the cluster

> [!CAUTION]
> 🔴 **DESTRUCTIVE** — destroys the node container and all cluster data. This is the normal way to finish with Kind.

```bash
# WSL Ubuntu
kind delete cluster --name demo
kind get clusters
docker ps -a --filter "name=demo"      # should be empty
```

**Expected output:**

```text
Deleting cluster "demo" ...
Deleted nodes: ["demo-control-plane"]
```

### Delete every Kind cluster

```bash
# WSL Ubuntu  🔴 DESTRUCTIVE
kind delete clusters --all
```

### Reclaim disk

```bash
# WSL Ubuntu
docker images | grep kindest/node
docker system df
docker image prune -a          # 🔴 removes ALL unused images, not just Kind's
```

Node images are ~1 GB each.

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

### Uninstall the tools

```bash
# WSL Ubuntu  🔴 DESTRUCTIVE
sudo rm -f /usr/local/bin/kind /usr/local/bin/kubectl
rm -rf ~/.kube
```

---

## Official documentation

- Kind quick start — <https://kind.sigs.k8s.io/docs/user/quick-start/>
- Configuration — <https://kind.sigs.k8s.io/docs/user/configuration/>
- Ingress — <https://kind.sigs.k8s.io/docs/user/ingress/>
- Known issues — <https://kind.sigs.k8s.io/docs/user/known-issues/>
- Releases and node images — <https://github.com/kubernetes-sigs/kind/releases>
- Docker Desktop WSL backend — <https://docs.docker.com/desktop/wsl/>
- WSL configuration — <https://learn.microsoft.com/en-us/windows/wsl/wsl-config>
