# Kind — Single-Node Cluster on Native Linux

Run one Kubernetes node — a Docker container — on an Ubuntu/Debian/Fedora laptop or desktop.

All commands run in your **Linux terminal**. `sudo` marks commands needing root.

Validated **2026-08-05** on Ubuntu 24.04 LTS, Kind **v0.32.0**, node image `kindest/node:v1.36.1`, Kubernetes **1.36**, Docker Engine. Time: 10 minutes. Cost: free.

> [!NOTE]
> Linux is the fastest Kind environment there is: no VM layer, containers run on your own kernel, `kind load` takes seconds, and mapped ports land directly on your machine.

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
# Linux terminal
nproc
free -h
df -h /
. /etc/os-release && echo "$PRETTY_NAME"
uname -m
```

**Expected output:**

```text
4
               total        used        free
Mem:           7.6Gi       1.2Gi       5.9Gi
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p2  234G   68G  155G  31% /
Ubuntu 24.04.3 LTS
x86_64
```

---

## 2. Install prerequisites

### 2.1 Docker Engine

**Ubuntu / Debian:**

```bash
# Linux terminal (root)
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

Debian users: replace both `ubuntu` occurrences with `debian`.

**Fedora / RHEL:**

```bash
# Linux terminal (root)
sudo dnf -y install dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io
sudo systemctl enable --now docker
```

### 2.2 Run Docker without sudo

**What:** add your user to the `docker` group.
**Why:** Kind talks to the Docker socket as your user, and writes `~/.kube/config` as your user. Running `kind` with `sudo` puts the kubeconfig in `/root` and everything afterwards fails.

```bash
# Linux terminal
sudo usermod -aG docker "$USER"
newgrp docker           # apply in this shell without logging out
```

✅ **Verify:**

```bash
# Linux terminal
groups | grep docker
docker version
docker run --rm hello-world
```

**Expected output:** both `Client:` and `Server:` sections, then `Hello from Docker!`.

> [!CAUTION]
> The `docker` group is effectively root — any member can mount the host filesystem into a container. Fine on a personal machine, not on a shared or production host.

### 2.3 kubectl

```bash
# Linux terminal
ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/${ARCH}/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm kubectl
kubectl version --client
```

**Expected output:**

```text
Client Version: v1.36.1
Kustomize Version: v5.x.x
```

### 2.4 Kind

```bash
# Linux terminal
ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
curl -Lo ./kind "https://kind.sigs.k8s.io/dl/v0.32.0/kind-linux-${ARCH}"
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
# Linux terminal
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

First run 1–3 minutes (image download); afterwards **30–40 seconds** on Linux.

### 3.2 Optionally pin the Kubernetes version

```bash
# Linux terminal
kind create cluster --name demo \
  --image kindest/node:v1.36.1@sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5
```

> [!IMPORTANT]
> Node images are built **per Kind release**. Always take the `@sha256` digest from the release notes of *your* Kind version. Omitting `--image` and using Kind's default is safest.

### 3.3 Verify

```bash
# Linux terminal
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

Kubernetes control plane is running at https://127.0.0.1:39215
CoreDNS is running at https://127.0.0.1:39215/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy

NAME                 STATUS   ROLES           AGE   VERSION   INTERNAL-IP   CONTAINER-RUNTIME
demo-control-plane   Ready    control-plane   45s   v1.36.1   172.18.0.2    containerd://2.x.x

NAMESPACE            NAME                                         READY   STATUS    RESTARTS   AGE
kube-system          coredns-...                                  1/1     Running   0          45s
kube-system          etcd-demo-control-plane                      1/1     Running   0          45s
kube-system          kindnet-...                                  1/1     Running   0          45s
kube-system          kube-apiserver-demo-control-plane            1/1     Running   0          45s
kube-system          kube-controller-manager-demo-control-plane   1/1     Running   0          45s
kube-system          kube-proxy-...                               1/1     Running   0          45s
kube-system          kube-scheduler-demo-control-plane            1/1     Running   0          45s
local-path-storage   local-path-provisioner-...                   1/1     Running   0          45s

