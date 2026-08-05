# Kind — Single-Node Cluster on Windows

Run one Kubernetes node — a Docker container — on Windows 10/11 using Kind.

All commands run in **PowerShell** unless marked otherwise. `# PowerShell (Administrator)` means an elevated window.

Validated **2026-08-05** on Windows 11 24H2, Kind **v0.32.0**, node image `kindest/node:v1.36.1`, Kubernetes **1.36**, Docker Desktop. Time: 10–15 minutes. Cost: free.

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

Plus Windows 10 build 19044+ or Windows 11, and virtualization enabled in BIOS/UEFI (Docker Desktop needs it).

```powershell
# PowerShell
Get-ComputerInfo -Property "HyperVRequirementVirtualizationFirmwareEnabled","HyperVisorPresent"
```

**Expected output:**

```text
HyperVRequirementVirtualizationFirmwareEnabled : True
HyperVisorPresent                              : True
```

`False` → enable Intel VT-x / AMD-V ("SVM Mode") in BIOS/UEFI.

**Kind nodes are Docker containers**, so everything hinges on Docker working.

---

## 2. Install prerequisites

### 2.1 Docker Desktop

1. Download from <https://www.docker.com/products/docker-desktop/>
2. Install, reboot when asked
3. Launch Docker Desktop and wait for the whale icon to settle

✅ **Verify:**

```powershell
# PowerShell
docker version
docker info --format "{{.ServerVersion}} / {{.NCPU}} CPUs / {{.MemTotal}} bytes"
docker run --rm hello-world
```

**Expected output:** both `Client:` and `Server:` sections, then `Hello from Docker!`.

Only a `Client:` section with an error means Docker Desktop is not running.

**Give it resources:** Docker Desktop → **Settings → Resources** → at least **4 CPUs** and **6 GB** memory → *Apply & restart*. Your Kind cluster can never exceed what Docker has.

> [!NOTE]
> **Docker Desktop's built-in Kubernetes is a different cluster.** If enabled (Settings → Kubernetes), you get a `docker-desktop` kubectl context alongside Kind's. Not a conflict, but a common source of "where did my Deployment go?". Watch your context in §3.

### 2.2 kubectl

```powershell
# PowerShell
winget install -e --id Kubernetes.kubectl
```

Or with Chocolatey:

```powershell
# PowerShell (Administrator)
choco install kubernetes-cli -y
```

✅ **Verify** (reopen PowerShell first so `PATH` refreshes):

```powershell
# PowerShell
kubectl version --client
```

**Expected output:**

```text
Client Version: v1.36.1
Kustomize Version: v5.x.x
```

### 2.3 Kind

```powershell
# PowerShell
winget install -e --id Kubernetes.kind
```

Or Chocolatey:

```powershell
# PowerShell (Administrator)
choco install kind -y
```

Or manual download:

```powershell
# PowerShell
curl.exe -Lo kind.exe https://kind.sigs.k8s.io/dl/v0.32.0/kind-windows-amd64
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\bin" | Out-Null
Move-Item -Force .\kind.exe "$env:USERPROFILE\bin\kind.exe"
$env:PATH += ";$env:USERPROFILE\bin"
```

To make that `PATH` change permanent, add `%USERPROFILE%\bin` under **Settings → System → About → Advanced system settings → Environment Variables**.

✅ **Verify:**

```powershell
# PowerShell
kind version
```

**Expected output:**

```text
kind v0.32.0 go1.25.x windows/amd64
```

---

## 3. Create a basic single-node cluster

### 3.1 One command

```powershell
# PowerShell
kind create cluster --name demo
```

That is the whole thing. Kind:

1. Pulls the node image (first run only)
2. Starts one Docker container named `demo-control-plane`
3. Runs `kubeadm init` inside it
4. Installs its own CNI (kindnet)
5. Removes the control-plane taint so your Pods can schedule
6. Writes a `kind-demo` context into `%USERPROFILE%\.kube\config` and selects it

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

