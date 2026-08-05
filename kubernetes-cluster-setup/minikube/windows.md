# Minikube — Single-Node Cluster on Windows

Run one Kubernetes node on Windows 10/11 using Minikube.

All commands run in **PowerShell** unless marked otherwise. `# PowerShell (Administrator)` means right-click PowerShell → *Run as administrator*.

Validated **2026-08-05** on Windows 11 24H2, Minikube **v1.38.1**, Kubernetes **1.36**, Docker Desktop. Time: 15–20 minutes. Cost: free.

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

Plus:

- Windows 10 build 19044+ or Windows 11
- Virtualization enabled in BIOS/UEFI
- Administrator rights for installing tools (and for the `hyperv` driver)

**Check virtualization:**

```powershell
# PowerShell
Get-ComputerInfo -Property "HyperVRequirementVirtualizationFirmwareEnabled","HyperVisorPresent"
```

**Expected output:**

```text
HyperVRequirementVirtualizationFirmwareEnabled : True
HyperVisorPresent                              : True
```

`False` → reboot into BIOS/UEFI and enable Intel VT-x or AMD-V ("SVM Mode" on AMD).

---

## 2. Choose a driver

The **driver** determines how Minikube creates the node.

| Driver | How it works | Choose it when |
|---|---|---|
| **`docker`** ⭐ | The node is a Docker container inside Docker Desktop's VM | Default. Fastest, simplest, works on Home/Pro. |
| `hyperv` | A dedicated Hyper-V VM | You want real VM isolation and do not use Docker Desktop. **Windows Pro/Enterprise only**, needs Administrator. |
| `virtualbox` | A VirtualBox VM | You already use VirtualBox. **Conflicts with Hyper-V** — you cannot run both. |

This page uses **`docker`**. Notes for the others are in §4.4.

> [!IMPORTANT]
> **Docker Desktop's built-in Kubernetes is a different thing.** If you have it enabled (Settings → Kubernetes → *Enable Kubernetes*), it creates its own cluster and its own `kubectl` context called `docker-desktop`. It does not conflict with Minikube, but it is a common source of "why is my Deployment not there?" confusion. Either disable it or watch your context carefully (§5).

---

## 3. Install prerequisites

### 3.1 Docker Desktop

1. Download from <https://www.docker.com/products/docker-desktop/>
2. Install and reboot when asked
3. Launch Docker Desktop and wait for the whale icon to stop animating

✅ **Verify:**

```powershell
# PowerShell
docker version
docker run --rm hello-world
```

**Expected output:** both a `Client:` and a `Server:` section from `docker version`, then `Hello from Docker!`.

If `docker version` shows only `Client:` with an error, Docker Desktop is not running — start it.

**Give Docker enough resources:** Docker Desktop → **Settings → Resources** → at least **4 CPUs** and **6 GB** memory → *Apply & restart*. Minikube cannot use more than Docker has.

### 3.2 kubectl

**Option A — winget (recommended):**

```powershell
# PowerShell
winget install -e --id Kubernetes.kubectl
```

**Option B — Chocolatey:**

```powershell
# PowerShell (Administrator)
choco install kubernetes-cli -y
```

**Option C — manual:** download `kubectl.exe` from <https://kubernetes.io/docs/tasks/tools/install-kubectl-windows/> and put it on your `PATH`.

✅ **Verify:**

```powershell
# PowerShell
kubectl version --client
```

**Expected output:**

```text
Client Version: v1.36.1
Kustomize Version: v5.x.x
```

> [!NOTE]
> Docker Desktop bundles its own `kubectl`. If `kubectl version` reports something old, check `Get-Command kubectl` — Docker's copy may be earlier on your `PATH`.

### 3.3 Minikube

**Option A — winget:**

```powershell
# PowerShell
winget install -e --id Kubernetes.minikube
```

**Option B — Chocolatey:**

```powershell
# PowerShell (Administrator)
choco install minikube -y
```

**Option C — manual installer:** <https://minikube.sigs.k8s.io/docs/start/>

**Close and reopen PowerShell** so the updated `PATH` takes effect.

✅ **Verify:**

```powershell
# PowerShell
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

```powershell
# PowerShell
minikube start `
  --driver=docker `
  --cpus=4 `
  --memory=6g `
  --disk-size=30g `
  --profile=demo
```

