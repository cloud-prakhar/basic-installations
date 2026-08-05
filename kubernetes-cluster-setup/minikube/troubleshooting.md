# Minikube — Troubleshooting

Every issue has **symptoms**, **cause**, a **diagnostic command**, and a **resolution**.

Jump to: [First response](#first-response) · [Driver and daemon](#a-driver-and-daemon) · [Resources](#b-resources) · [Profiles and context](#c-profiles-and-context) · [Networking and access](#d-networking-and-access) · [Images](#e-images) · [Add-ons](#f-add-ons) · [Platform-specific](#g-platform-specific) · [Nuclear option](#when-nothing-works)

Throughout, `-p demo` is the profile name used in the guides. Substitute yours (or drop it if you used the default `minikube` profile).

---

## First response

```bash
# 1. What does Minikube think is happening?
minikube status -p demo

# 2. Minikube's own problem detector
minikube logs -p demo --problems

# 3. Is the node up?
kubectl get nodes -o wide
kubectl get pods -A

# 4. Am I even talking to the right cluster?
kubectl config current-context
kubectl config get-contexts

# 5. Is the driver healthy?
docker version
docker ps -a --filter "name=demo"

# 6. Recent cluster complaints
kubectl get events -A --sort-by=.lastTimestamp | tail -30
```

> [!TIP]
> `minikube logs -p demo --problems` filters thousands of log lines down to the ones Minikube recognises as failures. Run it before reading full logs.

---

## A. Driver and daemon

### A1. Docker daemon unavailable

**Symptoms**

```text
X Exiting due to PROVIDER_DOCKER_NOT_RUNNING: "docker version --format ..." exit status 1
Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?
```

**Cause** — Docker is not started, not installed, or not reachable by your user.

**Diagnostic**

```bash
docker version
docker info 2>&1 | head -5
```

Linux/EC2 only:

```bash
systemctl status docker --no-pager
```

**Resolution**

| Platform | Fix |
|---|---|
| **Windows / macOS** | Start Docker Desktop; wait for the whale icon to stop animating |
| **macOS + Colima** | `colima start` (check with `colima status`) |
| **Linux / EC2** | `sudo systemctl start docker` and `sudo systemctl enable docker` |
| **WSL2** | Enable Docker Desktop → Settings → Resources → WSL Integration for this distro; or `sudo systemctl start docker` if you installed Docker Engine in WSL |

---

### A2. Docker permission denied

**Symptoms**

```text
permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock
X Exiting due to DRV_AS_ROOT: The "docker" driver should not be used with root privileges.
```

**Cause** — your user is not in the `docker` group, or you tried to work around that by using `sudo`.

**Diagnostic**

```bash
whoami
groups | grep docker
ls -l /var/run/docker.sock
```

**Resolution**

```bash
# Linux / WSL / EC2
sudo usermod -aG docker "$USER"
newgrp docker          # apply without logging out
docker version         # verify
```

> [!CAUTION]
> **Do not "fix" this with `sudo minikube start` or `--force`.** Both create root-owned `~/.minikube` and `~/.kube`, so every later command as your normal user fails with permission errors — a much more confusing problem than the one you started with.
>
> If you already did it:
>
> ```bash
> sudo rm -rf ~/.minikube ~/.kube /root/.minikube /root/.kube
> minikube start -p demo        # as your normal user
> ```

The `docker` group is effectively root on that machine. Acceptable on a personal or disposable machine, not on a shared host.

---

### A3. WSL Docker integration missing

**Symptoms** — `docker` works in PowerShell but not inside WSL, or `command not found: docker` in WSL.

**Cause** — Docker Desktop's WSL integration is off for that distribution.

**Diagnostic**

```bash
# WSL Ubuntu
which docker
docker version
cat /etc/wsl.conf 2>/dev/null
```

```powershell
# PowerShell
wsl --list --verbose
```

**Resolution**

1. Docker Desktop → **Settings → General** → tick **Use the WSL 2 based engine**
2. Docker Desktop → **Settings → Resources → WSL Integration** → tick your distro
3. **Apply & restart**
4. Reopen the WSL terminal and re-run `docker version`

Alternatively install Docker Engine inside WSL — this needs systemd:

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

Then install `docker-ce` and `sudo systemctl enable --now docker`.

---

### A4. Hyper-V conflicts

**Symptoms**

```text
This computer doesn't have VT-X/AMD-v enabled
VBoxManage: error: VT-x is not available (VERR_VMX_NO_VMX)
```

with VirtualBox, while Docker Desktop or WSL2 works fine.

**Cause** — Hyper-V and VirtualBox cannot both own the CPU's virtualization extensions. Docker Desktop and WSL2 both require Hyper-V; enabling it locks VirtualBox out.

**Diagnostic**

```powershell
# PowerShell
Get-ComputerInfo -Property "HyperVisorPresent"
bcdedit /enum | findstr -i hypervisorlaunchtype
```

**Resolution** — pick one stack:

**Keep Hyper-V** (recommended — required for Docker Desktop and WSL2):

```powershell
# PowerShell
minikube start --driver=docker -p demo
# or
minikube start --driver=hyperv -p demo     # needs Administrator
```

**Switch to VirtualBox** (disables WSL2 and Docker Desktop):

```powershell
# PowerShell (Administrator)  🔴 breaks WSL2 and Docker Desktop
bcdedit /set hypervisorlaunchtype off
Disable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
```

Reboot. To undo: `bcdedit /set hypervisorlaunchtype auto` and reboot.

---

### A5. Virtualization disabled in firmware

**Symptoms**

```text
This computer doesn't have VT-X/AMD-v enabled. Enabling it in the BIOS is mandatory
```

on a machine where Hyper-V is not the issue.

**Diagnostic**

```powershell
# PowerShell
Get-ComputerInfo -Property "HyperVRequirementVirtualizationFirmwareEnabled"
```

```bash
# Linux
egrep -c '(vmx|svm)' /proc/cpuinfo      # must be > 0
```

**Resolution** — reboot into BIOS/UEFI and enable **Intel VT-x** or **AMD-V** (often labelled "SVM Mode" on AMD boards). Save and reboot.

On a cloud VM this usually means nested virtualization is unavailable — use the `docker` driver, which does not need it.

---

## B. Resources

### B1. Insufficient CPU

**Symptoms**

```text
X Exiting due to RSRC_INSUFFICIENT_CORES: requested cpu count 4 is greater than the available cpus of 2
X Exiting due to MK_USAGE: Docker Desktop only has 2 CPUs available
```

**Diagnostic**

```bash
# Linux / macOS / WSL
nproc 2>/dev/null || sysctl -n hw.ncpu
docker info --format '{{.NCPU}}'
```

**Resolution**

| Platform | Fix |
|---|---|
| Windows / macOS + Docker Desktop | Settings → Resources → raise **CPUs** to 4 → Apply & restart |
| macOS + Colima | `colima stop && colima start --cpu 4 --memory 6` |
| WSL2 | `processors=4` under `[wsl2]` in `%USERPROFILE%\.wslconfig`, then `wsl --shutdown` |
| Linux / EC2 | Lower `--cpus`, or use a bigger machine |

**Minikube requires at least 2 CPUs.** With exactly 2 available, use `--cpus=2`.

---

### B2. Insufficient memory

**Symptoms**

```text
X Exiting due to RSRC_INSUFFICIENT_MEMORY: Docker Desktop has only 3901MB memory but you specified 6000MB
```

Or, later: Pods `Evicted`, node condition `MemoryPressure`.

**Diagnostic**

```bash
free -h 2>/dev/null || vm_stat
docker info --format '{{.MemTotal}}'
kubectl describe node demo | grep -A6 Conditions
kubectl top nodes           # needs metrics-server
```

**Resolution**

| Platform | Fix |
|---|---|
| Windows / macOS + Docker Desktop | Settings → Resources → raise **Memory** to 6 GB |
| macOS + Colima | `colima stop && colima start --cpu 4 --memory 6` |
| WSL2 | `memory=6GB` in `.wslconfig`, then `wsl --shutdown` |
| Linux / EC2 | Lower `--memory` (minimum ~1.8 GB), or close applications / resize the instance |

If Pods are evicted on a running cluster, your workloads' `resources.requests` exceed what the node has after the control plane takes its share. Lower them.

---

### B3. Disk exhaustion

**Symptoms** — `no space left on device`; Pods `Evicted` with `DiskPressure`; image pulls fail.

**Diagnostic**

```bash
df -h /
docker system df
minikube ssh -p demo -- df -h
du -sh ~/.minikube
```

**Resolution**

```bash
# Free node-internal space
minikube ssh -p demo -- docker system prune -a -f

# Free host space
docker system prune -a          # 🔴 removes ALL unused images, not only Minikube's
minikube delete --all --purge   # 🔴 removes every profile and cached base image
```

`~/.minikube` caches base images and ISOs and can reach several GB.

---

## C. Profiles and context

### C1. Profile already exists

**Symptoms**

```text
! Profile "demo" not found. Run "minikube profile list" to view all profiles.
! StartHost failed, but will try again: creating host: create: creating: create kic node: container name "demo" already in use
```

**Diagnostic**

```bash
minikube profile list
docker ps -a --filter "name=demo"
```

**Resolution**

Reuse it:

```bash
minikube start -p demo
```

Or recreate it:

```bash
minikube delete -p demo         # 🔴 destroys that cluster's data
minikube start -p demo --driver=docker --cpus=4 --memory=6g
```

If the profile is gone but a stale container remains:

```bash
docker rm -f demo
minikube start -p demo
```

---

### C2. Wrong kubectl context

**Symptoms** — `kubectl get pods` shows nothing you deployed; resources appear to vanish; you are somehow editing a different cluster.

**Cause** — your current context points at Docker Desktop's Kubernetes, another Minikube profile, Kind, or a remote cluster.

**Diagnostic**

```bash
kubectl config current-context
kubectl config get-contexts
kubectl cluster-info
```

**Expected output** for this guide:

```text
demo
```

**Resolution**

```bash
kubectl config use-context demo
# or let Minikube set it:
minikube update-context -p demo
kubectl get nodes
```

> [!TIP]
> If you keep Docker Desktop's Kubernetes enabled alongside Minikube, disable it (Settings → Kubernetes → untick *Enable Kubernetes*) unless you actively use it. It is the single most common cause of this confusion.

---

### C3. Cluster gone after a reboot

**Symptoms** — `kubectl` reports connection refused after restarting your machine.

**Cause** — Minikube does not start on boot. On WSL2, the distro itself does not start on login either.

**Diagnostic**

```bash
minikube status -p demo
docker ps -a --filter "name=demo"
```

**Resolution**

```bash
minikube start -p demo
```

State and workloads are preserved — this is a restart, not a recreate. Give it ~30 seconds.

WSL2 users: open the Ubuntu terminal first (that starts the WSL VM), then run `minikube start -p demo`.

---

## D. Networking and access

### D1. `minikube ip` is not reachable

**Symptoms** — `curl http://192.168.49.2:30080` hangs or refuses on Windows/macOS, while everything looks healthy.

**Cause** — **by design.** With the `docker` driver on Windows and macOS, the node lives inside Docker Desktop's / Colima's Linux VM. Your host has no route to that network. On **Linux** it works because containers run on the host kernel directly.

**Diagnostic**

```bash
minikube ip -p demo
ping -c2 "$(minikube ip -p demo)"        # times out on Windows/macOS — expected
minikube ssh -p demo -- curl -s localhost:30080 | head -3    # proves the app works
```

**Resolution** — use a method that does not need the node IP:

```bash
minikube service web-nodeport -n demo -p demo --url    # starts a tunnel on Win/macOS
kubectl -n demo port-forward svc/web 8080:80
```

| Platform | NodePort via `minikube ip` |
|---|---|
| Linux | ✅ works |
| Windows (docker driver) | ❌ use `minikube service` or `port-forward` |
| macOS (docker driver) | ❌ use `minikube service` or `port-forward` |
| Windows (hyperv/virtualbox) | ✅ works |
| macOS (qemu + socket_vmnet) | ✅ works |

---

### D2. `minikube service` does not open a browser

**Symptoms**

```text
X Exiting due to HOST_BROWSER: failed to open browser: exec: "xdg-open": executable file not found in $PATH
```

or the command prints a URL but nothing opens.

**Cause** — no graphical browser on that machine: a headless EC2 instance, a WSL distro, or a server.

**Diagnostic**

```bash
echo "$BROWSER"
which xdg-open open 2>/dev/null
```

**Resolution**

```bash
minikube service web-nodeport -n demo -p demo --url
```

Then use the URL yourself.

| Environment | How to actually reach it |
|---|---|
| WSL2 | `sudo apt-get install -y wslu && export BROWSER=wslview`, or `kubectl port-forward --address 0.0.0.0` and browse from Windows |
| Headless Linux | `--url` + SSH port forwarding |
| EC2 | `--url` + SSH or SSM port forwarding. `minikube service` cannot open a browser on a remote server — and even if it could, the browser would be on the server, not on your laptop. |

---

### D3. `minikube tunnel` failure

**Symptoms** — a `LoadBalancer` Service stays `<pending>`; the tunnel exits immediately; permission errors.

**Cause** — the tunnel needs elevated privileges to create host routes, or another tunnel is already running.

**Diagnostic**

```bash
kubectl -n demo get svc
ps aux | grep "minikube tunnel" | grep -v grep
```

**Resolution**

```bash
# Linux / macOS — prompts for sudo
minikube tunnel -p demo
```

```powershell
# PowerShell (Administrator)
minikube tunnel -p demo
```

Key points:

- The tunnel is a **foreground process**. Keep the terminal open; closing it removes the routes.
- Only run **one** tunnel per profile.
- On Windows/macOS with the docker driver it binds `127.0.0.1`, so the Service is reachable at `http://localhost`.
- Kill a stuck tunnel: `pkill -f "minikube tunnel"` (Linux/macOS) or close the window.

> [!NOTE]
> A `type: LoadBalancer` Service is a *request* that some controller must fulfil. On a cloud, the cloud provider does it. On Minikube, `minikube tunnel` is that controller. Without it the Service stays `<pending>` forever — that is not a bug.

---

### D4. Ingress is inaccessible

**Symptoms** — `curl http://demo.local` times out, returns `404`, or `connection refused`.

**Diagnostic**

```bash
minikube addons list -p demo | grep ingress
kubectl -n ingress-nginx get pods
kubectl -n demo get ingress
kubectl -n demo describe ingress web | tail -20
kubectl -n ingress-nginx logs -l app.kubernetes.io/component=controller --tail=50
```

**Resolution by cause:**

| Finding | Fix |
|---|---|
| Ingress add-on not enabled | `minikube addons enable ingress -p demo` |
| Controller Pod not `Running` | `kubectl -n ingress-nginx describe pod <name>` — usually resource pressure |
| Ingress `ADDRESS` column empty | Wait ~60 s after enabling; the controller must publish its address |
| `404 Not Found` from nginx | The `host:` in the Ingress does not match the `Host` header you sent, or the backend Service name/port is wrong |
| `503 Service Temporarily Unavailable` | No ready endpoints — `kubectl -n demo get endpoints web` must be non-empty |
| Times out on Windows/macOS | Minikube IP unroutable → `kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 8080:80` and point `demo.local` at `127.0.0.1` |
| `ingressClassName` mismatch | Must be `nginx` — check `kubectl get ingressclass` |

**Hosts file locations:**

| Platform | Path | Notes |
|---|---|---|
| Windows | `C:\Windows\System32\drivers\etc\hosts` | Edit as Administrator |
| Linux / WSL | `/etc/hosts` | Needs `sudo`. WSL regenerates it unless `generateHosts = false` is set in `/etc/wsl.conf` |
| macOS | `/etc/hosts` | Needs `sudo` |

---

### D5. Corporate proxy issues

**Symptoms** — `minikube start` hangs on "Pulling base image"; image pulls time out; `x509: certificate signed by unknown authority` from a TLS-inspecting proxy.

**Diagnostic**

```bash
env | grep -i proxy
curl -sSI https://registry.k8s.io/v2/ | head -1
docker info | grep -i proxy
```

**Resolution**

```bash
export HTTP_PROXY=http://<PROXY_HOST>:<PORT>
export HTTPS_PROXY=http://<PROXY_HOST>:<PORT>
export NO_PROXY=localhost,127.0.0.1,10.96.0.0/12,192.168.49.0/24,10.244.0.0/16,.svc,.cluster.local

minikube start -p demo \
  --driver=docker \
  --docker-env HTTP_PROXY="$HTTP_PROXY" \
  --docker-env HTTPS_PROXY="$HTTPS_PROXY" \
  --docker-env NO_PROXY="$NO_PROXY"
```

> [!IMPORTANT]
> `NO_PROXY` **must** include the Service CIDR (`10.96.0.0/12`), the Pod CIDR (`10.244.0.0/16`), the Minikube network (`192.168.49.0/24`), and `.svc,.cluster.local`. Without them, in-cluster traffic is sent to the proxy and fails in ways that look like DNS problems.

For a TLS-inspecting proxy, add your corporate CA to `~/.minikube/certs/` **before** `minikube start`:

```bash
mkdir -p ~/.minikube/certs
cp /path/to/corporate-ca.crt ~/.minikube/certs/
minikube start -p demo --embed-certs
```

Also configure Docker Desktop's own proxy under Settings → Resources → Proxies.

---

## E. Images

### E1. Local image not found

**Symptoms**

```text
Failed to pull image "my-web:v1": failed to resolve reference "docker.io/library/my-web:v1": not found
Status: ErrImagePull / ImagePullBackOff
```

**Cause** — one of three things:

1. The image was never loaded into the node (the node has its **own** image store, separate from your host Docker daemon).
2. `imagePullPolicy` is `Always`, so the kubelet ignores the local copy and tries the registry.
3. The image is tagged `:latest` — Kubernetes **defaults to `Always`** for that tag.

**Diagnostic**

```bash
docker images | grep my-web                 # on the host
minikube image ls -p demo | grep my-web     # inside the node — this is what matters
kubectl -n demo get deployment web -o jsonpath='{.spec.template.spec.containers[0].imagePullPolicy}'; echo
kubectl -n demo describe pod <POD> | grep -A5 -i "failed to pull"
```

**Resolution**

```bash
# 1. Load it into the node
minikube image load my-web:v1 -p demo
minikube image ls -p demo | grep my-web

# 2. Ensure the policy allows the local copy
kubectl -n demo patch deployment web \
  --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]'

# 3. Restart the Pods
kubectl -n demo rollout restart deployment/web
kubectl -n demo rollout status deployment/web
```

**Alternatives that avoid the load step entirely:**

```bash
# Build inside the node
minikube image build -t my-web:v2 . -p demo

# Or point your Docker CLI at the node's daemon
eval "$(minikube -p demo docker-env)"        # Linux/macOS/WSL
docker build -t my-web:v3 .
eval "$(minikube -p demo docker-env --unset)"
```

```powershell
# PowerShell equivalent
& minikube -p demo docker-env --shell powershell | Invoke-Expression
docker build -t my-web:v3 .
& minikube -p demo docker-env --unset --shell powershell | Invoke-Expression
```

> [!IMPORTANT]
> **Never tag local images `:latest`.** Use a real version tag. `docker-env` only works when the node's runtime is Docker (Minikube's default) — with `--container-runtime=containerd`, use `minikube image load` or `minikube image build`.

