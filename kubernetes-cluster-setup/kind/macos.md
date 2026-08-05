# Kind — Single-Node Cluster on macOS

Run one Kubernetes node — a Docker container — on a Mac, Intel or Apple Silicon.

All commands run in **macOS Terminal** (or iTerm).

Validated **2026-08-05** on macOS 15 (Apple Silicon and Intel), Kind **v0.32.0**, node image `kindest/node:v1.36.1`, Kubernetes **1.36**. Time: 10–15 minutes. Cost: free.

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

| Resource | Minimum | Recommended |
|----------|--------:|------------:|
| CPU | 2 cores | 4 cores |
| Memory free | 4 GB | 6–8 GB |
| Disk free | 15 GB | 25–30 GB |
| Nodes | 1 | 1 |

```bash
# macOS Terminal
sysctl -n hw.ncpu
sysctl -n hw.memsize | awk '{print $1/1024/1024/1024 " GB"}'
df -h / | tail -1
uname -m          # arm64 = Apple Silicon, x86_64 = Intel
sw_vers
```

> [!IMPORTANT]
> **Apple Silicon.** On `arm64` Macs the Kind node image and everything inside it are arm64. Kind publishes arm64 node images, ingress-nginx has arm64 builds, and `nginx:1.30-alpine` is multi-arch — so this guide works natively. You will only hit trouble with third-party images published for `amd64` only (symptom: `exec format error`, see §9).

**Homebrew** makes this much easier:

```bash
# macOS Terminal
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew --version
```

---

## 2. Install prerequisites

Kind nodes are Docker containers, and macOS cannot run Linux containers natively — something must provide a Linux VM. Pick **2.1a** (Docker Desktop) or **2.1b** (Colima).

### 2.1a Option A — Docker Desktop

```bash
# macOS Terminal
brew install --cask docker
open -a Docker
```

Or download from <https://www.docker.com/products/docker-desktop/>.

Wait for the whale icon in the menu bar to stop animating.

**Give it resources:** Docker Desktop → **Settings → Resources** → at least **4 CPUs** and **6 GB** memory → *Apply & restart*. Your Kind cluster can never exceed what Docker has.

✅ **Verify:**

```bash
# macOS Terminal
docker version
docker info --format "{{.ServerVersion}} / {{.NCPU}} CPUs"
docker run --rm hello-world
```

**Expected output:** both `Client:` and `Server:` sections, then `Hello from Docker!`.

> [!NOTE]
> Docker Desktop is free for personal use, education, and small businesses; larger organisations need a paid subscription. Check <https://www.docker.com/pricing/>. Colima has no such restriction.
>
> **Docker Desktop's built-in Kubernetes is a different cluster.** If enabled, you get a `docker-desktop` kubectl context alongside Kind's. Watch your context (§3.3).

### 2.1b Option B — Colima (no Docker Desktop)

```bash
# macOS Terminal
brew install colima docker
colima start --cpu 4 --memory 6 --disk 40
```

| Flag | Meaning |
|---|---|
| `--cpu 4` | vCPUs for the Colima VM — your Kind node lives inside it |
| `--memory 6` | GB of RAM for the VM |
| `--disk 40` | GB of disk |

✅ **Verify:**

```bash
# macOS Terminal
colima status
docker version
docker context ls
docker run --rm hello-world
```

**Expected output:**

```text
INFO[0000] colima is running using QEMU
INFO[0000] arch: aarch64
INFO[0000] runtime: docker
```

> [!IMPORTANT]
> With Colima, `extraPortMappings` land on the **Colima VM**, and Colima forwards them to macOS. This works for the standard cases in this guide, but if a mapped port is unreachable, use `kubectl port-forward` instead — see §9.

### 2.2 kubectl

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

If it conflicts with a Docker Desktop-provided `kubectl`:

```bash
# macOS Terminal
which -a kubectl
brew link --overwrite kubernetes-cli
```

### 2.3 Kind

```bash
# macOS Terminal
brew install kind
kind version
```

**Expected output:**

```text
kind v0.32.0 go1.25.x darwin/arm64
```

Without Homebrew:

```bash
# macOS Terminal
ARCH=$(uname -m | sed 's/x86_64/amd64/')
curl -Lo ./kind "https://kind.sigs.k8s.io/dl/v0.32.0/kind-darwin-${ARCH}"
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind
```

