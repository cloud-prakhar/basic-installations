# EKS — Troubleshooting

Every issue has **symptom**, **likely cause**, **diagnostic commands**, **resolution**, and the **relevant AWS console page**.

Jump to: [First response](#first-response) · [Authentication](#a-authentication-and-credentials) · [Cluster creation](#b-cluster-creation) · [Nodes](#c-nodes) · [Pods and networking](#d-pods-and-networking) · [Access and kubeconfig](#e-access-and-kubeconfig) · [Deletion and leftovers](#f-deletion-and-leftovers)

```bash
# Local terminal — set these first
export CLUSTER_NAME=<CLUSTER_NAME>
export AWS_REGION=<AWS_REGION>
export NODE_GROUP_NAME=<NODE_GROUP_NAME>
```

---

## First response

```bash
# 1. Who am I, and where?
aws sts get-caller-identity
aws configure list
echo "AWS_PROFILE=${AWS_PROFILE:-<default>}  AWS_REGION=${AWS_REGION}"

# 2. Does the cluster exist and is it healthy?
aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
  --query 'cluster.{Status:status,Version:version,Health:health}' --output json

# 3. Node group health — this field is genuinely useful
aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" \
  --nodegroup-name "${NODE_GROUP_NAME}" --region "${AWS_REGION}" \
  --query 'nodegroup.{Status:status,Health:health,Scaling:scalingConfig}' --output json

# 4. Am I pointed at the right cluster?
kubectl config current-context

# 5. Kubernetes side
kubectl get nodes -o wide
kubectl get pods -A
kubectl get events -A --sort-by=.lastTimestamp | tail -30

# 6. CloudFormation — where eksctl failures actually surface
aws cloudformation list-stacks --region "${AWS_REGION}" \
  --stack-status-filter CREATE_COMPLETE CREATE_FAILED ROLLBACK_COMPLETE DELETE_FAILED UPDATE_ROLLBACK_COMPLETE \
  --query "StackSummaries[?starts_with(StackName,'eksctl-${CLUSTER_NAME}')].{Name:StackName,Status:StackStatus}" --output table
```

> [!TIP]
> **`eksctl` errors are usually CloudFormation errors wearing a disguise.** When cluster creation fails, the real message is in the stack events, not in eksctl's output. Always look there — §B1 shows how.

---

## A. Authentication and credentials

### A1. AWS CLI not authenticated

**Symptom**

```text
Unable to locate credentials. You can configure credentials by running "aws configure".
```

**Likely cause** — no credentials configured, or configured in a different shell/profile than the one you are using.

**Diagnostics**

```bash
aws sts get-caller-identity
aws configure list
ls -la ~/.aws/          # %USERPROFILE%\.aws on Windows
env | grep -i AWS
```

**Resolution**

```bash
aws configure                                  # IAM user keys
# or
aws sso login --profile <PROFILE_NAME>         # IAM Identity Center
export AWS_PROFILE=<PROFILE_NAME>
```

> [!IMPORTANT]
> Credentials are **per shell**. Configuring them in PowerShell does not make them visible inside WSL, and an `export AWS_PROFILE` in one terminal does not apply in another.

**Console:** IAM → Users → Security credentials

---

### A2. Wrong profile or wrong account

**Symptom** — `AccessDeniedException`, or resources appear in an account you did not expect, or `list-clusters` returns nothing when a cluster clearly exists.

**Diagnostics**

```bash
aws sts get-caller-identity --output table
echo "AWS_PROFILE=${AWS_PROFILE:-<not set>}"
echo "AWS_REGION=${AWS_REGION:-<not set>}"
cat ~/.aws/config
```

**Resolution**

```bash
export AWS_PROFILE=<CORRECT_PROFILE>
export AWS_REGION=<CORRECT_REGION>
aws sts get-caller-identity
```

> [!CAUTION]
> 💰 Creating a cluster in the wrong account or region is expensive **and** easy to forget about — you go looking in the right region, find nothing, and the cluster in the wrong one keeps billing. Always run `aws sts get-caller-identity` before `eksctl create`.

**Console:** the account ID is shown top-right in the AWS Console.

---

### A3. Expired SSO session

**Symptom**

```text
Error loading SSO Token: Token for https://xxx.awsapps.com/start does not exist
The SSO session associated with this profile has expired or is otherwise invalid
```

**Likely cause** — SSO sessions expire (typically 1–12 hours). Nothing is broken.

**Diagnostics**

```bash
aws sts get-caller-identity
cat ~/.aws/sso/cache/*.json 2>/dev/null | jq -r '.expiresAt' 2>/dev/null
```

**Resolution**

```bash
aws sso login --profile <PROFILE_NAME>
aws sts get-caller-identity
```

> [!TIP]
> Cluster creation takes 15–20 minutes. Log in freshly before starting rather than 10 minutes before your session expires.

---

### A4. Access denied

**Symptom**

```text
AccessDeniedException: User: arn:aws:iam::123456789012:user/you is not authorized to perform: eks:CreateCluster
```

**Diagnostics**

```bash
aws sts get-caller-identity
aws iam list-attached-user-policies --user-name <YOUR_IAM_USER> 2>/dev/null
aws iam list-attached-role-policies --role-name <YOUR_ROLE> 2>/dev/null

# Simulate a specific action
aws iam simulate-principal-policy \
  --policy-source-arn "$(aws sts get-caller-identity --query Arn --output text)" \
  --action-names eks:CreateCluster ec2:CreateVpc cloudformation:CreateStack \
  --query 'EvaluationResults[].{Action:EvalActionName,Decision:EvalDecision}' --output table
```

**Resolution** — attach the missing permissions. eksctl needs a broad set (EKS, EC2, CloudFormation, IAM, Auto Scaling). In a personal learning account, `AdministratorAccess` is pragmatic. In a shared account, ask your administrator for the documented minimum: <https://eksctl.io/usage/minimum-iam-policies/>

**Console:** IAM → Users/Roles → Permissions

---

### A5. `eksctl: command not found`

**Diagnostics**

```bash
which eksctl || echo "not on PATH"
echo "$PATH"
```

```powershell
# PowerShell
Get-Command eksctl
$env:PATH -split ';'
```

**Resolution** — reinstall per [prerequisites.md §4.3](./prerequisites.md#43-eksctl). On Windows, reopen PowerShell so `PATH` refreshes. On Linux/macOS confirm the binary is in `/usr/local/bin` and executable.

---

## B. Cluster creation

### B1. CloudFormation failure

**Symptom**

```text
Error: failed to create cluster "eks-lab"
ResourceNotReady: failed waiting for successful resource state
Stack eksctl-eks-lab-cluster is in ROLLBACK_COMPLETE state and can not be updated
```

**Likely cause** — could be almost anything; the real reason is in the stack events.

**Diagnostics — this is the important one:**

```bash
aws cloudformation describe-stack-events \
  --stack-name "eksctl-${CLUSTER_NAME}-cluster" --region "${AWS_REGION}" \
  --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`].{Resource:LogicalResourceId,Type:ResourceType,Reason:ResourceStatusReason}' \
  --output table
```

**Resolution**

| Reason in the events | Fix |
|---|---|
| `You have requested more vCPU capacity than your current vCPU limit` | Request an EC2 quota increase (Service Quotas → EC2 → *Running On-Demand Standard instances*) |
| `The maximum number of VPCs has been reached` | Delete an unused VPC, or request a quota increase |
| `is not authorized to perform: iam:CreateRole` | Missing IAM permissions — see [A4](#a4-access-denied) |
| `Cannot create cluster ... unsupported Kubernetes version` | See [B2](#b2-unsupported-kubernetes-version) |
| `Value ... is not valid for AvailabilityZone` | See [B3](#b3-unsupported-availability-zone) |
| `InsufficientInstanceCapacity` | See [B4](#b4-ec2-capacity-issue) |

Then clean up the failed stack before retrying:

```bash
# Local terminal  🔴 DESTRUCTIVE
eksctl delete cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" --wait
# if that fails:
aws cloudformation delete-stack --stack-name "eksctl-${CLUSTER_NAME}-cluster" --region "${AWS_REGION}"
```

> [!WARNING]
> 💰 A `ROLLBACK_COMPLETE` stack may still hold billable resources (a VPC with an internet gateway, partially created instances). Delete it — do not just retry with a new cluster name.

**Console:** CloudFormation → Stacks → *stack* → **Events**

---

### B2. Unsupported Kubernetes version

**Symptom**

```text
InvalidParameterException: unsupported Kubernetes version
Error: unsupported Kubernetes version, supported values are: 1.33, 1.34, 1.35, 1.36
```

**Diagnostics**

```bash
aws eks describe-cluster-versions --region "${AWS_REGION}" \
  --query 'clusterVersions[].{Version:clusterVersion,Status:clusterVersionStatus}' --output table 2>/dev/null \
  || echo "See https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions-standard.html"
```

**Resolution** — use a supported minor version. In the config file it must be quoted and minor-only:

```yaml
metadata:
  version: "1.36"        # not "1.36.1", not 1.36 unquoted
```

> [!NOTE]
> EKS lags upstream Kubernetes by a few months. The newest upstream release is usually **not** yet available on EKS.

**Console:** EKS → Clusters → Create cluster (the version dropdown lists what is available)

---

### B3. Unsupported Availability Zone

**Symptom**

```text
UnsupportedAvailabilityZoneException: Cannot create cluster because us-east-1e does not currently have sufficient capacity
Value (us-east-1e) for parameter availabilityZone is invalid
```

**Likely cause** — some AZs (notably older ones in `us-east-1`) do not support EKS.

**Diagnostics**

```bash
aws ec2 describe-availability-zones --region "${AWS_REGION}" \
  --query 'AvailabilityZones[?State==`available`].[ZoneName,ZoneId]' --output table
```

**Resolution** — pin two known-good AZs:

```bash
eksctl create cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
  --zones "${AWS_REGION}a,${AWS_REGION}b" \
  ...
```

Or in the config file:

```yaml
availabilityZones:
  - <AWS_REGION>a
  - <AWS_REGION>b
```

**Console:** EC2 → Availability Zones (per-region info panel)

---

### B4. EC2 capacity issue

**Symptom**

```text
InsufficientInstanceCapacity: We currently do not have sufficient t3.medium capacity in the Availability Zone you requested
```

**Likely cause** — AWS genuinely has no capacity for that instance type in that AZ right now. Temporary, but not something you can force.

**Diagnostics**

```bash
aws ec2 describe-instance-type-offerings --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.medium" --region "${AWS_REGION}" \
  --query 'InstanceTypeOfferings[].Location' --output table
```

**Resolution**

1. **List several instance types** so EKS can pick whichever has capacity:

```yaml
managedNodeGroups:
  - name: <NODE_GROUP_NAME>
    instanceTypes:
      - t3.medium
      - t3a.medium
      - t2.medium
```

2. Try a different AZ, or a different region.
3. Wait — capacity usually returns within the hour.

**Console:** EC2 → Auto Scaling groups → *your ASG* → **Activity** (the real error appears here)

---

### B5. Node group creation failure

**Symptom** — the cluster is `ACTIVE` but the node group is `CREATE_FAILED`.

**Diagnostics**

```bash
aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" \
  --nodegroup-name "${NODE_GROUP_NAME}" --region "${AWS_REGION}" \
  --query 'nodegroup.health' --output json

ASG=$(aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" \
  --nodegroup-name "${NODE_GROUP_NAME}" --region "${AWS_REGION}" \
  --query 'nodegroup.resources.autoScalingGroups[0].name' --output text)
aws autoscaling describe-scaling-activities --auto-scaling-group-name "$ASG" \
  --region "${AWS_REGION}" --max-items 5 \
  --query 'Activities[].{Status:StatusCode,Cause:Cause}' --output table
```

The `health.issues` array names the problem directly.

| Health issue code | Meaning | Fix |
|---|---|---|
| `NodeCreationFailure` | Instances launched but never joined | See [C1](#c1-worker-node-does-not-join) |
| `InsufficientFreeAddresses` | Subnet ran out of IPs | Use a subnet with a larger CIDR |
| `AccessDenied` | Node role missing policies | Confirm the three required managed policies are attached |
| `InstanceLimitExceeded` | Hit an EC2 quota | Request an increase |
| `AsgInstanceLaunchFailures` | Read the ASG activity for the real cause | See [B4](#b4-ec2-capacity-issue) |

**Resolution** — delete and recreate the node group:

```bash
# Local terminal  🔴 DESTRUCTIVE
eksctl delete nodegroup --cluster "${CLUSTER_NAME}" --name "${NODE_GROUP_NAME}" --region "${AWS_REGION}" --wait
eksctl create nodegroup -f my-cluster.yaml
```

**Console:** EKS → Clusters → *cluster* → **Compute** → *node group* → Health issues

---

## C. Nodes

### C1. Worker node does not join

**Symptom** — EC2 instances are running, but `kubectl get nodes` shows nothing, and the node group reports `NodeCreationFailure`.

**Likely cause** — the node cannot reach the EKS API endpoint, cannot pull images, or is not authorised.

**Diagnostics**

```bash
kubectl get nodes
aws ec2 describe-instances --region "${AWS_REGION}" \
  --filters "Name=tag:eks:cluster-name,Values=${CLUSTER_NAME}" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name,PublicIP:PublicIpAddress,Subnet:SubnetId}' --output table

# Node role policies
NODE_ROLE=$(aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" \
  --nodegroup-name "${NODE_GROUP_NAME}" --region "${AWS_REGION}" --query 'nodegroup.nodeRole' --output text)
aws iam list-attached-role-policies --role-name "$(basename "$NODE_ROLE")" --output table
```

**Resolution by cause:**

| Cause | Check | Fix |
|---|---|---|
| **No internet access** | Instance has no public IP, and no NAT Gateway exists | With `nat.gateway: Disable` you **must** have `privateNetworking: false`. This combination is the most common cause. |
| Missing node role policies | `list-attached-role-policies` lacks `AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryReadOnly`, or `AmazonEKS_CNI_Policy` | Attach them |
| Security group blocks node↔control-plane | Cluster SG rules | Let eksctl manage the security groups |
| Subnet route table has no internet route | VPC → Route tables | Public subnets need a `0.0.0.0/0` route to the internet gateway |
| Not authorised (legacy path) | `kubectl -n kube-system get cm aws-auth -o yaml` | The node role must be mapped. Managed node groups do this automatically. |

**Get onto the node** to read the bootstrap log (SSM is enabled in this guide's config):

```bash
INSTANCE_ID=$(aws ec2 describe-instances --region "${AWS_REGION}" \
  --filters "Name=tag:eks:cluster-name,Values=${CLUSTER_NAME}" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
aws ssm start-session --target "$INSTANCE_ID"
```

Then on the node:

```bash
sudo journalctl -u kubelet -n 100 --no-pager
sudo cat /var/log/cloud-init-output.log | tail -50
```

**Console:** EKS → Compute → node group → Health issues · EC2 → Instances · VPC → Route tables

---

### C2. Node remains `NotReady`

**Symptom**

```text
NAME                            STATUS     ROLES    AGE   VERSION
ip-192-168-12-34.ec2.internal   NotReady   <none>   5m    v1.36.x-eks-xxxxxxx
```

**Likely cause** — the VPC CNI Pod is not running, or the node is under resource pressure.

**Diagnostics**

```bash
kubectl describe node <NODE_NAME> | sed -n '/Conditions/,/Addresses/p'
kubectl -n kube-system get pods -o wide | grep -E 'aws-node|kube-proxy'
kubectl -n kube-system logs -l k8s-app=aws-node --tail=50
```

**Resolution**

| Node condition reason | Fix |
|---|---|
| `NetworkPluginNotReady` / `cni plugin not initialized` | The `aws-node` Pod is failing → see [D1](#d1-vpc-cni-ip-problem) |
| `KubeletNotReady` + runtime errors | SSM onto the node, check `journalctl -u kubelet` |
| `MemoryPressure` / `DiskPressure` | Node too small, or disk full — use a larger instance or volume |
| `NodeStatusUnknown` | The node stopped reporting — check the instance state in EC2 |

Restarting the CNI often clears it:

```bash
kubectl -n kube-system rollout restart daemonset aws-node
kubectl -n kube-system rollout status daemonset aws-node
```

**Console:** EKS → Compute · CloudWatch → Metrics → EC2 (CPU, memory if the agent is installed)

---

## D. Pods and networking

### D1. VPC CNI IP problem

**Symptom**

```text
Warning  FailedCreatePodSandBox  ... failed to assign an IP address to container
0/1 nodes are available: 1 Too many pods
```

**Likely cause** — this is the defining EKS constraint. The VPC CNI gives every Pod a **real VPC IP address**, taken from ENIs attached to the node. Each instance type supports a fixed number of ENIs and IPs per ENI, so **the instance type caps how many Pods a node can run** — often well below what its CPU and memory could handle. A `t3.medium` supports roughly 17 Pods, and the system DaemonSets already use several.

**Diagnostics**

```bash
# What the node believes its Pod capacity is
kubectl get nodes -o custom-columns='NAME:.metadata.name,PODS:.status.allocatable.pods'

kubectl get pods -A --field-selector spec.nodeName=<NODE_NAME> --no-headers | wc -l

kubectl -n kube-system logs -l k8s-app=aws-node --tail=50 | grep -i "ip\|eni"

# Free IPs in the subnet
aws ec2 describe-subnets --region "${AWS_REGION}" \
  --filters "Name=tag:alpha.eksctl.io/cluster-name,Values=${CLUSTER_NAME}" \
  --query 'Subnets[].{ID:SubnetId,CIDR:CidrBlock,Free:AvailableIpAddressCount,AZ:AvailabilityZone}' --output table
```

**Resolution**

| Cause | Fix |
|---|---|
| Node at its Pod limit | Use a larger instance type (more ENIs), or scale to 2 nodes ([scaling.md](./scaling.md)) |
| Subnet out of IPs | Larger subnet CIDR — requires recreating the VPC |
| Want more Pods per node | Enable **prefix delegation**: `kubectl -n kube-system set env daemonset aws-node ENABLE_PREFIX_DELEGATION=true`, then replace the nodes. This assigns `/28` prefixes instead of individual IPs, greatly raising the limit. |
| `aws-node` failing | Check its logs; confirm the node role has `AmazonEKS_CNI_Policy` |

**Console:** VPC → Subnets (available IPs) · EKS → Compute

---

### D2. Pods remain `Pending`

**Diagnostics**

```bash
kubectl -n demo describe pod <POD_NAME> | sed -n '/Events/,$p'
kubectl describe node <NODE_NAME> | grep -A8 "Allocated resources"
kubectl get nodes
```

| Event message | Cause | Fix |
|---|---|---|
| `0/1 nodes are available: 1 Insufficient cpu` | Requests exceed capacity | Lower `resources.requests`, or scale to 2 nodes |
| `0/1 nodes are available: 1 Too many pods` | ENI/IP limit | [D1](#d1-vpc-cni-ip-problem) |
| `pod has unbound immediate PersistentVolumeClaims` | No EBS CSI driver, or no default StorageClass | Install the `aws-ebs-csi-driver` add-on — see [README §8.1](./README.md#81-the-core-four) |
| `no nodes available to schedule pods` | The node group has zero nodes | `eksctl scale nodegroup ... --nodes 1` |
| `node(s) had untolerated taint` | Something added a taint | `kubectl describe node <n> \| grep -i taints` — EKS nodes are untainted by default |

> [!NOTE]
> Unlike a kubeadm cluster, **EKS worker nodes carry no control-plane taint**. If you see one, something in your configuration added it.

---

### D3. CoreDNS problem

**Symptom** — CoreDNS Pods `Pending` or `CrashLoopBackOff`; Pods cannot resolve Service names.

**Diagnostics**

```bash
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=50
kubectl -n kube-system describe deployment coredns | tail -20

kubectl run dnstest --image=busybox:1.37 --rm -it --restart=Never -- \
  nslookup kubernetes.default.svc.cluster.local
```

**Resolution**

| Cause | Fix |
|---|---|
| Both replicas `Pending` on a one-node cluster | CoreDNS defaults to 2 replicas with anti-affinity. On one node they usually still schedule (the rule is a preference), but under resource pressure they will not. Free resources, or scale to 2 nodes. |
| `CrashLoopBackOff` | Check logs — often a corrupt Corefile after a manual edit. Reinstall the add-on: `aws eks update-addon --cluster-name "${CLUSTER_NAME}" --addon-name coredns --resolve-conflicts OVERWRITE --region "${AWS_REGION}"` |
| Resolution fails but Pods are healthy | kube-proxy problem — `kubectl -n kube-system rollout restart daemonset kube-proxy` |

**Console:** EKS → Clusters → *cluster* → **Add-ons** → CoreDNS

---

### D4. LoadBalancer Service stuck `<pending>`

**Symptom**

```text
NAME     TYPE           CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE
web-lb   LoadBalancer   10.100.55.190   <pending>     80:31234/TCP   10m
```

**Diagnostics**

```bash
kubectl -n demo describe svc web-lb | sed -n '/Events/,$p'
kubectl get nodes -o jsonpath='{.items[*].spec.providerID}'; echo

# Subnets must be tagged for ELB discovery
aws ec2 describe-subnets --region "${AWS_REGION}" \
  --filters "Name=tag:alpha.eksctl.io/cluster-name,Values=${CLUSTER_NAME}" \
  --query 'Subnets[].{ID:SubnetId,Tags:Tags[?starts_with(Key,`kubernetes.io/role`)].Key}' --output table
```

| Cause | Fix |
|---|---|
| Subnets missing `kubernetes.io/role/elb` tag | eksctl tags them automatically; if you used your own VPC, add `kubernetes.io/role/elb=1` to public subnets |
| Wrong annotation for the controller present | Match the annotations to whichever controller is installed (in-tree vs AWS Load Balancer Controller) |
| Node role lacks ELB permissions | Add them, or install the AWS Load Balancer Controller with IRSA |
| ELB quota reached | Service Quotas → Elastic Load Balancing |

> [!CAUTION]
> 💰 Once it succeeds, an NLB is billing. **Delete it as soon as you have tested it** — and always before deleting the cluster ([cleanup.md](./cleanup.md)).

**Console:** EC2 → Load Balancers · VPC → Subnets (tags)

---

### D5. EBS volume attachment failure

**Symptom**

```text
Warning  FailedAttachVolume  ... could not attach volume to node
Warning  FailedMount         ... timeout expired waiting for volumes to attach
PVC stuck Pending
```

**Diagnostics**

```bash
aws eks list-addons --cluster-name "${CLUSTER_NAME}" --region "${AWS_REGION}" --output table
kubectl -n kube-system get pods -l app=ebs-csi-controller
kubectl -n kube-system logs -l app=ebs-csi-controller -c ebs-plugin --tail=50
kubectl get storageclass
kubectl -n demo describe pvc <PVC_NAME> | tail -15
```

**Resolution**

| Cause | Fix |
|---|---|
| EBS CSI driver not installed | Install the `aws-ebs-csi-driver` add-on ([README §8.1](./README.md#81-the-core-four)) |
| Driver installed but has no IAM permissions | It needs an IRSA role — `wellKnownPolicies.ebsCSIController: true` in the config, or `eksctl create iamserviceaccount` |
| No default StorageClass | `kubectl get storageclass` — create one, or set `storageClassName` in the PVC |
| Volume in a different AZ from the node | EBS volumes are AZ-bound. Use `volumeBindingMode: WaitForFirstConsumer` in the StorageClass. |

**Console:** EKS → Add-ons · EC2 → Volumes

---

## E. Access and kubeconfig

### E1. Wrong kubeconfig context

**Symptom** — `kubectl` shows unexpected resources, or commands hit a completely different cluster.

**Diagnostics**

```bash
kubectl config current-context
kubectl config get-contexts
kubectl cluster-info
```

**Resolution**

```bash
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}"
kubectl config current-context
```

**Expected output:** the full cluster ARN, e.g. `arn:aws:eks:us-east-1:123456789012:cluster/eks-lab`

> [!CAUTION]
> 🔴 If you also use Kind, Minikube, or Docker Desktop, **check the context before every destructive command.** `kubectl delete namespace demo` against the wrong cluster is easy and unrecoverable.

---

### E2. API endpoint inaccessible

**Symptom**

```text
Unable to connect to the server: dial tcp <ip>:443: i/o timeout
error: You must be logged in to the server (Unauthorized)
```

**Likely cause** — your IP is not in `publicAccessCIDRs`, or the endpoint is private-only, or your IAM principal has no cluster access.

**Diagnostics**

```bash
aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
  --query 'cluster.resourcesVpcConfig.{PublicAccess:endpointPublicAccess,PrivateAccess:endpointPrivateAccess,CIDRs:publicAccessCidrs}' \
  --output json

echo "Your current public IP: $(curl -s https://checkip.amazonaws.com)"
```

**Resolution**

**Timeout** → your IP is not allowed. Very common: ISPs rotate addresses.

```bash
MY_IP="$(curl -s https://checkip.amazonaws.com)/32"
eksctl utils update-cluster-endpoints \
  --cluster "${CLUSTER_NAME}" --region "${AWS_REGION}" \
  --public-access-cidrs "${MY_IP}" --approve
```

Takes a few minutes to apply.

**`Unauthorized`** → you authenticated to AWS, but your principal has no Kubernetes access:

```bash
aws sts get-caller-identity --query Arn --output text
aws eks list-access-entries --cluster-name "${CLUSTER_NAME}" --region "${AWS_REGION}"
```

Recall that `bootstrapClusterCreatorAdminPermissions` binds to the **exact principal ARN that created the cluster**. If you created it with one role and are now using another, you must add an access entry — from a principal that still has access:

```bash
aws eks create-access-entry --cluster-name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
  --principal-arn "<YOUR_CURRENT_ARN>" --type STANDARD

aws eks associate-access-policy --cluster-name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
  --principal-arn "<YOUR_CURRENT_ARN>" \
  --policy-arn "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy" \
  --access-scope type=cluster
```

**Console:** EKS → Clusters → *cluster* → **Networking** (endpoint access) and **Access** (access entries)

---

### E3. Public-access CIDR is incorrect

**Symptom** — `kubectl` worked yesterday, times out today, and nothing changed on your side.

**Cause** — your ISP gave you a new IP.

**Diagnostics**

```bash
echo "Now:        $(curl -s https://checkip.amazonaws.com)"
aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
  --query 'cluster.resourcesVpcConfig.publicAccessCidrs' --output text
```

**Resolution**

```bash
MY_IP="$(curl -s https://checkip.amazonaws.com)/32"
eksctl utils update-cluster-endpoints \
  --cluster "${CLUSTER_NAME}" --region "${AWS_REGION}" \
  --public-access-cidrs "${MY_IP}" --approve
```

> [!TIP]
> If your IP changes constantly (mobile tethering, a large corporate NAT range), either use your organisation's egress CIDR block, or work from AWS CloudShell — which comes from AWS's own address space and needs no CIDR entry at all.

---

### E4. OIDC issue

**Symptom**

```text
no IAM OIDC provider associated with cluster
Error: unable to create iamserviceaccount: no OIDC provider
AccessDenied: Not authorized to perform sts:AssumeRoleWithWebIdentity
```

**Diagnostics**

```bash
aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
  --query 'cluster.identity.oidc.issuer' --output text

OIDC_ID=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
  --query 'cluster.identity.oidc.issuer' --output text | cut -d'/' -f5)
aws iam list-open-id-connect-providers | grep "$OIDC_ID" && echo "OIDC provider exists" || echo "MISSING"
```

**Resolution**

```bash
eksctl utils associate-iam-oidc-provider \
  --cluster "${CLUSTER_NAME}" --region "${AWS_REGION}" --approve
```

`AssumeRoleWithWebIdentity` denied usually means the IAM role's trust policy names the wrong ServiceAccount. Check that the role's trust policy `sub` condition matches `system:serviceaccount:<namespace>:<serviceaccount-name>` exactly. Letting `eksctl create iamserviceaccount` build the role avoids this entirely.

**Console:** IAM → Identity providers · EKS → Clusters → *cluster* → Overview (OIDC issuer URL)

---

## F. Deletion and leftovers

### F1. Cluster deletion stuck

**Symptom**

```text
DELETE_FAILED
The following resource(s) failed to delete: [VPC, SecurityGroup, InternetGateway]
Dependencies exist and cannot be deleted
```

**Likely cause** — something Kubernetes created (a load balancer, an ENI) still references the VPC, and CloudFormation cannot remove it.

**Diagnostics**

```bash
aws cloudformation describe-stack-events \
  --stack-name "eksctl-${CLUSTER_NAME}-cluster" --region "${AWS_REGION}" \
  --query 'StackEvents[?ResourceStatus==`DELETE_FAILED`].{Resource:LogicalResourceId,Reason:ResourceStatusReason}' \
  --output table

VPC_ID=$(aws ec2 describe-vpcs --region "${AWS_REGION}" \
  --filters "Name=tag:alpha.eksctl.io/cluster-name,Values=${CLUSTER_NAME}" \
  --query 'Vpcs[0].VpcId' --output text)
echo "VPC_ID=$VPC_ID"

# What is still holding the VPC?
aws ec2 describe-network-interfaces --region "${AWS_REGION}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Status:Status,Desc:Description}' --output table

aws elbv2 describe-load-balancers --region "${AWS_REGION}" \
  --query "LoadBalancers[?VpcId=='${VPC_ID}'].{Name:LoadBalancerName,ARN:LoadBalancerArn}" --output table
```

**Resolution** — remove the blockers in this order, then retry:

```bash
# Local terminal  🔴 DESTRUCTIVE
# 1. Load balancers
aws elbv2 delete-load-balancer --load-balancer-arn <LB_ARN> --region "${AWS_REGION}"

# 2. Orphaned ENIs
aws ec2 delete-network-interface --network-interface-id <ENI_ID> --region "${AWS_REGION}"

# 3. Retry the stack deletion
aws cloudformation delete-stack --stack-name "eksctl-${CLUSTER_NAME}-cluster" --region "${AWS_REGION}"
aws cloudformation wait stack-delete-complete --stack-name "eksctl-${CLUSTER_NAME}-cluster" --region "${AWS_REGION}"
```

> [!IMPORTANT]
> This is exactly why [cleanup.md](./cleanup.md) deletes LoadBalancer Services **before** the cluster. Doing it in the wrong order creates this problem.

**Console:** CloudFormation → Stacks → Events · VPC → Network Interfaces · EC2 → Load Balancers

---

### F2. Remaining AWS resources after deletion

**Symptom** — the cluster is gone but AWS is still charging you.

**Diagnostics** — run the full sweep from [cleanup.md §Final checklist](./cleanup.md#final-checklist):

```bash
# Local terminal
aws eks list-clusters --region "${AWS_REGION}" --output text
aws ec2 describe-instances --region "${AWS_REGION}" --filters Name=instance-state-name,Values=running --query 'Reservations[].Instances[].InstanceId' --output text
aws ec2 describe-volumes --region "${AWS_REGION}" --filters Name=status,Values=available --query 'Volumes[].VolumeId' --output text
aws elbv2 describe-load-balancers --region "${AWS_REGION}" --query 'LoadBalancers[].LoadBalancerName' --output text
aws ec2 describe-nat-gateways --region "${AWS_REGION}" --filter Name=state,Values=available --query 'NatGateways[].NatGatewayId' --output text
aws ec2 describe-addresses --region "${AWS_REGION}" --query 'Addresses[?AssociationId==null].PublicIp' --output text
```

**The usual culprits:**

| Resource | Why it survived | Cost impact |
|---|---|---|
| **NLB/ALB from a Service or Ingress** | Created by a Kubernetes controller, not CloudFormation | 💰💰 Hourly, indefinitely |
| **EBS volumes from `Retain` PVCs** | Retained deliberately | 💰 Per GB-month |
| **NAT Gateway** | Should not exist in this guide — check whether it belongs to other infrastructure | 💰💰💰 Hourly plus per GB |
| **Unassociated Elastic IPs** | Left after deleting something they were attached to | 💰 Hourly |
| **CloudWatch log groups** | Retained by design | 💰 Per GB stored |
| **IRSA IAM roles** | Separate CloudFormation stacks | Free, but untidy |

Full instructions in [cleanup.md](./cleanup.md).

**Console:** Billing and Cost Management → **Cost Explorer**, grouped by Service — this tells you exactly what is still costing money.

---

### F3. Deleted the cluster but Cost Explorer still shows charges

**Cause** — usually one of two things:

1. **Billing data lags up to 24 hours.** Charges shown today may be for hours the cluster genuinely ran yesterday.
2. Something survived — see [F2](#f2-remaining-aws-resources-after-deletion).

**Diagnostics**

```bash
aws ce get-cost-and-usage \
  --time-period Start="$(date -u -d '3 days ago' +%Y-%m-%d)",End="$(date -u +%Y-%m-%d)" \
  --granularity DAILY --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=SERVICE \
  --query 'ResultsByTime[].{Date:TimePeriod.Start,Costs:Groups[?Metrics.UnblendedCost.Amount>`0.01`].[Keys[0],Metrics.UnblendedCost.Amount]}' \
  --output json
```

(macOS: `date -u -v-3d +%Y-%m-%d`.)

**Resolution** — if a charge appears on a day **after** deletion, something survived. Run the sweep in [F2](#f2-remaining-aws-resources-after-deletion).

**Console:** Billing and Cost Management → Cost Explorer → daily granularity, grouped by Service

---

### F4. Node group stuck deleting

**Symptom** — the node group sits in `DELETING` for more than 20 minutes.

**Diagnostics**

```bash
aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" \
  --nodegroup-name "${NODE_GROUP_NAME}" --region "${AWS_REGION}" \
  --query 'nodegroup.{Status:status,Health:health}' --output json

kubectl get pods -A -o wide | grep -v Running
kubectl get pdb -A
```

**Cause** — a PodDisruptionBudget blocks eviction, or a Pod will not terminate.

**Resolution**

```bash
# Relax the blocking PDB
kubectl delete pdb <PDB_NAME> -n <NAMESPACE>

# Or force-delete the stuck Pod
kubectl delete pod <POD_NAME> -n <NAMESPACE> --force --grace-period=0
```

Last resort — delete the underlying Auto Scaling group directly:

```bash
# Local terminal  🔴 DESTRUCTIVE
ASG=$(aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" \
  --nodegroup-name "${NODE_GROUP_NAME}" --region "${AWS_REGION}" \
  --query 'nodegroup.resources.autoScalingGroups[0].name' --output text)
aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "$ASG" \
  --force-delete --region "${AWS_REGION}"
```

**Console:** EKS → Compute · EC2 → Auto Scaling groups

---

## Quick reference — symptom to section

| Symptom | Section |
|---|---|
| `Unable to locate credentials` | [A1](#a1-aws-cli-not-authenticated) |
| Wrong account / region | [A2](#a2-wrong-profile-or-wrong-account) |
| SSO token expired | [A3](#a3-expired-sso-session) |
| `AccessDeniedException` | [A4](#a4-access-denied) |
| `eksctl: command not found` | [A5](#a5-eksctl-command-not-found) |
| `ROLLBACK_COMPLETE` | [B1](#b1-cloudformation-failure) |
| Unsupported Kubernetes version | [B2](#b2-unsupported-kubernetes-version) |
| Availability Zone error | [B3](#b3-unsupported-availability-zone) |
| `InsufficientInstanceCapacity` | [B4](#b4-ec2-capacity-issue) |
| Node group `CREATE_FAILED` | [B5](#b5-node-group-creation-failure) |
| Node does not join | [C1](#c1-worker-node-does-not-join) |
| Node `NotReady` | [C2](#c2-node-remains-notready) |
| `failed to assign an IP address` / `Too many pods` | [D1](#d1-vpc-cni-ip-problem) |
| Pods `Pending` | [D2](#d2-pods-remain-pending) |
| CoreDNS broken | [D3](#d3-coredns-problem) |
| LoadBalancer `<pending>` | [D4](#d4-loadbalancer-service-stuck-pending) |
| PVC / volume attach failure | [D5](#d5-ebs-volume-attachment-failure) |
| Wrong kubectl context | [E1](#e1-wrong-kubeconfig-context) |
| `i/o timeout` or `Unauthorized` on the API | [E2](#e2-api-endpoint-inaccessible) |
| Worked yesterday, times out today | [E3](#e3-public-access-cidr-is-incorrect) |
| OIDC / IRSA errors | [E4](#e4-oidc-issue) |
| Deletion stuck | [F1](#f1-cluster-deletion-stuck) |
| Still being charged | [F2](#f2-remaining-aws-resources-after-deletion) · [F3](#f3-deleted-the-cluster-but-cost-explorer-still-shows-charges) |

---

## Official documentation

- EKS troubleshooting — <https://docs.aws.amazon.com/eks/latest/userguide/troubleshooting.html>
- EKS node group troubleshooting — <https://docs.aws.amazon.com/eks/latest/userguide/troubleshooting.html#worker-node-fail>
- eksctl troubleshooting — <https://eksctl.io/usage/troubleshooting/>
- VPC CNI troubleshooting — <https://docs.aws.amazon.com/eks/latest/userguide/cni-increase-ip-addresses.html>
- Cluster endpoint access — <https://docs.aws.amazon.com/eks/latest/userguide/cluster-endpoint.html>
- EKS access entries — <https://docs.aws.amazon.com/eks/latest/userguide/access-entries.html>
- IAM Roles for Service Accounts — <https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html>
- CloudFormation troubleshooting — <https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/troubleshooting.html>
- Debugging Pods — <https://kubernetes.io/docs/tasks/debug/debug-application/debug-pods/>
