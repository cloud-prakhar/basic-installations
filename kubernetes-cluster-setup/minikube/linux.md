# Minikube — Single-Node Cluster on Native Linux

Run one Kubernetes node on an Ubuntu/Debian/Fedora laptop or desktop.

All commands run in your **Linux terminal**. `sudo` marks commands needing root.

Validated **2026-08-05** on Ubuntu 24.04 LTS, Minikube **v1.38.1**, Kubernetes **1.36**, Docker Engine. Time: 15–20 minutes. Cost: free.

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

Linux gets the best Minikube experience of any platform: containers share the host kernel directly, so there is no VM overhead and no networking translation layer between you and the cluster. The Minikube IP is directly routable — NodePort and Ingress work without tunnels.

---

## 2. Choose a driver

| Driver | How it works | Choose it when |
|---|---|---|
| **`docker`** ⭐ | The node is a Docker container | Default. Fast, simple, well-supported. |
| `kvm2` | A KVM/QEMU virtual machine | You want real VM isolation. Needs `libvirt`. |
| `podman` | A rootless Podman container | You use Podman instead of Docker. Some rough edges. |
| `virtualbox` | A VirtualBox VM | You already use VirtualBox. |
| `none` | Runs **directly on your host**, no isolation | Almost never. See the warning below. |

This page uses **`docker`**. Others are covered in §4.4.

> [!CAUTION]
> The **`none` driver** installs kubelet, containerd, and the control plane directly onto your host with no isolation. It requires root, permanently modifies your system, and `minikube delete` does not fully undo it. It exists for CI runners. If you want Kubernetes running natively on your host, use **[kubeadm](../kubeadm/local-linux.md)** — that is what it is for, and it is cleaner.

---

## 3. Install prerequisites

### 3.1 Docker Engine

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

### 3.2 Run Docker without sudo

**What:** add your user to the `docker` group.
**Why:** Minikube must reach the Docker socket as **your** user. Running `minikube` with `sudo` writes root-owned files into `~/.minikube` and `~/.kube`, and every later command as your normal user fails.

```bash
# Linux terminal
sudo usermod -aG docker "$USER"
newgrp docker           # applies to this shell without logging out
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
> The `docker` group is effectively root — any member can mount the host filesystem into a container. Fine on a personal machine; do not do it on a shared or production host.

### 3.3 Install kubectl

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

Optional checksum verification:

```bash
# Linux terminal
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/${ARCH}/kubectl.sha256"
echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
```

### 3.4 Install Minikube

```bash
# Linux terminal
ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
curl -LO "https://storage.googleapis.com/minikube/releases/latest/minikube-linux-${ARCH}"
sudo install "minikube-linux-${ARCH}" /usr/local/bin/minikube
rm "minikube-linux-${ARCH}"
minikube version
```

**Expected output:**

```text
minikube version: v1.38.1
commit: <sha>
```

---

## 4. Start the single-node cluster

### 4.1 The command

```bash
# Linux terminal
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
| `--driver=docker` | Create the node as a Docker container. Explicit beats auto-detection. |
| `--cpus=4` | vCPUs for the node. **Minimum 2** — Minikube refuses fewer. |
| `--memory=6g` | Memory for the node. Minimum ~1.8 GB. |
| `--disk-size=30g` | Node disk for images and etcd. |
| `--profile=demo` | Names this cluster; later commands take `-p demo`. Without it, the profile is `minikube`. |

Optional: `--kubernetes-version=v1.36.1` to pin a version, `--container-runtime=containerd` to use containerd inside the node, `--addons=ingress,metrics-server` to enable add-ons at start.

> [!WARNING]
> Do **not** pass `--nodes=2` or higher — this guide is single-node.
>
> Do **not** run `minikube start` with `sudo`.

### 4.3 Expected output

```text
* [demo] minikube v1.38.1 on Ubuntu 24.04 (amd64)
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

2–5 minutes on first run; ~30 seconds afterwards.

### 4.4 Other drivers

**KVM2** — real VM isolation:

```bash
# Linux terminal (root)
sudo apt-get install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virt-manager
sudo usermod -aG libvirt "$USER"
newgrp libvirt

# check virtualization is available
egrep -c '(vmx|svm)' /proc/cpuinfo     # must be > 0
virt-host-validate | head
```

```bash
# Linux terminal
minikube start --driver=kvm2 --cpus=4 --memory=6g --disk-size=30g --profile=demo
```

**Podman** (rootless):

```bash
# Linux terminal
sudo apt-get install -y podman
minikube start --driver=podman --container-runtime=cri-o --cpus=4 --memory=6g --profile=demo
```

**VirtualBox:**

```bash
# Linux terminal
minikube start --driver=virtualbox --cpus=4 --memory=6g --disk-size=30g --profile=demo
```

---

## 5. Verify the cluster

```bash
# Linux terminal
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