---

## 3. Create a basic single-node cluster

### 3.1 One command

```bash
# macOS Terminal
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
You can now use your cluster with:

kubectl cluster-info --context kind-demo
```

First run 2–4 minutes (image download); afterwards 45–90 seconds.

### 3.2 Optionally pin the Kubernetes version

```bash
# macOS Terminal
kind create cluster --name demo \
  --image kindest/node:v1.36.1@sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5
```

> [!IMPORTANT]
> Node images are built **per Kind release**, and are multi-arch — the digest above resolves to the arm64 variant on Apple Silicon automatically. Always take the digest from the release notes of *your* Kind version at <https://github.com/kubernetes-sigs/kind/releases>. Omitting `--image` is safest.

### 3.3 Verify

```bash
# macOS Terminal
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

Kubernetes control plane is running at https://127.0.0.1:52341

NAME                 STATUS   ROLES           AGE   VERSION   INTERNAL-IP   CONTAINER-RUNTIME
demo-control-plane   Ready    control-plane   70s   v1.36.1   172.18.0.2    containerd://2.x.x

NAMESPACE            NAME                                         READY   STATUS    RESTARTS   AGE
kube-system          coredns-...                                  1/1     Running   0          70s
kube-system          etcd-demo-control-plane                      1/1     Running   0          70s
kube-system          kindnet-...                                  1/1     Running   0          70s
kube-system          kube-apiserver-demo-control-plane            1/1     Running   0          70s
kube-system          kube-controller-manager-demo-control-plane   1/1     Running   0          70s
kube-system          kube-proxy-...                               1/1     Running   0          70s
kube-system          kube-scheduler-demo-control-plane            1/1     Running   0          70s
local-path-storage   local-path-provisioner-...                   1/1     Running   0          70s
```

```text
One node named demo-control-plane
Status: Ready
```

**Notice:** `kindnet` (built-in CNI — no installation step) and `local-path-provisioner` (default StorageClass, so PVCs work immediately).

**Confirm the taint is already gone:**

```bash
# macOS Terminal
kubectl describe node demo-control-plane | grep -i -A2 taints
```

**Expected output:** `Taints: <none>`

**Confirm the node architecture:**

```bash
# macOS Terminal
kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}'; echo
```

**Expected output:** `arm64` on Apple Silicon, `amd64` on Intel.

> [!IMPORTANT]
> **`172.18.0.2` is not reachable from macOS.** It lives on the Docker network inside Docker Desktop's / Colima's Linux VM, and macOS has no route to it. This is why `extraPortMappings` (§4) matter so much here — on Linux you could just use the container IP.

### 3.4 Look inside the node container

```bash
# macOS Terminal
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

Kind nodes sit on an internal Docker network. A NodePort listens **inside the container only**, and on macOS you have no route to that network at all. `extraPortMappings` publishes container ports through Docker to your Mac's `localhost`.

> [!IMPORTANT]
> `extraPortMappings` **cannot be added to an existing cluster.** Decide your ports first. Recreating costs ~60 seconds.

### 4.2 The config file

Use [`kind-config.yaml`](./kind-config.yaml), or create it:

```bash
# macOS Terminal
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
        listenAddress: "127.0.0.1"
      - containerPort: 443
        hostPort: 443
        protocol: TCP
        listenAddress: "127.0.0.1"
      - containerPort: 30080
        hostPort: 30080
        protocol: TCP
        listenAddress: "127.0.0.1"
networking:
  apiServerAddress: "127.0.0.1"