---

### E2. Apple Silicon image compatibility

**Symptoms**

```text
exec /docker-entrypoint.sh: exec format error
standard_init_linux.go: exec user process caused: exec format error
no matching manifest for linux/arm64/v8 in the manifest list entries
```

**Cause** — an `amd64`-only image on an `arm64` node.

**Diagnostic**

```bash
uname -m                                    # arm64 on Apple Silicon
kubectl -n demo get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}'; echo
docker manifest inspect <IMAGE> | grep -A2 architecture
kubectl -n demo logs <POD>
```

**Resolution**

1. **Prefer multi-arch images.** `nginx`, `redis`, `postgres`, `busybox`, and most official images publish `arm64`. `nginx:1.30-alpine` (used in this guide) does.
2. **Build for the node's architecture** — on Apple Silicon, plain `docker build` already produces arm64. Do **not** add `--platform linux/amd64` unless you specifically want emulation.
3. **Build inside the node** so architecture always matches:

```bash
minikube image build -t my-web:v1 . -p demo
```

4. **Last resort — emulate.** Requires QEMU binfmt support and runs slowly:

```bash
docker build --platform linux/amd64 -t my-web:amd64 .
minikube image load my-web:amd64 -p demo
```

---

### E3. Image pull rate limits

**Symptoms**