CONTAINER ID   IMAGE                  PORTS                       NAMES
a1b2c3d4e5f6   kindest/node:v1.36.1   127.0.0.1:39215->6443/tcp   demo-control-plane
```

```text
One node named demo-control-plane
Status: Ready
```

**Notice:**

- `kindnet` — Kind's built-in CNI. No CNI installation step (compare the kubeadm guide, where the node sits `NotReady` until you install Calico).
- `local-path-provisioner` — a default StorageClass, so PVCs bind immediately.
- The only published port is the API server. Everything else needs §4.

**Confirm the taint is already gone:**

```bash
# Linux terminal
kubectl describe node demo-control-plane | grep -i -A2 taints
```

**Expected output:** `Taints: <none>`

**On Linux, the node's Docker IP is directly reachable:**

```bash
# Linux terminal
docker inspect demo-control-plane --format '{{.NetworkSettings.Networks.kind.IPAddress}}'
ping -c2 172.18.0.2
```

That is a Linux-only convenience — Windows and macOS have no route to it.

### 3.4 Look inside the node container

```bash
# Linux terminal
docker exec -it demo-control-plane bash
```

Inside:

```bash
crictl ps                       # containers the kubelet runs
systemctl status kubelet        # the kubelet is a systemd service in here
ls /etc/kubernetes/manifests/   # static Pod manifests — a real kubeadm node
exit
```

---

## 4. Create a cluster with port mapping

### 4.1 Why

Kind nodes sit on an internal Docker network (`kind`). A NodePort Service listens on 30080 **inside the container**. `extraPortMappings` publishes container ports onto your host, exactly like `docker run -p`.

> [!IMPORTANT]
> `extraPortMappings` **cannot be added to an existing cluster.** Decide your ports first. Recreating costs ~40 seconds.

### 4.2 The config file

Use [`kind-config.yaml`](./kind-config.yaml), or create it:

```bash
# Linux terminal
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
| `nodes:` | **One entry, `role: control-plane`.** No `role: worker` — this is a single-node cluster. |
| `kubeadmConfigPatches` | Kind bootstraps with kubeadm, so you can patch its config directly |
| `node-labels: "ingress-ready=true"` | **Required for ingress.** The ingress-nginx Kind manifest selects on this label; without it the controller Pod stays `Pending` forever. |
| `extraPortMappings` | Publishes container ports to the host |
| `containerPort: 80` | Port inside the node — where the ingress controller listens |
| `hostPort: 80` | Port on your machine. Must be free. **Ports below 1024 normally need root — Docker's port publishing handles this without you needing sudo.** |
| `protocol: TCP` | TCP or UDP |
| `listenAddress: "127.0.0.1"` | Binds to localhost only, so the cluster is not exposed to your LAN. Omit (defaults `0.0.0.0`) to expose it. |
| `networking.apiServerAddress` | Where the API server is published. Keep it localhost unless you deliberately want remote `kubectl`. |

### 4.4 Create

```bash
# Linux terminal
kind delete cluster --name demo          # 🔴 removes the §3 cluster
kind create cluster --config kind-config.yaml
```

✅ **Verify:**

```bash
# Linux terminal
docker port demo-control-plane
kubectl get nodes --show-labels | tr ',' '\n' | grep ingress-ready
```

**Expected output:**

```text
80/tcp -> 127.0.0.1:80
443/tcp -> 127.0.0.1:443
30080/tcp -> 127.0.0.1:30080
6443/tcp -> 127.0.0.1:39215
ingress-ready=true
```

> [!NOTE]
> If ports 80/443 are already used on your machine (a local nginx or Apache), `kind create` fails with a port conflict. Check with `sudo ss -tlnp | grep -E ':(80|443)\b'` and change `hostPort` to `8080`/`8443`.

---

## 5. Deploy the sample application