CONTAINER ID   IMAGE                                 NAMES
a1b2c3d4e5f6   gcr.io/k8s-minikube/kicbase:v0.0.48   demo
```

```text
One Kubernetes node in Ready status
```

Confirm `kubectl config current-context` is `demo`. Unlike a kubeadm cluster, Minikube does **not** taint the node — Pods schedule immediately.

**On Linux, `minikube ip` is directly routable:**

```bash
# Linux terminal
ping -c2 "$(minikube ip -p demo)"
```

That is the key Linux advantage — no tunnels needed for NodePort or Ingress.

---

## 6. Enable add-ons

```bash
# Linux terminal
minikube addons list -p demo
```

`storage-provisioner` and `default-storageclass` are on by default, giving you working PersistentVolumeClaims immediately.

> [!TIP]
> Enable only what you need — each add-on consumes CPU and memory on your one node.

### Ingress

```bash
# Linux terminal
minikube addons enable ingress -p demo
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=180s
kubectl get pods -n ingress-nginx
```

**Expected output:** `ingress-nginx-controller-...` `1/1 Running`, plus two `Completed` admission Jobs (they install the webhook and exit — expected).

### Metrics Server

```bash
# Linux terminal
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
# Linux terminal
minikube addons enable dashboard -p demo
minikube dashboard -p demo
```

Opens your browser and blocks the terminal. `Ctrl+C` to stop. For the URL only: `minikube dashboard --url -p demo`.

### Storage

```bash
# Linux terminal
kubectl get storageclass
```

**Expected output:**

```text
NAME                 PROVISIONER                RECLAIMPOLICY   VOLUMEBINDINGMODE   AGE
standard (default)   k8s.io/minikube-hostpath   Delete          Immediate           5m
```

Try it:

```bash
# Linux terminal
kubectl -n demo create -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
EOF
kubectl -n demo get pvc
kubectl -n demo delete pvc test-pvc
```

**Expected:** the PVC reaches `Bound` — no manual PersistentVolume required.

### Registry (optional)

```bash
# Linux terminal
minikube addons enable registry -p demo
```

Not needed for §9 — `minikube image load` is simpler.

### Disable

```bash
# Linux terminal
minikube addons disable dashboard -p demo
```

---

## 7. Deploy the sample application

```bash
# Linux terminal
cd kubernetes-cluster-setup/minikube
kubectl apply -f manifests/00-namespace.yaml
kubectl apply -f manifests/10-deployment.yaml
kubectl apply -f manifests/20-service.yaml
```

Ingress, only if you enabled the add-on:

```bash
# Linux terminal
kubectl apply -f manifests/30-ingress.yaml
```

```bash
# Linux terminal
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

**Both replicas on one node is expected.** `replicas: 2` means two Pods, not two machines — real ReplicaSet behaviour (rolling updates, self-healing, load-balanced endpoints), no node-failure tolerance.

Prove self-healing:

```bash
# Linux terminal
kubectl -n demo delete pod -l app.kubernetes.io/name=web --wait=false
kubectl -n demo get pods -w        # Ctrl+C when both are Running again
```

---

## 8. Access the application

Linux is the easy case — the Minikube IP is routable from the host.

### Method 1 — NodePort directly (works out of the box on Linux)

```bash
# Linux terminal
minikube ip -p demo
curl -s "http://$(minikube ip -p demo):30080" | head -5
xdg-open "http://$(minikube ip -p demo):30080"
```

**Expected output:** the nginx welcome HTML.

No tunnel, no port-forward. This is the Linux advantage — on Windows and macOS with the docker driver, this same command fails.

### Method 2 — `minikube service`

```bash
# Linux terminal
minikube service web-nodeport -n demo -p demo
```

Opens your default browser. On Linux with the docker driver it does **not** need a tunnel process, so the command returns immediately.

URL only:

```bash
# Linux terminal
minikube service web-nodeport -n demo -p demo --url
```

**Expected output:** `http://192.168.49.2:30080`

If you are on a headless machine, `--url` avoids `xdg-open: executable file not found`.

### Method 3 — `kubectl port-forward`

```bash
# Linux terminal — leave running
kubectl -n demo port-forward svc/web 8080:80
```

```bash
# Linux terminal (second shell)
curl -s http://localhost:8080 | head -5
```

Works with every driver everywhere. Use it when you want nothing bound on the node.

### Method 4 — Ingress

```bash
# Linux terminal
kubectl -n demo get ingress
```

**Expected output:**

```text
NAME   CLASS   HOSTS        ADDRESS        PORTS   AGE
web    nginx   demo.local   192.168.49.2   80      2m
```