First run: 1–3 minutes (image download). Afterwards: 30–60 seconds.

### 3.2 Optionally pin the Kubernetes version

```powershell
# PowerShell
kind create cluster --name demo --image kindest/node:v1.36.1@sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5
```

> [!IMPORTANT]
> Node images are built **per Kind release**. Always take the `@sha256` digest from the release notes of *your* Kind version at <https://github.com/kubernetes-sigs/kind/releases>. Omitting `--image` entirely and using Kind's default is the safest option.

### 3.3 Verify

```powershell
# PowerShell
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
CoreDNS is running at https://127.0.0.1:52341/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy

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

CONTAINER ID   IMAGE                  PORTS                       NAMES
a1b2c3d4e5f6   kindest/node:v1.36.1   127.0.0.1:52341->6443/tcp   demo-control-plane
```

```text
One node named demo-control-plane
Status: Ready
```

**Notice:**

- `kindnet` — Kind's built-in CNI. No CNI installation step, unlike kubeadm.
- `local-path-provisioner` — gives you a default StorageClass, so PVCs work immediately.
- The **only** published port is the API server (`52341->6443`). Nothing else is reachable from Windows — which is why §4 exists.

**Confirm the taint is already gone:**

```powershell
# PowerShell
kubectl describe node demo-control-plane | Select-String -Pattern "Taints" -Context 0,2
```

**Expected output:** `Taints: <none>` — Kind removes it automatically on a single-node cluster.

### 3.4 Look inside the node container

```powershell
# PowerShell
docker exec -it demo-control-plane bash
```

Inside:

```bash
crictl ps                       # containers the kubelet is running
systemctl status kubelet        # the kubelet is a systemd service in here
ls /etc/kubernetes/manifests/   # static Pod manifests — this is a real kubeadm node
exit
```

---

## 4. Create a cluster with port mapping

The basic cluster cannot serve traffic to your browser. Recreate it with host port mappings.

### 4.1 Why you need this

Kind nodes sit on an internal Docker network. A NodePort Service listens on port 30080 **inside the container** and nowhere else. `extraPortMappings` publishes container ports onto your Windows host, exactly like `docker run -p`.

> [!IMPORTANT]
> `extraPortMappings` **cannot be added to an existing cluster.** You must set them at creation. With Kind that costs 40 seconds — decide your ports, then create.

### 4.2 The config file

Use [`kind-config.yaml`](./kind-config.yaml) from this directory, or create it:

```powershell
# PowerShell
@"
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
"@ | Out-File -Encoding utf8 kind-config.yaml
```

### 4.3 Every field explained

| Field | Meaning |
|---|---|
| `kind: Cluster` / `apiVersion: kind.x-k8s.io/v1alpha4` | The Kind config kind and API version. `v1alpha4` is current. |
| `name: demo` | Cluster name. `--name` on the CLI overrides it. Container becomes `demo-control-plane`; context becomes `kind-demo`. |
| `nodes:` | The node list. **Exactly one entry with `role: control-plane`** — no `role: worker`. |
| `kubeadmConfigPatches` | Kind bootstraps with kubeadm, so you can patch the kubeadm config. |
| `node-labels: "ingress-ready=true"` | **Required for ingress.** The ingress-nginx Kind manifest uses this label as a `nodeSelector`; without it the controller Pod stays `Pending` forever. |
| `extraPortMappings` | Publishes container ports to the host. |
| `containerPort: 80` | Port inside the node — where the ingress controller listens. |
| `hostPort: 80` | Port on Windows. Must be free. |
| `protocol: TCP` | TCP or UDP. |
| `listenAddress: "127.0.0.1"` | Binds to localhost only, so the cluster is not exposed to your LAN. Omit (defaults to `0.0.0.0`) to expose it. |
| `networking.apiServerAddress: "127.0.0.1"` | Where the API server is published. Keep it localhost unless you deliberately want remote `kubectl` access. |