> [!NOTE]
> PowerShell uses a backtick (`` ` ``) for line continuation, not a backslash. On one line it is:
> `minikube start --driver=docker --cpus=4 --memory=6g --disk-size=30g --profile=demo`

### 4.2 What each flag does

| Flag | Meaning |
|---|---|
| `--driver=docker` | Create the node as a Docker container. Explicit beats auto-detection. |
| `--cpus=4` | vCPUs for the node. **Minimum 2** — Minikube refuses fewer. Cannot exceed what Docker Desktop has. |
| `--memory=6g` | Memory for the node. Minimum ~1.8 GB; 4 GB+ is realistic. |
| `--disk-size=30g` | Node disk. Images and etcd live here. |
| `--profile=demo` | Names this cluster. Profiles let you keep several independent clusters; commands take `-p demo`. Without it the profile is `minikube`. |

**Optional flags worth knowing:**

| Flag | Use |
|---|---|
| `--kubernetes-version=v1.36.1` | Pin an exact Kubernetes version instead of Minikube's default |
| `--container-runtime=containerd` | Use containerd instead of the default Docker runtime inside the node |
| `--addons=ingress,metrics-server` | Enable add-ons at start time |

> [!WARNING]
> Do **not** pass `--nodes=2` (or higher). This guide is a single-node cluster. Multi-node Minikube uses more memory and behaves differently.

### 4.3 Expected output

```text
* [demo] minikube v1.38.1 on Microsoft Windows 11 Pro 10.0.26100
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

First run takes 2–5 minutes (it downloads the base image). Later starts take ~30 seconds.

### 4.4 Other drivers

**Hyper-V** (Windows Pro/Enterprise, Administrator required):

```powershell
# PowerShell (Administrator)
minikube start --driver=hyperv --cpus=4 --memory=6g --disk-size=30g --profile=demo
```

Enable Hyper-V first if needed:

```powershell
# PowerShell (Administrator)
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All
```

Reboot afterwards. Note: enabling Hyper-V **breaks VirtualBox** — they cannot coexist.

**VirtualBox:**

```powershell
# PowerShell
minikube start --driver=virtualbox --cpus=4 --memory=6g --disk-size=30g --profile=demo
```

Requires Hyper-V to be **disabled**:

```powershell
# PowerShell (Administrator)
Disable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
bcdedit /set hypervisorlaunchtype off
```

Reboot. (This also disables WSL2 and Docker Desktop.)

---

## 5. Verify the cluster

```powershell
# PowerShell
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

> [!IMPORTANT]
> **`kubectl config current-context` must say `demo`.** If it says `docker-desktop` you are talking to Docker Desktop's cluster, not Minikube. Fix it:
>
> ```powershell
> kubectl config use-context demo
> ```

Unlike a kubeadm cluster, Minikube does **not** taint the node — Pods schedule immediately.

---

## 6. Enable add-ons

Add-ons are pre-packaged cluster components Minikube can install for you.

```powershell
# PowerShell
minikube addons list -p demo
```

`storage-provisioner` and `default-storageclass` are enabled by default. Those two give you a working `PersistentVolumeClaim` out of the box — something a plain kubeadm cluster does not have.

> [!TIP]
> Enable only what you need. Every add-on consumes CPU and memory on your one node.

### Ingress

**What:** installs the ingress-nginx controller.
**Why:** lets you route by hostname/path instead of one NodePort per service.

```powershell
# PowerShell
minikube addons enable ingress -p demo
kubectl get pods -n ingress-nginx
```

**Expected output:**

```text
NAME                                        READY   STATUS      RESTARTS   AGE
ingress-nginx-admission-create-xxxxx        0/1     Completed   0          60s
ingress-nginx-admission-patch-xxxxx         0/1     Completed   0          60s
ingress-nginx-controller-xxxxxxxxx-xxxxx    1/1     Running     0          60s
```

The two `Completed` Jobs are expected — they install the admission webhook and exit.

### Metrics Server

**What:** collects CPU/memory usage.
**Why:** required for `kubectl top` and for HorizontalPodAutoscaler.

```powershell
# PowerShell
minikube addons enable metrics-server -p demo
Start-Sleep -Seconds 45
kubectl top nodes
kubectl top pods -A
```

**Expected output:**

```text
NAME   CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
demo   240m         6%       1420Mi          23%
```

`error: Metrics API not available` right after enabling just means it has not scraped yet — wait a minute.

### Dashboard

**What:** the Kubernetes web UI.

```powershell
# PowerShell
minikube addons enable dashboard -p demo
minikube addons enable metrics-server -p demo   # dashboard graphs need this
minikube dashboard -p demo
```

This opens your browser and **blocks the terminal** while it proxies. `Ctrl+C` to stop. For the URL without opening a browser: `minikube dashboard --url -p demo`.

### Storage

Already on. Confirm:

```powershell
# PowerShell
kubectl get storageclass
```

**Expected output:**

```text
NAME                 PROVISIONER                RECLAIMPOLICY   VOLUMEBINDINGMODE   AGE
standard (default)   k8s.io/minikube-hostpath   Delete          Immediate           5m
```

### Registry (optional)

```powershell
# PowerShell
minikube addons enable registry -p demo
```

Runs an in-cluster registry at `localhost:5000` inside the node. For the local-image workflow in §9 you do **not** need it — `minikube image load` is simpler.

### Disabling an add-on

```powershell
# PowerShell
minikube addons disable dashboard -p demo
```

---

## 7. Deploy the sample application

Manifests are in [`manifests/`](./manifests/).

```powershell
# PowerShell
cd kubernetes-cluster-setup\minikube
kubectl apply -f manifests\00-namespace.yaml
kubectl apply -f manifests\10-deployment.yaml
kubectl apply -f manifests\20-service.yaml
```

Apply the Ingress only if you enabled the ingress add-on:

```powershell
# PowerShell
kubectl apply -f manifests\30-ingress.yaml
```

**Wait and verify:**

```powershell
# PowerShell
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

**Both replicas run on the same node — expected.** `replicas: 2` means two Pods, not two machines. You get real ReplicaSet behaviour (rolling updates, self-healing, load-balanced Service endpoints), just no node-failure tolerance.

---

## 8. Access the application

### Method 1 — `minikube service` (easiest)

```powershell
# PowerShell
minikube service web-nodeport -n demo -p demo
```

Opens your default browser at the right URL.

**Important Windows/Docker-driver behaviour:** with the `docker` driver, Minikube's IP (`192.168.49.2`) is **not routable from Windows** — it lives inside Docker Desktop's VM. So `minikube service` starts a **tunnel process** on a random `127.0.0.1` port and opens that instead. The terminal stays busy; `Ctrl+C` closes the tunnel and the URL stops working.

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
! Because you are using a Docker driver on windows, the terminal needs to be open to run it.
```

URL only, without opening a browser:

```powershell
# PowerShell
minikube service web-nodeport -n demo -p demo --url
```

### Method 2 — `kubectl port-forward` (most predictable)

```powershell
# PowerShell — leave running
kubectl -n demo port-forward svc/web 8080:80
```

Second window:

```powershell
# PowerShell
curl.exe http://localhost:8080
Start-Process "http://localhost:8080"
```

Works with every driver, on every platform.

### Method 3 — NodePort via the Minikube IP

```powershell
# PowerShell
minikube ip -p demo
curl.exe "http://$(minikube ip -p demo):30080"
```

- **`hyperv` / `virtualbox` drivers:** works directly — the VM IP is routable from Windows.
- **`docker` driver:** usually **fails**. The IP is inside Docker Desktop's VM. Use Method 1 or 2.

### Method 4 — Ingress

Requires the ingress add-on and `manifests\30-ingress.yaml`.

```powershell
# PowerShell
kubectl -n demo get ingress
```

**Expected output:**

```text
NAME   CLASS   HOSTS        ADDRESS        PORTS   AGE
web    nginx   demo.local   192.168.49.2   80      2m
```

Add the hosts entry. **Windows hosts file: `C:\Windows\System32\drivers\etc\hosts`** — must be edited as Administrator:

```powershell
# PowerShell (Administrator)
$ip = minikube ip -p demo
Add-Content -Path "$env:WINDIR\System32\drivers\etc\hosts" -Value "$ip demo.local"
Get-Content "$env:WINDIR\System32\drivers\etc\hosts" | Select-String demo.local
```

Then:

```powershell
# PowerShell
curl.exe http://demo.local
```

> [!IMPORTANT]
> With the **`docker` driver on Windows**, `192.168.49.2` is unreachable from Windows, so the hosts entry alone will not work. Run `minikube tunnel` (Method 5) in a separate Administrator window, then point `demo.local` at `127.0.0.1` instead.

### Method 5 — `minikube tunnel`

**What:** creates a network route from your host into the cluster and assigns real external IPs to `LoadBalancer` Services.
**Why:** without it, a `type: LoadBalancer` Service on Minikube stays `<pending>` forever — there is no cloud provider to fulfil it.

```powershell
# PowerShell (Administrator) — leave running
minikube tunnel -p demo
```

Needs Administrator to create routes. Then:

```powershell
# PowerShell (second window)
kubectl -n demo expose deployment web --type=LoadBalancer --name=web-lb --port=80
kubectl -n demo get svc web-lb
curl.exe http://127.0.0.1
```

`EXTERNAL-IP` fills in within a few seconds. With the docker driver on Windows the tunnel binds to `127.0.0.1`.

Clean up:

```powershell
# PowerShell
kubectl -n demo delete svc web-lb
```

Then `Ctrl+C` the tunnel.

### Comparison

| Method | Driver `docker` | Driver `hyperv`/`virtualbox` | Terminal stays busy |
|---|---|---|---|
| `minikube service` | ✅ via tunnel | ✅ direct | ✅ (docker only) |
| `kubectl port-forward` | ✅ | ✅ | ✅ |
| NodePort via minikube IP | ❌ | ✅ | No |
| Ingress + hosts file | ⚠️ needs tunnel | ✅ | Depends |
| `minikube tunnel` | ✅ | ✅ | ✅ |

---

## 9. Local image workflow

Build an image on Windows and run it in the cluster **without a registry** — no Docker Hub account, no pushing.

### 9.1 Build an image

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

### 9.2 Load it into Minikube

Minikube's node has its **own** image store, separate from Docker Desktop's. An image visible to `docker images` is not automatically visible to the cluster.

```powershell
# PowerShell
minikube image load my-web:v1 -p demo
```

✅ **Verify it landed inside the node:**

```powershell
# PowerShell
minikube image ls -p demo | Select-String my-web
```

**Expected output:**

```text
docker.io/library/my-web:v1
```

### 9.3 Build directly inside Minikube (alternative)

Skips the load step entirely — Minikube builds the image in the node.

```powershell
# PowerShell
minikube image build -t my-web:v2 . -p demo
minikube image ls -p demo | Select-String my-web
```

### 9.4 Point Docker at Minikube's daemon (alternative)

```powershell
# PowerShell
& minikube -p demo docker-env --shell powershell | Invoke-Expression
docker build -t my-web:v3 .
docker images | Select-String my-web
```

Now `docker build` writes straight into the node's image store. To go back to Docker Desktop:

```powershell
# PowerShell
& minikube -p demo docker-env --unset --shell powershell | Invoke-Expression
```

> [!NOTE]
> This only works when the node's container runtime is Docker (the Minikube default). It does nothing if you started with `--container-runtime=containerd`.

### 9.5 Use the image — `imagePullPolicy` matters

```powershell
# PowerShell
kubectl -n demo set image deployment/web web=my-web:v1
kubectl -n demo rollout status deployment/web
```

> [!IMPORTANT]
> The Deployment must use `imagePullPolicy: IfNotPresent` (or `Never`). With `Always`, the kubelet ignores the locally-loaded copy and tries to pull `my-web:v1` from Docker Hub — which does not exist — giving `ErrImagePull`.
>
> **Kubernetes also defaults to `Always` for any image tagged `:latest`.** Never tag local images `:latest`; use a real version tag. The provided `manifests/10-deployment.yaml` sets `IfNotPresent` explicitly.

Check what happened:

```powershell
# PowerShell
kubectl -n demo get pods
kubectl -n demo port-forward svc/web 8080:80
```

Browse <http://localhost:8080> — you should see *Hello from my local image*.

Revert:

```powershell
# PowerShell
kubectl -n demo set image deployment/web web=nginx:1.30-alpine
```

---

## 10. Cluster lifecycle

```powershell
# PowerShell

# Start (or restart) — same flags as the original create
minikube start -p demo

# Stop — shuts the node down, keeps all state and data
minikube stop -p demo

# Pause — freezes Kubernetes processes, frees CPU, keeps memory
minikube pause -p demo
minikube unpause -p demo

# Status
minikube status -p demo

# Logs
minikube logs -p demo
minikube logs -p demo --problems      # only detected problems
minikube logs -p demo -f              # follow

# Shell into the node
minikube ssh -p demo
#   inside:  docker ps ; crictl ps ; exit

# List all profiles
minikube profile list

# Delete one profile
minikube delete -p demo

# Delete every profile
minikube delete --all
```

### Stop vs pause vs delete

| Command | Node | Data | Restart time | Use when |
|---|---|---|---|---|
| `pause` | Frozen | Kept in memory | Instant | Short break; free CPU immediately |
| `stop` | Shut down | Kept on disk | ~30 s | End of day; keep your work |
| `delete` | 🔴 Destroyed | 🔴 Gone | Full recreate | Done, or starting clean |

> [!CAUTION]
> 🔴 `minikube delete` destroys the cluster, every workload, and all PersistentVolume data. There is no undo.

---

## 11. Troubleshooting

Full matrix in **[troubleshooting.md](./troubleshooting.md)**. The Windows-specific ones:

| Symptom | Cause | Diagnostic | Fix |
|---|---|---|---|
| `Cannot connect to the Docker daemon` | Docker Desktop not running | `docker version` | Start Docker Desktop, wait for the whale to settle |
| `Exiting due to RSRC_INSUFFICIENT_CORES` | Docker Desktop has <2 CPUs | Docker Desktop → Settings → Resources | Raise CPUs to 4, apply and restart |
| `Exiting due to MK_USAGE: Docker Desktop has only X MB memory` | Not enough memory allocated | Same | Raise memory to 6 GB, or lower `--memory` |
| `This computer doesn't have VT-X/AMD-v enabled` | Virtualization off in firmware | `Get-ComputerInfo` (§1) | Enable VT-x/AMD-V in BIOS/UEFI |
| Hyper-V and VirtualBox conflict | Both cannot run at once | `bcdedit /enum \| findstr hypervisor` | Pick one; disable the other and reboot |
| `profile "demo" already exists` | Profile is still there from before | `minikube profile list` | `minikube start -p demo` to reuse, or `minikube delete -p demo` |
| `minikube ip` unreachable | docker driver — the IP lives inside Docker's VM | `curl.exe http://<ip>:30080` fails | Use `minikube service --url` or `kubectl port-forward` |
| `minikube service` does not open a browser | No default browser association, or tunnel blocked | Run with `--url` | Copy the URL manually |
| `minikube tunnel` does nothing | Not running as Administrator | Check the window title | Re-run in PowerShell (Administrator) |
| Ingress returns 404 or times out | docker driver — Minikube IP unroutable | `kubectl -n ingress-nginx get pods` | Run `minikube tunnel` and point the hosts entry at `127.0.0.1` |
| `ErrImagePull` for a locally-built image | Image not loaded, or `imagePullPolicy: Always` | `minikube image ls -p demo \| Select-String <name>` | `minikube image load`; set `IfNotPresent`; avoid the `:latest` tag |
| `kubectl` talks to the wrong cluster | Context is `docker-desktop` | `kubectl config current-context` | `kubectl config use-context demo` |
| Downloads fail behind a corporate proxy | Proxy not configured | `$env:HTTP_PROXY` | Set `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` and pass `--docker-env` to `minikube start` |

**Diagnostics:**

```powershell
# PowerShell
minikube status -p demo
minikube logs -p demo --problems
kubectl get events -A --sort-by=.lastTimestamp | Select-Object -Last 20
docker ps -a --filter "name=demo"
kubectl config current-context
```

---

## 12. Cleanup

### Delete just the application

```powershell
# PowerShell
kubectl delete namespace demo
```

### Stop the cluster (keep everything)

```powershell
# PowerShell
minikube stop -p demo
```

### Delete the cluster

> [!CAUTION]
> 🔴 **DESTRUCTIVE** — destroys the node and all cluster data.

```powershell
# PowerShell
minikube delete -p demo
minikube profile list
```

**Expected output:** the `demo` profile is gone.

### Delete everything Minikube ever created

```powershell
# PowerShell  🔴 DESTRUCTIVE
minikube delete --all --purge
Remove-Item -Recurse -Force "$env:USERPROFILE\.minikube" -ErrorAction SilentlyContinue
```

`--purge` also removes the `.minikube` directory (cached ISOs and base images — often several GB).

### Reclaim Docker disk space

```powershell
# PowerShell
docker system df
docker system prune -a        # 🔴 removes ALL unused images, not just Minikube's
```

### Remove the hosts-file entry

```powershell
# PowerShell (Administrator)
$path = "$env:WINDIR\System32\drivers\etc\hosts"
(Get-Content $path) | Where-Object { $_ -notmatch "demo.local" } | Set-Content $path
```

### Uninstall the tools

```powershell
# PowerShell
winget uninstall Kubernetes.minikube
winget uninstall Kubernetes.kubectl
```

Docker Desktop: uninstall via **Settings → Apps**.

---

## Official documentation

- Minikube start — <https://minikube.sigs.k8s.io/docs/start/>
- Drivers — <https://minikube.sigs.k8s.io/docs/drivers/>
- Add-ons — <https://minikube.sigs.k8s.io/docs/handbook/addons/>
- Accessing apps — <https://minikube.sigs.k8s.io/docs/handbook/accessing/>
- Pushing images — <https://minikube.sigs.k8s.io/docs/handbook/pushing/>
- Install kubectl on Windows — <https://kubernetes.io/docs/tasks/tools/install-kubectl-windows/>
- Docker Desktop — <https://docs.docker.com/desktop/install/windows-install/>
