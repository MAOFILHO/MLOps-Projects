# M5 Lab B — Application Load Balancer + Target Group + Listener

**Module 5 — CI/CD & Production Deployment | Spine Project: Truck Delay Classification**

| Detail | Value |
|---|---|
| Duration | 45 minutes |
| Difficulty | Intermediate |
| Tools | AWS Console + AWS CLI v2 |
| AWS Services | **ALB (Application Load Balancer)**, Target Groups, ECS, Security Groups |
| Prerequisite | Lab A complete — ECS service `truck-delay-service` running with `desired-count=1` |
| Builds Toward | Lab C (CI/CD redeploys behind the ALB), M6 (drift monitoring against the ALB endpoint) |
| Cost Estimate | ALB: ~₹2/hour + minor LCU charges. ~₹10 for a 4-hour session. |

---

> **🪟 Git Bash on Windows — same callout as Lab A.** MSYS auto-mangles args starting with `/`. The big one in this lab is `--health-check-path /_stcore/health` — without protection it becomes `C:/Program Files/Git/_stcore/health` and `create-target-group` rejects it. Use one of: (a) prefix `MSYS_NO_PATHCONV=1`, (b) double the slash `//_stcore/health`, or (c) run from PowerShell.
>
> **🍎 macOS / 🐧 Linux / WSL users — ignore this callout.** Native bash/zsh on macOS and Linux do not have MSYS path mangling, so `/_stcore/health` works as written.

---

## Learning Objectives

By the end of this lab you will be able to:

1. Explain why ECS tasks need a load balancer (stable DNS, health checks, multi-AZ failover).
2. Create a **target group** of the `ip` type and configure a Streamlit-aware **health check** (`/_stcore/health`).
3. Create an **Application Load Balancer** in public subnets with a listener on port 80.
4. Update the ECS service to **register tasks into the target group** automatically.
5. Tighten the task security group so only the ALB can reach port 8501.

---

## Business Context

In Lab A, Priya can reach the dashboard at `http://<public-ip>:8501` — but that IP changes every time the task restarts. Worse, if she runs `desired-count=2` to handle more traffic, she'd have two IPs and no way to spread requests across them. The ops team has been emailing IPs around like it's 2005.

The fix is an Application Load Balancer (ALB) — a managed Layer-7 proxy. The ALB has one stable DNS name; behind it sits a **target group** that ECS tasks register into as they start. The ALB load-balances HTTP requests across healthy tasks and removes unhealthy ones from rotation automatically. Same pattern Netflix and every other large web service uses.

---

## About the ELB v2 stack (ALB + Target Group + Listener) — first encounter

### What it is

These are three AWS resources that always travel together — think of them as one logical "load balancer setup":

| Resource | What it is | One-line role |
|---|---|---|
| **Application Load Balancer (ALB)** | A managed Layer-7 reverse proxy | The front door — one stable public DNS, HTTPS termination, routes by host/path/header |
| **Target Group** | A pool of backends (IPs or EC2 instance IDs) the ALB routes traffic to | The list of "where can I send a request?" Health-checked continuously. |
| **Listener** | A rule that says "incoming traffic on port X using protocol Y → forward to target group Z" | The wiring between the ALB's port and the target group |

The flow on every request:
```
Browser  →  ALB's public DNS  →  Listener (port 80)  →  Target Group (healthy IPs)  →  ECS task
```

When ECS launches a Fargate task, it **automatically registers** the task's private IP into the target group. When ECS stops a task (crash, rolling update, scale-down), it **automatically deregisters** it. You never touch target-group membership by hand.

### The problem this stack solves (specifically for our project)

After Lab A you have a working ECS service, but reaching it has four ugly problems:

1. **Ephemeral IPs.** Every task gets a new public IP on launch. Restart = new IP. Two tasks = two IPs. There's no single address to share with users.
2. **No health-aware routing.** If a Streamlit task is hung but the container is technically "running", users still hit it and get blank pages.
3. **No load distribution.** If you scale to `desired-count=2`, half your users have to manually pick the second IP — pointless.
4. **No multi-AZ failover.** The single task is in one AZ. Zone outage = dashboard down.

The ALB + Target Group + Listener stack fixes all four at once:

| Problem | How the ALB fixes it |
|---|---|
| Ephemeral IPs | One stable DNS name (`truck-delay-alb-xxx.region.elb.amazonaws.com`) survives task restarts forever |
| No health-aware routing | Target group polls `/_stcore/health` every 30s; unhealthy targets get pulled out automatically |
| No load distribution | ALB round-robins requests across all healthy targets |
| No multi-AZ failover | ALB lives in ≥2 AZs; if one AZ dies, traffic routes to tasks in the surviving AZ |

### ALB vs NLB vs CloudFront — which load balancer where

AWS offers three load-balancer-shaped products. Pick the wrong one and you'll either over-pay or hit limits.

| Aspect | **ALB** (we're using this) | **NLB** (Network LB) | **CloudFront** (CDN) |
|---|---|---|---|
| OSI Layer | 7 (HTTP/HTTPS) — understands paths, headers, methods | 4 (TCP/UDP/TLS) — just bytes | 7 (HTTP) — global CDN, not regional LB |
| Routing rules | Path-based, host-based, header-based, weighted | None — just forwards by port | Cache + path-based at the edge |
| Latency | ~10ms overhead | ~1ms overhead | <50ms from any edge worldwide |
| Throughput | Auto-scales | Higher (~millions QPS) | Higher (global) |
| WebSockets | Yes (Streamlit needs this — *important*) | Yes | Yes |
| HTTPS termination | Yes (ACM cert integration) | Yes (recent feature) | Yes (free ACM) |
| Best for | HTTP web apps + APIs | Ultra-low-latency TCP, gaming, real-time | Static assets, global audiences, CDN-cacheable content |
| Cost shape | ~₹2/hour + LCU usage | Same hourly + LCU | Per-GB transfer + per-request |
| Our project fit | ✅ Streamlit is HTTP+WebSockets; team is regional | ❌ Overkill — we don't need L4 perf | ❌ Streamlit isn't cacheable; users are regional |

**The Streamlit detail matters**: Streamlit uses WebSockets for the bidirectional reactive UI (every widget update is a WS message). ALB supports WebSockets out of the box; NLB does too; raw HTTP/1.1 ELB Classic does not. We pick ALB because it's L7 (we get the routing flexibility for free) without losing WebSocket support.

### A subtle but critical detail: `target type = ip`

Target groups come in two flavours:

| Target type | When | Why |
|---|---|---|
| `instance` | ECS-on-EC2, ASG-backed services | ALB addresses the EC2 instance ID + a host port; works because the host has a stable identity |
| **`ip`** ← we use this | **Fargate**, EKS pods, any task without an EC2 instance you control | ALB addresses the task's *private IP* directly — Fargate-managed compute has no instance ID you can reference |

If you pick `instance` for Fargate, the target group will refuse to register anything and the ALB will return 503 forever. The lab uses `ip` — don't change it.

### Pricing (us-east-1)

| Component | Rate | Cost for a 4-hour class session |
|---|---|---|
| ALB per-hour | ~$0.0252/hour = **~₹2.1/hour** | ~₹8.4 |
| ALB LCU (capacity units — see below) | ~$0.008/LCU-hour | Negligible at class scale (~₹2) |
| Target group | Free | ₹0 |
| Listener | Free | ₹0 |
| **Total per session** | | **~₹10–12** |

**What's an LCU?** An "ELB Capacity Unit" rolls up four dimensions — new connections per second, active connections per minute, processed bytes, and rule evaluations. For a class workload (dozens of requests/hour), you'll use a fraction of one LCU. For production at thousands of QPS, this becomes the dominant cost — worth understanding before you size up.

**Important**: ALB charges per hour *whether or not anyone visits the URL*. Always tear down at end of session (see [Student Manual §13](../M5_Student_Manual.md#13-teardown--destroy-everything)).

### How the ALB stack compares to what we've already used

| Pattern | Where you saw it | Why we're replacing it now |
|---|---|---|
| **Curl the task's public IP directly** (Lab A Step 6) | Smoke-test once the task was running | IP changes on restart; doesn't survive scaling; no health checks |
| **EC2 + Streamlit on a hardcoded IP** (M3) | The "starter" deployment | Single-AZ; no auto-recovery if the box dies; no zero-downtime updates |
| **ALB + Target Group + Listener** (this lab) | Production-grade traffic layer | Stable DNS, multi-AZ, health-aware, scales horizontally |

The progression: image stored (ECR, M4) → image runs as managed service (ECS, Lab A) → image becomes publicly addressable + health-checked + load-balanced (this lab) → image auto-redeploys on commit (Labs C/D).

---

## Prerequisites

### From Lab A

```bash
# Confirm the service from Lab A is still running
aws ecs describe-services \
    --cluster m5-truck-delay-cluster \
    --services truck-delay-service \
    --query "services[0].{Running:runningCount, Desired:desiredCount}" \
    --region us-east-1
```

You should see `Running: 1, Desired: 1`. If it's zero, either re-create the service from Lab A or scale it back up:
```bash
aws ecs update-service \
    --cluster m5-truck-delay-cluster \
    --service truck-delay-service \
    --desired-count 1 \
    --region us-east-1
```

### Shell variables (paste into your terminal)

```bash
export AWS_REGION=us-east-1
export VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" --output text --region $AWS_REGION)
export SUBNETS=($(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "Subnets[].SubnetId" --output text --region $AWS_REGION))
echo "VPC: $VPC_ID"
echo "Subnets (need 2 across AZs for ALB): ${SUBNETS[@]}"
```

ALBs require **at least 2 subnets in different Availability Zones**. The default VPC has one subnet per AZ, so `${SUBNETS[@]}` typically gives you 3 (e.g., `us-east-1a`, `us-east-1b`, `us-east-1c`). We'll use the first two.

---

## Step 1: Create the Target Group

A target group is a "pool of backends" — ECS tasks register here when they start, and de-register when they stop. The ALB sends traffic to whichever targets are currently healthy.

### Key field: target type = `ip` (not `instance`)

Fargate tasks run on AWS-managed compute, not on EC2 instances you control. So the target type **must be `ip`** — the ALB routes to task private IPs (registered by ECS automatically).

### Console clicks

1. AWS Console → **EC2** → **Target groups** (left sidebar) → **Create target group**.
2. Fill in:

| Field | Value | Why |
|---|---|---|
| Choose a target type | **IP addresses** | Required for Fargate tasks (no EC2 instances) |
| Target group name | `truck-delay-tg` | Will be referenced by name in Step 3 and in Lab C's CI/CD workflow |
| Protocol | **HTTP** | Streamlit serves plain HTTP; we'll handle HTTPS termination at the ALB in a later module |
| Port | **8501** | The port Streamlit listens on inside the container |
| VPC | (your default VPC from `$VPC_ID`) | Must match the VPC ECS tasks run in |
| Protocol version | **HTTP1** | Default is fine for Streamlit |
| Health check protocol | HTTP | |
| Health check path | **`/_stcore/health`** | Streamlit's built-in health endpoint. Returns 200 OK when the app is ready. |
| Advanced health check → Port | **traffic-port** | Use the same 8501 as the target port |
| Healthy threshold | 2 | Two consecutive successful checks before marking healthy |
| Unhealthy threshold | 3 | Three consecutive failures before marking unhealthy |
| Timeout | 5 sec | |
| Interval | 30 sec | |
| Success codes | 200 | |

3. **Next** → on the "Register targets" page, **leave it empty** — ECS will register tasks automatically when we attach the target group to the service in Step 4. Click **Create target group**.

`[SCREENSHOT: Target group creation form with target type=IP and health check path=/_stcore/health]`

### CLI alternative

```bash
TG_ARN=$(aws elbv2 create-target-group \
    --name truck-delay-tg \
    --protocol HTTP \
    --port 8501 \
    --vpc-id $VPC_ID \
    --target-type ip \
    --health-check-protocol HTTP \
    --health-check-path /_stcore/health \
    --health-check-interval-seconds 30 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 3 \
    --region $AWS_REGION \
    --query "TargetGroups[0].TargetGroupArn" --output text)

echo "Target group ARN: $TG_ARN"
```

> **Why `/_stcore/health` matters:** Streamlit has a dedicated health endpoint that bypasses session state. Hitting `/` instead would technically work, but `/` triggers Streamlit's full app render (which can take 5+ seconds on cold start). The ALB would then mark targets unhealthy during legitimate slow renders. `/_stcore/health` returns 200 in under 100 ms. Always use it for Streamlit health checks.

---

## Step 2: Create a Security Group for the ALB

The ALB needs its own SG that allows inbound 80 from the public internet.

```bash
ALB_SG_ID=$(aws ec2 create-security-group \
    --group-name truck-delay-alb-sg \
    --description "ALB SG: allow HTTP 80 from anywhere" \
    --vpc-id $VPC_ID \
    --region $AWS_REGION \
    --query "GroupId" --output text)

# Allow inbound 80 from anywhere
aws ec2 authorize-security-group-ingress \
    --group-id $ALB_SG_ID \
    --protocol tcp --port 80 --cidr 0.0.0.0/0 \
    --region $AWS_REGION

echo "ALB SG: $ALB_SG_ID"
```

---

## Step 3: Create the Application Load Balancer

### Console

1. AWS Console → **EC2** → **Load Balancers** → **Create Load Balancer** → choose **Application Load Balancer**.
2. Fill in:

| Field | Value |
|---|---|
| Load balancer name | `truck-delay-alb` |
| Scheme | **Internet-facing** |
| IP address type | IPv4 |
| VPC | (your default VPC) |
| Mappings | Tick **2 AZs** (e.g., `us-east-1a` + `us-east-1b`) and select the subnet in each |
| Security groups | `truck-delay-alb-sg` (from Step 2) — **remove the default SG** |
| Listeners | Protocol HTTP, Port 80 |
| Default action | Forward to target group `truck-delay-tg` (from Step 1) |

3. **Create load balancer**.

### CLI alternative

```bash
# Pick the first two subnets (across AZs)
SUBNET_1=${SUBNETS[0]}
SUBNET_2=${SUBNETS[1]}

ALB_ARN=$(aws elbv2 create-load-balancer \
    --name truck-delay-alb \
    --subnets $SUBNET_1 $SUBNET_2 \
    --security-groups $ALB_SG_ID \
    --scheme internet-facing \
    --type application \
    --ip-address-type ipv4 \
    --region $AWS_REGION \
    --query "LoadBalancers[0].LoadBalancerArn" --output text)

echo "ALB ARN: $ALB_ARN"

# Create the listener (HTTP 80 → forward to target group)
LISTENER_ARN=$(aws elbv2 create-listener \
    --load-balancer-arn $ALB_ARN \
    --protocol HTTP \
    --port 80 \
    --default-actions "Type=forward,TargetGroupArn=$TG_ARN" \
    --region $AWS_REGION \
    --query "Listeners[0].ListenerArn" --output text)

echo "Listener ARN: $LISTENER_ARN"
```

### Wait for the ALB to become active

```bash
aws elbv2 wait load-balancer-available --load-balancer-arns $ALB_ARN --region $AWS_REGION
echo "ALB is active."
```

This takes ~2 minutes — ALBs provision ENIs in each AZ, allocate the DNS name, and warm up.

### Get the ALB's public DNS

```bash
ALB_DNS=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns $ALB_ARN \
    --query "LoadBalancers[0].DNSName" --output text \
    --region $AWS_REGION)
echo "ALB DNS: $ALB_DNS"
echo "Dashboard URL: http://$ALB_DNS"
```

You won't see the dashboard yet — the ECS tasks aren't registered with the target group. That's Step 4.

---

## Step 4: Update the ECS Service to Register Tasks with the Target Group

Right now, the ECS service from Lab A doesn't know about the target group. We need to update it.

```bash
aws ecs update-service \
    --cluster m5-truck-delay-cluster \
    --service truck-delay-service \
    --load-balancers "targetGroupArn=$TG_ARN,containerName=truck-delay-app,containerPort=8501" \
    --region $AWS_REGION \
    --force-new-deployment
```

`--force-new-deployment` forces ECS to replace the existing task with one that knows about the target group. ECS does a **rolling deployment**: start the new task, register it with the TG, wait for it to be healthy, then stop the old task. Zero-downtime by default.

> **`Error: container name in load balancer not match task definition`?** The `containerName` parameter must match what's in your task definition's `containerDefinitions[].name` (Lab A used `truck-delay-app`). If you changed that, update accordingly.

### Watch the rollout

```bash
aws ecs describe-services \
    --cluster m5-truck-delay-cluster \
    --services truck-delay-service \
    --query "services[0].{Running:runningCount, Desired:desiredCount, Events:events[0:3].message}" \
    --region $AWS_REGION
```

Expected events:
- "service truck-delay-service registered 1 targets in target-group truck-delay-tg"
- "service truck-delay-service has reached a steady state"

### Check target health

```bash
aws elbv2 describe-target-health \
    --target-group-arn $TG_ARN \
    --region $AWS_REGION \
    --query "TargetHealthDescriptions[].{IP:Target.Id, Port:Target.Port, State:TargetHealth.State}"
```

Expected (after ~1 minute):
```json
[
  { "IP": "172.31.x.y", "Port": 8501, "State": "healthy" }
]
```

If state is `initial`, wait 30 seconds and retry. If `unhealthy`, see Troubleshooting below.

---

## Step 5: Hit the ALB URL

```bash
echo "Open in browser: http://$ALB_DNS"
```

Open it. You should see the FreshBasket Truck Delay Dashboard at the **stable ALB DNS** instead of the ephemeral task IP from Lab A.

`[SCREENSHOT: Browser at http://truck-delay-alb-<random>.us-east-1.elb.amazonaws.com showing the dashboard]`

### Why the URL doesn't change

- Task crashes → ECS launches a new task with a new private IP → new task registers into the target group → ALB routes traffic to the new IP. **ALB DNS stays the same.**
- You scale `desired-count=3` → three tasks register → ALB load-balances across all three. **Same DNS.**
- The ALB DNS only changes if you delete and recreate the ALB.

---

## Step 6: Tighten the Task Security Group

In Lab A you opened port 8501 to `0.0.0.0/0` for debugging. Now that the ALB fronts the tasks, you can restrict 8501 to **only the ALB**.

```bash
# The default SG (where the task lives)
TASK_SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=default" \
    --query "SecurityGroups[0].GroupId" --output text \
    --region $AWS_REGION)

# Remove the wide-open 8501 rule
aws ec2 revoke-security-group-ingress \
    --group-id $TASK_SG_ID \
    --protocol tcp --port 8501 --cidr 0.0.0.0/0 \
    --region $AWS_REGION 2>/dev/null || true

# Add: 8501 from the ALB SG only
aws ec2 authorize-security-group-ingress \
    --group-id $TASK_SG_ID \
    --protocol tcp --port 8501 \
    --source-group $ALB_SG_ID \
    --region $AWS_REGION

echo "Task SG is now locked down: 8501 only from ALB SG."
```

Test that the direct-IP access from Lab A is now blocked, but the ALB URL still works:

```bash
# This should now hang / timeout (port 8501 no longer open to the world)
curl -m 5 http://$PUBLIC_IP:8501

# This should still return 200 OK
curl -I http://$ALB_DNS
```

---

## Step 7: Scale Test (Optional but Worth Doing)

Set desired-count to 2 and watch the ALB load-balance:

```bash
aws ecs update-service \
    --cluster m5-truck-delay-cluster \
    --service truck-delay-service \
    --desired-count 2 \
    --region $AWS_REGION
```

After ~1 minute:

```bash
aws elbv2 describe-target-health \
    --target-group-arn $TG_ARN \
    --region $AWS_REGION \
    --query "TargetHealthDescriptions[].{IP:Target.Id, State:TargetHealth.State}"
```

Now shows **two healthy targets**. Refresh the ALB URL a few times — Streamlit's session affinity means you may stick to one target, but server-side both are receiving traffic. ALB access logs (if enabled) would show ~50/50 split for unique sessions.

Scale back down to save cost:

```bash
aws ecs update-service \
    --cluster m5-truck-delay-cluster \
    --service truck-delay-service \
    --desired-count 1 \
    --region $AWS_REGION
```

---

## Verification Checklist

- [ ] Target group `truck-delay-tg` exists with target type `ip` and health check path `/_stcore/health`
- [ ] ALB `truck-delay-alb` is `active` and has a DNS name
- [ ] ECS service has `loadBalancers` populated and is in steady state
- [ ] `describe-target-health` shows one or more targets as `healthy`
- [ ] `curl -I http://$ALB_DNS` returns `HTTP/1.1 200 OK`
- [ ] Browser at `http://$ALB_DNS` shows the dashboard
- [ ] Task security group only allows 8501 from the ALB SG (not `0.0.0.0/0`)

---

## What's next — Lab C

The deployment is real, but updates still require manual `docker build` + `docker push` + `update-service`. Lab C wires up **GitHub Actions** so every `git push` to `main` triggers the full pipeline automatically: build new image → push to ECR → register new task definition revision → roll out the update.

The endpoint will stay at the same ALB DNS — only the underlying image changes. Zero downtime, zero clicks.

---

## Troubleshooting

| Symptom | Diagnosis | Fix |
|---|---|---|
| Target stays `initial` for >2 min | First task hasn't passed health check yet | `aws logs tail /ecs/truck-delay-service` — Streamlit might still be starting (cold start ~30 s). Wait. |
| Target goes `unhealthy` immediately | Health check path mismatch | Confirm target group health check path is `/_stcore/health` (not `/`). The Streamlit `/` returns a redirect → not a 200. |
| Target unhealthy: "Health checks failed" with no detail | ALB SG can't reach task port | Confirm task SG allows 8501 **from the ALB SG** (Step 6). After Step 6 the rule is `source-group=$ALB_SG_ID`. |
| `curl http://$ALB_DNS` returns 503 Service Unavailable | No healthy targets in the target group | Check task health: `aws elbv2 describe-target-health` |
| ALB creation fails: "At least two subnets in two different Availability Zones must be specified" | You passed subnets in the same AZ | Make sure `$SUBNETS` covers ≥2 AZs. Default VPC always does. |
| `update-service` returns `InvalidParameterException` when adding `--load-balancers` | The service uses the **CodeDeploy** (blue/green) deployment controller, or you're on an older AWS CLI that predates the Nov-2024 update | (a) Confirm rolling deployment controller: `aws ecs describe-services ... --query "services[0].deploymentController"` should return `{"type": "ECS"}`. (b) Upgrade AWS CLI to v2.18+. As a last resort, delete the service from Lab A and recreate it with `--load-balancers` from the start (see Quick Reference below). |

---

## Quick reference

```bash
# Variables
export AWS_REGION=us-east-1
export VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query "Vpcs[0].VpcId" --output text --region $AWS_REGION)
export SUBNETS=($(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query "Subnets[].SubnetId" --output text --region $AWS_REGION))

# Target Group
export TG_ARN=$(aws elbv2 create-target-group --name truck-delay-tg --protocol HTTP --port 8501 --vpc-id $VPC_ID --target-type ip --health-check-path /_stcore/health --region $AWS_REGION --query "TargetGroups[0].TargetGroupArn" --output text)

# ALB SG + ALB
export ALB_SG_ID=$(aws ec2 create-security-group --group-name truck-delay-alb-sg --description "ALB SG" --vpc-id $VPC_ID --region $AWS_REGION --query "GroupId" --output text)
aws ec2 authorize-security-group-ingress --group-id $ALB_SG_ID --protocol tcp --port 80 --cidr 0.0.0.0/0 --region $AWS_REGION

export ALB_ARN=$(aws elbv2 create-load-balancer --name truck-delay-alb --subnets ${SUBNETS[0]} ${SUBNETS[1]} --security-groups $ALB_SG_ID --scheme internet-facing --region $AWS_REGION --query "LoadBalancers[0].LoadBalancerArn" --output text)

aws elbv2 create-listener --load-balancer-arn $ALB_ARN --protocol HTTP --port 80 --default-actions "Type=forward,TargetGroupArn=$TG_ARN" --region $AWS_REGION

# Wait + get DNS
aws elbv2 wait load-balancer-available --load-balancer-arns $ALB_ARN --region $AWS_REGION
export ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN --query "LoadBalancers[0].DNSName" --output text --region $AWS_REGION)
echo "http://$ALB_DNS"

# Wire to ECS
aws ecs update-service --cluster m5-truck-delay-cluster --service truck-delay-service --load-balancers "targetGroupArn=$TG_ARN,containerName=truck-delay-app,containerPort=8501" --region $AWS_REGION --force-new-deployment
```