Add the hosts entry. **Linux hosts file: `/etc/hosts`**:

```bash
# Linux terminal (root)
echo "$(minikube ip -p demo) demo.local" | sudo tee -a /etc/hosts
grep demo.local /etc/hosts
```

```bash
# Linux terminal
curl -s http://demo.local | head -5
xdg-open http://demo.local
```

**Expected output:** the nginx welcome page, served through ingress-nginx.

For reference: Windows `C:\Windows\System32\drivers\etc\hosts` · Linux `/etc/hosts` · macOS `/etc/hosts`.

### Method 5 — `minikube tunnel`

**What:** routes host traffic into the cluster and assigns real external IPs to `LoadBalancer` Services.
**Why:** without it, a `type: LoadBalancer` Service stays `<pending>` forever — nothing fulfils the request.

```bash
# Linux terminal — leave running; prompts for sudo to create routes
minikube tunnel -p demo
```

```bash
# Linux terminal (second shell)
kubectl -n demo expose deployment web --type=LoadBalancer --name=web-lb --port=80
kubectl -n demo get svc web-lb
LB_IP=$(kubectl -n demo get svc web-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -s "http://${LB_IP}" | head -5
```

**Expected output:** `EXTERNAL-IP` fills in within seconds and `curl` returns the page.

Clean up: `kubectl -n demo delete svc web-lb`, then `Ctrl+C` the tunnel.

### Comparison

| Method | Works on Linux | Terminal stays busy | Use when |
|---|---|---|---|
| NodePort via minikube IP | ✅ directly | No | Default on Linux |
| `minikube service` | ✅ | No | Quick browser open |
| `kubectl port-forward` | ✅ | ✅ | Nothing exposed on the node |
| Ingress + `/etc/hosts` | ✅ | No | Testing host/path routing |
| `minikube tunnel` | ✅ | ✅ | Testing `LoadBalancer` Services |

---

## 9. Local image workflow

Build locally, run in the cluster, no registry.

### 9.1 Build

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

### 9.2 Load into Minikube

The node has its **own** image store, separate from your host Docker daemon.

```bash
# Linux terminal
minikube image load my-web:v1 -p demo
minikube image ls -p demo | grep my-web
```

**Expected output:**

```text
docker.io/library/my-web:v1
```

Verify from inside the node:

```bash
# Linux terminal
minikube ssh -p demo -- docker images | grep my-web
```

### 9.3 Build directly inside Minikube

```bash
# Linux terminal
minikube image build -t my-web:v2 . -p demo
minikube image ls -p demo | grep my-web
```

### 9.4 Point your Docker CLI at Minikube's daemon

```bash
# Linux terminal
eval "$(minikube -p demo docker-env)"
docker build -t my-web:v3 .
docker images | grep my-web
```

Builds land straight in the node's store. Revert:

```bash
# Linux terminal
eval "$(minikube -p demo docker-env --unset)"
```

Only works when the node's runtime is Docker (the default). With `--container-runtime=containerd`, use `minikube image load` or `minikube image build`.

### 9.5 Use it — `imagePullPolicy` matters

```bash
# Linux terminal
kubectl -n demo set image deployment/web web=my-web:v1
kubectl -n demo rollout status deployment/web
curl -s "http://$(minikube ip -p demo):30080"
```

**Expected output:** `<h1>Hello from my local image</h1>`

> [!IMPORTANT]
> The Deployment must use `imagePullPolicy: IfNotPresent` (or `Never`). With `Always`, the kubelet ignores the loaded copy and tries Docker Hub → `ErrImagePull`.
>
> Kubernetes also **defaults to `Always` for any `:latest` tag**. Never tag local images `:latest`. The provided `manifests/10-deployment.yaml` sets `IfNotPresent` explicitly.

Revert:

```bash
# Linux terminal
kubectl -n demo set image deployment/web web=nginx:1.30-alpine
```

---

## 10. Cluster lifecycle