```bash
# Linux terminal
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

**Both replicas on one node is expected** — `replicas: 2` means two Pods, not two machines. You get real ReplicaSet behaviour, just no node-failure tolerance.

### Access it

```bash
# Linux terminal
curl -s http://localhost:30080 | head -5
xdg-open http://localhost:30080
```

**Expected output:** the nginx welcome page HTML.

This works because of the port mapping. Without it, `connection refused` — the port exists inside the container only.

**Docker port mapping explained:** `docker port demo-control-plane` shows the same table Docker uses for any published port. Kind wires host `127.0.0.1:30080` → container `:30080`; kube-proxy inside the container routes `:30080` to your Pods.

**Via `kubectl port-forward`** (needs no mapping at all):

```bash
# Linux terminal — leave running
kubectl -n demo port-forward svc/web 8080:80
```

```bash
# Linux terminal (second shell)
curl -s http://localhost:8080 | head -5
```

**Via the node's Docker IP** (Linux only):

```bash
# Linux terminal
NODE_IP=$(docker inspect demo-control-plane --format '{{.NetworkSettings.Networks.kind.IPAddress}}')
curl -s "http://${NODE_IP}:30080" | head -5
```

---

## 6. Install an ingress controller

### 6.1 Install

```bash
# Linux terminal
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.15.1/deploy/static/provider/kind/deploy.yaml
```

The **Kind provider** manifest is purpose-built for this setup: hostPort binding plus the `ingress-ready` nodeSelector.

### 6.2 Wait for it

```bash
# Linux terminal
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s

kubectl get pods -n ingress-nginx
```

**Expected output:**

```text
NAME                                        READY   STATUS      RESTARTS   AGE
ingress-nginx-admission-create-xxxxx        0/1     Completed   0          45s
ingress-nginx-admission-patch-xxxxx         0/1     Completed   0          45s
ingress-nginx-controller-xxxxxxxxx-xxxxx    1/1     Running     0          45s
```

The two `Completed` Jobs installed the admission webhook and exited — expected.

> [!IMPORTANT]
> Controller stuck `Pending`? The node is missing `ingress-ready=true`:
> ```bash
> kubectl describe pod -n ingress-nginx -l app.kubernetes.io/component=controller | tail -10
> kubectl get nodes --show-labels
> ```
> Recreate the cluster with the `kubeadmConfigPatches` block from §4.2.

### 6.3 Apply the Ingress

```bash
# Linux terminal
kubectl apply -f manifests/30-ingress.yaml
kubectl -n demo get ingress
kubectl -n demo describe ingress web | tail -10
```

**Expected output:**

```text
NAME   CLASS   HOSTS        ADDRESS     PORTS   AGE
web    nginx   demo.local   localhost   80      30s
```

### 6.4 Verify with curl

No hosts-file edit needed if you send the `Host` header yourself:

```bash
# Linux terminal
curl -s -H "Host: demo.local" http://localhost | head -5
```

**Expected output:** the nginx welcome page HTML.

### 6.5 Hostname mapping

For browser access, map `demo.local` to `127.0.0.1`.

**Linux hosts file: `/etc/hosts`** (needs `sudo`):

```bash
# Linux terminal (root)
echo "127.0.0.1 demo.local" | sudo tee -a /etc/hosts
grep demo.local /etc/hosts
```

```bash
# Linux terminal
curl -s http://demo.local | head -5
xdg-open http://demo.local
```

**Hosts file paths on all platforms** (for reference):

| Platform | Path | Notes |
|---|---|---|
| Windows | `C:\Windows\System32\drivers\etc\hosts` | Edit as Administrator |
| Linux / WSL | `/etc/hosts` | Needs `sudo`. In WSL, set `generateHosts = false` in `/etc/wsl.conf` to make it stick |
| macOS | `/etc/hosts` | Needs `sudo` |

---

## 7. Load a local image

Build locally, run in the cluster, no registry.

### 7.1 Build

```bash
# Linux terminal
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

