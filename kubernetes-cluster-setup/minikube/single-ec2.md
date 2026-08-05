# Minikube — Single-Node Cluster on One Ubuntu EC2 Instance

Run one Minikube node on **exactly one** Ubuntu EC2 instance, using the Docker driver.

This page is self-contained — you do not need to read any other page.

Commands are marked:

- `# Local terminal` — your laptop (macOS/Linux/WSL, or PowerShell where noted)
- `# EC2 (ubuntu user)` — on the instance as the `ubuntu` user

Validated **2026-08-05** on Ubuntu 24.04 LTS (EC2), Minikube **v1.38.1**, Kubernetes **1.36**, Docker Engine. Time: 20–30 minutes.

> [!WARNING]
> 💰 **This costs money.** An EC2 instance with 2–4 vCPU and 8 GB plus a 30 GB gp3 volume bills **per second while running**, and the EBS volume bills even while the instance is stopped. Work through §9 when you are done. Check current pricing at <https://aws.amazon.com/ec2/pricing/on-demand/> before launching.

---

## Is Minikube appropriate on EC2?

**Yes, for learning.** A single EC2 instance running Minikube is a clean, disposable Kubernetes practice environment that does not touch your laptop, is reachable from anywhere, and can be destroyed in one command.

**No, for anything real.** Minikube is explicitly a local development tool:

| | Minikube on EC2 | Amazon EKS |
|---|---|---|
| Control plane | One container on one instance | AWS-managed, multi-AZ, patched by AWS |
| High availability | ❌ None — the instance dies, the cluster dies | ✅ Built in |
| Node failure tolerance | ❌ None | ✅ Managed node groups replace nodes |
| Cloud integrations (ELB, EBS CSI, IAM roles for pods) | ❌ Not wired up | ✅ Native |
| Upgrades | Recreate the cluster | Managed, in place |
| Supported for production | ❌ No | ✅ Yes |

If you want managed Kubernetes on AWS, use **[Guide 4 — EKS](../eksctl/)**. Use this page to practise Kubernetes itself on a machine that is not your laptop.

---

## Contents

