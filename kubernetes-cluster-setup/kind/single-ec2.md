# Kind — Single-Node Cluster on One Ubuntu EC2 Instance

Run one Kind control-plane container on **exactly one** Ubuntu EC2 instance.

```text
Ubuntu EC2 instance
└── Docker
    └── One Kind control-plane container
```

No additional Kind worker containers. No second EC2 instance.

This page is self-contained — you do not need to read any other page.

Commands are marked:

- `# Local terminal` — your laptop (macOS/Linux/WSL, or PowerShell where noted)
- `# EC2 (ubuntu user)` — on the instance as the `ubuntu` user

Validated **2026-08-05** on Ubuntu 24.04 LTS (EC2), Kind **v0.32.0**, node image `kindest/node:v1.36.1`, Kubernetes **1.36**. Time: 15–20 minutes.

> [!WARNING]
> 💰 **This costs money.** The EC2 instance bills per second while running; the EBS volume bills even while the instance is stopped. Work through §9 when you are done. Check current pricing at <https://aws.amazon.com/ec2/pricing/on-demand/> before launching.

---

## What Kind on EC2 is good for

| Good for | Not a substitute for |
|---|---|
| **Kubernetes practice** on a machine that is not your laptop | Production workloads |
| **Testing manifests** — apply, check, delete, repeat | Highly available clusters |
| **CI experiments** — Kind is designed for CI, and this mirrors a CI runner | Anything needing AWS integration (ELB, EBS CSI, IAM roles for pods) |
| **Disposable development clusters** — create in 40 s, delete in 5 s | Managed upgrades or AWS support |

> [!IMPORTANT]
> **Kind is not an EKS replacement.** The whole cluster is one container on one instance: no high availability, no node-failure tolerance, no cloud controller manager (so `type: LoadBalancer` Services stay `<pending>` forever), and no AWS storage integration. For managed Kubernetes on AWS, use **[Guide 4 — EKS](../eksctl/)**.

---

## Contents