```text
toomanyrequests: You have reached your pull rate limit
```

**Cause** — Docker Hub's anonymous pull limit.

**Resolution**

```bash
# Authenticate on the host, then load images in
docker login
docker pull <IMAGE>
minikube image load <IMAGE> -p demo
```

Or create a pull secret inside the cluster:

```bash
kubectl -n demo create secret docker-registry regcred \
  --docker-username=<USER> --docker-password=<TOKEN>
kubectl -n demo patch serviceaccount default \
  -p '{"imagePullSecrets":[{"name":"regcred"}]}'
```

---

## F. Add-ons

### F1. Add-on will not become ready

**Diagnostic**

```bash
minikube addons list -p demo
kubectl get pods -A | grep -v Running
kubectl describe pod <POD> -n <NAMESPACE> | tail -20
```

| Add-on | Namespace | Common failure |
|---|---|---|
| `ingress` | `ingress-nginx` | Not enough memory; admission webhook Jobs still `Completed` (that is normal) |
| `metrics-server` | `kube-system` | Needs ~30–60 s before `kubectl top` returns data |
| `dashboard` | `kubernetes-dashboard` | Needs `metrics-server` for graphs |
| `registry` | `kube-system` | Port 5000 conflict inside the node |

**Resolution**

```bash
minikube addons disable <addon> -p demo
minikube addons enable <addon> -p demo
kubectl get pods -n <namespace> -w
```