1. [EC2 prerequisites](#1-ec2-prerequisites)
2. [Networking and security group](#2-networking-and-security-group)
3. [Launch the instance](#3-launch-the-instance)
4. [Connect to the instance](#4-connect-to-the-instance)
5. [Install Docker, kubectl, Minikube](#5-install-docker-kubectl-minikube)
6. [Start the single-node cluster](#6-start-the-single-node-cluster)
7. [Verify and enable add-ons](#7-verify-and-enable-add-ons)
8. [Deploy and access the sample application](#8-deploy-and-access-the-sample-application)
9. [Cleanup and cost checklist](#9-cleanup-and-cost-checklist)
10. [Troubleshooting](#10-troubleshooting)

---

## 1. EC2 prerequisites

| Setting | Minimum | Recommended |
|---|---|---|
| AMI | Ubuntu Server **24.04 LTS** (or 22.04 LTS) | Ubuntu Server 24.04 LTS |
| Instances | **1** | 1 |
| vCPU | 2 | 4 |
| Memory | 4 GB | 8 GB |
| Root volume | 30 GB gp3 | 30–40 GB gp3 |
| Driver | **`docker`** | `docker` |
| Security group | 1 | 1 |
| Access | SSH key pair **or** Systems Manager | Systems Manager |

> [!IMPORTANT]
> **Use the Docker driver on EC2. Do not use a VM driver.**
>
> `virtualbox`, `hyperv`, and `kvm2` all need to create a virtual machine, which requires **nested virtualization**. Standard EC2 instance types do not expose it (only bare-metal `*.metal` types do — far more expensive than this lab warrants). Trying anyway gives you `This computer doesn't have VT-X/AMD-v enabled` or a hang.
>
> The `docker` driver runs the node as a container directly on the instance's kernel. It is the right and only sensible choice here.

**Instance families that work well** — check current pricing and free-tier eligibility for your account and region before choosing:

| Family | Character |
|---|---|
| Burstable (`t3`, `t3a`, `t4g`) | Cheapest. CPU credits accumulate and burn; sustained load may throttle. Fine for a lab. `t4g` is Graviton/arm64 — cheaper, and Minikube and the sample image both have arm64 builds. |
| General purpose (`m6i`, `m7i`, `m7g`) | Consistent performance, more expensive |
| Compute optimized (`c6i`, `c7i`, `c7i-flex`) | More CPU per GB. `c7i-flex.large` is free-tier eligible on some newer accounts. |

A `*.large` (2 vCPU / 8 GB) meets the minimum comfortably.

You also need: an AWS account (**not** the root user — use an IAM user or IAM Identity Center role), a chosen region, and billing alerts set up under **Billing and Cost Management → Budgets**.

---

## 2. Networking and security group

> [!CAUTION]
> 🔴 **Never open ports to `0.0.0.0/0` here.** Anything you expose is scanned within minutes.

### 2.1 Find your public IP

```bash
# Local terminal
curl -s https://checkip.amazonaws.com
```

```powershell
# PowerShell
(Invoke-WebRequest -Uri https://checkip.amazonaws.com).Content.Trim()
```

Your CIDR is that address + `/32`, e.g. `203.0.113.45/32`. That is `<YOUR_PUBLIC_IP_CIDR>` below. Home ISPs rotate addresses — if access stops working, re-check and update the rule.

### 2.2 Minimal inbound rules

| # | Port | Source | Needed when |
|---|---|---|---|
| 1 | 22 | `<YOUR_PUBLIC_IP_CIDR>` | You use SSH. **Omit entirely if using Session Manager.** |
| 2 | 30080 | `<YOUR_PUBLIC_IP_CIDR>` | You want to hit the NodePort demo from a browser. **Omit** if you use SSH forwarding. |

**Outbound:** leave the default *All traffic* — the instance must pull packages and container images.

Nothing else is required. Minikube's cluster networking is entirely internal to the instance (Docker bridge + the node container), and security groups do not filter loopback or intra-host traffic.

### 2.3 Safer alternatives to opening ports

| Approach | Avoids | How |
|---|---|---|
| **Session Manager** ⭐ | Port 22 entirely — no key, no inbound rule, sessions logged in CloudTrail | Attach an instance profile with `AmazonSSMManagedInstancePolicy`, then `aws ssm start-session --target <INSTANCE_ID>` |
| **SSH local port forwarding** | Port 30080 | `ssh -N -L 8080:localhost:30080 ubuntu@<PUBLIC_IP>` |
| **SSM port forwarding** | Everything | `aws ssm start-session --document-name AWS-StartPortForwardingSession ...` |
| **`kubectl port-forward`** | Any NodePort rule | Tunnels through the API server |

**Best combination:** Session Manager + SSM port forwarding = **zero** inbound rules.

### 2.4 Create the security group

**Console:** EC2 → Security Groups → **Create security group** → name `minikube-lab-sg` → default VPC → add only the rules you need, each with **Source = My IP** → Create.

**CLI:**

```bash
# Local terminal
export AWS_REGION=<AWS_REGION>
MY_IP="$(curl -s https://checkip.amazonaws.com)/32"
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)

SG_ID=$(aws ec2 create-security-group \
  --group-name minikube-lab-sg \
  --description "Single-node Minikube learning cluster" \
  --vpc-id "$VPC_ID" --query GroupId --output text)
echo "SG_ID=$SG_ID  MY_IP=$MY_IP"

# SSH — skip if using Session Manager
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 22 --cidr "$MY_IP"
```

Optional NodePort rule:

```bash
# Local terminal — only if you want browser access to the NodePort
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 30080 --cidr "$MY_IP"
```

✅ **Verify no rule is `0.0.0.0/0`:**

```bash
# Local terminal
aws ec2 describe-security-groups --group-ids "$SG_ID" --query 'SecurityGroups[0].IpPermissions' --output table
```

---

## 3. Launch the instance

**Console:** EC2 → **Launch instances** → Name `minikube-lab` → AMI **Ubuntu Server 24.04 LTS** → instance type meeting §1 → key pair (or *Proceed without* if using SSM) → **Select existing security group** `minikube-lab-sg` → storage **30 GiB gp3** → *(optional)* IAM instance profile with `AmazonSSMManagedInstancePolicy` → **Launch instance**.

**CLI:**

```bash
# Local terminal
export AWS_REGION=<AWS_REGION>

AMI_ID=$(aws ssm get-parameter \
  --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
  --query 'Parameter.Value' --output text)

aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type <INSTANCE_TYPE> \
  --count 1 \
  --key-name <KEY_PAIR_NAME> \
  --security-group-ids "$SG_ID" \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=minikube-lab},{Key=Purpose,Value=kubernetes-learning}]' \
  --query 'Instances[0].InstanceId' --output text
```

Use `arm64` in the SSM parameter path for Graviton instance types.

> [!IMPORTANT]
> `"DeleteOnTermination": true` means the EBS volume goes away with the instance. Without it you keep paying for an orphaned volume indefinitely.

✅ **Verify exactly one instance:**

```bash
# Local terminal
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=minikube-lab" "Name=instance-state-name,Values=running,pending" \
  --query 'Reservations[].Instances[].{ID:InstanceId,Type:InstanceType,State:State.Name,PublicIP:PublicIpAddress}' \
  --output table
```

---

## 4. Connect to the instance

### Option A — Session Manager (no open SSH port)

```bash
# Local terminal
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=minikube-lab" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

aws ssm start-session --target "$INSTANCE_ID"
```

You land as `ssm-user`; switch to `ubuntu`:

```bash
# EC2
sudo su - ubuntu
```

> [!IMPORTANT]
> **Switch to the `ubuntu` user and stay there.** Minikube writes to `~/.minikube` and `~/.kube`, and mixing users (or running as root) causes permission failures later.

Needs the Session Manager plugin locally: <https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html>

### Option B — SSH

```bash
# Local terminal
PUBLIC_IP=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=minikube-lab" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "PUBLIC_IP=$PUBLIC_IP"

chmod 400 ~/.ssh/<KEY_PAIR_NAME>.pem
ssh -i ~/.ssh/<KEY_PAIR_NAME>.pem ubuntu@"$PUBLIC_IP"
```

✅ **Verify:**

```bash
# EC2 (ubuntu user)
whoami
nproc
free -h
df -h /
. /etc/os-release && echo "$PRETTY_NAME"
```

**Expected output:**

```text
ubuntu
2
               total        used        free
Mem:           7.6Gi       0.3Gi       7.0Gi
Filesystem      Size  Used Avail Use% Mounted on
/dev/root        29G  2.1G   27G   8% /
Ubuntu 24.04.3 LTS
```

`nproc` must be ≥ 2 and memory ≥ 4 GB.

---

## 5. Install Docker, kubectl, Minikube

### 5.1 Update packages

```bash
# EC2 (ubuntu user)
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get install -y ca-certificates curl gnupg
```

### 5.2 Install Docker Engine

```bash
# EC2 (ubuntu user)
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

`$(dpkg --print-architecture)` resolves to `amd64` or `arm64` automatically.

### 5.3 Let the `ubuntu` user run Docker

**What:** add `ubuntu` to the `docker` group.
**Why:** Minikube must reach the Docker socket as the user running it. This is what lets you avoid `sudo` entirely.

```bash
# EC2 (ubuntu user)
sudo usermod -aG docker ubuntu
newgrp docker            # apply in this shell without logging out
```

✅ **Verify:**

```bash
# EC2 (ubuntu user)
groups | grep docker
docker version
docker run --rm hello-world
```

**Expected output:** both `Client:` and `Server:` sections, then `Hello from Docker!`.

If you still get `permission denied ... docker.sock`, log out and back in.

> [!CAUTION]
> The `docker` group is effectively root on this machine. Acceptable on a disposable single-purpose lab instance; do not do it on a shared or production host.

### 5.4 Should you use `--force` as root?

**No. Use the `ubuntu` user.**

Minikube **refuses to run as root with the Docker driver** and tells you:

```text
X Exiting due to DRV_AS_ROOT: The "docker" driver should not be used with root privileges.
```

`minikube start --driver=docker --force` overrides that check. Do not use it:

- Minikube itself calls it out as unsupported and prints warnings.
- It creates root-owned `/root/.minikube` and `/root/.kube`, so `kubectl` as `ubuntu` then fails.
- Everything inside the cluster runs with unnecessary host privileges.
- It hides real problems — the usual reason people reach for `--force` is that they forgot §5.3.

The **only** legitimate use is a throwaway CI container that has no non-root user at all. On this instance, the `ubuntu` user with `docker` group membership is the correct setup.

### 5.5 Install kubectl

```bash
# EC2 (ubuntu user)
ARCH=$(dpkg --print-architecture)
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

### 5.6 Install Minikube

```bash
# EC2 (ubuntu user)
ARCH=$(dpkg --print-architecture)
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

## 6. Start the single-node cluster

Size the flags to your instance. On a 2 vCPU / 8 GB instance leave headroom for the OS:

```bash
# EC2 (ubuntu user) — NOT root, NOT with sudo
minikube start \
  --driver=docker \
  --cpus=2 \
  --memory=4g \
  --disk-size=20g \
  --profile=demo
```

On a 4 vCPU / 16 GB instance:

```bash
# EC2 (ubuntu user)
minikube start --driver=docker --cpus=4 --memory=8g --disk-size=30g --profile=demo
```

| Flag | Meaning |
|---|---|
| `--driver=docker` | The node is a Docker container on this instance. The only workable driver on EC2. |
| `--cpus=2` | **Minimum 2.** Cannot exceed `nproc`. |
| `--memory=4g` | Minimum ~1.8 GB. Leave ~1 GB for the OS. |
| `--disk-size=20g` | Node disk. Must fit within the instance's root volume. |
| `--profile=demo` | Names the cluster; later commands take `-p demo`. |

Optional: `--kubernetes-version=v1.36.1`, `--addons=ingress,metrics-server`.

> [!WARNING]
> Do **not** use `--nodes=2` — single-node guide.
> Do **not** use `sudo` or `--force`.

**Expected output:**

```text
* [demo] minikube v1.38.1 on Ubuntu 24.04 (amd64)
* Using the docker driver based on user configuration
* Starting "demo" primary control-plane node in "demo" cluster
* Pulling base image v0.0.48 ...
* Creating docker container (CPUs=2, Memory=4096MB) ...
* Preparing Kubernetes v1.36.1 on Docker 28.x ...
* Configuring bridge CNI (Container Networking Interface) ...
* Verifying Kubernetes components...
* Enabled addons: storage-provisioner, default-storageclass
* Done! kubectl is now configured to use "demo" cluster and "default" namespace by default
```

---

## 7. Verify and enable add-ons

### 7.1 Verify

```bash
# EC2 (ubuntu user)
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

Minikube does not taint the node — Pods schedule immediately.

> [!NOTE]
> `192.168.49.2` is the Docker bridge address **on the instance**. It is reachable from the instance itself, never from the internet. That is a feature, not a problem — see §8.

### 7.2 Add-ons

```bash
# EC2 (ubuntu user)
minikube addons list -p demo
```

`storage-provisioner` and `default-storageclass` are on by default.

> [!TIP]
> On a 2 vCPU / 4 GB node, enable **only** what you need. The dashboard plus ingress plus metrics-server on a small instance leaves very little for your workloads.

**Ingress:**

```bash
# EC2 (ubuntu user)
minikube addons enable ingress -p demo
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=180s
```

**Metrics Server:**

```bash
# EC2 (ubuntu user)
minikube addons enable metrics-server -p demo
sleep 45
kubectl top nodes
```

**Expected output:**

```text
NAME   CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
demo   240m         12%      1420Mi          36%
```

**Dashboard** — only worth enabling if you will actually port-forward it:

```bash
# EC2 (ubuntu user)
minikube addons enable dashboard -p demo
```

Never use plain `minikube dashboard` here — see §8.

**Storage:**

```bash
# EC2 (ubuntu user)
kubectl get storageclass
```

**Expected output:**

```text
NAME                 PROVISIONER                RECLAIMPOLICY   VOLUMEBINDINGMODE   AGE
standard (default)   k8s.io/minikube-hostpath   Delete          Immediate           5m
```

---

## 8. Deploy and access the sample application

### 8.1 Write the manifests

```bash
# EC2 (ubuntu user)
mkdir -p ~/manifests

cat > ~/manifests/00-namespace.yaml <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: demo
EOF

cat > ~/manifests/10-deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: demo
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: web
  template:
    metadata:
      labels:
        app.kubernetes.io/name: web
    spec:
      containers:
        - name: web
          image: nginx:1.30-alpine
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 80
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              cpu: 200m
              memory: 128Mi
          livenessProbe:
            httpGet: { path: /, port: http }
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet: { path: /, port: http }
            initialDelaySeconds: 2
            periodSeconds: 5
EOF

cat > ~/manifests/20-service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: demo
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: web
  ports:
    - name: http
      port: 80
      targetPort: http
---
apiVersion: v1
kind: Service
metadata:
  name: web-nodeport
  namespace: demo
spec:
  type: NodePort
  selector:
    app.kubernetes.io/name: web
  ports:
    - name: http
      port: 80
      targetPort: http
      nodePort: 30080
EOF

kubectl apply -f ~/manifests/
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

**Both replicas on one node is expected** — `replicas: 2` means two Pods, not two machines.

### 8.2 Why `minikube service` does not open a browser here

```bash
# EC2 (ubuntu user)
minikube service web-nodeport -n demo -p demo
```

gives:

```text
X Exiting due to HOST_BROWSER: failed to open browser: exec: "xdg-open": executable file not found in $PATH
```

**Why:** `minikube service` tries to launch a graphical browser on the machine it runs on. An EC2 instance is headless — no display, no browser, no `xdg-open`. Even if one existed, it would open on the server, not on your laptop.

Use `--url` to get the address instead of an attempted browser launch:

```bash
# EC2 (ubuntu user)
minikube service web-nodeport -n demo -p demo --url
```

**Expected output:**

```text
http://192.168.49.2:30080
```

That URL is reachable **from the instance only**. Getting it to your laptop is what the rest of this section covers.

### 8.3 Method 1 — verify on the instance

```bash
# EC2 (ubuntu user)
curl -s "$(minikube service web-nodeport -n demo -p demo --url)" | head -5
curl -s "http://$(minikube ip -p demo):30080" | head -5
```

**Expected output:** the nginx welcome HTML. Always confirm this works before debugging remote access — it separates "the app is broken" from "the tunnel is broken".

### 8.4 Method 2 — `kubectl port-forward` (safest)

```bash
# EC2 (ubuntu user) — leave running
kubectl -n demo port-forward svc/web 8080:80
```

```bash
# EC2 (second session)
curl -s http://localhost:8080 | head -5
```

Combine with SSH forwarding (below) to reach it from your laptop with **no** NodePort rule.

### 8.5 Method 3 — SSH local port forwarding ⭐

Needs only port 22 open to your IP.

```bash
# Local terminal — leave running
ssh -i ~/.ssh/<KEY_PAIR_NAME>.pem -N -L 8080:localhost:30080 ubuntu@<PUBLIC_IP>
```

`-L 8080:localhost:30080` = listen on your laptop's `:8080`, tunnel over SSH, deliver to `localhost:30080` on the instance.

> [!IMPORTANT]
> This works because Minikube's Docker driver **also publishes the NodePort on the instance's `localhost`**. Confirm with `ss -tlnp | grep 30080` on the instance. If nothing is listening, use §8.6 instead — forward to the Minikube IP:
>
> ```bash
> ssh -i ~/.ssh/<KEY>.pem -N -L 8080:$(ssh -i ~/.ssh/<KEY>.pem ubuntu@<PUBLIC_IP> minikube ip -p demo):30080 ubuntu@<PUBLIC_IP>
> ```

```bash
# Local terminal (second window)
curl -s http://localhost:8080 | head -5
open http://localhost:8080          # macOS
xdg-open http://localhost:8080      # Linux
```

Stop with `Ctrl+C`.

### 8.6 Method 4 — SSM port forwarding (zero inbound rules)

```bash
# Local terminal
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["30080"],"localPortNumber":["8080"]}'
```

Then browse <http://localhost:8080>. Requires **no** security-group rule at all — the most secure option.

### 8.7 Method 5 — NodePort over the public IP

Only if you added the port-30080 rule scoped to your IP (§2.2).

```bash
# Local terminal
curl -s "http://<PUBLIC_IP>:30080" | head -5
```

If this times out but §8.3 works on the instance, the NodePort is bound to the Docker bridge but not to the instance's public interface. Bridge it with `socat`:

```bash
# EC2 (ubuntu user)
sudo apt-get install -y socat
sudo socat TCP-LISTEN:30080,fork,reuseaddr TCP:"$(minikube ip -p demo)":30080 &
```

> [!CAUTION]
> 🔴 Remove the security-group rule when you are done. A NodePort open to the internet is an unauthenticated public web server on your AWS account. Kill the `socat` process too: `sudo pkill socat`.

### 8.8 Method 6 — Ingress

Requires the ingress add-on.

```bash
# EC2 (ubuntu user)
cat > ~/manifests/30-ingress.yaml <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web
  namespace: demo
spec:
  ingressClassName: nginx
  rules:
    - host: demo.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: web
                port:
                  number: 80
EOF

kubectl apply -f ~/manifests/30-ingress.yaml
kubectl -n demo get ingress

echo "$(minikube ip -p demo) demo.local" | sudo tee -a /etc/hosts
curl -s http://demo.local | head -5
```

To reach it from your laptop, port-forward the controller and add a **local** hosts entry:

```bash
# EC2 (ubuntu user) — leave running
kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 8080:80
```

```bash
# Local terminal (in another window)
ssh -i ~/.ssh/<KEY_PAIR_NAME>.pem -N -L 8080:localhost:8080 ubuntu@<PUBLIC_IP>
echo "127.0.0.1 demo.local" | sudo tee -a /etc/hosts     # Linux/macOS
curl -s http://demo.local:8080 | head -5
```

Hosts file locations: Windows `C:\Windows\System32\drivers\etc\hosts` · Linux `/etc/hosts` · macOS `/etc/hosts`.

### Access method comparison

| Method | Inbound rules | Exposure | Use when |
|---|---|---|---|
| `curl` on the instance | None | None | Always check this first |
| `kubectl port-forward` | None | Instance-local | Combine with SSH/SSM |
| SSH `-L` forwarding | 22 from your IP | Your laptop | Default choice |
| SSM port forwarding | **None** | Your laptop | Most secure |
| NodePort over public IP | 30080 from your IP | Your IP | Browser demo |
| `minikube service` | — | ❌ Cannot open a browser | Only with `--url` |

---

## 9. Cleanup and cost checklist

> [!CAUTION]
> 💰 **Do this.** A forgotten instance bills continuously; an EBS volume bills even while the instance is stopped.

### 9.1 Delete the cluster

```bash
# EC2 (ubuntu user)
kubectl delete namespace demo

minikube delete -p demo          # 🔴 destroys the cluster
minikube profile list
```

**Expected output:** the `demo` profile is gone.

Remove every profile and cached image:

```bash
# EC2 (ubuntu user)  🔴 DESTRUCTIVE
minikube delete --all --purge
rm -rf ~/.minikube ~/.kube
```

### 9.2 Remove Docker resources

```bash
# EC2 (ubuntu user)
docker ps -a
docker system df
```

```bash
# EC2 (ubuntu user)  🔴 DESTRUCTIVE
docker system prune -a --volumes -f
docker system df
```

Pointless if you are terminating the instance — go to §9.3.

### 9.3 Stop or terminate the instance

**Stop** — keeps the disk. You still pay for the EBS volume, and the public IP changes on next start.

```bash
# Local terminal
aws ec2 stop-instances --instance-ids "$INSTANCE_ID"
aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].State.Name' --output text
```

**Terminate** — 🔴 **DESTRUCTIVE and irreversible.** Deletes the instance and (with `DeleteOnTermination=true`) its root volume. All charges stop.

```bash
# Local terminal  🔴 DESTRUCTIVE
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID"
aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID"
echo "Terminated."
```

Console: **EC2 → Instances → select → Instance state → Terminate (delete) instance**

### 9.4 Verify no billable resources remain

```bash
# Local terminal
echo "=== Running instances ==="
aws ec2 describe-instances --filters Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].{ID:InstanceId,Type:InstanceType,Name:Tags[?Key==`Name`]|[0].Value}' --output table

echo "=== Unattached EBS volumes (billing for nothing) ==="
aws ec2 describe-volumes --filters Name=status,Values=available \
  --query 'Volumes[].{ID:VolumeId,Size:Size,Created:CreateTime}' --output table

echo "=== Unassociated Elastic IPs (billed hourly) ==="
aws ec2 describe-addresses \
  --query 'Addresses[?AssociationId==null].{IP:PublicIp,Alloc:AllocationId}' --output table

echo "=== Snapshots you own ==="
aws ec2 describe-snapshots --owner-ids self \
  --query 'Snapshots[].{ID:SnapshotId,Size:VolumeSize,Started:StartTime}' --output table
```

All four tables should be empty (or contain only things you intend to keep). Delete leftovers:

```bash
# Local terminal  🔴 DESTRUCTIVE
aws ec2 delete-volume --volume-id <VOLUME_ID>
aws ec2 release-address --allocation-id <ALLOCATION_ID>
aws ec2 delete-snapshot --snapshot-id <SNAPSHOT_ID>
aws ec2 delete-security-group --group-id "$SG_ID"
```

### 9.5 Final checklist

- [ ] **EC2 instance** terminated (or deliberately stopped) — EC2 → Instances
- [ ] **EBS volumes** — none in `available` state — EC2 → Volumes
- [ ] **Elastic IPs** — none unassociated — EC2 → Elastic IPs
- [ ] **Snapshots / AMIs** — none unwanted — EC2 → Snapshots, EC2 → AMIs
- [ ] **Security group** deleted if unused — EC2 → Security Groups
- [ ] **Key pair** deleted if created only for this lab — EC2 → Key Pairs
- [ ] **IAM role** removed if created only for Session Manager — IAM → Roles
- [ ] **Local SSH / SSM port-forward sessions** closed
- [ ] **Local hosts-file entries** for `demo.local` removed
- [ ] **Billing checked** — Billing and Cost Management → **Cost Explorer**, grouped by Service, the next day

> [!NOTE]
> Billing data lags up to 24 hours. Check Cost Explorer the following day to confirm charges stopped.

---

## 10. Troubleshooting

| Symptom | Likely cause | Diagnostic | Resolution |
|---|---|---|---|
| `DRV_AS_ROOT: The "docker" driver should not be used with root privileges` | Running as root | `whoami` | `sudo su - ubuntu`; do §5.3. Do **not** use `--force`. |
| `permission denied ... /var/run/docker.sock` | `ubuntu` not in the `docker` group | `groups \| grep docker` | `sudo usermod -aG docker ubuntu; newgrp docker` |
| `Exiting due to RSRC_INSUFFICIENT_CORES` | Instance has 1 vCPU | `nproc` | Stop instance → change instance type to ≥2 vCPU → start |
| `Exiting due to RSRC_INSUFFICIENT_MEMORY` | `--memory` exceeds free RAM | `free -h` | Lower `--memory` |
| `This computer doesn't have VT-X/AMD-v enabled` | You chose a VM driver | Check the `--driver` flag | Use `--driver=docker`. VM drivers need nested virtualization, unavailable on standard EC2. |
| `xdg-open: executable file not found` | `minikube service`/`dashboard` on a headless server | — | Add `--url`; use SSH or SSM forwarding to reach it |
| NodePort unreachable from laptop | No SG rule, or not bound on the public interface | `curl` on the instance first; `ss -tlnp \| grep 30080` | Use SSH forwarding (§8.5), or add the SG rule and `socat` (§8.7) |
| `no space left on device` | 30 GB filled by images | `df -h /`; `docker system df` | `docker system prune -a`; grow the EBS volume |
| Cluster gone after instance restart | Minikube does not auto-start | `minikube status -p demo` | `minikube start -p demo` |
| Very slow, then unresponsive | Burstable instance out of CPU credits | CloudWatch → `CPUCreditBalance` | Use a non-burstable instance type, or reduce workload |
| `kubectl` says `connection refused` | Cluster stopped | `minikube status -p demo` | `minikube start -p demo` |
| Everything root-owned, permissions broken | You ran `minikube` with `sudo` at some point | `ls -la ~/.minikube ~/.kube` | `sudo rm -rf ~/.minikube ~/.kube` and start again as `ubuntu` |
| SSH times out | SG missing port 22 for your IP, or your ISP IP changed | `curl -s https://checkip.amazonaws.com` | Update the SG rule to your current `/32` |

**Diagnostics:**

```bash
# EC2 (ubuntu user)
minikube status -p demo
minikube logs -p demo --problems
kubectl get events -A --sort-by=.lastTimestamp | tail -20
docker ps -a
kubectl config current-context
nproc; free -h; df -h /
ss -tlnp | grep 30080
```

**Relevant AWS console pages:** EC2 → Instances · EC2 → Security Groups · EC2 → Volumes · Systems Manager → Session Manager · CloudWatch → Metrics (for `CPUCreditBalance` on burstable types).

---

## Official documentation

- Minikube start — <https://minikube.sigs.k8s.io/docs/start/>
- Docker driver — <https://minikube.sigs.k8s.io/docs/drivers/docker/>
- Accessing apps — <https://minikube.sigs.k8s.io/docs/handbook/accessing/>
- Docker Engine on Ubuntu — <https://docs.docker.com/engine/install/ubuntu/>
- Install kubectl on Linux — <https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/>
- EC2 security groups — <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-security-groups.html>
- Session Manager port forwarding — <https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-sessions-port-forwarding.html>
- EC2 on-demand pricing — <https://aws.amazon.com/ec2/pricing/on-demand/>