### 4.4 Create

```powershell
# PowerShell
kind delete cluster --name demo          # 🔴 removes the basic cluster from §3
kind create cluster --config kind-config.yaml
```

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

✅ **Verify the mappings:**

```powershell
# PowerShell
docker port demo-control-plane
kubectl get nodes --show-labels | Select-String ingress-ready
```

**Expected output:**

```text
80/tcp -> 127.0.0.1:80
443/tcp -> 127.0.0.1:443
30080/tcp -> 127.0.0.1:30080
6443/tcp -> 127.0.0.1:52341
```

and `ingress-ready=true` present in the node labels.

> [!NOTE]
> Ports 80 and 443 may already be in use on Windows (IIS, Skype, or another web server). If `kind create` fails with a port conflict, change `hostPort` to `8080` and `8443` and adjust the URLs later.

---

## 5. Deploy the sample application

```powershell
# PowerShell
cd kubernetes-cluster-setup\kind
kubectl apply -f manifests\00-namespace.yaml
kubectl apply -f manifests\10-deployment.yaml
kubectl apply -f manifests\20-service.yaml

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

**Via the mapped NodePort:**

```powershell
# PowerShell
curl.exe http://localhost:30080
Start-Process "http://localhost:30080"
```

**Expected output:** the nginx welcome page HTML.

This works **only because** `kind-config.yaml` maps `containerPort: 30080` to `hostPort: 30080`. Without that mapping you would get `connection refused` — the port exists inside the container and nowhere else.

**Via `kubectl port-forward`** (works with any cluster, mapped or not):

```powershell
# PowerShell — leave running
kubectl -n demo port-forward svc/web 8080:80
```

```powershell
# PowerShell (second window)
curl.exe http://localhost:8080
```

**Docker port mapping explained:** `docker port demo-control-plane` shows the same table Docker uses for any `-p` published port. Kind wires host `127.0.0.1:30080` → container `:30080`, and kube-proxy inside the container routes `:30080` to your Pods. Three hops, all invisible once configured.

---

## 6. Install an ingress controller

### 6.1 Install

Use ingress-nginx's **Kind provider** manifest — it is built for exactly this setup (hostPort binding, `ingress-ready` nodeSelector).

```powershell
# PowerShell
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.15.1/deploy/static/provider/kind/deploy.yaml
```

### 6.2 Wait for it

```powershell
# PowerShell
kubectl wait --namespace ingress-nginx `
  --for=condition=ready pod `
  --selector=app.kubernetes.io/component=controller `
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

The two `Completed` Jobs installed the admission webhook and exited — expected, not an error.

> [!IMPORTANT]
> If the controller Pod stays `Pending`, your node is missing the `ingress-ready=true` label. Check with `kubectl get nodes --show-labels`. You must recreate the cluster with the `kubeadmConfigPatches` block from §4.2.

### 6.3 Apply the Ingress

```powershell
# PowerShell
kubectl apply -f manifests\30-ingress.yaml
kubectl -n demo get ingress
```

**Expected output:**

```text
NAME   CLASS   HOSTS        ADDRESS     PORTS   AGE
web    nginx   demo.local   localhost   80      30s
```

### 6.4 Verify with curl

The quickest check needs no hosts-file edit — just send the `Host` header:

```powershell
# PowerShell
curl.exe -H "Host: demo.local" http://localhost
```

**Expected output:** the nginx welcome page HTML.

### 6.5 Hostname mapping

For browser access, map `demo.local` to `127.0.0.1`.

**Windows hosts file: `C:\Windows\System32\drivers\etc\hosts`** — must be edited as Administrator:

```powershell
# PowerShell (Administrator)
Add-Content -Path "$env:WINDIR\System32\drivers\etc\hosts" -Value "127.0.0.1 demo.local"
Get-Content "$env:WINDIR\System32\drivers\etc\hosts" | Select-String demo.local
```

```powershell
# PowerShell
curl.exe http://demo.local
Start-Process "http://demo.local"
```

**Hosts file paths on all platforms** (for reference):

| Platform | Path |
|---|---|
| Windows | `C:\Windows\System32\drivers\etc\hosts` (edit as Administrator) |
| Linux / WSL | `/etc/hosts` (needs `sudo`) |
| macOS | `/etc/hosts` (needs `sudo`) |

---

## 7. Load a local image

Build on Windows, run in the cluster, no registry.

### 7.1 Build

```powershell
# PowerShell
mkdir demo-app; cd demo-app