EOF
```

### 4.3 Every field explained

| Field | Meaning |
|---|---|
| `kind: Cluster` / `apiVersion: kind.x-k8s.io/v1alpha4` | Config kind and API version; `v1alpha4` is current |
| `name: demo` | Cluster name → container `demo-control-plane`, context `kind-demo`. `--name` on the CLI overrides it. |
| `nodes:` | **One entry, `role: control-plane`.** No `role: worker` — single-node cluster. |
| `kubeadmConfigPatches` | Kind bootstraps with kubeadm, so you can patch its config |
| `node-labels: "ingress-ready=true"` | **Required for ingress.** The ingress-nginx Kind manifest selects on this label; without it the controller Pod stays `Pending` forever. |
| `extraPortMappings` | Publishes container ports to macOS |
| `containerPort: 80` | Port inside the node — where the ingress controller listens |
| `hostPort: 80` | Port on your Mac. Must be free. |
| `protocol: TCP` | TCP or UDP |
| `listenAddress: "127.0.0.1"` | Binds to localhost only, so nothing is exposed to your LAN. Omit (defaults `0.0.0.0`) to expose it. |
| `networking.apiServerAddress` | Where the API server is published. Keep it localhost. |

### 4.4 Create

```bash
# macOS Terminal
kind delete cluster --name demo          # 🔴 removes the §3 cluster
kind create cluster --config kind-config.yaml
```

✅ **Verify:**

```bash
# macOS Terminal
docker port demo-control-plane
kubectl get nodes --show-labels | tr ',' '\n' | grep ingress-ready
```

**Expected output:**

```text
80/tcp -> 127.0.0.1:80
443/tcp -> 127.0.0.1:443
30080/tcp -> 127.0.0.1:30080
6443/tcp -> 127.0.0.1:52341
ingress-ready=true
```

> [!NOTE]
> macOS may already use ports 80/443 (a local web server, or another Docker container). If `kind create` fails with a port conflict, check `sudo lsof -iTCP:80 -sTCP:LISTEN` and change `hostPort` to `8080`/`8443`.

---

## 5. Deploy the sample application

```bash
# macOS Terminal
cd kubernetes-cluster-setup/kind
kubectl apply -f manifests/00-namespace.yaml
kubectl apply -f manifests/10-deployment.yaml
kubectl apply -f manifests/20-service.yaml

kubectl -n demo rollout status deployment/web --timeout=180s
kubectl -n demo get all -o wide
```

**Expected output:**

```text
namespace/demo created
deployment.apps/web created
service/web created
service/web-nodeport created

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

### Access it

```bash
# macOS Terminal
curl -s http://localhost:30080 | head -5
open http://localhost:30080
```

**Expected output:** the nginx welcome page HTML.

This works **only because** `kind-config.yaml` maps `containerPort: 30080` to `hostPort: 30080`. Without it you get `connection refused` — the port exists inside the container and macOS has no route to that network.

**Docker port mapping explained:** `docker port demo-control-plane` shows the same table Docker uses for any published port. The chain is macOS `localhost:30080` → Docker Desktop/Colima VM → node container `:30080` → kube-proxy → your Pods.

**Via `kubectl port-forward`** (needs no mapping):

```bash
# macOS Terminal — leave running
kubectl -n demo port-forward svc/web 8080:80
```

```bash
# macOS Terminal (second window)
curl -s http://localhost:8080 | head -5
open http://localhost:8080
```

---

## 6. Install an ingress controller

### 6.1 Install

```bash
# macOS Terminal
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.15.1/deploy/static/provider/kind/deploy.yaml
```

The **Kind provider** manifest is purpose-built for this setup: hostPort binding plus the `ingress-ready` nodeSelector. Its images are multi-arch, so it works on Apple Silicon.

### 6.2 Wait