If it fails on resources, free some by disabling other add-ons — every one of them takes memory from your single node.

---

### F2. `kubectl top` says metrics are not available

**Symptoms**

```text
error: Metrics API not available
```

**Diagnostic**

```bash
minikube addons list -p demo | grep metrics-server
kubectl -n kube-system get deployment metrics-server
kubectl get apiservice v1beta1.metrics.k8s.io
```

**Resolution**

```bash
minikube addons enable metrics-server -p demo
kubectl -n kube-system rollout status deployment/metrics-server --timeout=120s
sleep 30
kubectl top nodes
```

The 30-second wait is real — metrics-server needs at least one scrape interval before it has data.

---

### F3. PersistentVolumeClaim stuck `Pending`

**Diagnostic**

```bash
kubectl get storageclass
kubectl -n demo describe pvc <PVC_NAME> | tail -10
kubectl -n kube-system get pod -l integration-test=storage-provisioner
```

**Resolution**

```bash
minikube addons enable storage-provisioner -p demo
minikube addons enable default-storageclass -p demo
kubectl get storageclass
```

**Expected output:**

```text
NAME                 PROVISIONER                RECLAIMPOLICY   VOLUMEBINDINGMODE   AGE
standard (default)   k8s.io/minikube-hostpath   Delete          Immediate           5m
```