@"
FROM nginx:1.30-alpine
RUN echo '<h1>Hello from my local image</h1>' > /usr/share/nginx/html/index.html
"@ | Out-File -Encoding ascii Dockerfile

docker build -t my-web:v1 .
docker images my-web
```

**Expected output:**

```text
REPOSITORY   TAG   IMAGE ID       CREATED         SIZE
my-web       v1    a1b2c3d4e5f6   2 seconds ago   52.5MB
```

Confirm the exact name and tag — `kind load` matches on `name:tag` and will not guess.

### 7.2 Load it into the cluster

```powershell
# PowerShell
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

```powershell
# PowerShell
docker exec demo-control-plane crictl images | Select-String my-web
```

**Expected output:**

```text
docker.io/library/my-web    v1    a1b2c3d4e5f6   52.5MB
```

The node uses **containerd**, so `crictl` is the tool inside — not `docker`.

### 7.4 Redeploy with it

```powershell
# PowerShell
kubectl -n demo set image deployment/web web=my-web:v1
kubectl -n demo rollout status deployment/web
curl.exe http://localhost:30080
```

**Expected output:** `<h1>Hello from my local image</h1>`

> [!IMPORTANT]
> **`imagePullPolicy` must be `IfNotPresent` (or `Never`).** With `Always`, the kubelet ignores the loaded image and tries to pull `my-web:v1` from Docker Hub, which does not exist → `ErrImagePull`.
>
> Kubernetes also **defaults to `Always` for any `:latest` tag**. Never tag local images `:latest`. The provided `manifests\10-deployment.yaml` sets `IfNotPresent` explicitly.

Revert:

```powershell
# PowerShell
kubectl -n demo set image deployment/web web=nginx:1.30-alpine
```

---

## 8. Cluster lifecycle

```powershell
# PowerShell

# List clusters
kind get clusters

# Switch kubectl context
kubectl config get-contexts
kubectl config use-context kind-demo

# Get the kubeconfig for a cluster
kind get kubeconfig --name demo

# Export logs for debugging (writes a directory of logs)
kind export logs --name demo .\kind-logs
Get-ChildItem .\kind-logs

# Inspect the node container
docker ps --filter "name=demo-control-plane"
docker exec -it demo-control-plane bash

# Delete
kind delete cluster --name demo          # 🔴 destroys it
kind delete clusters --all               # 🔴 destroys every Kind cluster

# Recreate
kind create cluster --config kind-config.yaml
```

> [!NOTE]
> **Kind has no stop/start.** Unlike Minikube, a Kind cluster is either running or deleted. You *can* `docker stop demo-control-plane` and `docker start` it, but the cluster often needs a minute to recover and this is not an officially supported workflow. Because creation takes under a minute, deleting and recreating is the normal pattern.

**Remove unused node images safely:**

```powershell
# PowerShell
docker images | Select-String kindest/node
docker rmi kindest/node:<OLD_VERSION>    # only versions you no longer use
```

Do not remove the image your current cluster runs on — check with `docker ps --format "{{.Image}}"`.

---

## 9. Troubleshooting

Full matrix in **[troubleshooting.md](./troubleshooting.md)**. Windows-specific:

| Symptom | Cause | Diagnostic | Fix |
|---|---|---|---|
| `Cannot connect to the Docker daemon` | Docker Desktop not running | `docker version` | Start Docker Desktop, wait for the whale |
| `failed to create cluster: node(s) already exist` | A cluster with that name exists | `kind get clusters` | `kind delete cluster --name demo`, then recreate |
| `port is already allocated` | Host port 80/443/30080 in use | `netstat -ano \| findstr :80` | Change `hostPort` in the config, or stop the conflicting service (IIS is a common culprit) |
| Cluster creation times out | Docker has too little memory | Docker Desktop → Settings → Resources | Raise to 6 GB and retry |
| `curl http://localhost:30080` refused | No `extraPortMappings` for 30080 | `docker port demo-control-plane` | Recreate with the config from §4 |
| Ingress controller Pod `Pending` | Node missing `ingress-ready=true` | `kubectl get nodes --show-labels` | Recreate with `kubeadmConfigPatches` (§4.2) |
| `ErrImagePull` for a local image | Not loaded, or `imagePullPolicy: Always` | `docker exec demo-control-plane crictl images \| Select-String <name>` | `kind load docker-image`; set `IfNotPresent`; avoid `:latest` |
| Wrong `kubectl` context | Docker Desktop Kubernetes also enabled | `kubectl config current-context` | `kubectl config use-context kind-demo` |
| Windows Firewall blocks access | Firewall rule on the Docker port | Windows Defender Firewall settings | Allow Docker Desktop, or use `kubectl port-forward` |
| Control-plane container exits | Out of memory, or a bad node image | `docker logs demo-control-plane` | Raise Docker memory; use Kind's default image |
| Downloads fail behind a corporate proxy | Proxy not configured | `$env:HTTP_PROXY` | Set proxy variables and configure them in Docker Desktop → Settings → Resources → Proxies |

**Diagnostics:**

```powershell
# PowerShell
kind get clusters
docker ps -a --filter "name=demo"
docker logs demo-control-plane --tail 50
kubectl get nodes
kubectl get pods -A
kubectl get events -A --sort-by=.lastTimestamp | Select-Object -Last 20
kind export logs --name demo .\kind-logs
```

---

## 10. Cleanup

### Delete just the application

```powershell
# PowerShell
kubectl delete namespace demo
```

### Delete the cluster

> [!CAUTION]
> 🔴 **DESTRUCTIVE** — destroys the node container and all cluster data. There is no stop/start with Kind; this is the normal way to finish.

```powershell
# PowerShell
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

```powershell
# PowerShell  🔴 DESTRUCTIVE
kind delete clusters --all
```

### Reclaim disk space

```powershell
# PowerShell
docker images | Select-String kindest/node
docker system df
docker image prune -a          # 🔴 removes ALL unused images, not just Kind's
```

Node images are ~1 GB each. Removing old versions you no longer use is usually the biggest win.

### Remove the hosts entry

```powershell
# PowerShell (Administrator)
$path = "$env:WINDIR\System32\drivers\etc\hosts"
(Get-Content $path) | Where-Object { $_ -notmatch "demo.local" } | Set-Content $path
```

### Uninstall the tools

```powershell
# PowerShell
winget uninstall Kubernetes.kind
winget uninstall Kubernetes.kubectl
Remove-Item -Recurse -Force "$env:USERPROFILE\.kube" -ErrorAction SilentlyContinue
```

Docker Desktop: uninstall via **Settings → Apps**.

---

## Official documentation

- Kind quick start — <https://kind.sigs.k8s.io/docs/user/quick-start/>
- Configuration — <https://kind.sigs.k8s.io/docs/user/configuration/>
- Ingress — <https://kind.sigs.k8s.io/docs/user/ingress/>
- Known issues — <https://kind.sigs.k8s.io/docs/user/known-issues/>
- Releases and node images — <https://github.com/kubernetes-sigs/kind/releases>
- Install kubectl on Windows — <https://kubernetes.io/docs/tasks/tools/install-kubectl-windows/>
- Docker Desktop for Windows — <https://docs.docker.com/desktop/install/windows-install/>