```bash
# macOS Terminal
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

The two `Completed` Jobs installed the admission webhook and exited — expected.

> [!IMPORTANT]
> Controller `Pending`? The node is missing `ingress-ready=true`:
> ```bash
> kubectl describe pod -n ingress-nginx -l app.kubernetes.io/component=controller | tail -10
> kubectl get nodes --show-labels
> ```
> Recreate the cluster with the `kubeadmConfigPatches` block from §4.2.

### 6.3 Apply the Ingress

```bash
# macOS Terminal
kubectl apply -f manifests/30-ingress.yaml
kubectl -n demo get ingress
```

**Expected output:**

```text
NAME   CLASS   HOSTS        ADDRESS     PORTS   AGE
web    nginx   demo.local   localhost   80      30s
```

### 6.4 Verify with curl

No hosts-file edit needed if you send the `Host` header yourself:

```bash
# macOS Terminal
curl -s -H "Host: demo.local" http://localhost | head -5
```

**Expected output:** the nginx welcome page HTML.

### 6.5 Hostname mapping

For browser access, map `demo.local` to `127.0.0.1`.

**macOS hosts file: `/etc/hosts`** (needs `sudo`):

```bash
# macOS Terminal
echo "127.0.0.1 demo.local" | sudo tee -a /etc/hosts
grep demo.local /etc/hosts
```

```bash
# macOS Terminal
curl -s http://demo.local | head -5
open http://demo.local
```

If macOS caches the old resolution:

```bash
# macOS Terminal
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
```

**Hosts file paths on all platforms** (for reference):

| Platform | Path | Notes |
|---|---|---|
| Windows | `C:\Windows\System32\drivers\etc\hosts` | Edit as Administrator |
| Linux / WSL | `/etc/hosts` | Needs `sudo` |
| macOS | `/etc/hosts` | Needs `sudo`; may need a DNS cache flush |

---

## 7. Load a local image

Build on macOS, run in the cluster, no registry.

### 7.1 Build

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
> **Apple Silicon:** plain `docker build` produces an `arm64` image, which matches your arm64 node exactly. Do **not** add `--platform linux/amd64` unless you specifically want an emulated amd64 image — it will be slow, or fail with `exec format error` if emulation is unavailable in the node.

Confirm the architecture:

```bash
# macOS Terminal
docker image inspect my-web:v1 --format '{{.Architecture}}'
```

**Expected output:** `arm64` on Apple Silicon.

### 7.2 Load

```bash
# macOS Terminal
kind load docker-image my-web:v1 --name demo
```

**Expected output:**

```text
Image: "my-web:v1" with ID "sha256:..." not yet present on node "demo-control-plane", loading...
```

Generic form:

```text
kind load docker-image <IMAGE_NAME> --name <CLUSTER_NAME>
```

### 7.3 Verify the image is inside the node

```bash
# macOS Terminal
docker exec demo-control-plane crictl images | grep my-web
```

**Expected output:**

```text
docker.io/library/my-web    v1    a1b2c3d4e5f6   52.5MB
```

The node runs **containerd**, so `crictl` is the tool inside — not `docker`.

### 7.4 Redeploy

```bash
# macOS Terminal
kubectl -n demo set image deployment/web web=my-web:v1
kubectl -n demo rollout status deployment/web
curl -s http://localhost:30080
```

**Expected output:** `<h1>Hello from my local image</h1>`

> [!IMPORTANT]
> **`imagePullPolicy` must be `IfNotPresent` (or `Never`).** With `Always`, the kubelet ignores the loaded image and tries Docker Hub → `ErrImagePull`.
>
> Kubernetes also **defaults to `Always` for any `:latest` tag**. Never tag local images `:latest`. `manifests/10-deployment.yaml` sets `IfNotPresent` explicitly.

Revert:

```bash
# macOS Terminal
kubectl -n demo set image deployment/web web=nginx:1.30-alpine
```

---

## 8. Cluster lifecycle

```bash
# macOS Terminal
kind get clusters                              # list
kubectl config get-contexts                    # all contexts
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
> **Kind has no stop/start.** A cluster is running or deleted. `docker stop`/`docker start` on the node container mostly works but is not supported — and creation takes about a minute, so delete-and-recreate is the normal pattern.
>
> **After a Mac restart:** Docker Desktop may not auto-start. Open it, then `docker start demo-control-plane` — or just recreate.
>
> **Colima users:** `colima stop` shuts down the whole VM (and with it the Kind cluster). `colima start` brings the VM back; the node container may need `docker start demo-control-plane`.

**Remove unused node images safely:**

```bash
# macOS Terminal
docker images | grep kindest/node
docker ps --format "{{.Image}}"        # in use — do NOT delete these
docker rmi kindest/node:<OLD_VERSION>
```

---

## 9. Troubleshooting

Full matrix in **[troubleshooting.md](./troubleshooting.md)**. macOS-specific:

