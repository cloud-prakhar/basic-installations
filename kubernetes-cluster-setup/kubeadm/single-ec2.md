# kubeadm — Single-Node Cluster on One Ubuntu EC2 Instance

Build a one-node Kubernetes cluster on **exactly one** Ubuntu EC2 instance. That instance is simultaneously:

- Kubernetes control-plane node
- Kubernetes worker node
- Container runtime host
- Application workload node

There is **no second EC2 instance**. There is **no `kubeadm join`**.

This page is self-contained — you do not need to read any other page.

Commands are marked:

- `# Local terminal` — your laptop (macOS Terminal, Linux terminal, WSL, or PowerShell where noted)
- `# EC2 (ubuntu user)` — on the instance, as the `ubuntu` user

Validated **2026-08-05** on Ubuntu 24.04 LTS (EC2), Kubernetes **1.36**, containerd **2.3.x**, Calico **v3.32.1**. Time: 30–40 minutes.

> [!WARNING]
> 💰 **This costs money.** An EC2 instance with 4 vCPU / 8 GB plus a 40 GB gp3 volume bills **per second while running**, and the EBS volume bills even when the instance is stopped. Go through §10 when you are done. Check current pricing at <https://aws.amazon.com/ec2/pricing/on-demand/> before you launch — do not trust any figure quoted in a tutorial, including this one.

---

## Contents