If your PVC names a `storageClassName` that does not exist, either create that class or remove the field so the default is used.

---

## G. Platform-specific

### G1. Windows

| Symptom | Cause | Fix |
|---|---|---|
| `minikube` not recognised after install | `PATH` not refreshed | Close and reopen PowerShell |
| Backslash line continuation fails | PowerShell uses a backtick | Use `` ` `` or put the command on one line |
| `minikube tunnel` does nothing | Not elevated | Re-run in PowerShell (Administrator) |
| Hosts file edit rejected | Not elevated | Edit `C:\Windows\System32\drivers\etc\hosts` as Administrator |
| Docker Desktop starts then stops | WSL2 backend problem | `wsl --update`, restart Docker Desktop |
| Antivirus blocks the node container | Security software | Add Docker Desktop and `%USERPROFILE%\.minikube` to exclusions |

### G2. macOS

| Symptom | Cause | Fix |
|---|---|---|
| Two `kubectl` binaries disagree | Homebrew's and Docker Desktop's both on `PATH` | `which -a kubectl`; `brew link --overwrite kubernetes-cli` |
| `minikube tunnel` asks for a password repeatedly | It creates routes via `sudo` | Expected — keep the window open |
| Cluster hangs after the Mac sleeps | VM clock drift | `minikube stop -p demo && minikube start -p demo` |
| Fans spin constantly | Too many vCPUs, or amd64 emulation | Lower `--cpus`; avoid `--platform linux/amd64` images |
| `sed -i` fails in a cleanup command | macOS `sed` needs an argument to `-i` | `sed -i '' '/demo.local/d' /etc/hosts` |
| Colima VM is still running after `minikube stop` | Separate lifecycle | `colima stop` |

### G3. WSL2

| Symptom | Cause | Fix |
|---|---|---|
| Windows browser cannot reach a port-forward | Bound to `127.0.0.1` | `kubectl port-forward --address 0.0.0.0 ...` |
| `localhost` from Windows does not reach WSL | `localhostForwarding` off | `localhostForwarding=true` in `.wslconfig`, then `wsl --shutdown` |
| `/etc/hosts` entry keeps disappearing | WSL regenerates it | `[network] generateHosts = false` in `/etc/wsl.conf`, then `wsl --shutdown` |
| WSL2 has too little RAM/CPU | Defaults | `memory=6GB`, `processors=4` in `%USERPROFILE%\.wslconfig`, `wsl --shutdown` |
| Cluster gone after Windows reboot | WSL does not auto-start | Open Ubuntu, then `minikube start -p demo` |

### G4. EC2

| Symptom | Cause | Fix |
|---|---|---|
| `DRV_AS_ROOT` | Running as root | `sudo su - ubuntu`; add `ubuntu` to the `docker` group. Do **not** use `--force` |
| VM driver fails | No nested virtualization on standard EC2 | Use `--driver=docker` |
| `xdg-open not found` | Headless server | Use `--url` plus SSH/SSM port forwarding |
| NodePort unreachable from your laptop | No security-group rule, or not bound on the public interface | `curl` on the instance first; then SSH forwarding, or add a `/32` SG rule |
| Slow then unresponsive | Burstable instance out of CPU credits | CloudWatch → `CPUCreditBalance`; use a non-burstable type |
| Disk fills at 30 GB | Cached images | `docker system prune -a`; grow the EBS volume |

---

## When nothing works

> [!CAUTION]
> 🔴 **DESTRUCTIVE.** Destroys the cluster and all its data. With Minikube this is cheap — recreating takes a couple of minutes — so reach for it earlier than you would with kubeadm.

```bash
# 1. Delete the profile
minikube delete -p demo

# 2. Or delete everything Minikube ever created
minikube delete --all --purge
rm -rf ~/.minikube ~/.kube/config

# 3. Clean up stale containers
docker ps -a --filter "name=demo"
docker rm -f demo 2>/dev/null || true

# 4. Reclaim space
docker system prune -a          # 🔴 removes ALL unused images

# 5. Start fresh
minikube start --driver=docker --cpus=4 --memory=6g --disk-size=30g -p demo
```

Then return to your platform page:
[windows.md](./windows.md) · [wsl2.md](./wsl2.md) · [linux.md](./linux.md) · [macos.md](./macos.md) · [single-ec2.md](./single-ec2.md)

---

## Official documentation

- Minikube troubleshooting — <https://minikube.sigs.k8s.io/docs/handbook/troubleshooting/>
- Drivers — <https://minikube.sigs.k8s.io/docs/drivers/>
- Accessing apps — <https://minikube.sigs.k8s.io/docs/handbook/accessing/>
- Pushing images — <https://minikube.sigs.k8s.io/docs/handbook/pushing/>
- Add-ons — <https://minikube.sigs.k8s.io/docs/handbook/addons/>
- Debugging Pods — <https://kubernetes.io/docs/tasks/debug/debug-application/debug-pods/>