| Symptom | Cause | Diagnostic | Fix |
|---|---|---|---|
| `Cannot connect to the Docker daemon` | Docker Desktop not started, or Colima stopped | `docker version`; `colima status` | `open -a Docker`, or `colima start` |
| Cluster creation times out | Docker VM has too little memory | Docker Desktop → Settings → Resources | Raise to 6 GB and retry |
| `exec format error` in a Pod | amd64-only image on an arm64 node | `kubectl describe pod <n>`; `docker image inspect <img> --format '{{.Architecture}}'` | Use a multi-arch image; do not build with `--platform linux/amd64` |
| `no matching manifest for linux/arm64` | Image has no arm64 variant | `docker manifest inspect <IMAGE>` | Pick a multi-arch image, or build one yourself |
| `curl localhost:30080` refused | No `extraPortMappings` | `docker port demo-control-plane` | Recreate with the config from §4 |
| `port is already allocated` | Host port 80/443 in use | `sudo lsof -iTCP:80 -sTCP:LISTEN` | Change `hostPort`, or stop the conflicting service |
| Cannot reach the container IP `172.18.0.x` | No route from macOS to Docker's network | `ping 172.18.0.2` times out | Expected. Use mapped ports or `kubectl port-forward` |
| Mapped port unreachable with Colima | Colima's own port forwarding | `colima status`; `docker port demo-control-plane` | Use `kubectl port-forward`, or restart Colima |
| Ingress controller `Pending` | Node missing `ingress-ready=true` | `kubectl get nodes --show-labels` | Recreate with `kubeadmConfigPatches` (§4.2) |
| `demo.local` resolves to the wrong thing | macOS DNS cache | `dscacheutil -q host -a name demo.local` | `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder` |
| Two `kubectl` binaries disagree | Homebrew's and Docker Desktop's both on `PATH` | `which -a kubectl` | `brew link --overwrite kubernetes-cli` |
| Wrong kubectl context | Docker Desktop Kubernetes also enabled | `kubectl config current-context` | `kubectl config use-context kind-demo` |
| `ErrImagePull` for a local image | Not loaded, or `imagePullPolicy: Always` | `docker exec demo-control-plane crictl images \| grep <name>` | `kind load docker-image`; use `IfNotPresent`; avoid `:latest` |
| Cluster unresponsive after the Mac sleeps | VM clock drift | `kubectl get nodes` | `kind delete cluster --name demo` and recreate; or restart Docker Desktop |

**Diagnostics:**

```bash
# macOS Terminal
kind get clusters
docker ps -a --filter "name=demo"
docker logs demo-control-plane --tail 50
kubectl get nodes
kubectl get pods -A
kubectl get events -A --sort-by=.lastTimestamp | tail -20
kind export logs --name demo ./kind-logs
uname -m
colima status 2>/dev/null || echo "not using colima"
```

---

## 10. Cleanup

### Delete just the application

```bash
# macOS Terminal
kubectl delete namespace demo
```

### Delete the cluster

> [!CAUTION]
> 🔴 **DESTRUCTIVE** — destroys the node container and all cluster data. With Kind this is the normal way to finish.

```bash
# macOS Terminal
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
# macOS Terminal  🔴 DESTRUCTIVE
kind delete clusters --all
```

### Reclaim disk space

```bash
# macOS Terminal
docker images | grep kindest/node
docker system df
docker image prune -a          # 🔴 removes ALL unused images, not just Kind's
```

Node images are ~1 GB each.

### Stop or remove Colima

```bash
# macOS Terminal
colima stop
colima delete                  # 🔴 DESTRUCTIVE — removes the whole VM
```

### Remove the hosts entry

```bash
# macOS Terminal
sudo sed -i '' '/demo.local/d' /etc/hosts
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
grep demo.local /etc/hosts || echo "removed"
```

(Note the empty `''` after `-i` — macOS `sed` requires it.)

### Uninstall the tools

```bash
# macOS Terminal
brew uninstall kind kubectl
brew uninstall colima                # if you used it
brew uninstall --cask docker         # if you want Docker Desktop gone
rm -rf ~/.kube
```

---

## Official documentation

- Kind quick start — <https://kind.sigs.k8s.io/docs/user/quick-start/>
- Configuration — <https://kind.sigs.k8s.io/docs/user/configuration/>
- Ingress — <https://kind.sigs.k8s.io/docs/user/ingress/>
- Known issues — <https://kind.sigs.k8s.io/docs/user/known-issues/>
- Releases and node images — <https://github.com/kubernetes-sigs/kind/releases>
- Install kubectl on macOS — <https://kubernetes.io/docs/tasks/tools/install-kubectl-macos/>
- Docker Desktop for Mac — <https://docs.docker.com/desktop/install/mac-install/>
- Colima — <https://github.com/abiosoft/colima>
