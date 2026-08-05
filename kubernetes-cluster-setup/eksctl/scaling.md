# EKS — Scaling from One Node to Two (Optional Exercise)

An optional exercise: scale the managed node group from **1** node to **2**, watch what changes, then scale back to **1**.

> [!CAUTION]
> 💰 **A second node doubles your EC2 cost** — a second instance, a second EBS volume, and a second public IPv4 address, all billed continuously until you scale back down. Do the exercise, observe the result, and **scale back to one node immediately**.

> [!WARNING]
> 🔴 **Never scale beyond two nodes in this guide.** `maxSize` is `2` for a reason. Do not raise it.

Assumes you followed [README.md](./README.md) and have a cluster with desired 1 / min 1 / max 2.

---

## Contents

1. [Set your variables](#1-set-your-variables)
2. [Confirm the current state](#2-confirm-the-current-state)
3. [Scale up to two nodes](#3-scale-up-to-two-nodes)
4. [Observe what changed](#4-observe-what-changed)
5. [Scale back to one node](#5-scale-back-to-one-node)
6. [Cost impact](#6-cost-impact)
7. [Troubleshooting](#7-troubleshooting)

---

## 1. Set your variables

```bash
# Local terminal
export CLUSTER_NAME=<CLUSTER_NAME>
export AWS_REGION=<AWS_REGION>
export NODE_GROUP_NAME=<NODE_GROUP_NAME>

aws sts get-caller-identity --query Arn --output text
kubectl config current-context
```

✅ Confirm the context is your EKS cluster ARN, not a Kind or Minikube context.

---

## 2. Confirm the current state

```bash
# Local terminal
kubectl get nodes -o wide

aws eks describe-nodegroup \
  --cluster-name "${CLUSTER_NAME}" \
  --nodegroup-name "${NODE_GROUP_NAME}" \
  --region "${AWS_REGION}" \
  --query 'nodegroup.{Status:status,Desired:scalingConfig.desiredSize,Min:scalingConfig.minSize,Max:scalingConfig.maxSize}' \
  --output table
```

**Expected output:**

```text
NAME                            STATUS   ROLES    AGE   VERSION
ip-192-168-12-34.ec2.internal   Ready    <none>   25m   v1.36.x-eks-xxxxxxx

+---------------------------------+
|        DescribeNodegroup        |
+-----------+---------------------+
|  Desired  |  1                  |
|  Max      |  2                  |
|  Min      |  1                  |
|  Status   |  ACTIVE             |
+-----------+---------------------+
```

Also note where your Pods are running now, so you can see the difference later:

```bash
# Local terminal
kubectl -n demo get pods -o wide
```

**Expected output:** both `web` Pods on the single node.

---

## 3. Scale up to two nodes

Target state:

```text
Minimum: 1
Desired: 2
Maximum: 2
```

### Option A — eksctl (simplest)

```bash
# Local terminal  💰 starts billing a second instance
eksctl scale nodegroup \
  --cluster "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --name "${NODE_GROUP_NAME}" \
  --nodes 2 \
  --nodes-min 1 \
  --nodes-max 2
```

**Expected output:**

```text
2026-08-05 11:00:00 [ℹ]  scaling nodegroup "ng-lab" in cluster eks-lab
2026-08-05 11:00:02 [ℹ]  waiting for scaling of nodegroup "ng-lab" to complete
2026-08-05 11:02:15 [ℹ]  nodegroup successfully scaled
```

### Option B — AWS CLI

```bash
# Local terminal  💰 starts billing a second instance
aws eks update-nodegroup-config \
  --cluster-name "${CLUSTER_NAME}" \
  --nodegroup-name "${NODE_GROUP_NAME}" \
  --region "${AWS_REGION}" \
  --scaling-config minSize=1,maxSize=2,desiredSize=2
```

**Expected output:** JSON with `"status": "InProgress"` and an update ID.

Follow it:

```bash
# Local terminal
aws eks describe-nodegroup \
  --cluster-name "${CLUSTER_NAME}" --nodegroup-name "${NODE_GROUP_NAME}" \
  --region "${AWS_REGION}" --query 'nodegroup.status' --output text
```

Wait for `ACTIVE` (it passes through `UPDATING`).

### Option C — AWS Console

**EKS → Clusters → *your cluster* → Compute → *your node group* → Edit → Node group scaling configuration**

Set Minimum 1, Desired 2, Maximum 2 → **Save changes**.

### Watch the node join

```bash
# Local terminal
kubectl get nodes -w        # Ctrl+C once the second node is Ready
```

Takes 2–4 minutes: EC2 launch, kubelet start, node registration, VPC CNI and kube-proxy DaemonSet Pods starting.

**Expected sequence:**

```text
NAME                            STATUS     ROLES    AGE   VERSION
ip-192-168-12-34.ec2.internal   Ready      <none>   30m   v1.36.x-eks-xxxxxxx
ip-192-168-45-67.ec2.internal   NotReady   <none>   10s   v1.36.x-eks-xxxxxxx
ip-192-168-45-67.ec2.internal   Ready      <none>   45s   v1.36.x-eks-xxxxxxx
```

`NotReady` briefly is normal — the node is waiting for its CNI Pod.

---

## 4. Observe what changed

### 4.1 Two nodes

```bash
# Local terminal
kubectl get nodes -o wide
kubectl get nodes --no-headers | wc -l
```

**Expected output:** `2`

Notice each node has its own `EXTERNAL-IP` — 💰 two billable public IPv4 addresses now.

### 4.2 DaemonSets scaled automatically

```bash
# Local terminal
kubectl -n kube-system get daemonset
kubectl -n kube-system get pods -o wide | grep -E 'aws-node|kube-proxy'
```

**Expected output:**

```text
NAME         DESIRED   CURRENT   READY   AGE
aws-node     2         2         2       35m
kube-proxy   2         2         2       35m
```

`DESIRED` went from 1 to 2 by itself. **That is what a DaemonSet is** — exactly one Pod per node, automatically. You did nothing.

### 4.3 Existing Pods did not move

```bash
# Local terminal
kubectl -n demo get pods -o wide
```

**Expected output:** both `web` Pods still on the **original** node.

> [!IMPORTANT]
> **Kubernetes does not rebalance running Pods.** The scheduler places a Pod once, at creation. Adding a node does not trigger any redistribution. This surprises people constantly. Descheduler exists for this, but it is not installed by default.

### 4.4 Force a redistribution

```bash
# Local terminal
kubectl -n demo rollout restart deployment/web
kubectl -n demo rollout status deployment/web
kubectl -n demo get pods -o wide
```

**Expected output:** one Pod on each node.

That is `topologySpreadConstraints` in [`manifests/10-deployment.yaml`](./manifests/10-deployment.yaml) doing its job. It was a no-op on one node; with two, the scheduler spreads Pods across them.

> [!NOTE]
> Because `whenUnsatisfiable: ScheduleAnyway` is set, the constraint is a *preference*, not a hard rule. With `DoNotSchedule` instead, a Pod that could not be spread would stay `Pending` — which would have broken the single-node setup entirely.

### 4.5 Scale the application to use both nodes

```bash
# Local terminal
kubectl -n demo scale deployment/web --replicas=4
kubectl -n demo rollout status deployment/web
kubectl -n demo get pods -o wide
```

**Expected output:** roughly two Pods per node.

Back to two:

```bash
# Local terminal
kubectl -n demo scale deployment/web --replicas=2
```

### 4.6 Capacity across both nodes

```bash
# Local terminal
kubectl describe nodes | grep -A5 "Allocated resources"
kubectl top nodes 2>/dev/null || echo "Install metrics-server for kubectl top"
```

---

## 5. Scale back to one node

> [!CAUTION]
> 💰 **Do this as soon as you have finished observing.** The second node keeps billing until you do.

Target state:

```text
Minimum: 1
Desired: 1
Maximum: 2
```

```bash
# Local terminal
eksctl scale nodegroup \
  --cluster "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --name "${NODE_GROUP_NAME}" \
  --nodes 1 \
  --nodes-min 1 \
  --nodes-max 2
```

Or with the AWS CLI:

```bash
# Local terminal
aws eks update-nodegroup-config \
  --cluster-name "${CLUSTER_NAME}" \
  --nodegroup-name "${NODE_GROUP_NAME}" \
  --region "${AWS_REGION}" \
  --scaling-config minSize=1,maxSize=2,desiredSize=1
```

### What happens during scale-in

A **managed** node group does this gracefully — one of its main advantages:

1. Marks a node unschedulable (cordon)
2. Evicts its Pods, respecting PodDisruptionBudgets
3. Waits for Pods to reschedule onto the remaining node
4. Terminates the EC2 instance
5. Deletes its EBS root volume

```bash
# Local terminal
kubectl get nodes -w         # Ctrl+C when only one node remains
```

Takes 2–5 minutes.

✅ **Verify:**

```bash
# Local terminal
kubectl get nodes
kubectl get nodes --no-headers | wc -l
kubectl -n demo get pods -o wide

aws eks describe-nodegroup \
  --cluster-name "${CLUSTER_NAME}" --nodegroup-name "${NODE_GROUP_NAME}" \
  --region "${AWS_REGION}" \
  --query 'nodegroup.{Desired:scalingConfig.desiredSize,Min:scalingConfig.minSize,Max:scalingConfig.maxSize,Status:status}' \
  --output table
```

**Expected output:** `1` node, `Desired: 1`, `Status: ACTIVE`, and both `web` Pods running on the surviving node.

✅ **Confirm the EC2 instance is really gone:**

```bash
# Local terminal
aws ec2 describe-instances --region "${AWS_REGION}" \
  --filters "Name=tag:eks:cluster-name,Values=${CLUSTER_NAME}" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].{ID:InstanceId,Type:InstanceType,IP:PublicIpAddress}' \
  --output table
```

**Expected output:** exactly one instance.

✅ **And its EBS volume:**

```bash
# Local terminal
aws ec2 describe-volumes --region "${AWS_REGION}" \
  --filters Name=status,Values=available \
  --query 'Volumes[].{ID:VolumeId,Size:Size,Created:CreateTime}' --output table
```

**Expected output:** empty. Managed node groups delete the root volume with the instance; if one is left in `available`, delete it — it bills for nothing.

---

## 6. Cost impact

### What a second node adds

| Resource | Extra cost of node 2 |
|---|---|
| EC2 instance | A second instance, per second while running |
| EBS root volume | A second 20 GB gp3 volume, per GB-month |
| Public IPv4 address | A second address, per hour |
| Cross-AZ data transfer | Per GB, if Pods on different nodes in different AZs talk to each other |

The EKS control-plane charge is **per cluster**, so it does not change.

> [!WARNING]
> 💰 **Leaving the second node running doubles your compute bill for the whole time it exists.** Not while it is busy — while it *exists*. An idle node costs exactly as much as a loaded one.
>
> Check current prices before deciding: <https://aws.amazon.com/ec2/pricing/on-demand/> and <https://aws.amazon.com/vpc/pricing/> (for the IPv4 address).

### Estimate your own cost

```bash
# Local terminal
INSTANCE_TYPE=$(aws eks describe-nodegroup \
  --cluster-name "${CLUSTER_NAME}" --nodegroup-name "${NODE_GROUP_NAME}" \
  --region "${AWS_REGION}" --query 'nodegroup.instanceTypes[0]' --output text)
echo "Instance type: $INSTANCE_TYPE in $AWS_REGION"
echo "Look up the on-demand hourly rate: https://aws.amazon.com/ec2/pricing/on-demand/"
echo "Multiply by node count and hours, then add EBS and public IPv4."
```

Use the **AWS Pricing Calculator** for a full estimate: <https://calculator.aws/>

### After the exercise

```bash
# Local terminal
aws ce get-cost-and-usage \
  --time-period Start="$(date -u -d '2 days ago' +%Y-%m-%d)",End="$(date -u +%Y-%m-%d)" \
  --granularity DAILY --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=SERVICE \
  --query 'ResultsByTime[].Groups[?Metrics.UnblendedCost.Amount>`0.01`].[Keys[0],Metrics.UnblendedCost.Amount]' \
  --output table 2>/dev/null || echo "Enable Cost Explorer, or check the Billing console"
```

(On macOS, `date -u -d` is GNU syntax — use `date -u -v-2d +%Y-%m-%d` instead.)

Billing data lags up to 24 hours.

---

## 7. Troubleshooting

| Symptom | Likely cause | Diagnostic | Resolution |
|---|---|---|---|
| Scaling fails: `desiredSize must be <= maxSize` | You asked for more than `maxSize` | `aws eks describe-nodegroup ... --query 'nodegroup.scalingConfig'` | Pass `--nodes-max 2` alongside `--nodes 2`. **Do not raise max above 2.** |
| Second node never appears | EC2 capacity in the AZ, or a quota | `aws autoscaling describe-scaling-activities --auto-scaling-group-name <ASG>` | Check the ASG activity error; try a different instance type; check your vCPU quota |
| Second node stuck `NotReady` | CNI Pod not started, or no route to the control plane | `kubectl describe node <name>`; `kubectl -n kube-system get pods -o wide \| grep aws-node` | Wait 2 min; if it persists, check the node's security group and subnet routing |
| `InsufficientInstanceCapacity` | AWS has no capacity for that type in that AZ | ASG scaling activities | Use `instanceTypes` with several similar types, or a different region |
| Pods do not spread after scaling up | Kubernetes never rebalances running Pods | `kubectl -n demo get pods -o wide` | `kubectl -n demo rollout restart deployment/web` |
| Scale-in hangs | A PodDisruptionBudget blocks eviction, or a Pod will not terminate | `kubectl get pdb -A`; `kubectl get pods -A --field-selector spec.nodeName=<node>` | Relax the PDB, or delete the stuck Pod with `--force --grace-period=0` |
| Node terminated but the volume remains | Volume was created without delete-on-termination | `aws ec2 describe-volumes --filters Name=status,Values=available` | `aws ec2 delete-volume --volume-id <id>` — 💰 it bills otherwise |
| Node group stuck `UPDATING` | An update is already in flight | `aws eks list-updates --name <cluster> --nodegroup-name <ng>` | Wait; concurrent updates are not allowed |
| `UnauthorizedOperation` when scaling | Missing IAM permissions | `aws sts get-caller-identity` | Needs `eks:UpdateNodegroupConfig` and `autoscaling:*` |

**Diagnostics:**

```bash
# Local terminal
aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" \
  --nodegroup-name "${NODE_GROUP_NAME}" --region "${AWS_REGION}" --output json | jq '.nodegroup | {status, health, scalingConfig}'

ASG=$(aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" \
  --nodegroup-name "${NODE_GROUP_NAME}" --region "${AWS_REGION}" \
  --query 'nodegroup.resources.autoScalingGroups[0].name' --output text)
aws autoscaling describe-scaling-activities --auto-scaling-group-name "$ASG" \
  --region "${AWS_REGION}" --max-items 5 \
  --query 'Activities[].{Status:StatusCode,Cause:Cause,Time:StartTime}' --output table

kubectl get nodes -o wide
kubectl get events -A --sort-by=.lastTimestamp | tail -20
```

**Relevant AWS console pages:** EKS → Clusters → *cluster* → Compute · EC2 → Auto Scaling groups → *your ASG* → Activity · EC2 → Instances · EC2 → Volumes.

---

## Finished?

> [!CAUTION]
> 💰 Confirm you are back to **one** node — then, if the lab is over, go to **[cleanup.md](./cleanup.md)** and delete the cluster.

```bash
# Local terminal
kubectl get nodes --no-headers | wc -l        # must print 1
```

---

## Official documentation

- Managed node groups — <https://docs.aws.amazon.com/eks/latest/userguide/managed-node-groups.html>
- Updating a managed node group — <https://docs.aws.amazon.com/eks/latest/userguide/update-managed-node-group.html>
- `eksctl scale nodegroup` — <https://eksctl.io/usage/managing-nodegroups/>
- Topology spread constraints — <https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/>
- DaemonSets — <https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/>
- EC2 on-demand pricing — <https://aws.amazon.com/ec2/pricing/on-demand/>
- AWS Pricing Calculator — <https://calculator.aws/>
