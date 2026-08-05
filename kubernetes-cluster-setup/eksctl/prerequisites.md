# EKS — Prerequisites

Everything you need **before** running `eksctl create cluster`: the AWS account setup, the tools, authentication, and a pre-flight checklist.

Do not skip §6. Ten minutes of validation saves a twenty-minute failed cluster creation.

Validated **2026-08-05** with eksctl **v0.229.0**, AWS CLI **v2**, kubectl **1.36**.

---

## Contents

1. [AWS account setup](#1-aws-account-setup)
2. [Region and Availability Zones](#2-region-and-availability-zones)
3. [IAM permissions](#3-iam-permissions)
4. [Install the tools](#4-install-the-tools)
5. [Configure AWS authentication](#5-configure-aws-authentication)
6. [Pre-flight validation](#6-pre-flight-validation)

---

## 1. AWS account setup

### 1.1 An AWS account

You need one with billing enabled. EKS is **not** in the AWS Free Tier — the control plane bills from the moment the cluster exists.

### 1.2 Do not use the root account

> [!CAUTION]
> 🔴 **Never do day-to-day work as the AWS account root user.** Root has unrestricted, unrestrictable access to everything including billing and account closure. If those credentials leak, you lose the account.

Use one of these instead, in order of preference:

| Option | Best for | How |
|---|---|---|
| **IAM Identity Center** ⭐ | Anyone, especially organisations | Short-lived credentials, browser login, easy MFA. AWS's current recommendation. |
| **IAM role assumed from a user** | Individuals wanting temporary credentials | `aws sts assume-role`, or a named profile with `role_arn` |
| **IAM user with access keys** | Simplest for a solo lab | Long-lived keys — rotate them and delete when the lab ends |

### 1.3 Enable MFA

On the root user (always) and on any IAM user you log in with.

**Console:** IAM → Users → *your user* → **Security credentials** → **Assign MFA device**

For root: click your account name (top right) → **Security credentials** → **Assign MFA device**.

### 1.4 Set a billing alert before you create anything

> [!WARNING]
> 💰 Do this **now**, not after the surprise. An EKS cluster left running over a weekend costs real money.

**Console:** **Billing and Cost Management → Budgets → Create budget**

- Budget type: **Cost budget**
- Period: **Monthly**
- Amount: something you would notice — e.g. $20
- Alert threshold: **80%** of budgeted amount
- Email: your address

**CLI:**

```bash
# Local terminal
cat > /tmp/budget.json <<'EOF'
{
  "BudgetName": "eks-lab-budget",
  "BudgetLimit": {"Amount": "20", "Unit": "USD"},
  "TimeUnit": "MONTHLY",
  "BudgetType": "COST"
}
EOF

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws budgets create-budget --account-id "$ACCOUNT_ID" --budget file:///tmp/budget.json
```

Also enable **Cost Explorer** (Billing → Cost Explorer → Enable) — it takes up to 24 hours to populate, so turn it on before the lab, not after.

---

## 2. Region and Availability Zones

### 2.1 Choose a region

Pick one close to you. Prices differ between regions; `us-east-1` is usually cheapest but also the busiest (more capacity errors).

```bash
# Local terminal
export AWS_REGION=<AWS_REGION>          # e.g. us-east-1
echo "$AWS_REGION"
aws ec2 describe-regions --query 'Regions[].RegionName' --output text | tr '\t' '\n' | sort
```

### 2.2 Availability Zones

EKS requires subnets in **at least two** Availability Zones — that is a hard requirement of the control plane, not something you can opt out of. `eksctl` handles this automatically when it creates the VPC.

```bash
# Local terminal
aws ec2 describe-availability-zones --region "$AWS_REGION" \
  --query 'AvailabilityZones[?State==`available`].[ZoneName,ZoneId]' --output table
```

**Expected output:** at least two rows.

> [!NOTE]
> Some AZs do not support EKS or specific instance types — usually older AZs in `us-east-1`. §6 checks this for you. If cluster creation fails with an AZ error, pin the AZs explicitly:
> ```bash
> eksctl create cluster ... --zones=<AWS_REGION>a,<AWS_REGION>b
> ```

### 2.3 Instance type availability

Confirm your chosen instance type actually exists in your AZs:

```bash
# Local terminal
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.medium" \
  --region "$AWS_REGION" \
  --query 'InstanceTypeOfferings[].Location' --output text
```

**Expected output:** two or more AZ names. If only one is listed, pick a different instance type or region.

---

## 3. IAM permissions

### 3.1 What eksctl needs

`eksctl` drives CloudFormation, which creates a lot: a VPC, subnets, route tables, an internet gateway, security groups, IAM roles, the EKS cluster, an EC2 Auto Scaling group, and the managed node group.

Minimum service permissions:

| Service | Why |
|---|---|
| `eks:*` | Create/describe/delete the cluster, node groups, and add-ons |
| `ec2:*` (or a scoped subset) | VPC, subnets, route tables, IGW, security groups, instances, volumes |
| `cloudformation:*` | eksctl builds everything through CloudFormation stacks |
| `iam:CreateRole`, `AttachRolePolicy`, `CreateOpenIDConnectProvider`, `PassRole`, … | Cluster role, node role, IRSA roles, OIDC provider |
| `autoscaling:*` | The managed node group's Auto Scaling group |
| `ssm:GetParameter` | Resolve the EKS-optimized AMI ID |

For a **personal learning account**, `AdministratorAccess` is the pragmatic choice and avoids a frustrating hunt for the one missing permission.

For a **shared or corporate account**, ask your administrator for the minimum policy set documented at
<https://eksctl.io/usage/minimum-iam-policies/> — that page is authoritative and kept current.

### 3.2 Check what you have

```bash
# Local terminal
aws sts get-caller-identity

# For an IAM user
aws iam list-attached-user-policies --user-name <YOUR_IAM_USER>

# For an assumed role
aws iam list-attached-role-policies --role-name <YOUR_ROLE_NAME>
```

### 3.3 Service quotas that matter

Default quotas are usually generous enough for a one-to-two-node cluster, but check if you already have infrastructure in the account:

| Quota | Default | Needed here |
|---|---|---|
| VPCs per region | 5 | 1 (eksctl creates one) |
| Elastic IPs per region | 5 | 0 (with no NAT Gateway) |
| Running On-Demand Standard instances (vCPU) | varies; often 5 | 2–4 vCPU |
| EKS clusters per region | 100 | 1 |
| Internet gateways per region | 5 | 1 |

```bash
# Local terminal
# VPCs per region
aws service-quotas get-service-quota --service-code vpc --quota-code L-F678F1CE --region "$AWS_REGION" \
  --query 'Quota.{Name:QuotaName,Value:Value}' --output table

# Running On-Demand Standard instances, measured in vCPUs
aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A --region "$AWS_REGION" \
  --query 'Quota.{Name:QuotaName,Value:Value}' --output table

# How many VPCs you already have
aws ec2 describe-vpcs --region "$AWS_REGION" --query 'length(Vpcs)'
```

If a quota is too low: **Service Quotas → AWS services → *service* → *quota* → Request quota increase**. Approval can take hours to days — do this before lab day.

---

## 4. Install the tools

You need: **AWS CLI v2**, **kubectl**, **eksctl**. Helm, Git, and jq are useful.

> [!TIP]
> **AWS CloudShell needs none of this.** Open the AWS Console → the `>_` icon in the top bar → you get a browser shell with the AWS CLI and `kubectl` pre-installed and already authenticated as your console identity. Install `eksctl` in it (§4.5) and you are ready. Skip to §5.3.
>
> Caveats: CloudShell sessions time out after ~20 minutes idle, and only `$HOME` (1 GB) persists. Fine for creating and deleting a cluster; less good for a long working session.

### 4.1 AWS CLI v2

**Windows (PowerShell):**

```powershell
# PowerShell
winget install -e --id Amazon.AWSCLI
```

**WSL2 / Linux:**

```bash
# WSL Ubuntu / Linux terminal
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -q awscliv2.zip
sudo ./aws/install --update
rm -rf aws awscliv2.zip
```

For arm64 Linux, use `awscli-exe-linux-aarch64.zip`.

**macOS:**

```bash
# macOS Terminal
brew install awscli
```

Or the official installer:

```bash
# macOS Terminal
curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "AWSCLIV2.pkg"
sudo installer -pkg AWSCLIV2.pkg -target /
rm AWSCLIV2.pkg
```

✅ **Verify:**

```bash
aws --version
```

**Expected output:**

```text
aws-cli/2.31.x Python/3.13.x ...
```

> [!WARNING]
> Must be **version 2**. AWS CLI v1 lacks `aws eks update-kubeconfig` improvements and IAM Identity Center support. If you see `aws-cli/1.x`, uninstall it first.

### 4.2 kubectl

**Windows:**

```powershell
# PowerShell
winget install -e --id Kubernetes.kubectl
```

**WSL2 / Linux:**

```bash
# WSL Ubuntu / Linux terminal
ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/${ARCH}/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm kubectl
```

**macOS:**

```bash
# macOS Terminal
brew install kubectl
```

✅ **Verify:**

```bash
kubectl version --client
```

**Expected output:**

```text
Client Version: v1.36.1
Kustomize Version: v5.x.x
```

> [!NOTE]
> **Version skew:** `kubectl` may be one minor version above or below the cluster. A 1.36 client works with a 1.35, 1.36, or 1.37 cluster. Match your cluster version where you can.

### 4.3 eksctl

**Windows:**

```powershell
# PowerShell
winget install -e --id Weaveworks.eksctl
```

Or Chocolatey:

```powershell
# PowerShell (Administrator)
choco install eksctl -y
```

**WSL2 / Linux:**

```bash
# WSL Ubuntu / Linux terminal
ARCH=amd64        # use arm64 on ARM machines
PLATFORM="$(uname -s)_$ARCH"

curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_${PLATFORM}.tar.gz"
curl -sL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_checksums.txt" \
  | grep "$PLATFORM" | sha256sum --check

tar -xzf "eksctl_${PLATFORM}.tar.gz" -C /tmp && rm "eksctl_${PLATFORM}.tar.gz"
sudo mv /tmp/eksctl /usr/local/bin
```

**macOS:**

```bash
# macOS Terminal
brew tap weaveworks/tap
brew install weaveworks/tap/eksctl
```

✅ **Verify:**

```bash
eksctl version
```

**Expected output:**

```text
0.229.0
```

Check the current release at <https://github.com/eksctl-io/eksctl/releases>.

### 4.4 Helm, Git, jq

Not strictly required for this lab, but you will want them.

**Windows:**

```powershell
# PowerShell
winget install -e --id Helm.Helm
winget install -e --id Git.Git
winget install -e --id jqlang.jq
```

**WSL2 / Linux:**

```bash
# WSL Ubuntu / Linux terminal
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
sudo apt-get install -y git jq
```

**macOS:**

```bash
# macOS Terminal
brew install helm git jq
```

✅ **Verify:**

```bash
helm version --short
git --version
jq --version
```

### 4.5 eksctl in AWS CloudShell

```bash
# AWS CloudShell
ARCH=amd64
PLATFORM="$(uname -s)_$ARCH"
curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_${PLATFORM}.tar.gz"
tar -xzf "eksctl_${PLATFORM}.tar.gz" -C /tmp && rm "eksctl_${PLATFORM}.tar.gz"
sudo mv /tmp/eksctl /usr/local/bin
eksctl version
```

CloudShell already has the AWS CLI and `kubectl`, and is already authenticated.

### 4.6 Which shell runs what

| Command | Windows | WSL2 | Linux | macOS | CloudShell |
|---|---|---|---|---|---|
| `winget install ...` | PowerShell | — | — | — | — |
| `brew install ...` | — | — | — | macOS Terminal | — |
| `curl ... \| sudo install` | — | WSL Ubuntu | Linux terminal | macOS Terminal | CloudShell |
| `aws`, `kubectl`, `eksctl` | PowerShell | WSL Ubuntu | Linux terminal | macOS Terminal | CloudShell |

Pick **one** environment and stay in it. Credentials configured in PowerShell are not visible inside WSL, and vice versa — a very common source of "it worked a minute ago".

---

## 5. Configure AWS authentication

Pick the method matching how your account is set up.

### 5.1 `aws configure` — IAM user access keys

Simplest for a solo lab. Long-lived credentials, so treat them carefully.

```bash
# Local terminal
aws configure
```

Prompts:

```text
AWS Access Key ID [None]: AKIA...
AWS Secret Access Key [None]: ...
Default region name [None]: <AWS_REGION>
Default output format [None]: json
```

Get keys from **IAM → Users → *your user* → Security credentials → Create access key**.

> [!CAUTION]
> 🔴 Access keys are long-lived. Never commit them to git, paste them in chat, or put them in a container image. Delete them when the lab ends: **IAM → Users → Security credentials → Deactivate → Delete**.

### 5.2 Named profiles — several accounts or roles

```bash
# Local terminal
aws configure --profile eks-lab
```

Then either pass `--profile` on every command, or set it for the session:

```bash
# Linux / macOS / WSL
export AWS_PROFILE=eks-lab
export AWS_REGION=<AWS_REGION>
```

```powershell
# PowerShell
$env:AWS_PROFILE = "eks-lab"
$env:AWS_REGION  = "<AWS_REGION>"
```

**The files involved:**

| File | Contents |
|---|---|
| `~/.aws/credentials` (`%USERPROFILE%\.aws\credentials` on Windows) | Access keys, per profile |
| `~/.aws/config` | Region, output format, SSO settings, role assumption |

Example `~/.aws/config` for assuming a role:

```ini
[profile eks-lab]
region = us-east-1
output = json

[profile eks-admin]
role_arn = arn:aws:iam::<ACCOUNT_ID>:role/EKSAdminRole
source_profile = eks-lab
region = us-east-1
```

> [!IMPORTANT]
> **`eksctl` respects `AWS_PROFILE` and `AWS_REGION`.** The single most common EKS mistake is creating a cluster in the wrong account or region because a profile variable was left over from earlier work. Always run `aws sts get-caller-identity` first.

### 5.3 IAM Identity Center (AWS SSO) — recommended

Short-lived credentials, browser login, MFA built in.

```bash
# Local terminal
aws configure sso
```

Prompts:

```text
SSO session name (Recommended): my-sso
SSO start URL [None]: https://<YOUR_SUBDOMAIN>.awsapps.com/start
SSO region [None]: <AWS_REGION>
SSO registration scopes [sso:account:access]: <press Enter>
```

A browser opens for authentication. Then choose the account and permission set, and name the profile.

**Log in each day:**

```bash
# Local terminal
aws sso login --profile <PROFILE_NAME>
export AWS_PROFILE=<PROFILE_NAME>
```

> [!IMPORTANT]
> **SSO sessions expire** — typically after 1–12 hours depending on configuration. When they do, commands fail with:
>
> ```text
> Error loading SSO Token: Token for <start-url> does not exist
> The SSO session associated with this profile has expired or is otherwise invalid
> ```
>
> Fix: `aws sso login --profile <PROFILE_NAME>`. Nothing is broken; you just need to log in again. This mid-cluster-creation surprise catches everyone once.

### 5.4 Temporary credentials via `assume-role`

```bash
# Local terminal
CREDS=$(aws sts assume-role \
  --role-arn arn:aws:iam::<ACCOUNT_ID>:role/<ROLE_NAME> \
  --role-session-name eks-lab-session \
  --duration-seconds 3600)

export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r .Credentials.AccessKeyId)
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r .Credentials.SecretAccessKey)
export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r .Credentials.SessionToken)

aws sts get-caller-identity
```

These expire after `--duration-seconds` (max 1 hour by default, up to 12 if the role allows). Cluster creation takes 15–20 minutes, so a 1-hour session is enough — but do not start with 10 minutes left.

### 5.5 Verify authentication

```bash
# Local terminal
aws sts get-caller-identity
aws configure list
```

**Expected output:**

```text
{
    "UserId": "AIDACKCEVSQ6C2EXAMPLE",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012/user/your-user"
}

      Name                    Value             Type    Location
      ----                    -----             ----    --------
   profile                 eks-lab           manual    --profile
access_key     ****************ABCD shared-credentials-file
secret_key     ****************wXyZ shared-credentials-file
    region                us-east-1      config-file    ~/.aws/config
```

✅ **Check every line:** is the account the one you meant? Is the ARN the identity you meant? Is the region right?

---

## 6. Pre-flight validation

Run this whole block. Every check should pass before you create a cluster.

```bash
# Local terminal
set -u
export AWS_REGION=${AWS_REGION:-<AWS_REGION>}
INSTANCE_TYPE=t3.medium         # the type you plan to use

echo "==================== 1. AWS IDENTITY ===================="
aws sts get-caller-identity --output table

echo "==================== 2. REGION AND PROFILE ===================="
aws configure list
echo "AWS_REGION=$AWS_REGION"
echo "AWS_PROFILE=${AWS_PROFILE:-<not set — using default>}"

echo "==================== 3. TOOL VERSIONS ===================="
aws --version
eksctl version
kubectl version --client 2>/dev/null | head -2
helm version --short 2>/dev/null || echo "helm: not installed (optional)"
jq --version 2>/dev/null || echo "jq: not installed (optional)"

echo "==================== 4. EKS PERMISSIONS ===================="
aws eks list-clusters --region "$AWS_REGION" --output table \
  && echo "OK: can call the EKS API" \
  || echo "FAIL: no EKS permissions, or wrong region"

echo "==================== 5. EC2 QUOTAS ===================="
aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A \
  --region "$AWS_REGION" --query 'Quota.{Quota:QuotaName,Value:Value}' --output table

echo "==================== 6. VPC QUOTAS ===================="
aws service-quotas get-service-quota --service-code vpc --quota-code L-F678F1CE \
  --region "$AWS_REGION" --query 'Quota.{Quota:QuotaName,Value:Value}' --output table
echo -n "VPCs currently in use: "
aws ec2 describe-vpcs --region "$AWS_REGION" --query 'length(Vpcs)'

echo "==================== 7. AVAILABILITY ZONES ===================="
aws ec2 describe-availability-zones --region "$AWS_REGION" \
  --query 'AvailabilityZones[?State==`available`].[ZoneName,ZoneId]' --output table

echo "==================== 8. INSTANCE TYPE AVAILABILITY ===================="
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=${INSTANCE_TYPE}" \
  --region "$AWS_REGION" --query 'InstanceTypeOfferings[].Location' --output table

echo "==================== 9. SUPPORTED EKS VERSIONS ===================="
aws eks describe-cluster-versions --region "$AWS_REGION" \
  --query 'clusterVersions[].{Version:clusterVersion,Status:clusterVersionStatus}' --output table 2>/dev/null \
  || echo "Check https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions-standard.html"

echo "==================== 10. EXISTING RESOURCES ===================="
echo "Existing EKS clusters:"
aws eks list-clusters --region "$AWS_REGION" --query 'clusters' --output text
echo "Existing CloudFormation stacks named eksctl-*:"
aws cloudformation list-stacks --region "$AWS_REGION" \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE ROLLBACK_COMPLETE CREATE_FAILED \
  --query 'StackSummaries[?starts_with(StackName, `eksctl-`)].{Name:StackName,Status:StackStatus}' --output table

echo "==================== 11. YOUR PUBLIC IP ===================="
echo "Your public IP CIDR (for publicAccessCIDRs): $(curl -s https://checkip.amazonaws.com)/32"

echo "==================== 12. BILLING ALERT ===================="
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws budgets describe-budgets --account-id "$ACCOUNT_ID" \
  --query 'Budgets[].{Name:BudgetName,Limit:BudgetLimit.Amount}' --output table 2>/dev/null \
  || echo "No budgets configured — see section 1.4"

echo "==================== PRE-FLIGHT COMPLETE ===================="
```

### Checklist

Tick every line before creating a cluster:

- [ ] **AWS identity** — `get-caller-identity` shows the account and principal you intend, and it is **not** root
- [ ] **AWS region** — set, and the one you meant
- [ ] **AWS profile** — set (or deliberately using the default)
- [ ] **eksctl version** — installed, current
- [ ] **kubectl version** — installed, within one minor of your target cluster version
- [ ] **AWS CLI v2** — `aws --version` starts with `aws-cli/2`
- [ ] **EKS permissions** — `aws eks list-clusters` succeeds
- [ ] **EC2 quotas** — enough vCPU headroom for 1–2 nodes
- [ ] **VPC quota** — at least one VPC slot free
- [ ] **Availability Zones** — at least two available
- [ ] **Instance type availability** — your type exists in at least two AZs
- [ ] **Kubernetes version** — supported by EKS today
- [ ] **Your public IP CIDR** — noted, for `publicAccessCIDRs`
- [ ] **Billing alert** — configured
- [ ] **Cost Explorer** — enabled
- [ ] **A calendar reminder to delete the cluster** — seriously

---

## Common pre-flight failures

| Symptom | Cause | Fix |
|---|---|---|
| `Unable to locate credentials` | No credentials configured, or wrong shell | `aws configure`, or check `AWS_PROFILE` in **this** shell |
| `The security token included in the request is invalid` | Expired temporary credentials | `aws sso login --profile <p>`, or re-run `assume-role` |
| `Token for ... does not exist` | SSO session expired | `aws sso login --profile <p>` |
| `AccessDeniedException` on `eks:ListClusters` | Missing EKS permissions | Attach the eksctl minimum policies, or `AdministratorAccess` in a personal account |
| `You must specify a region` | No region set | `export AWS_REGION=<AWS_REGION>` or `aws configure set region <AWS_REGION>` |
| `aws: command not found` | Not installed, or wrong shell | §4.1; on Windows reopen PowerShell so `PATH` refreshes |
| `eksctl: command not found` | Not on `PATH` | §4.3; `which eksctl` / `Get-Command eksctl` |
| `aws-cli/1.x` reported | AWS CLI v1 installed | Uninstall v1, install v2 |
| Only one AZ listed | Region has limited AZs, or a filter is wrong | Choose a different region |
| VPC quota exhausted | Five VPCs already exist | Delete an unused VPC, or request a quota increase |

---

## Next

→ **[README.md](./README.md)** — architecture, cost warnings, and creating the cluster.

---

## Official documentation

- eksctl installation — <https://eksctl.io/installation/>
- eksctl minimum IAM policies — <https://eksctl.io/usage/minimum-iam-policies/>
- AWS CLI v2 installation — <https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html>
- Configure the AWS CLI — <https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.html>
- IAM Identity Center with the AWS CLI — <https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sso.html>
- Install kubectl for EKS — <https://docs.aws.amazon.com/eks/latest/userguide/install-kubectl.html>
- EKS service quotas — <https://docs.aws.amazon.com/eks/latest/userguide/service-quotas.html>
- EKS Kubernetes versions — <https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions-standard.html>
- AWS Budgets — <https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html>