Note the exact `name:tag` — `kind load` matches on it exactly and will not guess.

### 7.2 Load

```bash
# Linux terminal
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

You can also load from a tar archive:

```bash
# Linux terminal
docker save my-web:v1 -o my-web.tar
kind load image-archive my-web.tar --name demo
```

### 7.3 Verify the image is inside the node

```bash
# Linux terminal
docker exec demo-control-plane crictl images | grep my-web
```

**Expected output:**

```text
docker.io/library/my-web    v1    a1b2c3d4e5f6   52.5MB
```

The node runs **containerd**, so `crictl` is the tool inside — not `docker`.

### 7.4 Redeploy

```bash
# Linux terminal
kubectl -n demo set image deployment/web web=my-web:v1
kubectl -n demo rollout status deployment/web
curl -s http://localhost:30080
```

**Expected output:** `<h1>Hello from my local image</h1>`

> [!IMPORTANT]
> **`imagePullPolicy` must be `IfNotPresent` (or `Never`).** With `Always`, the kubelet ignores the loaded image and tries to pull `my-web:v1` from Docker Hub → `ErrImagePull`.
>
> Kubernetes also **defaults to `Always` for any `:latest` tag**. Never tag local images `:latest`. `manifests/10-deployment.yaml` sets `IfNotPresent` explicitly.

Revert:

```bash
# Linux terminal
kubectl -n demo set image deployment/web web=nginx:1.30-alpine
```

---

## 8. Cluster lifecycle

```bash
# Linux terminal
kind get clusters                              # list all Kind clusters
kubectl config get-contexts                    # all contexts
kubectl config use-context kind-demo           # switch
kind get kubeconfig --name demo                # print this cluster's kubeconfig

kind export logs --name demo ./kind-logs       # dump all logs for debugging
ls ./kind-logs

docker ps --filter "name=demo-control-plane"
docker exec -it demo-control-plane bash

