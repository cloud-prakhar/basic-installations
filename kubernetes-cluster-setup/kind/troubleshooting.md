# Kind — Troubleshooting

Every issue has **symptoms**, **cause**, a **diagnostic command**, and a **resolution**.

Jump to: [First response](#first-response) · [Docker](#a-docker) · [Cluster creation](#b-cluster-creation) · [Networking and ports](#c-networking-and-ports) · [Ingress](#d-ingress) · [Images](#e-images) · [Context and DNS](#f-context-and-dns) · [Platform-specific](#g-platform-specific) · [Nuclear option](#when-nothing-works)

Throughout, `demo` is the cluster name used in the guides — the container is `demo-control-plane` and the context is `kind-demo`. Substitute yours.

> [!TIP]
> **Kind's great advantage in troubleshooting: deleting and recreating costs under a minute.** If you have spent more than five minutes on a broken cluster, `kind delete cluster && kind create cluster` is usually the faster path. That is a legitimate strategy here in a way it is not with kubeadm.

---

## First response

```bash
# 1. Does Kind know about the cluster?
kind get clusters

# 2. Is the node container running?
docker ps -a --filter "name=demo-control-plane"

# 3. What did the container say?
docker logs demo-control-plane --tail 50

# 4. Am I talking to the right cluster?
kubectl config current-context
kubectl config get-contexts

# 5. Is Kubernetes healthy?
kubectl get nodes -o wide
kubectl get pods -A

# 6. What ports are published?
docker port demo-control-plane

# 7. Recent complaints
kubectl get events -A --sort-by=.lastTimestamp | tail -30

# 8. Everything, dumped to disk
kind export logs --name demo ./kind-logs
```

---

## A. Docker

### A1. Docker unavailable

**Symptoms**

```text
ERROR: failed to create cluster: failed to list nodes: command "docker ps ..." failed with error: exit status 1
Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?
```

**Cause** — Docker is not running, not installed, or not reachable by your user.

**Diagnostic**

```bash
docker version
docker info 2>&1 | head -5
```

Linux/EC2:

```bash
systemctl status docker --no-pager
```

**Resolution**

| Platform | Fix |
|---|---|
| Windows / macOS | Start Docker Desktop; wait for the whale icon to settle |
| macOS + Colima | `colima start` |
| Linux / EC2 | `sudo systemctl start docker; sudo systemctl enable docker` |
| WSL2 | Enable Docker Desktop → Settings → Resources → **WSL Integration** for this distro; or `sudo systemctl start docker` if you installed Docker Engine in WSL |

---

### A2. Docker permission denied

**Symptoms**

```text
permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock
```

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
newgrp docker
docker version
```

> [!CAUTION]
> **Do not use `sudo kind create cluster` as a workaround.** Kind writes `~/.kube/config` for whichever user runs it — with `sudo`, the kubeconfig lands in `/root/.kube/config` and your normal `kubectl` cannot find the cluster at all.
>
> If you already did:
>
> ```bash
> sudo kind delete cluster --name demo
> sudo rm -rf /root/.kube
> kind create cluster --name demo        # as your normal user
> ```

---

### A3. WSL integration missing

**Symptoms** — `docker` works in PowerShell but not in WSL, or `command not found: docker` inside WSL.

**Diagnostic**

```bash
# WSL Ubuntu
which docker
docker version
```

```powershell
# PowerShell
wsl --list --verbose
```

**Resolution**

1. Docker Desktop → **Settings → General** → tick **Use the WSL 2 based engine**
2. Docker Desktop → **Settings → Resources → WSL Integration** → tick your distro
3. **Apply & restart**, reopen the WSL terminal

Or install Docker Engine inside WSL — which requires systemd (`[boot] systemd=true` in `/etc/wsl.conf`, then `wsl --shutdown`).

---

### A4. Insufficient Docker resources

**Symptoms** — cluster creation hangs at "Starting control-plane"; the node container is `OOMKilled`; Pods evicted.

**Diagnostic**

```bash
docker info --format 'CPUs: {{.NCPU}}  Memory: {{.MemTotal}}'
docker stats --no-stream demo-control-plane
free -h 2>/dev/null || vm_stat
kubectl describe node demo-control-plane | grep -A6 Conditions
```

**Resolution**

| Platform | Fix |
|---|---|
| Windows / macOS + Docker Desktop | Settings → **Resources** → 4 CPUs, 6 GB → Apply & restart |
| macOS + Colima | `colima stop && colima start --cpu 4 --memory 6 --disk 40` |
| WSL2 | `memory=6GB`, `processors=4` under `[wsl2]` in `%USERPROFILE%\.wslconfig`, then `wsl --shutdown` |
| Linux / EC2 | Free memory, or use a bigger machine |

---

## B. Cluster creation

### B1. Cluster-creation timeout

**Symptoms**

```text
ERROR: failed to create cluster: failed to init node with kubeadm: ... timed out waiting for the condition
 ✗ Starting control-plane 🕹️
```

**Cause** — usually resources, occasionally inotify limits or a corrupt node image.

**Diagnostic**

```bash
docker logs demo-control-plane --tail 100
docker exec demo-control-plane journalctl -u kubelet --no-pager -n 50 2>/dev/null
free -h
cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null
cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null
```

**Resolution by cause:**

| Finding | Fix |
|---|---|
| Low memory | Raise Docker's memory allocation (see [A4](#a4-insufficient-docker-resources)) |
| `too many open files` / inotify exhausted | Raise the limits (below) |
| Bad or partial node image | `docker rmi kindest/node:<version>` and recreate so it re-pulls |
| Kubelet errors in the container log | Read them — usually cgroup or resource related |

**inotify limits** (Linux, and common when running several Kind clusters):

```bash
# Linux terminal (root)
sudo sysctl fs.inotify.max_user_instances=512
sudo sysctl fs.inotify.max_user_watches=524288

# persist
cat <<'EOF' | sudo tee /etc/sysctl.d/99-kind-inotify.conf
fs.inotify.max_user_instances = 512
fs.inotify.max_user_watches = 524288
EOF
sudo sysctl --system
```

Then retry:

```bash
kind delete cluster --name demo
kind create cluster --name demo
```

---

### B2. Cluster or container name already exists

**Symptoms**

```text
ERROR: failed to create cluster: node(s) already exist for a cluster with the name "demo"
docker: Error response from daemon: Conflict. The container name "/demo-control-plane" is already in use
```

**Diagnostic**

```bash
kind get clusters
docker ps -a --filter "name=demo-control-plane"
```

**Resolution**

```bash
kind delete cluster --name demo
kind create cluster --name demo
```

If Kind does not list it but the container exists (a half-deleted cluster):

```bash
docker rm -f demo-control-plane
kind create cluster --name demo
```

---

### B3. Control-plane container exits

**Symptoms** — `docker ps -a` shows the node `Exited (1)` or `Exited (137)`; `kubectl` cannot connect.

**Cause** — `137` is OOM-kill. Others are usually a bad node image or a host kernel/cgroup issue.

**Diagnostic**

```bash
docker ps -a --filter "name=demo-control-plane"
docker inspect demo-control-plane --format '{{.State.ExitCode}} {{.State.OOMKilled}} {{.State.Error}}'
docker logs demo-control-plane --tail 100
```

**Resolution**

| Exit code | Cause | Fix |
|---|---|---|
| `137` with `OOMKilled: true` | Out of memory | Raise Docker's memory ([A4](#a4-insufficient-docker-resources)) |
| `1` with kubeadm errors in the log | Bad node image, or a host/kernel mismatch | Use Kind's default image (omit `--image`); update Kind |
| `125` | Docker could not start it at all | Check `docker logs` and Docker's own daemon log |

Try restarting before recreating:

```bash
docker start demo-control-plane
sleep 60
kubectl get nodes
```

If that does not work, delete and recreate — it takes under a minute.

---

### B4. Wrong Kind node image

**Symptoms**

```text
ERROR: failed to create cluster: failed to pull image "kindest/node:v1.99.0": not found
```

or the cluster starts but behaves oddly with an unexpected Kubernetes version.

**Cause** — **node images are built per Kind release.** `kindest/node:v1.36.1` built for one Kind version is not necessarily the image for another. Copying a digest from an old blog post is the usual mistake.

**Diagnostic**

```bash
kind version
docker images | grep kindest/node
kubectl version
```

**Resolution**

Easiest — let Kind choose:

```bash
kind create cluster --name demo        # no --image at all
```

Or take the exact digest from the release notes of **your** Kind version at <https://github.com/kubernetes-sigs/kind/releases>:

```bash
kind create cluster --name demo \
  --image kindest/node:v1.36.1@sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5
```

> [!IMPORTANT]
> Always use the `@sha256` digest, not the tag alone. The digest guarantees you get the image built for your Kind release.

---

## C. Networking and ports

### C1. Port conflict

**Symptoms**

```text
ERROR: failed to create cluster: command "docker run ..." failed
Bind for 0.0.0.0:80 failed: port is already allocated
```

**Cause** — a `hostPort` in your config is already in use on the host.

**Diagnostic**

```bash
# Linux / WSL
sudo ss -tlnp | grep -E ':(80|443|30080)\b'
```

```bash
# macOS
sudo lsof -iTCP:80 -sTCP:LISTEN
```

```powershell
# PowerShell
netstat -ano | findstr ":80 "
Get-Process -Id <PID>
```

Common culprits: IIS or Skype (Windows), a local nginx/Apache (Linux/macOS), another Kind or Docker container.

**Resolution** — either stop the conflicting service, or change `hostPort` in your config:

```yaml
extraPortMappings:
  - containerPort: 80
    hostPort: 8080        # instead of 80
    protocol: TCP
  - containerPort: 443
    hostPort: 8443
    protocol: TCP
```

Then recreate the cluster and adjust your URLs (`http://localhost:8080`).

---

### C2. Cannot reach a NodePort from the host

**Symptoms** — `curl http://localhost:30080` gives `connection refused`, though Pods are `Running` and the Service exists.

**Cause** — no `extraPortMappings` entry for that port. Kind nodes sit on an internal Docker network; a NodePort listens **inside the container only**.

**Diagnostic**

```bash
docker port demo-control-plane
kubectl -n demo get svc
kubectl -n demo get endpoints web-nodeport      # must be non-empty
docker exec demo-control-plane curl -s localhost:30080 | head -3   # proves the app works
```

**Resolution**

> [!IMPORTANT]
> `extraPortMappings` **cannot be added to an existing cluster.** You must recreate. With Kind that costs under a minute.

```bash
kind delete cluster --name demo
# add the mapping to kind-config.yaml, then:
kind create cluster --config kind-config.yaml
docker port demo-control-plane
```

The mapping's `containerPort` must equal the Service's `nodePort` (both `30080` in these guides).

**Immediate workaround that needs no recreate:**

```bash
kubectl -n demo port-forward svc/web 8080:80
curl -s http://localhost:8080 | head -3
```

---

### C3. Cannot reach the node container's IP

**Symptoms** — `curl http://172.18.0.2:30080` times out.

**Cause** — depends on platform:

| Platform | Reachable? | Why |
|---|---|---|
| **Linux** | ✅ Yes | Containers run on your kernel; Docker bridges are routable |
| **Windows / macOS** | ❌ No | The Docker network lives inside Docker Desktop's / Colima's Linux VM; your host has no route |
| **WSL2** | ✅ from WSL, ❌ from Windows | Same reason |
| **EC2** | ✅ on the instance, ❌ from the internet | The bridge is internal to the instance |

**Resolution** — use `extraPortMappings` (host ports) or `kubectl port-forward`. On Windows/macOS this is not a bug to fix; it is how the platform works.

---

### C4. Windows firewall issues

**Symptoms** — mapped ports unreachable on Windows even though `docker port` shows them; a firewall prompt appeared and was dismissed.

**Diagnostic**

```powershell
# PowerShell
docker port demo-control-plane
Test-NetConnection -ComputerName localhost -Port 30080
Get-NetFirewallRule -DisplayName "*Docker*" | Select-Object DisplayName,Enabled,Direction
```

**Resolution**

1. Allow **Docker Desktop Backend** through Windows Defender Firewall for private networks
2. Or bind mappings to loopback only, which firewalls generally do not filter:

```yaml
extraPortMappings:
  - containerPort: 30080
    hostPort: 30080
    listenAddress: "127.0.0.1"
```

3. Or side-step it entirely with `kubectl port-forward`

---

### C5. Corporate proxy issues

**Symptoms** — `kind create cluster` hangs pulling the node image; in-cluster image pulls fail; `x509: certificate signed by unknown authority` from a TLS-inspecting proxy.

**Diagnostic**

```bash
env | grep -i proxy
docker info | grep -i proxy
curl -sSI https://registry.k8s.io/v2/ | head -1
```

**Resolution** — Kind passes proxy environment variables into the node automatically when they are set in your shell:

```bash
export HTTP_PROXY=http://<PROXY_HOST>:<PORT>
export HTTPS_PROXY=http://<PROXY_HOST>:<PORT>
export NO_PROXY=localhost,127.0.0.1,10.96.0.0/16,10.244.0.0/16,172.18.0.0/16,.svc,.cluster.local

kind create cluster --name demo
```

> [!IMPORTANT]
> `NO_PROXY` **must** include the Service CIDR (`10.96.0.0/16`), the Pod CIDR (`10.244.0.0/16`), Kind's Docker network (`172.18.0.0/16`), and `.svc,.cluster.local`. Without them, in-cluster traffic is sent to the proxy and fails in ways that look like DNS problems.

Also configure Docker's own proxy (Docker Desktop → Settings → Resources → Proxies; on Linux, a systemd drop-in for `docker.service`).

For a TLS-inspecting proxy, add the corporate CA into the node:

```bash
docker cp corporate-ca.crt demo-control-plane:/usr/local/share/ca-certificates/
docker exec demo-control-plane update-ca-certificates
docker exec demo-control-plane systemctl restart containerd
```

---

## D. Ingress

### D1. Ingress controller Pod stays `Pending`

**Symptoms**

```text
NAME                                       READY   STATUS    RESTARTS   AGE
ingress-nginx-controller-xxxxx-xxxxx       0/1     Pending   0          3m
```

**Cause** — almost always the node is missing the `ingress-ready=true` label. The ingress-nginx **Kind provider** manifest uses it as a `nodeSelector`.

**Diagnostic**

```bash
kubectl -n ingress-nginx describe pod -l app.kubernetes.io/component=controller | tail -15
kubectl get nodes --show-labels | tr ',' '\n' | grep ingress-ready
```

If the describe output says `0/1 nodes are available: 1 node(s) didn't match Pod's node affinity/selector`, that is it.

**Resolution** — the label is set at cluster creation via `kubeadmConfigPatches`, so recreate:

```bash
kind delete cluster --name demo
kind create cluster --config kind-config.yaml    # with the kubeadmConfigPatches block
kubectl get nodes --show-labels | grep ingress-ready
```

The required block:

```yaml
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
```

**Quick workaround without recreating** — label the node by hand:

```bash
kubectl label node demo-control-plane ingress-ready=true
kubectl -n ingress-nginx delete pod -l app.kubernetes.io/component=controller
```

That works, but the label is lost if the node is recreated. Fix the config properly.

---

### D2. Ingress unavailable — 404, 503, or timeout

**Diagnostic**

```bash
kubectl -n ingress-nginx get pods
kubectl -n demo get ingress
kubectl -n demo describe ingress web | tail -20
kubectl -n demo get endpoints web
kubectl -n ingress-nginx logs -l app.kubernetes.io/component=controller --tail=50
docker port demo-control-plane | grep -E '^(80|443)/tcp'
```

| Symptom | Cause | Fix |
|---|---|---|
| `connection refused` on port 80 | Port 80 not mapped | Recreate with `extraPortMappings` for `containerPort: 80` |
| `404 Not Found` from nginx | The `Host` header does not match the Ingress `host:` | Use `curl -H "Host: demo.local" http://localhost`, or add the hosts entry |
| `503 Service Temporarily Unavailable` | No ready endpoints behind the Service | `kubectl -n demo get endpoints web` must be non-empty; check Pod readiness probes |
| Ingress `ADDRESS` column empty | Controller has not published its address yet | Wait ~60 s |
| `ingressClassName` not found | Class mismatch | `kubectl get ingressclass` — must be `nginx` |
| Times out with no response at all | Controller not running | `kubectl -n ingress-nginx get pods` |

**Quickest verification, no hosts file needed:**

```bash
curl -s -H "Host: demo.local" http://localhost | head -5
```

If that works but browsing `http://demo.local` does not, the problem is only your hosts file.

**Hosts file locations:**

| Platform | Path | Notes |
|---|---|---|
| Windows | `C:\Windows\System32\drivers\etc\hosts` | Edit as Administrator |
| Linux / WSL | `/etc/hosts` | Needs `sudo`; WSL regenerates it unless `generateHosts = false` is set in `/etc/wsl.conf` |
| macOS | `/etc/hosts` | Needs `sudo`; may need `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder` |

---

## E. Images

### E1. Local image unavailable

**Symptoms**

```text
Failed to pull image "my-web:v1": failed to resolve reference "docker.io/library/my-web:v1": not found
Status: ErrImagePull / ImagePullBackOff
```

**Cause** — one of three:

1. The image was never loaded into the node. The Kind node has its **own containerd image store**, entirely separate from your host's Docker daemon.
2. `imagePullPolicy: Always` — the kubelet ignores the local copy and tries the registry.
3. The image is tagged `:latest`, and Kubernetes **defaults to `Always`** for that tag.

**Diagnostic**

```bash
docker images | grep my-web                              # on the host
docker exec demo-control-plane crictl images | grep my-web    # inside the node — this is what matters
kubectl -n demo get deployment web -o jsonpath='{.spec.template.spec.containers[0].imagePullPolicy}'; echo
kubectl -n demo describe pod <POD> | grep -A5 -i "failed to pull"
```

**Resolution**

```bash
# 1. Load it (name:tag must match EXACTLY)
kind load docker-image my-web:v1 --name demo

# 2. Confirm it landed
docker exec demo-control-plane crictl images | grep my-web

# 3. Make sure the policy allows it
kubectl -n demo patch deployment web \
  --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]'

# 4. Restart
kubectl -n demo rollout restart deployment/web
kubectl -n demo rollout status deployment/web
```

**Alternative — load from a tar archive:**

```bash
docker save my-web:v1 -o my-web.tar
kind load image-archive my-web.tar --name demo
```

> [!IMPORTANT]
> The node uses **containerd**, so inspect images with `crictl`, not `docker`. And **never tag local images `:latest`** — use a real version tag.

---

### E2. Apple Silicon image mismatch

**Symptoms**

```text
exec /docker-entrypoint.sh: exec format error
no matching manifest for linux/arm64/v8 in the manifest list entries
```

**Cause** — an `amd64`-only image on an `arm64` node.

**Diagnostic**

```bash
uname -m                                                          # arm64 on Apple Silicon
kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}'; echo
docker image inspect my-web:v1 --format '{{.Architecture}}'
docker manifest inspect <IMAGE> | grep -A2 architecture
```

**Resolution**

1. **Use multi-arch images.** `nginx`, `redis`, `postgres`, `busybox`, and most official images publish arm64. `nginx:1.30-alpine` (used here) does.
2. **Do not force amd64.** On Apple Silicon, plain `docker build` already produces arm64 — the right thing. Adding `--platform linux/amd64` produces an image the node cannot run without emulation.
3. **Build for arm64 explicitly** if you need to be sure:

```bash
docker build --platform linux/arm64 -t my-web:v1 .
kind load docker-image my-web:v1 --name demo
```

4. Kind node images are multi-arch, so `kindest/node:v1.36.1` resolves to the arm64 build automatically. If you see an architecture error from the *node* image, your Kind version is too old — `brew upgrade kind`.

---

### E3. Docker Hub rate limit

**Symptoms**

```text
toomanyrequests: You have reached your pull rate limit
```

**Resolution**

```bash
docker login
docker pull <IMAGE>
kind load docker-image <IMAGE> --name demo
```

Pulling on the host and side-loading avoids the node hitting the limit at all — a genuine Kind advantage.

---

## F. Context and DNS

### F1. Wrong kubectl context

**Symptoms** — resources you deployed are not there; you seem to be editing a different cluster.

**Diagnostic**

```bash
kubectl config current-context
kubectl config get-contexts
kubectl cluster-info
```

**Expected output:**

```text
kind-demo
```

**Resolution**

```bash
kubectl config use-context kind-demo
kubectl get nodes
```

Or regenerate the kubeconfig entry:

```bash
kind export kubeconfig --name demo
```

> [!TIP]
> If Docker Desktop's Kubernetes is enabled you also have a `docker-desktop` context. Disable it (Settings → Kubernetes → untick *Enable Kubernetes*) unless you use it — it is the most common cause of this confusion.

---

### F2. DNS issues inside the cluster

**Symptoms** — Pods cannot resolve Service names; `nslookup kubernetes.default` times out.

**Diagnostic**

```bash
kubectl -n kube-system get pods -l k8s-app=kube-dns
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=50
kubectl run dnstest --image=busybox:1.37 --rm -it --restart=Never -- \
  nslookup kubernetes.default.svc.cluster.local
kubectl get svc kube-dns -n kube-system
```

**Expected output** from the `nslookup`:

```text
Server:    10.96.0.10
Address:   10.96.0.10:53

Name:      kubernetes.default.svc.cluster.local
Address:   10.96.0.1
```

**Resolution**

```bash
kubectl -n kube-system rollout restart deployment coredns
kubectl -n kube-system rollout status deployment coredns
```

If CoreDNS itself cannot reach upstream DNS (external names fail, internal ones work), the node inherited a broken resolver from the host:

```bash
docker exec demo-control-plane cat /etc/resolv.conf
```

On a host using `systemd-resolved` with `127.0.0.53`, the container may get a stub resolver it cannot use. Fix Docker's DNS by setting `"dns": ["1.1.1.1"]` in `/etc/docker/daemon.json`, restart Docker, then recreate the cluster.

---

### F3. Node `NotReady`

**Symptoms** — `kubectl get nodes` shows `NotReady`.

**Cause** — unlike kubeadm, this is *not* a missing CNI: Kind installs kindnet automatically. Look at the kubelet instead.

**Diagnostic**

```bash
kubectl describe node demo-control-plane | sed -n '/Conditions/,/Addresses/p'
kubectl -n kube-system get pods -l app=kindnet
docker exec demo-control-plane systemctl status kubelet --no-pager | head -20
docker exec demo-control-plane journalctl -u kubelet --no-pager -n 50
```

**Resolution**

| Finding | Fix |
|---|---|
| kindnet Pod not running | `kubectl -n kube-system delete pod -l app=kindnet` to restart it |
| kubelet failing on resources | Raise Docker memory ([A4](#a4-insufficient-docker-resources)) |
| `DiskPressure` | `docker system prune -a` on the host; check `df -h` |
| Node stopped reporting entirely | `docker restart demo-control-plane`, wait 60 s |

Recreating is usually faster than debugging.

---

## G. Platform-specific

### G1. Windows

| Symptom | Cause | Fix |
|---|---|---|
| `kind` not recognised after install | `PATH` not refreshed | Reopen PowerShell; ensure the install dir is on `PATH` |
| Backslash line continuation fails | PowerShell uses a backtick | Use `` ` `` or one line |
| Hosts file edit rejected | Not elevated | Edit `C:\Windows\System32\drivers\etc\hosts` as Administrator |
| Port 80 in use | IIS or another service | `netstat -ano \| findstr ":80 "`; change `hostPort` |
| Docker Desktop starts then stops | WSL2 backend problem | `wsl --update`, restart Docker Desktop |
| Mapped ports blocked | Windows Firewall | Allow Docker Desktop, or bind to `127.0.0.1` |

### G2. macOS

| Symptom | Cause | Fix |
|---|---|---|
| Cannot reach `172.18.0.x` | No route from macOS into Docker's VM network | Expected. Use mapped ports or `port-forward` |
| Mapped port unreachable with Colima | Colima's own forwarding layer | `kubectl port-forward`, or restart Colima |
| `demo.local` resolves wrongly | macOS DNS cache | `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder` |
| Two `kubectl` binaries disagree | Homebrew's and Docker Desktop's both on `PATH` | `which -a kubectl`; `brew link --overwrite kubernetes-cli` |
| `sed -i` fails in cleanup | macOS `sed` needs an argument | `sed -i '' '/demo.local/d' /etc/hosts` |
| Cluster unresponsive after sleep | VM clock drift | Recreate the cluster, or restart Docker Desktop |
| Colima stopped, cluster gone | `colima stop` stops the VM | `colima start`, then `docker start demo-control-plane` |

### G3. WSL2

| Symptom | Cause | Fix |
|---|---|---|
| Windows cannot reach a mapped port | `listenAddress: 127.0.0.1`, or `localhostForwarding` off | Omit `listenAddress` (defaults `0.0.0.0`); set `localhostForwarding=true` in `.wslconfig`, `wsl --shutdown` |
| Windows cannot reach a `port-forward` | Bound to `127.0.0.1` | `kubectl port-forward --address 0.0.0.0 ...` |
| `/etc/hosts` entry vanishes | WSL regenerates it | `[network] generateHosts = false` in `/etc/wsl.conf`, `wsl --shutdown` |
| Cluster gone after Windows reboot | WSL and Docker do not auto-start | Open Ubuntu, start Docker, `docker start demo-control-plane` or recreate |
| Not enough memory | WSL defaults | `memory=6GB` in `%USERPROFILE%\.wslconfig`, `wsl --shutdown` |

### G4. EC2

| Symptom | Cause | Fix |
|---|---|---|
| `kubectl` finds no config | Cluster created as a different user | Work consistently as `ubuntu`; never `sudo kind` |
| Cannot reach it from your laptop | Kind's Docker network is internal to the instance | Use SSH or SSM port forwarding — expected behaviour |
| `LoadBalancer` Service `<pending>` | No cloud controller manager | Expected on Kind. Use NodePort or `port-forward`; use EKS for real load balancers |
| Disk full at 30 GB | Node images plus your images | `docker system prune -a`; grow the EBS volume |
| Slow, then unresponsive | Burstable instance out of CPU credits | CloudWatch → `CPUCreditBalance`; use a non-burstable type |
| Cluster gone after instance restart | Container not restarted | `docker start demo-control-plane`, wait 60 s; or recreate |

---

## When nothing works

> [!CAUTION]
> 🔴 **DESTRUCTIVE** — destroys the cluster and all data. With Kind, recreating takes under a minute, so this is a normal move rather than a last resort.

```bash
# 1. Delete the cluster
kind delete cluster --name demo

# 2. Or every Kind cluster
kind delete clusters --all

# 3. Clean up stragglers
docker ps -a --filter "label=io.x-k8s.kind.cluster"
docker rm -f $(docker ps -aq --filter "label=io.x-k8s.kind.cluster") 2>/dev/null || true
docker network ls | grep kind
docker network rm kind 2>/dev/null || true

# 4. Remove the node image so it re-pulls cleanly
docker images | grep kindest/node
docker rmi kindest/node:v1.36.1 2>/dev/null || true

# 5. Reset kubeconfig entries
kubectl config get-contexts
kubectl config delete-context kind-demo 2>/dev/null || true

# 6. Start fresh — omit --image so Kind picks its own default
kind create cluster --name demo
```

Then return to your platform page:
[windows.md](./windows.md) · [wsl2.md](./wsl2.md) · [linux.md](./linux.md) · [macos.md](./macos.md) · [single-ec2.md](./single-ec2.md)

---

## Official documentation

- Kind known issues — <https://kind.sigs.k8s.io/docs/user/known-issues/>
- Quick start — <https://kind.sigs.k8s.io/docs/user/quick-start/>
- Configuration — <https://kind.sigs.k8s.io/docs/user/configuration/>
- Ingress — <https://kind.sigs.k8s.io/docs/user/ingress/>
- Releases and node images — <https://github.com/kubernetes-sigs/kind/releases>
- Debugging Pods — <https://kubernetes.io/docs/tasks/debug/debug-application/debug-pods/>
- Debugging DNS — <https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/>