```bash
# Linux terminal
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
| `pause` | Frozen | In memory | Instant | Short break; need CPU back now |
| `stop` | Shut down | On disk | ~30 s | End of day; keep your work |
| `delete` | 🔴 Destroyed | 🔴 Gone | Full recreate | Finished, or starting clean |

> [!CAUTION]
> 🔴 `minikube delete` destroys the cluster, every workload, and all PersistentVolume data. No undo.

Minikube can start automatically on login if you want — but on Linux it is a plain user process, so just run `minikube start -p demo` when you need it.

---

## 11. Troubleshooting

Full matrix in **[troubleshooting.md](./troubleshooting.md)**. Linux-specific issues:

| Symptom | Cause | Diagnostic | Fix |
|---|---|---|---|
| `permission denied while trying to connect to the Docker daemon socket` | Not in the `docker` group | `groups \| grep docker` | `sudo usermod -aG docker $USER; newgrp docker` |
| `Cannot connect to the Docker daemon` | Docker not running | `systemctl status docker` | `sudo systemctl start docker` |
| `Exiting due to RSRC_INSUFFICIENT_CORES` | <2 CPUs available | `nproc` | Lower `--cpus`, or use a bigger machine |
| `Exiting due to RSRC_INSUFFICIENT_MEMORY` | Not enough free RAM | `free -h` | Lower `--memory`, or close applications |
| `profile "demo" already exists` | Leftover profile | `minikube profile list` | `minikube start -p demo` to reuse, or `minikube delete -p demo` |
| Everything root-owned, permission errors everywhere | You ran `minikube start` with `sudo` | `ls -la ~/.minikube ~/.kube` | `sudo rm -rf ~/.minikube ~/.kube`, restart without `sudo` |
| `xdg-open: executable file not found` | Headless machine, no browser | — | Add `--url` to `minikube service` / `minikube dashboard` |
| Cannot reach `minikube ip` | Docker bridge blocked by a host firewall | `sudo iptables -L -n \| grep DOCKER` | Allow the Docker bridge, or use `kubectl port-forward` |
| `kvm2` fails: `no virtualization` | VT-x/AMD-V off in BIOS | `egrep -c '(vmx\|svm)' /proc/cpuinfo` | Enable in BIOS/UEFI, or use the docker driver |
| `ErrImagePull` for a local image | Not loaded, or `imagePullPolicy: Always` | `minikube image ls -p demo \| grep <name>` | `minikube image load`; use `IfNotPresent`; avoid `:latest` |
| Wrong `kubectl` context | Another cluster is selected | `kubectl config current-context` | `kubectl config use-context demo` |
| Disk fills up | Cached images and old profiles | `docker system df`; `du -sh ~/.minikube` | `minikube delete --all --purge`; `docker system prune` |
| Downloads fail behind a corporate proxy | Proxy not configured | `env \| grep -i proxy` | Export `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY`; pass `--docker-env HTTP_PROXY=...` to `minikube start` |

**Diagnostics:**

```bash
# Linux terminal
minikube status -p demo
minikube logs -p demo --problems
kubectl get events -A --sort-by=.lastTimestamp | tail -20
docker ps -a --filter "name=demo"
kubectl config current-context
nproc; free -h; df -h /
```

---

## 12. Cleanup

### Delete just the application

```bash
# Linux terminal
kubectl delete namespace demo
```

### Stop the cluster (keep everything)

```bash
# Linux terminal
minikube stop -p demo
```

### Delete the cluster

> [!CAUTION]
> 🔴 **DESTRUCTIVE** — destroys the node and all cluster data, including PersistentVolumes.

```bash
# Linux terminal
minikube delete -p demo
minikube profile list
docker ps -a --filter "name=demo"      # should be empty
```

### Delete everything Minikube created

```bash
# Linux terminal  🔴 DESTRUCTIVE
minikube delete --all --purge
rm -rf ~/.minikube
```

`--purge` also removes cached ISOs and base images (often several GB).

### Reclaim Docker space

```bash
# Linux terminal
docker system df
docker system prune -a        # 🔴 removes ALL unused images, not just Minikube's
```

### Remove the hosts entry

```bash
# Linux terminal (root)
sudo sed -i '/demo.local/d' /etc/hosts
```

### Uninstall the tools

```bash
# Linux terminal  🔴 DESTRUCTIVE
sudo rm -f /usr/local/bin/minikube /usr/local/bin/kubectl
rm -rf ~/.kube ~/.minikube
```

Docker itself (only if you want it gone):

```bash
# Linux terminal (root)  🔴 DESTRUCTIVE
sudo apt-get purge -y docker-ce docker-ce-cli containerd.io
sudo rm -rf /var/lib/docker
```

---

## Official documentation

- Minikube start — <https://minikube.sigs.k8s.io/docs/start/>
- Docker driver — <https://minikube.sigs.k8s.io/docs/drivers/docker/>
- KVM2 driver — <https://minikube.sigs.k8s.io/docs/drivers/kvm2/>
- Add-ons — <https://minikube.sigs.k8s.io/docs/handbook/addons/>
- Accessing apps — <https://minikube.sigs.k8s.io/docs/handbook/accessing/>
- Pushing images — <https://minikube.sigs.k8s.io/docs/handbook/pushing/>
- Install kubectl on Linux — <https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/>
- Docker Engine on Ubuntu — <https://docs.docker.com/engine/install/ubuntu/>