kind delete cluster --name demo                # 🔴 destroy this one
kind delete clusters --all                     # 🔴 destroy all
kind create cluster --config kind-config.yaml  # recreate
```

> [!NOTE]
> **Kind has no stop/start.** A cluster is running or deleted. `docker stop demo-control-plane` / `docker start` mostly works and the cluster recovers after a minute, but it is not an officially supported workflow. Since creation takes under a minute on Linux, delete-and-recreate is the normal pattern.

**Multiple clusters are cheap:**

```bash
# Linux terminal
kind create cluster --name test-a
kind create cluster --name test-b
kind get clusters
kubectl config use-context kind-test-a
```

**Remove unused node images safely:**

```bash
# Linux terminal
docker images | grep kindest/node
docker ps --format "{{.Image}}"        # in use — do NOT delete these
docker rmi kindest/node:<OLD_VERSION>
```

---

## 9. Troubleshooting

Full matrix in **[troubleshooting.md](./troubleshooting.md)**. Linux-specific:

| Symptom | Cause | Diagnostic | Fix |
|---|---|---|---|
| `permission denied ... /var/run/docker.sock` | Not in the `docker` group | `groups \| grep docker` | `sudo usermod -aG docker $USER; newgrp docker` |
| `Cannot connect to the Docker daemon` | Docker not running | `systemctl status docker` | `sudo systemctl start docker` |
| `port is already allocated` | Host port 80/443/30080 in use | `sudo ss -tlnp \| grep -E ':(80\|443\|30080)\b'` | Stop the conflicting service, or change `hostPort` |
| `node(s) already exist` | Cluster of that name exists | `kind get clusters` | `kind delete cluster --name demo` then recreate |
| Cluster creation hangs at "Starting control-plane" | Low memory, or `inotify` limits exhausted | `free -h`; `cat /proc/sys/fs/inotify/max_user_instances` | Free memory; raise inotify limits (below) |
| `too many open files` | inotify limits too low for multiple clusters | `sysctl fs.inotify.max_user_instances` | `sudo sysctl fs.inotify.max_user_instances=512` and `fs.inotify.max_user_watches=524288`; persist in `/etc/sysctl.d/` |
| `curl localhost:30080` refused | No `extraPortMappings` | `docker port demo-control-plane` | Recreate with the config from §4 |
| Ingress controller `Pending` | Node missing `ingress-ready=true` | `kubectl get nodes --show-labels` | Recreate with `kubeadmConfigPatches` (§4.2) |
| `ErrImagePull` for a local image | Not loaded, or `imagePullPolicy: Always` | `docker exec demo-control-plane crictl images \| grep <name>` | `kind load docker-image`; use `IfNotPresent`; avoid `:latest` |
| Wrong kubectl context | Another cluster selected | `kubectl config current-context` | `kubectl config use-context kind-demo` |
| Everything root-owned | You ran `kind` with `sudo` | `ls -la ~/.kube` | `sudo rm -rf /root/.kube`; recreate the cluster as your normal user |
| Cluster gone after reboot | Docker restarted the container but the cluster needs a moment, or `docker` did not autostart | `docker ps -a`; `systemctl status docker` | `docker start demo-control-plane`, wait ~60 s; or recreate |
| Downloads fail behind a corporate proxy | Proxy not configured | `env \| grep -i proxy` | Set proxy vars for Docker in `/etc/systemd/system/docker.service.d/http-proxy.conf`, `systemctl daemon-reload`, restart Docker |

**Diagnostics:**

```bash
# Linux terminal
kind get clusters
docker ps -a --filter "name=demo"
docker logs demo-control-plane --tail 50
kubectl get nodes
kubectl get pods -A
kubectl get events -A --sort-by=.lastTimestamp | tail -20
kind export logs --name demo ./kind-logs
free -h; df -h /
```

---

## 10. Cleanup

### Delete just the application

```bash
# Linux terminal
kubectl delete namespace demo
```

### Delete the cluster

> [!CAUTION]
> 🔴 **DESTRUCTIVE** — destroys the node container and all cluster data. With Kind this is the normal way to finish.

```bash
# Linux terminal
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
# Linux terminal  🔴 DESTRUCTIVE
kind delete clusters --all
```

### Reclaim disk space

```bash
# Linux terminal
docker images | grep kindest/node
docker system df
docker image prune -a          # 🔴 removes ALL unused images, not just Kind's
```

Node images are ~1 GB each; old versions are usually the biggest reclaim.

Kind also creates a Docker network — harmless, but if you want it gone once no cluster uses it:

```bash
# Linux terminal
docker network ls | grep kind
docker network rm kind         # only when no Kind cluster exists
```

### Remove the hosts entry

```bash
# Linux terminal (root)
sudo sed -i '/demo.local/d' /etc/hosts
```

### Uninstall the tools

```bash
# Linux terminal  🔴 DESTRUCTIVE
sudo rm -f /usr/local/bin/kind /usr/local/bin/kubectl
rm -rf ~/.kube
```

Docker itself, only if you want it gone:

```bash
# Linux terminal (root)  🔴 DESTRUCTIVE
sudo apt-get purge -y docker-ce docker-ce-cli containerd.io
sudo rm -rf /var/lib/docker
```

---

## Official documentation

- Kind quick start — <https://kind.sigs.k8s.io/docs/user/quick-start/>
- Configuration — <https://kind.sigs.k8s.io/docs/user/configuration/>
- Ingress — <https://kind.sigs.k8s.io/docs/user/ingress/>
- Local registry — <https://kind.sigs.k8s.io/docs/user/local-registry/>
- Known issues — <https://kind.sigs.k8s.io/docs/user/known-issues/>
- Releases and node images — <https://github.com/kubernetes-sigs/kind/releases>
- Install kubectl on Linux — <https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/>
- Docker Engine on Ubuntu — <https://docs.docker.com/engine/install/ubuntu/>