1. [EC2 prerequisites](#1-ec2-prerequisites)
2. [Networking and security group](#2-networking-and-security-group)
3. [Launch the instance](#3-launch-the-instance)
4. [Connect to the instance](#4-connect-to-the-instance)
5. [Prepare the host](#5-prepare-the-host)
6. [Install containerd](#6-install-containerd)
7. [Install kubeadm, kubelet, kubectl](#7-install-kubeadm-kubelet-kubectl)
8. [Initialize the cluster, CNI, taint](#8-initialize-the-cluster)
9. [Verify and deploy the sample application](#9-verify-and-deploy-the-sample-application)
10. [Access the application](#10-access-the-application)
11. [Troubleshooting](#11-troubleshooting)
12. [Cleanup and cost checklist](#12-cleanup-and-cost-checklist)

---

## 1. EC2 prerequisites

### 1.1 What to launch

| Setting | Minimum | Recommended |
|---|---|---|
| AMI | Ubuntu Server **24.04 LTS** (or 22.04 LTS) | Ubuntu Server 24.04 LTS |
| Instances | **1** | 1 |
| vCPU | 2 | 4 |
| Memory | 4 GB | 8 GB |
| Root volume | 30 GB gp3 | 40 GB gp3 |
| Security group | 1 | 1 |
| Access | SSH key pair **or** AWS Systems Manager | Systems Manager (no open SSH port) |

> [!WARNING]
> `kubeadm init` **hard-fails** with fewer than 2 vCPUs. `t2.micro`/`t3.micro` (1 vCPU, 1 GB) will not work. Free-tier-only accounts should expect to pay for this lab.

### 1.2 Choosing an instance family

Do not fixate on one instance type — availability, price, and free-tier eligibility vary by account and region. Suitable families for a learning cluster:

| Family | Character | Note |
|---|---|---|
| **General purpose burstable** (`t3`, `t3a`, `t4g`) | Cheapest; CPU credits accumulate and burn | Fine for a lab. Under sustained load you may hit credit throttling and see the cluster get sluggish. `t4g` is Graviton/arm64 — cheaper, and everything in this guide has arm64 builds. |
| **General purpose** (`m6i`, `m7i`, `m7g`) | Consistent performance, more expensive | Best if the cluster feels slow on burstable instances |
| **Compute optimized** (`c6i`, `c7i`, `c7i-flex`) | More CPU per GB of RAM | `c7i-flex.large` is free-tier eligible on some newer AWS accounts |

Rough sizing: a `*.large` (2 vCPU / 8 GB) meets the minimum comfortably; a `*.xlarge` (4 vCPU / 16 GB) is roomy.

> [!IMPORTANT]
> **Check current pricing and free-tier eligibility for your account and region before launching.** AWS pricing changes, and the newer AWS Free Tier plan refuses to launch some instance types entirely. Console: **EC2 → Instances → Launch instance** shows the hourly price next to each type.

### 1.3 Architecture note

If you pick a **Graviton** type (`t4g`, `m7g`, `c7g`), choose the **arm64** Ubuntu AMI. Every command in this guide works unchanged — `$(dpkg --print-architecture)` resolves correctly, and Kubernetes, containerd, Calico, and `nginx:1.30-alpine` all publish arm64 builds.

### 1.4 What you need before starting

- An AWS account with permission to create EC2 instances, security groups, and (for Session Manager) IAM roles
- A region selected — use one close to you
- **Not the root account.** Use an IAM user or IAM Identity Center role.
- Billing alerts configured — **Billing and Cost Management → Budgets**

---

## 2. Networking and security group

### 2.1 Principle

> [!CAUTION]
> 🔴 **Never open ports to `0.0.0.0/0` on this instance.** Port `6443` open to the world means anyone can attempt to reach your Kubernetes API server. NodePorts open to the world means your test apps are on the public internet. Both get scanned within minutes.

### 2.2 Find your public IP

```bash
# Local terminal (macOS / Linux / WSL)
curl -s https://checkip.amazonaws.com
```

```powershell
# PowerShell
(Invoke-WebRequest -Uri https://checkip.amazonaws.com).Content.Trim()
```

**Expected output:** `203.0.113.45`

Your CIDR is that address with `/32`: `203.0.113.45/32`. This is `<YOUR_PUBLIC_IP_CIDR>` below.

> [!NOTE]
> Home ISPs change your IP periodically. If access stops working, re-run the command above and update the security group rule.

### 2.3 Minimal security group

**Inbound rules — create only what you actually need:**

| # | Port | Protocol | Source | Needed when |
|---|---|---|---|---|
| 1 | 22 | TCP | `<YOUR_PUBLIC_IP_CIDR>` | You use SSH. **Omit entirely if using Session Manager.** |
| 2 | 6443 | TCP | `<YOUR_PUBLIC_IP_CIDR>` | You want to run `kubectl` from your laptop against the cluster. **Omit** if you will only run `kubectl` on the instance. |
| 3 | 30080 | TCP | `<YOUR_PUBLIC_IP_CIDR>` | You want to hit the NodePort demo directly. **Omit** if you use SSH forwarding or `port-forward`. |

**Outbound rules:** leave the default *All traffic to `0.0.0.0/0`*. The instance must reach the internet to pull packages and container images.

**Intra-node traffic:** all Kubernetes control-plane traffic on this cluster is node-to-itself — API server ↔ etcd ↔ kubelet ↔ scheduler all over `127.0.0.1` or the instance's own private IP. Loopback and same-ENI traffic are not filtered by security groups, so **no additional inbound rules are required** for Kubernetes to function. If you later add a real second node you would need the full port list from <https://kubernetes.io/docs/reference/networking/ports-and-protocols/> — you do not need it here.

### 2.4 Safer alternatives to opening ports

| Approach | What it avoids | How |
|---|---|---|
| **AWS Systems Manager Session Manager** ⭐ | Port 22 entirely — no SSH key, no inbound rule, and every session is logged in CloudTrail | Attach an instance profile with `AmazonSSMManagedInstancePolicy`, then `aws ssm start-session --target <INSTANCE_ID>` |
| **SSH local port forwarding** | Ports 6443 and 30080 | `ssh -N -L 8080:localhost:30080 ubuntu@<PUBLIC_IP>` |
| **`kubectl port-forward`** | Any NodePort rule | Tunnels through the API server; nothing is bound on the node externally |
| **Restricting source CIDRs** | Public exposure | `/32` of your own IP, never `0.0.0.0/0` |

**Best combination for this lab:** Session Manager for shell access + `kubectl` run on the instance + `kubectl port-forward` over an SSM port-forward session. That needs **zero** inbound rules.

### 2.5 Create the security group (console)

1. **EC2 → Network & Security → Security Groups → Create security group**
2. Name: `k8s-single-node-sg`; description: `Single-node kubeadm learning cluster`
3. VPC: your default VPC
4. Add only the inbound rules from §2.3 that you need, each with **Source = My IP**
5. **Create security group**

### 2.6 Or with the AWS CLI

```bash
# Local terminal
export AWS_REGION=<AWS_REGION>
MY_IP="$(curl -s https://checkip.amazonaws.com)/32"
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text)

SG_ID=$(aws ec2 create-security-group \
  --group-name k8s-single-node-sg \
  --description "Single-node kubeadm learning cluster" \
  --vpc-id "$VPC_ID" --query GroupId --output text)
echo "SG_ID=$SG_ID  MY_IP=$MY_IP"

# SSH — skip this if you will use Session Manager
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
  --protocol tcp --port 22 --cidr "$MY_IP"
```

Add the other rules only if you decided you need them:

```bash
# Local terminal — optional
# Kubernetes API from your laptop
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
  --protocol tcp --port 6443 --cidr "$MY_IP"

# NodePort demo
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
  --protocol tcp --port 30080 --cidr "$MY_IP"
```

✅ **Verify:**

```bash
# Local terminal
aws ec2 describe-security-groups --group-ids "$SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' --output table
```

Confirm no rule has `0.0.0.0/0` as a source.

---

## 3. Launch the instance

### 3.1 Console

1. **EC2 → Instances → Launch instances**
2. **Name:** `k8s-single`
3. **AMI:** Ubuntu Server 24.04 LTS (arm64 if you chose a Graviton type)
4. **Instance type:** one meeting §1.1 (≥2 vCPU, ≥4 GB)
5. **Key pair:** select yours, or **Proceed without a key pair** if using Session Manager
6. **Network settings → Select existing security group →** `k8s-single-node-sg`
7. **Configure storage:** `40` GiB, `gp3`
8. **Advanced details → IAM instance profile:** attach a role with `AmazonSSMManagedInstancePolicy` if using Session Manager
9. **Launch instance**

### 3.2 Or with the AWS CLI

```bash
# Local terminal
export AWS_REGION=<AWS_REGION>

AMI_ID=$(aws ssm get-parameter \
  --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
  --query 'Parameter.Value' --output text)
echo "AMI_ID=$AMI_ID"

aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type <INSTANCE_TYPE> \
  --count 1 \
  --key-name <KEY_PAIR_NAME> \
  --security-group-ids "$SG_ID" \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":40,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=k8s-single},{Key=Purpose,Value=kubernetes-learning}]' \
  --query 'Instances[0].InstanceId' --output text
```

For arm64, swap `amd64` for `arm64` in the SSM parameter path.

> [!IMPORTANT]
> `"DeleteOnTermination": true` means the EBS volume is deleted with the instance. Without it you keep paying for an orphaned volume forever.

✅ **Verify — exactly one instance:**

```bash
# Local terminal
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=k8s-single" "Name=instance-state-name,Values=running,pending" \
  --query 'Reservations[].Instances[].{ID:InstanceId,Type:InstanceType,State:State.Name,PublicIP:PublicIpAddress}' \
  --output table
```

---

## 4. Connect to the instance

### Option A — Session Manager (recommended; no open SSH port)

```bash
# Local terminal
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=k8s-single" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

aws ssm start-session --target "$INSTANCE_ID"
```

You land as `ssm-user`. Switch to `ubuntu`:

```bash
# EC2
sudo su - ubuntu
```

Requires the Session Manager plugin locally: <https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html>

### Option B — SSH

```bash
# Local terminal
PUBLIC_IP=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=k8s-single" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "PUBLIC_IP=$PUBLIC_IP"

chmod 400 ~/.ssh/<KEY_PAIR_NAME>.pem
ssh -i ~/.ssh/<KEY_PAIR_NAME>.pem ubuntu@"$PUBLIC_IP"
```

✅ **Verify you are on the instance:**

```bash
# EC2 (ubuntu user)
whoami
hostname
nproc
free -h
df -h /
. /etc/os-release && echo "$PRETTY_NAME"
```

**Expected output:**

```text
ubuntu
ip-172-31-XX-XX
4
               total        used        free
Mem:           7.6Gi       0.3Gi       7.0Gi
Filesystem      Size  Used Avail Use% Mounted on
/dev/root        39G  2.1G   37G   6% /
Ubuntu 24.04.3 LTS
```

`nproc` must be ≥ 2 and memory ≥ 4 GB.

---

## 5. Prepare the host

Everything from here runs on the EC2 instance.

### 5.1 Update packages

```bash
# EC2 (ubuntu user, root via sudo)
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get install -y ca-certificates curl gnupg apt-transport-https
```

### 5.2 Hostname

**Why:** the Kubernetes node object takes its name from the hostname, and that name goes into TLS certificates. EC2's default `ip-172-31-x-x` works, but a stable, meaningful name is clearer — and on some AMIs the DHCP-derived hostname can change.

```bash
# EC2 (ubuntu user)
sudo hostnamectl set-hostname k8s-single
hostnamectl --static
```

Make it survive reboots — Ubuntu's cloud-init otherwise resets it from DHCP:

```bash
# EC2 (ubuntu user)
sudo sed -i 's/^preserve_hostname: false/preserve_hostname: true/' /etc/cloud/cloud.cfg || \
  echo "preserve_hostname: true" | sudo tee -a /etc/cloud/cloud.cfg
grep preserve_hostname /etc/cloud/cloud.cfg
```

**Expected output:** `preserve_hostname: true`

### 5.3 `/etc/hosts`

**Why:** several components resolve the node's own name; a failure there produces slow startup and kubelet DNS errors.

```bash
# EC2 (ubuntu user)
echo "127.0.1.1 k8s-single" | sudo tee -a /etc/hosts
getent hosts k8s-single
```

**Expected output:** `127.0.1.1       k8s-single`

### 5.4 Disable swap

**Why:** the kubelet's memory accounting and eviction logic assume RAM is the hard limit. With swap on, an over-limit Pod swaps instead of being evicted and the node degrades silently. The kubelet refuses to start with swap enabled.

```bash
# EC2 (ubuntu user)
# Temporarily
sudo swapoff -a

# Permanently
sudo sed -i.bak -E 's|^([^#].*\sswap\s.*)$|#\1|' /etc/fstab

# Some AMIs use a swapfile unit instead of fstab
systemctl list-units --type swap --no-legend
# if any listed:  sudo systemctl mask <unit-name>
```

✅ **Verify:**

```bash
# EC2 (ubuntu user)
swapon --show
free -h | grep -i swap
```

**Expected output** — `swapon --show` prints nothing:

```text
Swap:            0B          0B          0B
```

> [!NOTE]
> Most stock Ubuntu EC2 AMIs ship with **no swap at all**. If `swapon --show` was already empty, nothing to do.

### 5.5 Kernel modules

**Why:** `overlay` is the filesystem containerd's snapshotter uses to layer images. `br_netfilter` makes traffic crossing a Linux bridge visible to iptables/nftables — without it, kube-proxy's Service rules are never evaluated and Services silently do nothing.

```bash
# EC2 (ubuntu user)
cat <<'EOF' | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter
lsmod | grep -E '^(overlay|br_netfilter)'
```

**Expected output:**

```text
br_netfilter           32768  0
overlay               212992  0
```

### 5.6 sysctl

**Why:** `ip_forward` lets the node route packets between Pod interfaces and the outside world (off by default). The bridge settings ensure Service NAT applies to bridged Pod traffic.

```bash
# EC2 (ubuntu user)
cat <<'EOF' | sudo tee /etc/sysctl.d/99-kubernetes.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
```

✅ **Verify:**

```bash
# EC2 (ubuntu user)
sysctl net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables
```

**Expected output:**

```text
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
```

**Common error:** `cannot stat /proc/sys/net/bridge/bridge-nf-call-iptables` → run `sudo modprobe br_netfilter` then `sudo sysctl --system` again.

### 5.7 Choose the Pod CIDR

**Why:** the Pod IP range must not overlap your **VPC** CIDR, or Pod traffic will be routed into the VPC instead of inside the cluster.

```bash
# EC2 (ubuntu user)
ip -4 addr show | grep inet
```

Default VPCs use `172.31.0.0/16`. So **`192.168.0.0/16`** (Calico's default) is safe and is what this page uses.

```bash
# EC2 (ubuntu user)
export POD_NETWORK_CIDR=192.168.0.0/16
echo "$POD_NETWORK_CIDR"
```

If your VPC happens to use `192.168.x.x`, use `10.244.0.0/16` instead and substitute it everywhere below.

---

## 6. Install containerd

### 6.1 Why containerd, not Docker

Kubernetes talks to container runtimes over the **CRI** (Container Runtime Interface). containerd implements CRI natively via a built-in plugin. Docker Engine does not — kubelet support for Docker was removed in Kubernetes 1.24 and now requires the extra `cri-dockerd` shim. Fewer moving parts.

### 6.2 Install

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
sudo apt-get install -y containerd.io
containerd --version
```

**Expected output:**

```text
containerd containerd.io 2.3.3 <commit-sha>
```

### 6.3 Configure and enable `SystemdCgroup`

**Why:** on a systemd host, systemd is the single owner of the cgroup hierarchy. The kubelet defaults to the `systemd` cgroup driver. If containerd uses `cgroupfs`, two components write to one hierarchy — wrong accounting and Pods killed unpredictably under memory pressure. **They must match.**

```bash
# EC2 (ubuntu user)
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
grep -n 'SystemdCgroup' /etc/containerd/config.toml
```

**Expected output:**

```text
<line>:            SystemdCgroup = true
```

**Ensure the CRI plugin is enabled** — Docker's package has historically shipped `disabled_plugins = ["cri"]`, which makes containerd invisible to the kubelet and fails `kubeadm init` at preflight:

```bash
# EC2 (ubuntu user)
grep -n 'disabled_plugins' /etc/containerd/config.toml
sudo sed -i 's/disabled_plugins = \["cri"\]/disabled_plugins = []/' /etc/containerd/config.toml
```

**Expected output:** `disabled_plugins = []`

### 6.4 Start and verify

```bash
# EC2 (ubuntu user)
sudo systemctl restart containerd
sudo systemctl enable containerd

systemctl is-active containerd
systemctl is-enabled containerd
ls -l /run/containerd/containerd.sock
sudo ctr plugin ls | grep -E 'NAME|cri'
```

**Expected output:**

```text
active
enabled
srw-rw---- 1 root root 0 Aug  5 10:12 /run/containerd/containerd.sock
```

CRI plugin rows must show `STATUS: ok`.

**Logs on failure:**

```bash
# EC2 (ubuntu user)
sudo journalctl -u containerd -n 50 --no-pager
```

---

## 7. Install kubeadm, kubelet, kubectl

| Component | Role |
|---|---|
| **kubeadm** | Bootstrapper. Runs once (`init`) to generate certificates and start the control plane. Not a daemon. |
| **kubelet** | The node agent — a permanent systemd service. Talks to containerd over CRI and to the API server. |
| **kubectl** | The CLI for the API server. |

### 7.1 Repository

> [!WARNING]
> 🔴 Do **not** use `apt.kubernetes.io` or `packages.cloud.google.com/apt`. Retired and no longer served — tutorials using them fail with `404` or `NO_PUBKEY`. `pkgs.k8s.io` is versioned per minor release; the version is part of the URL.

```bash
# EC2 (ubuntu user)
export KUBERNETES_VERSION=v1.36     # minor version only, leading "v"

sudo mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/Release.key" \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
sudo chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo chmod 644 /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
```

### 7.2 Install, hold, enable

**Why hold:** Kubernetes upgrades are an ordered procedure. Ubuntu's unattended-upgrades bumping the kubelet under a running control plane breaks the cluster.

```bash
# EC2 (ubuntu user)
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet
```

**Expected output:**

```text
kubelet set on hold.
kubeadm set on hold.
kubectl set on hold.
```

> [!NOTE]
> The kubelet now crash-loops every few seconds. **Expected** — it has no config until `kubeadm init` runs.

✅ **Verify:**

```bash
# EC2 (ubuntu user)
kubeadm version -o short
kubelet --version
kubectl version --client
```

**Expected output:**

```text
v1.36.1
Kubernetes v1.36.1
Client Version: v1.36.1
```

**Version skew:** the kubelet must never be newer than the API server (may be up to three minor versions older); `kubectl` may be one minor either side. Installed together as above, automatic.

---

## 8. Initialize the cluster

### 8.1 Node IP

Use the instance's **private** IP, not the public one. The public IP is a NAT translation performed outside the instance — the instance has no interface with that address, so `kubeadm` cannot bind to it.

```bash
# EC2 (ubuntu user)
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
export NODE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/local-ipv4)
echo "NODE_IP=$NODE_IP  POD_NETWORK_CIDR=$POD_NETWORK_CIDR"
```

**Expected output:**

```text
NODE_IP=172.31.24.118  POD_NETWORK_CIDR=192.168.0.0/16
```

(That is IMDSv2, which newer AMIs require. `ip route get 1.1.1.1 | awk '{print $7; exit}'` gives the same answer.)

### 8.2 Run `kubeadm init`

| Flag | Meaning |
|---|---|
| `--apiserver-advertise-address` | The IP the API server binds to and writes into certificates and kubeconfig |
| `--pod-network-cidr` | The range Pods get addresses from; read by the CNI and controller-manager |
| `--cri-socket` | Which runtime socket the kubelet uses |
| `--apiserver-cert-extra-sans` | **Extra names/IPs added to the API server certificate.** Add the public IP here if you want to run `kubectl` from your laptop against `https://<PUBLIC_IP>:6443` — without it you get a `x509: certificate is valid for ...` error. |
| `--node-name` | Name of the Node object |

```bash
# EC2 (ubuntu user)
# Optional: only if you want kubectl from your laptop over the public IP
PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/public-ipv4)
echo "PUBLIC_IP=$PUBLIC_IP"

sudo kubeadm init \
  --apiserver-advertise-address="${NODE_IP}" \
  --pod-network-cidr="${POD_NETWORK_CIDR}" \
  --cri-socket="unix:///run/containerd/containerd.sock" \
  --apiserver-cert-extra-sans="${PUBLIC_IP}" \
  --node-name="k8s-single"
```

Drop the `--apiserver-cert-extra-sans` line if you will only use `kubectl` on the instance.

2–6 minutes on first run.

**Expected output** (tail):

```text
Your Kubernetes control-plane has initialized successfully!

To start using your cluster, you need to run the following as a regular user:
  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config
...
kubeadm join 172.31.24.118:6443 --token abcdef.0123456789abcdef ...
```

> [!NOTE]
> **Ignore the `kubeadm join` line.** There is no second instance. The token expiring in 24 hours is irrelevant.

**What was created:** certificates in `/etc/kubernetes/pki/`; static Pod manifests (`kube-apiserver`, `etcd`, `kube-scheduler`, `kube-controller-manager`) in `/etc/kubernetes/manifests/`, which the kubelet watches and runs — that is how the control plane starts itself; admin kubeconfig at `/etc/kubernetes/admin.conf`; kubelet config at `/var/lib/kubelet/config.yaml`; etcd data in `/var/lib/etcd/`.

### 8.3 Configure kubectl

```bash
# EC2 (ubuntu user — NOT root)
mkdir -p "$HOME/.kube"
sudo cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"

kubectl cluster-info
kubectl get nodes
```

**Expected output:**

```text
Kubernetes control plane is running at https://172.31.24.118:6443

NAME         STATUS     ROLES           AGE   VERSION
k8s-single   NotReady   control-plane   45s   v1.36.1
```

`NotReady` is correct — no CNI yet.

> [!CAUTION]
> 🔴 This file holds **cluster-admin credentials for a publicly-addressable instance**. Never commit it, paste it, or store it in an S3 bucket.

### 8.4 Install the CNI plugin (Calico)

**Why the node is `NotReady`:** the kubelet only reports `Ready` once a network plugin is initialized. With no `/etc/cni/net.d/` config it sets `NetworkReady=false` / `NetworkPluginNotReady`, and CoreDNS stays `Pending` because it needs Pod networking. The other `kube-system` Pods run because they use host networking.

```bash
# EC2 (ubuntu user)
kubectl describe node k8s-single | grep -A5 Conditions
kubectl get pods -n kube-system

kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.32.1/manifests/calico.yaml
kubectl -n kube-system rollout status daemonset/calico-node --timeout=300s
```

✅ **Verify:**

```bash
# EC2 (ubuntu user)
kubectl get nodes
kubectl get pods -n kube-system
```

**Expected output:**

```text
NAME         STATUS   ROLES           AGE   VERSION
k8s-single   Ready    control-plane   5m    v1.36.1
```

with `calico-node`, `calico-kube-controllers`, both `coredns` Pods, `etcd`, `kube-apiserver`, `kube-controller-manager`, `kube-proxy`, and `kube-scheduler` all `Running`.

**Alternatives:** **Cilium** (`cilium install --version 1.20.0`) — eBPF-based, heavier; **Flannel** — lightest, but hard-codes `10.244.0.0/16` and has no NetworkPolicy. Install **exactly one**.

**If you used `10.244.0.0/16`:** Calico normally auto-detects the kubeadm-configured CIDR. If Pod IPs come out wrong, download `calico.yaml`, uncomment `CALICO_IPV4POOL_CIDR` in the `calico-node` DaemonSet, set it to your CIDR, and re-apply.

### 8.5 Remove the control-plane taint

A **taint** repels Pods that lack a matching **toleration**. `kubeadm` applies `node-role.kubernetes.io/control-plane:NoSchedule` so ordinary workloads cannot starve etcd and the API server. With exactly one node, your app has nowhere else to go.

```bash
# EC2 (ubuntu user)
kubectl describe node k8s-single | grep -i -A2 taints
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
kubectl describe node k8s-single | grep -i -A2 taints
```

**Expected output:**

```text
Taints:             node-role.kubernetes.io/control-plane:NoSchedule
node/k8s-single untainted
Taints:             <none>
```

> [!WARNING]
> Correct **only** because this is a single-node learning cluster. In production you add worker nodes. Restore with `kubectl taint nodes k8s-single node-role.kubernetes.io/control-plane=:NoSchedule`.

✅ **Confirm scheduling works:**

```bash
# EC2 (ubuntu user)
kubectl run scheduling-test --image=nginx:1.30-alpine --restart=Never
kubectl wait --for=condition=Ready pod/scheduling-test --timeout=120s
kubectl get pod scheduling-test -o wide
kubectl delete pod scheduling-test
```

The Pod IP must come from your Pod CIDR — proof the CNI works.

---

## 9. Verify and deploy the sample application

### 9.1 Full verification

```bash
# EC2 (ubuntu user)
kubectl get nodes -o wide
kubectl get pods -n kube-system -o wide
kubectl get deployment coredns -n kube-system
kubectl get svc kube-dns -n kube-system
kubectl get daemonset calico-node -n kube-system
systemctl is-active kubelet containerd
kubectl cluster-info
kubectl get --raw='/readyz?verbose' | tail -5
```

**Expected result:**

```text
One node
Status: Ready
Roles: control-plane
```

**Pod networking and DNS:**

```bash
# EC2 (ubuntu user)
kubectl run net-a --image=nginx:1.30-alpine
kubectl run net-b --image=busybox:1.37 --restart=Never --command -- sleep 3600
kubectl wait --for=condition=Ready pod/net-a pod/net-b --timeout=120s

POD_A_IP=$(kubectl get pod net-a -o jsonpath='{.status.podIP}')
kubectl exec net-b -- wget -qO- --timeout=5 "http://${POD_A_IP}" | head -4

kubectl expose pod net-a --name=net-a-svc --port=80
kubectl exec net-b -- nslookup net-a-svc.default.svc.cluster.local

kubectl delete pod net-a net-b; kubectl delete svc net-a-svc
```

### 9.2 Deploy the sample app

Write the manifests directly on the instance:

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

cat > ~/manifests/20-service-clusterip.yaml <<'EOF'
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
EOF

cat > ~/manifests/30-service-nodeport.yaml <<'EOF'
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
namespace/demo created
deployment.apps/web created
service/web created
service/web-nodeport created

NAME                      READY   STATUS    RESTARTS   AGE   IP                NODE
pod/web-6c9d8f7b4-abcde   1/1     Running   0          40s   192.168.109.66    k8s-single
pod/web-6c9d8f7b4-fghij   1/1     Running   0          40s   192.168.109.67    k8s-single

NAME                   TYPE        CLUSTER-IP     PORT(S)        AGE
service/web            ClusterIP   10.96.171.22   80/TCP         40s
service/web-nodeport   NodePort    10.96.203.11   80:30080/TCP   40s

NAME                  READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/web   2/2     2            2           40s
```

**Both replicas run on the same instance — expected.** `replicas: 2` means two Pods, not two machines. You get real ReplicaSet behaviour (rolling updates, self-healing, load-balanced endpoints) but no node-failure tolerance, because there is one node.

---

## 10. Access the application

### Method 1 — `kubectl port-forward` on the instance (safest)

Nothing is exposed publicly; no security-group rule needed.

```bash
# EC2 (ubuntu user)
curl -s http://localhost:30080 | head -5
```

Or through the Service:

```bash
# EC2 (ubuntu user) — leave running
kubectl -n demo port-forward svc/web 8080:80
```

```bash
# EC2 (second session)
curl -s http://localhost:8080 | head -5
```

### Method 2 — SSH local port forwarding (recommended for reaching it from your laptop)

Needs only port 22 open to your IP — no NodePort rule at all.

```bash
# Local terminal — leave running
ssh -i ~/.ssh/<KEY_PAIR_NAME>.pem -N -L 8080:localhost:30080 ubuntu@<PUBLIC_IP>
```

`-L 8080:localhost:30080` = listen on your laptop's `:8080`, tunnel over SSH, deliver to `localhost:30080` on the instance.

```bash
# Local terminal (second window)
curl -s http://localhost:8080 | head -5
open http://localhost:8080          # macOS
xdg-open http://localhost:8080      # Linux
```

Stop with `Ctrl+C`.

### Method 3 — Session Manager port forwarding (no SSH port at all)

```bash
# Local terminal
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["30080"],"localPortNumber":["8080"]}'
```

Then browse to <http://localhost:8080>. Zero inbound security-group rules required.

### Method 4 — NodePort over the public IP (requires an open port)

Only if you added the port-30080 rule from §2.3 scoped to your IP.

```bash
# Local terminal
curl -s "http://<PUBLIC_IP>:30080" | head -5
```

> [!CAUTION]
> 🔴 Remove this security-group rule when you are done. A NodePort open to the internet is an unauthenticated public web server on your AWS account.

### Method 5 — `kubectl` from your laptop

Requires the port-6443 rule and `--apiserver-cert-extra-sans=<PUBLIC_IP>` at init time (§8.2).

```bash
# Local terminal
scp -i ~/.ssh/<KEY_PAIR_NAME>.pem ubuntu@<PUBLIC_IP>:~/.kube/config ~/.kube/config-ec2
sed -i.bak "s|server: https://.*:6443|server: https://<PUBLIC_IP>:6443|" ~/.kube/config-ec2
export KUBECONFIG=~/.kube/config-ec2
kubectl get nodes
```

If you did not add the SAN, you get `x509: certificate is valid for 172.31.x.x, 10.96.0.1, not <PUBLIC_IP>`. Fix by regenerating the certificate:

```bash
# EC2 (ubuntu user)
sudo rm -f /etc/kubernetes/pki/apiserver.crt /etc/kubernetes/pki/apiserver.key
sudo kubeadm init phase certs apiserver --apiserver-cert-extra-sans="<PUBLIC_IP>"
sudo systemctl restart kubelet
```

### Why there is no LoadBalancer Service here

> [!IMPORTANT]
> On this plain kubeadm cluster, creating a `type: LoadBalancer` Service leaves it **`<pending>` forever**.
>
> A `LoadBalancer` Service does nothing by itself. It is a request that some **cloud controller manager** watches and fulfils by provisioning real infrastructure. On EKS, the AWS cloud controller (or the AWS Load Balancer Controller) sees the request and creates an NLB/ALB. This cluster has no cloud controller manager installed, so nothing ever answers, and `EXTERNAL-IP` stays `<pending>`.
>
> Try it if you like — `kubectl -n demo expose deployment web --type=LoadBalancer --name=web-lb --port=80` then `kubectl -n demo get svc web-lb` — and delete it afterwards. On a single-node lab, use NodePort or `port-forward` instead. (If you genuinely want LoadBalancer semantics on bare metal, MetalLB is the usual answer, but it is out of scope here.)

### Access method comparison

| Method | Inbound rules needed | Exposure | Use when |
|---|---|---|---|
| `curl` on the instance | None | None | Quick check |
| SSH `-L` forwarding | 22 from your IP | Your laptop only | Default choice |
| SSM port forwarding | **None** | Your laptop only | Most secure |
| NodePort over public IP | 30080 from your IP | Your IP | Demoing in a browser |
| Remote `kubectl` | 6443 from your IP | Your IP | Working from your laptop |

---

## 11. Troubleshooting

| Symptom | Likely cause | Diagnostic | Resolution |
|---|---|---|---|
| `kubeadm init`: `[ERROR NumCPU]: the number of available CPUs 1 is less than the required 2` | Instance too small | `nproc` | Stop the instance, change instance type to ≥2 vCPU, start again. Do **not** use `--ignore-preflight-errors`. |
| `kubeadm init`: `[ERROR Mem]` | <1700 MB RAM | `free -h` | Larger instance type |
| `kubeadm init`: `[ERROR Swap]` | Swap enabled | `swapon --show` | `sudo swapoff -a` and redo §5.4 |
| `kubeadm init`: `[ERROR CRI]: container runtime is not running` | containerd down or CRI plugin disabled | `systemctl status containerd`; `sudo ctr plugin ls \| grep cri` | Redo §6.3–6.4; check `journalctl -u containerd` |
| kubelet crash-loops after init | cgroup driver mismatch | `sudo journalctl -u kubelet -n 50 \| grep -i cgroup` | `SystemdCgroup = true` (§6.3), `sudo systemctl restart containerd kubelet` |
| Node stuck `NotReady` | No CNI installed | `kubectl describe node k8s-single \| grep -i networkready` | Install Calico (§8.4) |
| CoreDNS stuck `Pending` | Same — no CNI, or taint still present | `kubectl -n kube-system describe pod -l k8s-app=kube-dns \| tail -10` | Install CNI; remove taint (§8.5) |
| Calico Pods `CrashLoopBackOff` | Pod CIDR mismatch, or IP autodetection picked the wrong interface | `kubectl -n kube-system logs -l k8s-app=calico-node --tail=50` | Verify `--pod-network-cidr` matches Calico's pool; set `IP_AUTODETECTION_METHOD=interface=ens5` in the DaemonSet |
| Pods stuck `Pending` | Control-plane taint, or insufficient CPU/memory | `kubectl describe pod <n> \| tail -10` | Remove the taint (§8.5); or reduce resource requests / use a bigger instance |
| Pods `Pending` with `Insufficient cpu` | Requests exceed capacity | `kubectl describe node k8s-single \| grep -A8 "Allocated resources"` | Lower `resources.requests`, or resize the instance |
| API server unreachable from the instance | API server static Pod not running | `sudo crictl ps -a \| grep apiserver`; `sudo journalctl -u kubelet -n 100` | Check `/etc/kubernetes/manifests/kube-apiserver.yaml`; check disk space with `df -h` |
| `x509: certificate is valid for ..., not <PUBLIC_IP>` | Public IP not in the cert SANs | `sudo kubeadm certs check-expiration` | Regenerate with `--apiserver-cert-extra-sans` (§10 Method 5) |
| `kubectl` from laptop times out | Security group missing the 6443 rule, or your ISP IP changed | `curl -s https://checkip.amazonaws.com`; check the SG | Update the SG rule to your current `/32` |
| NodePort unreachable from laptop | No SG rule for 30080 | `curl localhost:30080` on the instance first | Add the rule scoped to your IP, or use SSH forwarding |
| `The connection to the server ... was refused` after instance restart | Public IP changed (no Elastic IP), or kubelet still starting | `aws ec2 describe-instances`; `systemctl status kubelet` | Fetch the new public IP; wait 60 s for static Pods |
| `kubectl` says `no configuration has been provided` | `~/.kube/config` missing, or you are the wrong user | `ls -l ~/.kube/config; whoami` | Redo §8.3 as the `ubuntu` user |
| Instance unreachable entirely | SG rule missing, wrong key, or instance stopped | `aws ec2 describe-instances --query '...State.Name'` | Check state, SG, and that your IP has not changed |
| Disk full, Pods evicted | 30 GB filled by images and logs | `df -h /`; `kubectl describe node \| grep -i pressure` | `sudo crictl rmi --prune`; grow the EBS volume |

**Diagnostics:**

```bash
# EC2 (ubuntu user)
sudo journalctl -u kubelet -n 100 --no-pager
sudo journalctl -u containerd -n 100 --no-pager
kubectl get events -A --sort-by=.lastTimestamp | tail -30
sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps -a
df -h /; free -h; nproc
```

**Relevant AWS console pages:** EC2 → Instances (state, type, IPs) · EC2 → Security Groups (inbound rules) · EC2 → Volumes (disk) · Systems Manager → Session Manager (shell access) · CloudWatch → Logs (if enabled).

---

## 12. Cleanup and cost checklist

> [!CAUTION]
> 💰 **Do this. A forgotten instance bills continuously.** An EBS volume bills even while the instance is stopped.

### 12.1 Delete workloads

```bash
# EC2 (ubuntu user)
kubectl delete namespace demo
kubectl get all -A
```

### 12.2 Reset kubeadm

> [!CAUTION]
> 🔴 **DESTRUCTIVE** — destroys the cluster and all etcd data. Skip straight to §12.4 if you are terminating the instance anyway.

```bash
# EC2 (ubuntu user)  🔴 DESTRUCTIVE
sudo kubeadm reset -f --cri-socket=unix:///run/containerd/containerd.sock

sudo rm -rf /etc/cni/net.d /var/lib/cni/
sudo rm -rf /opt/cni/bin/calico*
rm -rf "$HOME/.kube"

# Kubernetes network interfaces
ip link show | grep -E 'cali|tunl|vxlan|cni0'
# for each:  sudo ip link delete <INTERFACE_NAME>

sudo systemctl restart containerd
```

Networking rules do not survive a reboot, so `sudo reboot` is the safest flush. To do it manually (review first — this also drops any other firewall rules on the box):

```bash
# EC2 (ubuntu user)  🔴 DESTRUCTIVE — review first
sudo iptables-save | grep -E 'KUBE-|CALI-' | head
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X
```

### 12.3 Remove Kubernetes packages (optional)

```bash
# EC2 (ubuntu user)  🔴 DESTRUCTIVE
sudo apt-mark unhold kubelet kubeadm kubectl
sudo apt-get purge -y kubelet kubeadm kubectl kubernetes-cni containerd.io
sudo apt-get autoremove -y
sudo rm -rf /var/lib/kubelet /etc/kubernetes /var/lib/etcd /var/lib/containerd /etc/containerd
sudo rm -f /etc/apt/sources.list.d/kubernetes.list /etc/apt/sources.list.d/docker.list
```

Pointless if you are terminating the instance — go to §12.4.

### 12.4 Stop or terminate the instance

**Stop** — keeps the disk and everything on it. You still pay for the EBS volume (a few dollars a month for 40 GB gp3), and the public IP changes on next start.

```bash
# Local terminal
aws ec2 stop-instances --instance-ids "$INSTANCE_ID"
aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].State.Name' --output text
```

**Terminate** — 🔴 **DESTRUCTIVE**, deletes the instance and (with `DeleteOnTermination=true`) its root volume. Compute and storage charges stop.

```bash
# Local terminal  🔴 DESTRUCTIVE — irreversible
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID"
aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID"
echo "Terminated."
```

Console: **EC2 → Instances → select → Instance state → Terminate (delete) instance**

### 12.5 Delete unused EBS volumes

Volumes created without `DeleteOnTermination` survive termination and keep billing.

```bash
# Local terminal
aws ec2 describe-volumes --filters Name=status,Values=available \
  --query 'Volumes[].{ID:VolumeId,Size:Size,Type:VolumeType,Created:CreateTime}' --output table
```

Any volume in `available` state is unattached and billing for nothing:

```bash
# Local terminal  🔴 DESTRUCTIVE
aws ec2 delete-volume --volume-id <VOLUME_ID>
```

Console: **EC2 → Elastic Block Store → Volumes**, filter `State = available`.

### 12.6 Release unused Elastic IPs

An Elastic IP not attached to a running instance is billed hourly.

```bash
# Local terminal
aws ec2 describe-addresses \
  --query 'Addresses[].{IP:PublicIp,AllocationId:AllocationId,Instance:InstanceId}' --output table
```

```bash
# Local terminal  🔴 DESTRUCTIVE
aws ec2 release-address --allocation-id <ALLOCATION_ID>
```

Console: **EC2 → Network & Security → Elastic IPs**

### 12.7 Delete the security group

Security groups are free, but leaving one with an open port is untidy and risky. Delete it once no instance uses it.

```bash
# Local terminal
aws ec2 delete-security-group --group-id "$SG_ID"
```

If it fails with `DependencyViolation`, something still references it — wait for termination to finish and retry.

### 12.8 Snapshots

If you took an AMI or snapshot of the instance, it bills for storage:

```bash
# Local terminal
aws ec2 describe-snapshots --owner-ids self \
  --query 'Snapshots[].{ID:SnapshotId,Size:VolumeSize,Started:StartTime,Desc:Description}' --output table
aws ec2 delete-snapshot --snapshot-id <SNAPSHOT_ID>     # 🔴 DESTRUCTIVE
```

### 12.9 Final cost-cleanup checklist

Run through this every time:

- [ ] **EC2 instance** terminated (or deliberately stopped) — EC2 → Instances, filter `Instance state = running`
- [ ] **EBS volumes** — no volumes in `available` state — EC2 → Volumes
- [ ] **Elastic IPs** — none unassociated — EC2 → Elastic IPs
- [ ] **Snapshots / AMIs** — none you no longer want — EC2 → Snapshots, EC2 → AMIs
- [ ] **Security group** deleted if unused — EC2 → Security Groups
- [ ] **Key pair** deleted if it was created only for this lab — EC2 → Key Pairs
- [ ] **IAM role / instance profile** removed if created only for Session Manager — IAM → Roles
- [ ] **Local SSH port-forward sessions** closed
- [ ] **Local kubeconfig** (`~/.kube/config-ec2`) deleted — it holds cluster-admin credentials
- [ ] **CloudWatch log groups** deleted if you enabled any — CloudWatch → Log groups
- [ ] **Billing checked** — Billing and Cost Management → **Cost Explorer**, grouped by Service, next day

**Single sweep for leftovers:**

```bash
# Local terminal
echo "=== Running instances ==="
aws ec2 describe-instances --filters Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].{ID:InstanceId,Type:InstanceType,Name:Tags[?Key==`Name`]|[0].Value}' --output table

echo "=== Unattached volumes ==="
aws ec2 describe-volumes --filters Name=status,Values=available \
  --query 'Volumes[].{ID:VolumeId,Size:Size}' --output table

echo "=== Unassociated Elastic IPs ==="
aws ec2 describe-addresses --query 'Addresses[?AssociationId==null].{IP:PublicIp,Alloc:AllocationId}' --output table
```

All three tables should be empty (or contain only resources you intend to keep).

> [!NOTE]
> Billing data lags by up to 24 hours. Check Cost Explorer the next day to confirm charges stopped.

---

## Official documentation

- Installing kubeadm — <https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/>
- Creating a cluster with kubeadm — <https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/>
- Container runtimes — <https://kubernetes.io/docs/setup/production-environment/container-runtimes/>
- Ports and protocols — <https://kubernetes.io/docs/reference/networking/ports-and-protocols/>
- Calico quickstart — <https://docs.tigera.io/calico/latest/getting-started/kubernetes/quickstart>
- EC2 security groups — <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-security-groups.html>
- Session Manager — <https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html>
- Session Manager port forwarding — <https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-sessions-port-forwarding.html>
- EC2 on-demand pricing — <https://aws.amazon.com/ec2/pricing/on-demand/>
