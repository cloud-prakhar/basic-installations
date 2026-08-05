# Minikube — Single-Node Cluster on macOS

Run one Kubernetes node on a Mac — Intel or Apple Silicon.

All commands run in **macOS Terminal** (or iTerm).

Validated **2026-08-05** on macOS 15 (Apple Silicon and Intel), Minikube **v1.38.1**, Kubernetes **1.36**. Time: 15–25 minutes. Cost: free (Docker Desktop requires a paid subscription for larger companies — see §3.1).

---

## Contents

1. [Requirements](#1-requirements)
2. [Choose a driver](#2-choose-a-driver)
3. [Install prerequisites](#3-install-prerequisites)
4. [Start the single-node cluster](#4-start-the-single-node-cluster)
5. [Verify the cluster](#5-verify-the-cluster)
6. [Enable add-ons](#6-enable-add-ons)
7. [Deploy the sample application](#7-deploy-the-sample-application)
8. [Access the application](#8-access-the-application)
9. [Local image workflow](#9-local-image-workflow)
10. [Cluster lifecycle](#10-cluster-lifecycle)
11. [Troubleshooting](#11-troubleshooting)
12. [Cleanup](#12-cleanup)

---

## 1. Requirements

| Resource | Minimum | Recommended |
|----------|--------:|------------:|
| CPU | 2 cores | 4 cores |
| Memory free | 4 GB | 6–8 GB |
| Disk free | 20 GB | 30–40 GB |
| Nodes | 1 | 1 |

```bash
# macOS Terminal
sysctl -n hw.ncpu
sysctl -n hw.memsize | awk '{print $1/1024/1024/1024 " GB"}'
df -h / | tail -1
uname -m           # arm64 = Apple Silicon, x86_64 = Intel
sw_vers
```

**Expected output:**

```text
10
16 GB
/dev/disk3s5   460Gi  180Gi  260Gi  41%  /
arm64
ProductName:    macOS
ProductVersion: 15.x
```

> [!IMPORTANT]
> **Apple Silicon note.** On `arm64` Macs your cluster nodes and everything running in them are arm64. Kubernetes, Minikube's base image, ingress-nginx, and `nginx:1.30-alpine` all publish arm64 builds, so this guide works natively. You will only hit trouble with third-party images published for `amd64` only — the symptom is `exec format error` (see §11).

**Homebrew** makes everything easier. Install it if you do not have it:

```bash
# macOS Terminal
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew --version
```

---

## 2. Choose a driver

macOS cannot run Linux containers natively — something has to provide a Linux VM. Your choice is which.

| Driver / stack | How it works | Choose it when |
|---|---|---|
| **`docker` via Docker Desktop** ⭐ | Docker Desktop runs a Linux VM; the node is a container in it | Default. Best-supported, GUI, works on Intel and Apple Silicon. |
| **`docker` via Colima** ⭐ | Colima runs a lightweight Lima VM with a Docker-compatible daemon | You want a free, CLI-only, open-source alternative to Docker Desktop. |
| `qemu` | Minikube creates its own QEMU VM | You want no Docker at all. Slower; networking needs `socket_vmnet`. |
| `virtualbox` | A VirtualBox VM | Intel Macs only. **Do not use on Apple Silicon** — arm64 support is a developer preview. |
| `hyperkit` | Deprecated | Do not use. |

**Colima is not a Minikube driver** — it is a Docker-compatible runtime. You start Colima, then use Minikube's `docker` driver against it.

This page covers Docker Desktop and Colima. `qemu` is in §4.4.

---

## 3. Install prerequisites

Pick **3.1a** (Docker Desktop) **or** **3.1b** (Colima). You do not need both.

### 3.1a Option A — Docker Desktop

```bash
# macOS Terminal
brew install --cask docker
open -a Docker
```

Or download from <https://www.docker.com/products/docker-desktop/>.

Wait for the whale icon in the menu bar to stop animating.

**Give it enough resources:** Docker Desktop → **Settings → Resources** → at least **4 CPUs** and **6 GB** memory → *Apply & restart*. Minikube cannot use more than Docker has.

✅ **Verify:**

```bash
# macOS Terminal
docker version
docker run --rm hello-world
```

**Expected output:** both `Client:` and `Server:` sections, then `Hello from Docker!`.

> [!NOTE]
> Docker Desktop is free for personal use, education, and small businesses, but requires a paid subscription for larger organisations. Check current terms at <https://www.docker.com/pricing/>. Colima (below) has no such restriction.

> [!IMPORTANT]
> **Docker Desktop's built-in Kubernetes is a different cluster.** If you enable it (Settings → Kubernetes), you get a `docker-desktop` kubectl context alongside Minikube's. It does not conflict, but it is a common source of "where did my Deployment go?". Watch your context (§5).

### 3.1b Option B — Colima (no Docker Desktop)

```bash
# macOS Terminal
brew install colima docker
colima start --cpu 4 --memory 6 --disk 40
```

| Flag | Meaning |
|---|---|
| `--cpu 4` | vCPUs for the Colima VM. Minikube's node lives inside it, so this is the real ceiling. |
| `--memory 6` | GB of RAM for the VM. |
| `--disk 40` | GB of disk. |

✅ **Verify:**

```bash
# macOS Terminal
colima status
docker version
docker run --rm hello-world
docker context ls
```

**Expected output:**

```text
INFO[0000] colima is running using QEMU
INFO[0000] arch: aarch64
INFO[0000] runtime: docker
```

and `docker context ls` shows `colima` as current.

### 3.2 Install kubectl

```bash
# macOS Terminal
brew install kubectl
kubectl version --client
```

**Expected output:**

```text
Client Version: v1.36.1
Kustomize Version: v5.x.x
```

If `brew install kubectl` conflicts with a Docker Desktop-provided `kubectl`:

```bash
# macOS Terminal
brew link --overwrite kubernetes-cli
which kubectl
```

### 3.3 Install Minikube

```bash
# macOS Terminal
brew install minikube
minikube version
```

**Expected output:**

```text
minikube version: v1.38.1
commit: <sha>
```

Without Homebrew:

```bash
# macOS Terminal
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/arm64/arm64/')
curl -LO "https://storage.googleapis.com/minikube/releases/latest/minikube-darwin-${ARCH}"
sudo install "minikube-darwin-${ARCH}" /usr/local/bin/minikube
rm "minikube-darwin-${ARCH}"
```

---

## 4. Start the single-node cluster

### 4.1 The command

Same for Docker Desktop and Colima — both provide a Docker daemon.

```bash
# macOS Terminal
minikube start \
  --driver=docker \
  --cpus=4 \
  --memory=6g \
  --disk-size=30g \
  --profile=demo
```

### 4.2 What each flag does

| Flag | Meaning |
|---|---|
| `--driver=docker` | The node is a Docker container. Explicit beats auto-detection. |
| `--cpus=4` | vCPUs for the node. **Minimum 2.** Cannot exceed what Docker Desktop / Colima has. |
| `--memory=6g` | Memory for the node. Minimum ~1.8 GB. Cannot exceed the VM's allocation. |
| `--disk-size=30g` | Node disk for images and etcd. |
| `--profile=demo` | Names this cluster; later commands take `-p demo`. |

Optional: `--kubernetes-version=v1.36.1` to pin, `--container-runtime=containerd`, `--addons=ingress,metrics-server`.

> [!WARNING]
> Do **not** pass `--nodes=2` or higher — this guide is single-node.
>
> Do **not** run `minikube start` with `sudo` on macOS.

### 4.3 Expected output

```text
* [demo] minikube v1.38.1 on Darwin 15.x (arm64)
* Using the docker driver based on user configuration
* Starting "demo" primary control-plane node in "demo" cluster
* Pulling base image v0.0.48 ...
* Creating docker container (CPUs=4, Memory=6144MB) ...
* Preparing Kubernetes v1.36.1 on Docker 28.x ...
  - Generating certificates and keys ...
  - Booting up control plane ...
  - Configuring RBAC rules ...
* Configuring bridge CNI (Container Networking Interface) ...
* Verifying Kubernetes components...
  - Using image gcr.io/k8s-minikube/storage-provisioner:v5
* Enabled addons: storage-provisioner, default-storageclass
* Done! kubectl is now configured to use "demo" cluster and "default" namespace by default
```

2–5 minutes first run; ~30 seconds afterwards.

### 4.4 QEMU driver (no Docker at all)

```bash
# macOS Terminal
brew install qemu socket_vmnet
minikube start \
  --driver=qemu \
  --network=socket_vmnet \
  --cpus=4 --memory=6g --disk-size=30g \
  --profile=demo
```

`--network=socket_vmnet` is what gives the VM a routable IP; without it the default QEMU user networking makes NodePort access awkward. `socket_vmnet` needs a one-time privileged setup — follow <https://minikube.sigs.k8s.io/docs/drivers/qemu/>.

QEMU is slower than the docker driver. Use it only if you cannot install Docker Desktop or Colima.

---

## 5. Verify the cluster

```bash
# macOS Terminal
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
> `kubectl config current-context` must say `demo`. If it says `docker-desktop`, you are talking to a different cluster:
> ```bash
> kubectl config use-context demo
> ```

Minikube does **not** taint the node — Pods schedule immediately.

> [!IMPORTANT]
> **`192.168.49.2` is not reachable from macOS.** It lives inside Docker Desktop's / Colima's Linux VM, and macOS has no route to it. This is the single biggest difference from Linux and it shapes all of §8: on macOS with the docker driver you always need a tunnel or a port-forward.
>
> ```bash
> ping -c1 -W2 "$(minikube ip -p demo)"     # will time out — expected
> ```

---

## 6. Enable add-ons

```bash
# macOS Terminal
minikube addons list -p demo
```

`storage-provisioner` and `default-storageclass` are on by default — working PersistentVolumeClaims out of the box.

> [!TIP]
> Enable only what you need. Each add-on consumes CPU and memory on your one node.

### Ingress

```bash
# macOS Terminal
minikube addons enable ingress -p demo
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=180s
kubectl get pods -n ingress-nginx
```

**Expected output:** `ingress-nginx-controller-...` `1/1 Running`, plus two `Completed` admission Jobs (expected).

> [!NOTE]
> On Apple Silicon the ingress-nginx images are arm64-native, so this works. If a controller Pod shows `exec format error`, you are on an older Minikube — upgrade with `brew upgrade minikube`.

### Metrics Server

```bash
# macOS Terminal
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

### Dashboard

```bash
# macOS Terminal
minikube addons enable dashboard -p demo
minikube dashboard -p demo
```

Opens Safari/Chrome and blocks the terminal (it runs a proxy). `Ctrl+C` to stop. For the URL only: `minikube dashboard --url -p demo`.

### Storage

```bash
# macOS Terminal
kubectl get storageclass
```

**Expected output:**

```text
NAME                 PROVISIONER                RECLAIMPOLICY   VOLUMEBINDINGMODE   AGE
standard (default)   k8s.io/minikube-hostpath   Delete          Immediate           5m
```

### Registry (optional)

```bash
# macOS Terminal
minikube addons enable registry -p demo
```

Not needed for §9.

### Disable

```bash
# macOS Terminal
minikube addons disable dashboard -p demo
```

---

## 7. Deploy the sample application

```bash
# macOS Terminal
cd kubernetes-cluster-setup/minikube
kubectl apply -f manifests/00-namespace.yaml
kubectl apply -f manifests/10-deployment.yaml
kubectl apply -f manifests/20-service.yaml
```

Ingress only if you enabled the add-on:

```bash
# macOS Terminal
kubectl apply -f manifests/30-ingress.yaml
```

```bash
# macOS Terminal
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

## 8. Access the application

macOS with the docker driver always needs a tunnel or a port-forward, because the node's IP is inside the Linux VM.

### Method 1 — `minikube service` (easiest)

```bash
# macOS Terminal
minikube service web-nodeport -n demo -p demo
```

Minikube notices the docker driver on macOS, starts a **tunnel process**, and opens your browser at a `127.0.0.1` URL. **The terminal stays busy** — closing it or `Ctrl+C` kills the tunnel and the URL stops working.

**Expected output:**

```text
|-----------|--------------|-------------|---------------------------|
| NAMESPACE |     NAME     | TARGET PORT |            URL            |
| demo      | web-nodeport |          80 | http://192.168.49.2:30080 |
|-----------|--------------|-------------|---------------------------|
* Starting tunnel for service web-nodeport.
|-----------|--------------|-------------|------------------------|
| NAMESPACE |     NAME     | TARGET PORT |          URL           |
| demo      | web-nodeport |             | http://127.0.0.1:53472 |
|-----------|--------------|-------------|------------------------|
* Opening service demo/web-nodeport in default browser...
! Because you are using a Docker driver on darwin, the terminal needs to be open to run it.
```

URL only:

```bash
# macOS Terminal
minikube service web-nodeport -n demo -p demo --url
```

### Method 2 — `kubectl port-forward` (most predictable)

```bash
# macOS Terminal — leave running
kubectl -n demo port-forward svc/web 8080:80
```

```bash
# macOS Terminal (second window)
curl -s http://localhost:8080 | head -5
open http://localhost:8080
```

Works with every driver, always.

### Method 3 — NodePort via the Minikube IP

```bash
# macOS Terminal
curl -s --max-time 5 "http://$(minikube ip -p demo):30080" | head -5
```

**This fails with the docker driver** — expected. `192.168.49.2` is inside the Linux VM. It works only with the `qemu` driver using `socket_vmnet`.

### Method 4 — Ingress

```bash
# macOS Terminal
kubectl -n demo get ingress
```

**Expected output:**

```text
NAME   CLASS   HOSTS        ADDRESS        PORTS   AGE
web    nginx   demo.local   192.168.49.2   80      2m
```

Because the Minikube IP is unreachable, port-forward the ingress controller and point `demo.local` at localhost.

**macOS hosts file: `/etc/hosts`** (needs `sudo`):

```bash
# macOS Terminal
echo "127.0.0.1 demo.local" | sudo tee -a /etc/hosts
grep demo.local /etc/hosts
```

```bash
# macOS Terminal — leave running
kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 8080:80
```

```bash
# macOS Terminal (second window)
curl -s http://demo.local:8080 | head -5
open http://demo.local:8080
```

For reference: Windows `C:\Windows\System32\drivers\etc\hosts` · Linux `/etc/hosts` · macOS `/etc/hosts`.

### Method 5 — `minikube tunnel`

**What:** routes host traffic into the cluster and assigns external IPs to `LoadBalancer` Services.
**Why:** without it, a `type: LoadBalancer` Service stays `<pending>` forever — nothing fulfils the request.

```bash
# macOS Terminal — leave running; prompts for your password to create routes
minikube tunnel -p demo
```

```bash
# macOS Terminal (second window)
kubectl -n demo expose deployment web --type=LoadBalancer --name=web-lb --port=80
kubectl -n demo get svc web-lb
curl -s http://127.0.0.1 | head -5
```

On macOS with the docker driver the tunnel binds `127.0.0.1`, so the Service is reachable at `http://localhost`.

Clean up: `kubectl -n demo delete svc web-lb`, then `Ctrl+C` the tunnel.

### Comparison

| Method | Docker Desktop / Colima | `qemu` + socket_vmnet | Terminal stays busy |
|---|---|---|---|
| `minikube service` | ✅ via tunnel | ✅ direct | ✅ (docker driver) |
| `kubectl port-forward` | ✅ | ✅ | ✅ |
| NodePort via minikube IP | ❌ | ✅ | No |
| Ingress + `/etc/hosts` | ⚠️ needs port-forward | ✅ | Depends |
| `minikube tunnel` | ✅ | ✅ | ✅ |

---

## 9. Local image workflow

Build on macOS, run in the cluster, no registry.

### 9.1 Build

```bash
# macOS Terminal
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

> [!IMPORTANT]
> **Apple Silicon:** `docker build` produces an `arm64` image by default, which is exactly what your arm64 node needs. Do **not** add `--platform linux/amd64` unless you specifically want an emulated amd64 image — it will run slowly under emulation, or fail with `exec format error` if emulation is unavailable.

### 9.2 Load into Minikube

The node has its **own** image store, separate from Docker Desktop's / Colima's.

```bash
# macOS Terminal
minikube image load my-web:v1 -p demo
minikube image ls -p demo | grep my-web
```

**Expected output:**

```text
docker.io/library/my-web:v1
```

Verify inside the node:

```bash
# macOS Terminal
minikube ssh -p demo -- docker images | grep my-web
```

### 9.3 Build directly inside Minikube

```bash
# macOS Terminal
minikube image build -t my-web:v2 . -p demo
minikube image ls -p demo | grep my-web
```

Handy on Apple Silicon: the build happens inside the arm64 node, so architecture always matches.

### 9.4 Point your Docker CLI at Minikube's daemon

```bash
# macOS Terminal
eval "$(minikube -p demo docker-env)"
docker build -t my-web:v3 .
docker images | grep my-web
```

Revert:

```bash
# macOS Terminal
eval "$(minikube -p demo docker-env --unset)"
```

Only works when the node's runtime is Docker (the default).

### 9.5 Use it — `imagePullPolicy` matters

```bash
# macOS Terminal
kubectl -n demo set image deployment/web web=my-web:v1
kubectl -n demo rollout status deployment/web
kubectl -n demo port-forward svc/web 8080:80
```

Browse <http://localhost:8080> — *Hello from my local image*.

> [!IMPORTANT]
> The Deployment must use `imagePullPolicy: IfNotPresent` (or `Never`). With `Always`, the kubelet ignores the loaded copy and tries Docker Hub → `ErrImagePull`.
>
> Kubernetes **defaults to `Always` for any `:latest` tag**. Never tag local images `:latest`. The provided `manifests/10-deployment.yaml` sets `IfNotPresent` explicitly.

Revert:

```bash
# macOS Terminal
kubectl -n demo set image deployment/web web=nginx:1.30-alpine
```

---

## 10. Cluster lifecycle

```bash
# macOS Terminal
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
| `pause` | Frozen | In memory | Instant | Short break; get CPU (and battery) back |
| `stop` | Shut down | On disk | ~30 s | End of day |
| `delete` | 🔴 Destroyed | 🔴 Gone | Full recreate | Finished, or starting clean |

> [!TIP]
> On a laptop, `minikube pause` is the polite option during a meeting — it drops CPU usage to near zero without losing the cluster. `minikube stop` also stops the battery drain from the underlying VM.

**Colima users:** stopping Minikube does not stop Colima's VM. To reclaim everything:

```bash
# macOS Terminal
minikube stop -p demo
colima stop
```

---

## 11. Troubleshooting

Full matrix in **[troubleshooting.md](./troubleshooting.md)**. macOS-specific issues:

| Symptom | Cause | Diagnostic | Fix |
|---|---|---|---|
| `Cannot connect to the Docker daemon` | Docker Desktop not started, or Colima stopped | `docker version`; `colima status` | `open -a Docker`, or `colima start` |
| `Exiting due to RSRC_INSUFFICIENT_CORES` | Docker VM has <2 CPUs | Docker Desktop → Settings → Resources; `colima status` | Raise to 4 CPUs; Colima: `colima stop && colima start --cpu 4 --memory 6` |
| `Exiting due to MK_USAGE: ... has only X MB memory` | VM memory too low | Same | Raise to 6 GB, or lower `--memory` |
| `exec format error` in a Pod | amd64-only image on Apple Silicon | `kubectl describe pod <n>`; `docker manifest inspect <image>` | Use a multi-arch image; or build inside the node with `minikube image build` |
| `curl http://$(minikube ip):30080` times out | Node IP is inside the Linux VM | `ping $(minikube ip -p demo)` fails | Expected. Use `minikube service --url` or `kubectl port-forward` |
| `minikube service` closes when I close the terminal | The tunnel is a foreground process | — | Keep it open, or use `kubectl port-forward` in a dedicated window |
| `minikube tunnel` asks for a password repeatedly | It creates routes via `sudo` | — | Expected on macOS. Keep the window open. |
| Ingress unreachable at `demo.local` | Minikube IP unroutable from macOS | `kubectl -n ingress-nginx get pods` | Point `demo.local` at `127.0.0.1` and port-forward the controller (§8 Method 4) |
| `kubectl` talks to the wrong cluster | Docker Desktop Kubernetes also enabled | `kubectl config current-context` | `kubectl config use-context demo` |
| Two `kubectl` binaries disagree | Homebrew's and Docker Desktop's both on `PATH` | `which -a kubectl` | `brew link --overwrite kubernetes-cli`, or reorder `PATH` |
| `ErrImagePull` for a local image | Not loaded, or `imagePullPolicy: Always` | `minikube image ls -p demo \| grep <name>` | `minikube image load`; use `IfNotPresent`; avoid `:latest` |
| Very slow, fans spinning | The VM has too many CPUs, or Rosetta emulation | `top`; check Docker Desktop settings | Reduce `--cpus`; avoid `--platform linux/amd64` images |
| Everything hangs after a MacBook sleep | The VM's clock drifted | `minikube status -p demo` | `minikube stop -p demo && minikube start -p demo` |
| Downloads fail behind a corporate proxy | Proxy not configured | `env \| grep -i proxy` | Set proxy vars and pass `--docker-env HTTP_PROXY=...` to `minikube start` |

**Diagnostics:**

```bash
# macOS Terminal
minikube status -p demo
minikube logs -p demo --problems
kubectl get events -A --sort-by=.lastTimestamp | tail -20
docker ps -a --filter "name=demo"
kubectl config current-context
uname -m
colima status 2>/dev/null || echo "not using colima"
```

---

## 12. Cleanup

### Delete just the application

```bash
# macOS Terminal
kubectl delete namespace demo
```

### Stop the cluster (keep everything)

```bash
# macOS Terminal
minikube stop -p demo
```

### Delete the cluster

> [!CAUTION]
> 🔴 **DESTRUCTIVE** — destroys the node and all cluster data, including PersistentVolumes.

```bash
# macOS Terminal
minikube delete -p demo
minikube profile list
docker ps -a --filter "name=demo"      # should be empty
```

### Delete everything Minikube created

```bash
# macOS Terminal  🔴 DESTRUCTIVE
minikube delete --all --purge
rm -rf ~/.minikube
```

`--purge` also removes cached base images (often several GB).

### Reclaim Docker space

```bash
# macOS Terminal
docker system df
docker system prune -a        # 🔴 removes ALL unused images, not just Minikube's
```

### Stop or remove Colima

```bash
# macOS Terminal
colima stop
colima delete                 # 🔴 DESTRUCTIVE — removes the whole VM
```

### Remove the hosts entry

```bash
# macOS Terminal
sudo sed -i '' '/demo.local/d' /etc/hosts
grep demo.local /etc/hosts || echo "removed"
```

(Note the empty `''` after `-i` — macOS `sed` requires it.)

### Uninstall the tools

```bash
# macOS Terminal
brew uninstall minikube kubectl
brew uninstall colima              # if you used it
brew uninstall --cask docker       # if you want Docker Desktop gone
rm -rf ~/.kube ~/.minikube
```

---

## Official documentation

- Minikube start — <https://minikube.sigs.k8s.io/docs/start/>
- Docker driver — <https://minikube.sigs.k8s.io/docs/drivers/docker/>
- QEMU driver — <https://minikube.sigs.k8s.io/docs/drivers/qemu/>
- Add-ons — <https://minikube.sigs.k8s.io/docs/handbook/addons/>
- Accessing apps — <https://minikube.sigs.k8s.io/docs/handbook/accessing/>
- Pushing images — <https://minikube.sigs.k8s.io/docs/handbook/pushing/>
- Install kubectl on macOS — <https://kubernetes.io/docs/tasks/tools/install-kubectl-macos/>
- Colima — <https://github.com/abiosoft/colima>
- Docker Desktop for Mac — <https://docs.docker.com/desktop/install/mac-install/>