1. [EC2 prerequisites](#1-ec2-prerequisites)
2. [Networking and security group](#2-networking-and-security-group)
3. [Launch the instance](#3-launch-the-instance)
4. [Connect to the instance](#4-connect-to-the-instance)
5. [Install Docker, kubectl, Kind](#5-install-docker-kubectl-kind)
6. [Create the single-node cluster](#6-create-the-single-node-cluster)
7. [Deploy the sample application](#7-deploy-the-sample-application)
8. [Access the application from your laptop](#8-access-the-application-from-your-laptop)
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
| Root volume | 30 GB gp3 | 30 GB gp3 |
| Runtime | Docker Engine | Docker Engine |
| Security group | 1, restricted | 1, restricted |
| Access | SSH key pair **or** Systems Manager | Systems Manager |

Kind is the lightest of the three local options — no VM layer, and the node container shares the instance's kernel. A 2 vCPU / 4 GB instance runs it comfortably.

**Instance families** — check current pricing and free-tier eligibility for your account and region before choosing:

| Family | Character |
|---|---|
| Burstable (`t3`, `t3a`, `t4g`) | Cheapest. CPU credits accrue and burn. Fine for Kind, which is idle most of the time. `t4g` is Graviton/arm64 — cheaper, and Kind publishes arm64 node images. |
| General purpose (`m6i`, `m7i`, `m7g`) | Consistent performance |
| Compute optimized (`c6i`, `c7i`, `c7i-flex`) | More CPU per GB; `c7i-flex.large` is free-tier eligible on some newer accounts |

You also need an AWS account (**not** the root user), a chosen region, and billing alerts under **Billing and Cost Management → Budgets**.

---

## 2. Networking and security group

> [!CAUTION]
> 🔴 **Never open ports to `0.0.0.0/0`.** Anything exposed is scanned within minutes.

### 2.1 Find your public IP

```bash
# Local terminal
curl -s https://checkip.amazonaws.com
```

```powershell
# PowerShell
(Invoke-WebRequest -Uri https://checkip.amazonaws.com).Content.Trim()
```

Your CIDR is that address + `/32`. That is `<YOUR_PUBLIC_IP_CIDR>` below. Home ISPs rotate addresses — re-check if access stops working.

### 2.2 Minimal inbound rules

| # | Port | Source | Needed when |
|---|---|---|---|
| 1 | 22 | `<YOUR_PUBLIC_IP_CIDR>` | You use SSH. **Omit entirely if using Session Manager.** |
| 2 | 30080 | `<YOUR_PUBLIC_IP_CIDR>` | You want browser access to the NodePort. **Omit** if you use SSH forwarding. |

**Outbound:** leave the default *All traffic* — the instance must pull packages and images.

Nothing else. Kind's networking is entirely internal to the instance (a Docker bridge network plus the node container), and security groups do not filter loopback or intra-host traffic.

### 2.3 Safer alternatives

| Approach | Avoids | How |
|---|---|---|
| **Session Manager** ⭐ | Port 22 entirely | Instance profile with `AmazonSSMManagedInstancePolicy`, then `aws ssm start-session --target <INSTANCE_ID>` |
| **SSH local port forwarding** | Port 30080 | `ssh -N -L 8080:localhost:30080 ubuntu@<PUBLIC_IP>` |
| **SSM port forwarding** | Everything | `aws ssm start-session --document-name AWS-StartPortForwardingSession ...` |
| **`kubectl port-forward`** | Any NodePort rule | Tunnels through the API server |

**Best combination:** Session Manager + SSM port forwarding = **zero** inbound rules.

### 2.4 Create the security group

**Console:** EC2 → Security Groups → **Create security group** → name `kind-lab-sg` → default VPC → add only the rules you need, each with **Source = My IP** → Create.

**CLI:**

```bash
# Local terminal
export AWS_REGION=<AWS_REGION>
MY_IP="$(curl -s https://checkip.amazonaws.com)/32"
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)

SG_ID=$(aws ec2 create-security-group \
  --group-name kind-lab-sg \
  --description "Single-node Kind learning cluster" \
  --vpc-id "$VPC_ID" --query GroupId --output text)
echo "SG_ID=$SG_ID  MY_IP=$MY_IP"

# SSH — skip if using Session Manager
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 22 --cidr "$MY_IP"
```

Optional NodePort rule:

```bash
# Local terminal — only if you want direct browser access
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 30080 --cidr "$MY_IP"
```

✅ **Verify no rule is `0.0.0.0/0`:**

```bash
# Local terminal
aws ec2 describe-security-groups --group-ids "$SG_ID" --query 'SecurityGroups[0].IpPermissions' --output table
```

---

## 3. Launch the instance

**Console:** EC2 → **Launch instances** → Name `kind-lab` → AMI **Ubuntu Server 24.04 LTS** → instance type meeting §1 → key pair (or *Proceed without* for SSM) → **Select existing security group** `kind-lab-sg` → storage **30 GiB gp3** → *(optional)* IAM instance profile with `AmazonSSMManagedInstancePolicy` → **Launch instance**.

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
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=kind-lab},{Key=Purpose,Value=kubernetes-learning}]' \
  --query 'Instances[0].InstanceId' --output text
```

Use `arm64` in the SSM parameter path for Graviton types.

> [!IMPORTANT]
> `"DeleteOnTermination": true` deletes the EBS volume with the instance. Without it you keep paying for an orphaned volume indefinitely.

✅ **Verify exactly one instance:**

```bash
# Local terminal
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=kind-lab" "Name=instance-state-name,Values=running,pending" \
  --query 'Reservations[].Instances[].{ID:InstanceId,Type:InstanceType,State:State.Name,PublicIP:PublicIpAddress}' \
  --output table
```

---

## 4. Connect to the instance

### Option A — Session Manager (no open SSH port)

```bash
# Local terminal
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=kind-lab" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

aws ssm start-session --target "$INSTANCE_ID"
```

You land as `ssm-user`; switch to `ubuntu`:

```bash
# EC2
sudo su - ubuntu
```

> [!IMPORTANT]
> **Work as the `ubuntu` user throughout.** Kind writes `~/.kube/config` for whichever user runs it. Mixing users (or using `sudo`) means `kubectl` cannot find the cluster later.

Needs the Session Manager plugin locally: <https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html>

### Option B — SSH

```bash
# Local terminal
PUBLIC_IP=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=kind-lab" "Name=instance-state-name,Values=running" \
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

---

## 5. Install Docker, kubectl, Kind

### 5.1 Update packages

```bash
# EC2 (ubuntu user)
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get install -y ca-certificates curl gnupg
```

### 5.2 Docker Engine

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

### 5.3 Configure the non-root user

**What:** add `ubuntu` to the `docker` group.
**Why:** Kind must reach the Docker socket as the user that runs it, and it writes `~/.kube/config` for that same user. This is what lets you avoid `sudo` entirely.

```bash
# EC2 (ubuntu user)
sudo usermod -aG docker ubuntu
newgrp docker           # apply in this shell without logging out
```

✅ **Verify:**

```bash
# EC2 (ubuntu user)
groups | grep docker
docker version
docker run --rm hello-world
```

**Expected output:** both `Client:` and `Server:` sections, then `Hello from Docker!`.

Still `permission denied`? Log out and back in.

> [!CAUTION]
> The `docker` group is effectively root on this machine. Acceptable on a disposable single-purpose lab instance.

### 5.4 kubectl

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

### 5.5 Kind

```bash
# EC2 (ubuntu user)
ARCH=$(dpkg --print-architecture)
curl -Lo ./kind "https://kind.sigs.k8s.io/dl/v0.32.0/kind-linux-${ARCH}"
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind
kind version
```

**Expected output:**

```text
kind v0.32.0 go1.25.x linux/amd64
```

---

## 6. Create the single-node cluster

### 6.1 Write the config with port mapping

Kind nodes sit on an internal Docker network. A NodePort listens **inside the container only** unless you map it. Mappings must be set at creation — they cannot be added later.

```bash
# EC2 (ubuntu user)
cat > ~/kind-config.yaml <<'EOF'
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
      - containerPort: 30080
        hostPort: 30080
        protocol: TCP
        listenAddress: "0.0.0.0"
      - containerPort: 80
        hostPort: 8080
        protocol: TCP
        listenAddress: "127.0.0.1"
networking:
  apiServerAddress: "127.0.0.1"
EOF
```

| Field | Meaning |
|---|---|
| `nodes:` | **One entry, `role: control-plane`.** No `role: worker`. |
| `node-labels: "ingress-ready=true"` | Required if you later install ingress-nginx's Kind manifest — it selects on this label |
| `containerPort: 30080` → `hostPort: 30080` | Publishes the NodePort onto the instance so SSH/SSM forwarding and (optionally) the security-group rule can reach it |
| `listenAddress: "0.0.0.0"` on 30080 | Binds all instance interfaces. **Only your security group keeps this private** — it must be scoped to your `/32`. |
| `containerPort: 80` → `hostPort: 8080` on `127.0.0.1` | Ingress HTTP, bound to loopback only. Reachable via SSH/SSM forwarding, never from the internet. |
| `networking.apiServerAddress: "127.0.0.1"` | **Important.** Keeps the Kubernetes API server on loopback so it is never internet-reachable. |

> [!CAUTION]
> 🔴 Do **not** set `apiServerAddress` to the instance's private or public IP unless you fully understand the consequence — the API server holds cluster-admin access, and exposing `6443` publicly is a serious risk. Use SSH or SSM forwarding for remote `kubectl` instead.

### 6.2 Create

```bash
# EC2 (ubuntu user) — NOT root, NOT with sudo
kind create cluster --config ~/kind-config.yaml
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

First run 1–3 minutes; afterwards 40 seconds.

### 6.3 Verify

```bash
# EC2 (ubuntu user)
kubectl config current-context
kubectl cluster-info --context kind-demo
kubectl get nodes -o wide
kubectl get pods -A
docker ps --filter "name=demo-control-plane"
docker port demo-control-plane
kind get clusters
```

**Expected output:**

```text
kind-demo

Kubernetes control plane is running at https://127.0.0.1:38423

NAME                 STATUS   ROLES           AGE   VERSION   INTERNAL-IP   CONTAINER-RUNTIME
demo-control-plane   Ready    control-plane   50s   v1.36.1   172.18.0.2    containerd://2.x.x

NAMESPACE            NAME                                         READY   STATUS    RESTARTS   AGE
kube-system          coredns-...                                  1/1     Running   0          50s
kube-system          etcd-demo-control-plane                      1/1     Running   0          50s
kube-system          kindnet-...                                  1/1     Running   0          50s
kube-system          kube-apiserver-demo-control-plane            1/1     Running   0          50s
kube-system          kube-controller-manager-demo-control-plane   1/1     Running   0          50s
kube-system          kube-proxy-...                               1/1     Running   0          50s
kube-system          kube-scheduler-demo-control-plane            1/1     Running   0          50s
local-path-storage   local-path-provisioner-...                   1/1     Running   0          50s

30080/tcp -> 0.0.0.0:30080
80/tcp -> 127.0.0.1:8080
6443/tcp -> 127.0.0.1:38423
```

```text
One node named demo-control-plane
Status: Ready
```

**Notice:**

- `kindnet` — Kind's built-in CNI. No CNI installation step.
- `local-path-provisioner` — default StorageClass, so PVCs bind immediately.
- The API server is on `127.0.0.1` only — good.

**Confirm the taint is gone:**

```bash
# EC2 (ubuntu user)
kubectl describe node demo-control-plane | grep -i -A2 taints
```

**Expected output:** `Taints: <none>` — Kind removes it automatically on a single-node cluster.

### 6.4 Look inside the node container

```bash
# EC2 (ubuntu user)
docker exec -it demo-control-plane bash
```

Inside:

```bash
crictl ps
systemctl status kubelet
ls /etc/kubernetes/manifests/
exit
```

---

## 7. Deploy the sample application

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
      nodePort: 30080          # matches extraPortMappings in kind-config.yaml
EOF

kubectl apply -f ~/manifests/
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

✅ **Verify on the instance first** — always do this before debugging remote access:

```bash
# EC2 (ubuntu user)
curl -s http://localhost:30080 | head -5
```

**Expected output:** the nginx welcome page HTML.

This works because `extraPortMappings` published container `:30080` to the instance's `:30080`.

---

## 8. Access the application from your laptop

> [!IMPORTANT]
> **Kind's internal Docker network is not exposed to the internet.** The node container has an address like `172.18.0.2` on a Docker bridge that exists only inside the instance. No route from outside reaches it, and no security-group rule can change that. Everything below works by going through a port that Kind published onto the instance, or by tunnelling.

### Method 1 — SSH local port forwarding ⭐

Needs only port 22 open to your IP.

```bash
# Local terminal — leave running
ssh -i ~/.ssh/<KEY_PAIR_NAME>.pem -N -L 8080:localhost:30080 ubuntu@<PUBLIC_IP>
```

`-L 8080:localhost:30080` = listen on your laptop's `:8080`, tunnel over SSH, deliver to `localhost:30080` on the instance — where Kind published the NodePort.

```bash
# Local terminal (second window)
curl -s http://localhost:8080 | head -5
open http://localhost:8080          # macOS
xdg-open http://localhost:8080      # Linux
```

Stop with `Ctrl+C`.

### Method 2 — SSM port forwarding (zero inbound rules)

```bash
# Local terminal
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["30080"],"localPortNumber":["8080"]}'
```

Then browse <http://localhost:8080>. The most secure option — no security-group rule at all.

### Method 3 — `kubectl port-forward` plus a tunnel

Works even without any `extraPortMappings`.

```bash
# EC2 (ubuntu user) — leave running
kubectl -n demo port-forward svc/web 8081:80
```

```bash
# Local terminal — in another window
ssh -i ~/.ssh/<KEY_PAIR_NAME>.pem -N -L 8080:localhost:8081 ubuntu@<PUBLIC_IP>
curl -s http://localhost:8080 | head -5
```

### Method 4 — host port mapping over the public IP

Only if you added the port-30080 security-group rule scoped to your IP, and `listenAddress: "0.0.0.0"` in the config (as written in §6.1).

```bash
# Local terminal
curl -s "http://<PUBLIC_IP>:30080" | head -5
```

> [!CAUTION]
> 🔴 This is the **only** method that exposes anything to the internet. The security-group `/32` rule is the sole thing keeping it private. Remove the rule when you finish:
>
> ```bash
> aws ec2 revoke-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 30080 --cidr "$MY_IP"
> ```

### Method 5 — Ingress (optional)

```bash
# EC2 (ubuntu user)
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.15.1/deploy/static/provider/kind/deploy.yaml

kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s

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

# Verify on the instance — port 80 in the node maps to 8080 on the instance loopback
curl -s -H "Host: demo.local" http://localhost:8080 | head -5
```

From your laptop:

```bash
# Local terminal — leave running
ssh -i ~/.ssh/<KEY_PAIR_NAME>.pem -N -L 8080:localhost:8080 ubuntu@<PUBLIC_IP>
```

```bash
# Local terminal (second window)
curl -s -H "Host: demo.local" http://localhost:8080 | head -5
```

For browser access, add a hosts entry on **your laptop** pointing `demo.local` at `127.0.0.1`:

| Platform | Path |
|---|---|
| Windows | `C:\Windows\System32\drivers\etc\hosts` (edit as Administrator) |
| Linux / WSL | `/etc/hosts` (needs `sudo`) |
| macOS | `/etc/hosts` (needs `sudo`) |

Then browse `http://demo.local:8080`.

### Comparison

| Method | Inbound rules | Exposure | Use when |
|---|---|---|---|
| `curl` on the instance | None | None | Always check this first |
| SSH `-L` forwarding | 22 from your IP | Your laptop | Default choice |
| SSM port forwarding | **None** | Your laptop | Most secure |
| `port-forward` + tunnel | None extra | Your laptop | No port mapping configured |
| Host mapping + public IP | 30080 from your IP | Your IP only | Browser demo |

---

## 9. Cleanup and cost checklist

> [!CAUTION]
> 💰 **Do this.** A forgotten instance bills continuously; an EBS volume bills even while stopped.

### 9.1 Delete the Kind cluster

```bash
# EC2 (ubuntu user)
kubectl delete namespace demo

kind delete cluster --name demo          # 🔴 destroys the cluster
kind get clusters
```

**Expected output:**

```text
Deleting cluster "demo" ...
Deleted nodes: ["demo-control-plane"]
```

Every Kind cluster:

```bash
# EC2 (ubuntu user)  🔴 DESTRUCTIVE
kind delete clusters --all
```

### 9.2 Remove Docker containers

```bash
# EC2 (ubuntu user)
docker ps -a
```

Any leftover Kind containers:

```bash
# EC2 (ubuntu user)  🔴 DESTRUCTIVE
docker rm -f $(docker ps -aq --filter "label=io.x-k8s.kind.cluster") 2>/dev/null || echo "none"
docker network ls | grep kind
docker network rm kind 2>/dev/null || echo "already gone"
```

### 9.3 Remove images carefully

```bash
# EC2 (ubuntu user)
docker images
docker system df
```

Remove only the Kind node images you no longer need:

```bash
# EC2 (ubuntu user)
docker images | grep kindest/node
docker rmi kindest/node:v1.36.1        # 🔴 only if no cluster uses it
```

Or reclaim everything:

```bash
# EC2 (ubuntu user)  🔴 DESTRUCTIVE — removes ALL unused images and volumes
docker system prune -a --volumes -f
docker system df
```

Pointless if you are terminating the instance — go to §9.4.

### 9.4 Stop or terminate the instance

**Stop** — keeps the disk. You still pay for the EBS volume, and the public IP changes on next start.

```bash
# Local terminal
aws ec2 stop-instances --instance-ids "$INSTANCE_ID"
aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].State.Name' --output text
```

**Terminate** — 🔴 **DESTRUCTIVE and irreversible.** Deletes the instance and its root volume. All charges stop.

```bash
# Local terminal  🔴 DESTRUCTIVE
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID"
aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID"
echo "Terminated."
```

Console: **EC2 → Instances → select → Instance state → Terminate (delete) instance**

### 9.5 Verify EBS and Elastic IP cleanup

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

All four should be empty (or contain only things you intend to keep). Delete leftovers:

```bash
# Local terminal  🔴 DESTRUCTIVE
aws ec2 delete-volume --volume-id <VOLUME_ID>
aws ec2 release-address --allocation-id <ALLOCATION_ID>
aws ec2 delete-snapshot --snapshot-id <SNAPSHOT_ID>
aws ec2 delete-security-group --group-id "$SG_ID"
```

### 9.6 Final checklist

- [ ] **Kind cluster** deleted (`kind get clusters` is empty)
- [ ] **EC2 instance** terminated (or deliberately stopped) — EC2 → Instances
- [ ] **EBS volumes** — none in `available` state — EC2 → Volumes
- [ ] **Elastic IPs** — none unassociated — EC2 → Elastic IPs
- [ ] **Snapshots / AMIs** — none unwanted — EC2 → Snapshots, EC2 → AMIs
- [ ] **Security group** deleted if unused; port-30080 rule revoked in any case — EC2 → Security Groups
- [ ] **Key pair** deleted if created only for this lab — EC2 → Key Pairs
- [ ] **IAM role** removed if created only for Session Manager — IAM → Roles
- [ ] **Local SSH / SSM sessions** closed
- [ ] **Local hosts-file entries** for `demo.local` removed
- [ ] **Billing checked** — Billing and Cost Management → **Cost Explorer**, next day

> [!NOTE]
> Billing data lags up to 24 hours. Check Cost Explorer the following day.

---

## 10. Troubleshooting

| Symptom | Likely cause | Diagnostic | Resolution |
|---|---|---|---|
| `permission denied ... /var/run/docker.sock` | `ubuntu` not in the `docker` group | `groups \| grep docker` | `sudo usermod -aG docker ubuntu; newgrp docker` |
| `kubectl` says `no configuration has been provided` | You created the cluster as a different user | `whoami; ls -l ~/.kube/config` | Work consistently as `ubuntu`; recreate the cluster if needed |
| Cluster creation times out at "Starting control-plane" | Not enough memory, or inotify limits | `free -h`; `sysctl fs.inotify.max_user_instances` | Use a bigger instance; `sudo sysctl fs.inotify.max_user_instances=512` |
| `port is already allocated` | Host port in use | `sudo ss -tlnp \| grep 30080` | Change `hostPort`, or stop the conflicting process |
| `curl localhost:30080` refused on the instance | No `extraPortMappings` for 30080 | `docker port demo-control-plane` | Recreate with the config from §6.1 — mappings cannot be added later |
| Cannot reach it from the laptop, but `curl` works on the instance | It is a tunnel/SG problem, not an app problem | Try SSH forwarding (§8.1) | Use SSH or SSM forwarding; or add the `/32` SG rule |
| Cannot reach `172.18.0.2` from anywhere outside | Kind's Docker network is internal to the instance | — | Expected and correct. Use published ports or tunnels. |
| `LoadBalancer` Service stuck `<pending>` | No cloud controller manager | `kubectl get svc -A \| grep pending` | Expected on Kind. Use NodePort or `port-forward`. Use [EKS](../eksctl/) if you need real load balancers. |
| Ingress controller `Pending` | Node missing `ingress-ready=true` | `kubectl get nodes --show-labels` | Recreate with the `kubeadmConfigPatches` block from §6.1 |
| `no space left on device` | 30 GB filled with images | `df -h /`; `docker system df` | `docker system prune -a`; grow the EBS volume |
| Cluster gone after instance restart | Docker container not restarted, or Docker did not autostart | `docker ps -a`; `systemctl status docker` | `docker start demo-control-plane`, wait ~60 s; or recreate the cluster |
| Slow, then unresponsive | Burstable instance out of CPU credits | CloudWatch → `CPUCreditBalance` | Use a non-burstable instance type |
| SSH times out | SG missing port 22 for your IP, or ISP IP changed | `curl -s https://checkip.amazonaws.com` | Update the SG rule to your current `/32` |
| `ErrImagePull` for a locally built image | Not loaded, or `imagePullPolicy: Always` | `docker exec demo-control-plane crictl images \| grep <name>` | `kind load docker-image <IMAGE> --name demo`; use `IfNotPresent`; avoid `:latest` |

**Diagnostics:**

```bash
# EC2 (ubuntu user)
kind get clusters
docker ps -a
docker port demo-control-plane
docker logs demo-control-plane --tail 50
kubectl get nodes
kubectl get pods -A
kubectl get events -A --sort-by=.lastTimestamp | tail -20
kind export logs --name demo ./kind-logs
df -h /; free -h; nproc
ss -tlnp | grep 30080
```

**Relevant AWS console pages:** EC2 → Instances · EC2 → Security Groups · EC2 → Volumes · Systems Manager → Session Manager · CloudWatch → Metrics (`CPUCreditBalance` for burstable types).

---

## Official documentation

- Kind quick start — <https://kind.sigs.k8s.io/docs/user/quick-start/>
- Configuration — <https://kind.sigs.k8s.io/docs/user/configuration/>
- Ingress — <https://kind.sigs.k8s.io/docs/user/ingress/>
- Known issues — <https://kind.sigs.k8s.io/docs/user/known-issues/>
- Releases and node images — <https://github.com/kubernetes-sigs/kind/releases>
- Docker Engine on Ubuntu — <https://docs.docker.com/engine/install/ubuntu/>
- EC2 security groups — <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-security-groups.html>
- Session Manager port forwarding — <https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-sessions-port-forwarding.html>
- EC2 on-demand pricing — <https://aws.amazon.com/ec2/pricing/on-demand/>
