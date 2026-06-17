# M5 Lab A — ECS Cluster + Task Definition + Service

**Module 5 — CI/CD & Production Deployment | Spine Project: Truck Delay Classification**

| Detail | Value |
|---|---|
| Duration | 60 minutes |
| Difficulty | Intermediate |
| Tools | AWS CLI v2, AWS Console (CloudWatch + ECS) |
| AWS Services | **ECS (Elastic Container Service)**, IAM, CloudWatch Logs, VPC |
| Prerequisite | M4 Lab 4 complete — Truck Delay image pushed to ECR |
| Builds Toward | Lab B (ALB front-end), Lab C (GitHub Actions CI/CD) |
| Cost Estimate | ~₹3/hour while the task runs (0.5 vCPU, 1 GB Fargate) — destroy at end of session |

---

## Learning Objectives

By the end of this lab you will be able to:

1. Create an **ECS cluster** and explain the difference between Fargate and EC2 launch types.
2. Write an **ECS task definition** JSON (image URI, CPU/memory, port mapping, log configuration).
3. Create the **`ecsTaskExecutionRole`** IAM role and explain what permissions it grants.
4. Run the task definition as a **service** with desired-count and auto-restart behaviour.
5. Verify the task is running by viewing **CloudWatch Logs** and the **ECS service event log**.

---

## Business Context

Priya's team has been running the Streamlit dashboard on the M3 EC2 instance. It works — until the EC2 reboots, the laptop running `tmux` dies, or someone needs to deploy a new version. Every restart involves SSH, manual `streamlit run`, port checks. Last month an unplanned EC2 maintenance window took the dashboard down for 4 hours and nobody noticed until ops staff complained at 2 PM.

Priya wants the dashboard to behave like a real service: it should restart itself if it crashes, scale horizontally if traffic spikes, and version-roll without downtime. In M5 you'll move the container from "running on a server I SSH'd into" to "running as a managed service on AWS ECS". Today's lab is the foundation — get the container running on ECS Fargate. Lab B adds the public URL.

---

## Prerequisites

### 1. The Truck Delay image is in ECR

Verify your M4 ECR repository has at least one image:

```bash
aws ecr describe-images \
    --repository-name truck-delay-app \
    --region us-east-1
```

You should see at least one entry under `imageDetails` with an `imageTag` of `v1`. Note the full image URI — you'll need it in Step 3:

```
<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/truck-delay-app:v1
```

> **Don't have an image yet?** Two options:
> 1. **Run M4 Lab 4** (~20 min including the docker build) — recommended.
> 2. **Pull a course-supplied image from ECR Public**, re-tag, and push into your own private ECR (~2 min):
>    ```bash
>    # No AWS auth needed for the pull — ECR Public is anonymous-readable.
>    docker pull public.ecr.aws/h9p3c4g2/truck-delay-app:v1
>
>    # From here on, use your own private ECR (M5 + later modules push new versions here)
>    docker tag public.ecr.aws/h9p3c4g2/truck-delay-app:v1 \
>              <YOUR_ACCOUNT>.dkr.ecr.us-east-1.amazonaws.com/truck-delay-app:v1
>    aws ecr get-login-password --region us-east-1 \
>        | docker login --username AWS --password-stdin <YOUR_ACCOUNT>.dkr.ecr.us-east-1.amazonaws.com
>    docker push <YOUR_ACCOUNT>.dkr.ecr.us-east-1.amazonaws.com/truck-delay-app:v1
>    ```
>    `h9p3c4g2` is the K21 Academy course instructor's ECR Public alias for this cohort — the image is anonymous-readable so no AWS account or login is required to `docker pull` it. If your instructor publishes from a different account, swap in the alias they share.
>
> *(Instructors: see [../INSTRUCTOR_publish_image_to_ECR_Public.md](../INSTRUCTOR_publish_image_to_ECR_Public.md) for the publish + revert procedure. Learners don't need to read it.)*

### 2. AWS CLI permissions

Your IAM user needs at least:

- `AmazonECS_FullAccess`
- `IAMFullAccess` (to create the task execution role in Step 2)
- `AmazonVPCReadOnlyAccess` (to look up the default VPC)
- `CloudWatchLogsFullAccess`

`AdministratorAccess` covers all of these.

### 3. Your account ID + region noted

```bash
aws sts get-caller-identity --query Account --output text
# Returns your 12-digit account ID -- note it as <ACCOUNT_ID>

# Region you've been using throughout M3/M4 — usually us-east-1
export AWS_REGION=us-east-1
```

---

## Step 1: Create the ECS cluster

A **cluster** in ECS is just a logical group of compute. For Fargate launches the cluster doesn't represent any real EC2 instances — it's a namespace for your services and tasks.

### Console clicks

1. AWS Console → search **ECS** → open the **Elastic Container Service** dashboard.
2. Left sidebar → **Clusters** → top-right **Create cluster**.
3. Fill in the form:

| Field | Value | Why |
|---|---|---|
| Cluster name | `m5-truck-delay-cluster` | Matches the convention used in the rest of M5 |
| Infrastructure | **AWS Fargate (serverless)** | No EC2 to manage. AWS provisions compute on demand per task. |
| Monitoring | (leave default) | Container Insights costs extra; not needed for this lab. |
| Tags | (optional) — `Project=m5-truck-delay` | Helpful for cost allocation later |

4. **Create** (orange button, bottom-right).

`[SCREENSHOT: ECS "Create cluster" form with Fargate selected and the cluster name filled in]`

### CLI alternative (one command)

```bash
aws ecs create-cluster \
    --cluster-name m5-truck-delay-cluster \
    --region us-east-1
```

### Verify

```bash
aws ecs list-clusters --region us-east-1
```

Expected: an entry like `arn:aws:ecs:us-east-1:<ACCOUNT_ID>:cluster/m5-truck-delay-cluster`.

### Fargate vs EC2 — when to pick which

| Aspect | Fargate (what we're using) | EC2 launch type |
|---|---|---|
| Compute management | AWS provisions / patches / scales | You manage the underlying EC2 fleet |
| Pricing | Pay per-second per-vCPU + per-GB-memory | Pay per-EC2-instance (whether used or not) |
| Cold-start | A few seconds at task start | Slightly faster if instance is already warm |
| GPU support | Limited (only specific Fargate types) | Full — pick any EC2 GPU instance type |
| Best for | Stateless web/API workloads (this is us) | Long-running stateful tasks, GPU workloads, custom kernels |

For Streamlit at low-to-medium scale, Fargate is the right default. We pay for what we use, and AWS handles patching.

---

## Step 2: Create the ECS Task Execution Role

The task execution role is the IAM identity that ECS itself uses to:
- Pull the container image from ECR
- Send container logs to CloudWatch Logs
- Read secrets from Secrets Manager / SSM (if your task has any)

This is **not** the same as the "task role" (which the application inside the container would assume — we'll add that in M6 when the app needs to read S3 / SNS).

### Check if it already exists

If you went through some of the AWS-managed quickstart flows, AWS may have created `ecsTaskExecutionRole` automatically. Check:

> **🪟 Windows PowerShell:** replace `2>&1 | head -5` with `2>&1 | Select-Object -First 5`. On Git Bash / WSL / macOS / Linux the original works as-is.

```bash
aws iam get-role --role-name ecsTaskExecutionRole 2>&1 | head -5
```

If you see `arn:aws:iam::<ACCOUNT_ID>:role/ecsTaskExecutionRole`, skip to Step 3. If the call returns `NoSuchEntity`, create it:

### Console clicks

1. AWS Console → search **IAM** → **Roles** (left sidebar) → **Create role**.
2. **Trusted entity type** → **AWS service** → **Use case: Elastic Container Service** → pick **Elastic Container Service Task** (NOT the `EC2 Container Service` option).
3. **Next**. Search and tick: **`AmazonECSTaskExecutionRolePolicy`** (a managed policy).
4. **Next**. Role name: `ecsTaskExecutionRole` (exact spelling — AWS docs use this name).
5. **Create role**.

### CLI alternative

> **🪟 Windows PowerShell users:** the bash here-doc below (`cat > file <<'EOF'`) is not valid PowerShell. Use either (a) Git Bash / WSL for this block, or (b) save the JSON manually to `ecs-trust-policy.json` in your current directory with Notepad / VS Code and skip the `cat` line. Then point `--assume-role-policy-document` at `file://ecs-trust-policy.json` (relative path) instead of `file:///tmp/...`.

```bash
# Trust policy: who can assume this role (only ECS tasks)
cat > /tmp/ecs-trust-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ecs-tasks.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

aws iam create-role \
    --role-name ecsTaskExecutionRole \
    --assume-role-policy-document file:///tmp/ecs-trust-policy.json

aws iam attach-role-policy \
    --role-name ecsTaskExecutionRole \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
```

### What the `AmazonECSTaskExecutionRolePolicy` grants

It's a small, scoped policy. Worth reading once:

- `ecr:GetAuthorizationToken` + `ecr:BatchGetImage` + `ecr:GetDownloadUrlForLayer` — pull images from any ECR in this account.
- `logs:CreateLogStream` + `logs:PutLogEvents` — write container logs to CloudWatch.

Nothing else. Specifically, the task execution role does NOT grant your container access to S3, RDS, or any other AWS resource — those go in the (separate) **task role** when needed.

---

## Step 3: Write the Task Definition

A task definition is a JSON document that describes:
- Which container image(s) to run
- How much CPU + memory each task gets
- Port mappings + environment variables
- Where to send logs
- Which IAM roles to use

This is the "recipe" — ECS uses it to launch concrete tasks.

### Create `truck-delay-task.json` on your laptop

```json
{
  "family": "truck-delay-task",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "512",
  "memory": "1024",
  "executionRoleArn": "arn:aws:iam::<ACCOUNT_ID>:role/ecsTaskExecutionRole",
  "containerDefinitions": [
    {
      "name": "truck-delay-app",
      "image": "<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/truck-delay-app:v1",
      "essential": true,
      "portMappings": [
        {
          "containerPort": 8501,
          "protocol": "tcp"
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/truck-delay-service",
          "awslogs-region": "us-east-1",
          "awslogs-stream-prefix": "ecs",
          "awslogs-create-group": "true"
        }
      }
    }
  ]
}
```

Replace `<ACCOUNT_ID>` with your 12-digit account ID (twice — once in `executionRoleArn` and once in `image`).

### What each field does

| Field | Meaning |
|---|---|
| `family` | Logical name for this task definition. New revisions share the family; `family:1`, `family:2`, etc. |
| `networkMode: awsvpc` | Each task gets its own ENI (private IP) in the VPC. Required for Fargate. |
| `requiresCompatibilities: ["FARGATE"]` | Tells ECS this task can only run on Fargate (not EC2 launch type). |
| `cpu: "512"` | 0.5 vCPU. Fargate accepts 256/512/1024/2048/4096. |
| `memory: "1024"` | 1 GB. Must be a valid pairing with CPU (e.g. 512 CPU supports 1024–4096 MB). |
| `executionRoleArn` | The IAM role from Step 2 that ECS uses to pull the image + write logs. |
| `containerDefinitions[].image` | Full ECR URI including the tag. ECS pulls this on every task launch. |
| `portMappings[].containerPort` | Port the container listens on inside the container's network namespace. Streamlit defaults to 8501. |
| `logConfiguration.awslogs-create-group: "true"` | Tells ECS to create the CloudWatch log group if it doesn't exist. |

> **Why no `environment` block?** The M4 image is **self-contained** — it loads the trained `.pkl` artifacts that were baked into the image at build time (see `Module 4/labs/M4_Lab3_Docker_Compose/app/artifacts/`). It does not connect to RDS, S3, or MLflow at startup, so there are no runtime env vars to set. Later modules (M6 onwards) will add `environment` entries when the app needs DB endpoints, feature-store URIs, or secrets.

### Register the task definition

```bash
aws ecs register-task-definition \
    --cli-input-json file://truck-delay-task.json \
    --region us-east-1
```

Expected output (key fields):

```json
{
  "taskDefinition": {
    "taskDefinitionArn": "arn:aws:ecs:us-east-1:<ACCOUNT_ID>:task-definition/truck-delay-task:1",
    "family": "truck-delay-task",
    "revision": 1,
    "status": "ACTIVE",
    ...
  }
}
```

The `:1` at the end is the **revision number**. Every time you re-run `register-task-definition`, you get a new revision — `:2`, `:3`, etc. This is how ECS supports rollback (just point the service at an older revision).

---

## Step 4: Note your default VPC + subnets + security group

ECS Fargate tasks run in a VPC. Easiest path: use your account's default VPC.

> **🪟 Windows PowerShell:** `tr` doesn't exist on Windows; use `-replace "`t", ","` instead, and `$(...)` becomes `$(...)` natively. PowerShell variant directly below the bash block.

**Bash (Git Bash / WSL / macOS / Linux):**

```bash
# Default VPC ID
VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" --output text \
    --region us-east-1)
echo "VPC: $VPC_ID"

# Subnets in the default VPC (we'll use these) -- comma-joined for the --network-configuration shorthand
SUBNETS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "Subnets[].SubnetId" --output text \
    --region us-east-1 | tr '\t' ',')
echo "Subnets: $SUBNETS"

# Default SG (we'll create a more scoped one in Lab B)
SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=default" \
    --query "SecurityGroups[0].GroupId" --output text \
    --region us-east-1)
echo "SG: $SG_ID"
```

**PowerShell:**

```powershell
$VPC_ID = aws ec2 describe-vpcs `
    --filters "Name=isDefault,Values=true" `
    --query "Vpcs[0].VpcId" --output text --region us-east-1
"VPC: $VPC_ID"

$SUBNETS = (aws ec2 describe-subnets `
    --filters "Name=vpc-id,Values=$VPC_ID" `
    --query "Subnets[].SubnetId" --output text --region us-east-1) -replace "`t", ","
"Subnets: $SUBNETS"

$SG_ID = aws ec2 describe-security-groups `
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=default" `
    --query "SecurityGroups[0].GroupId" --output text --region us-east-1
"SG: $SG_ID"
```

Write these three values down (or keep the shell open). Step 5 needs them.

### Quick security-group tweak for Lab A testing

The default security group blocks inbound 8501. Add a temporary rule so you can hit the Fargate task's private IP from a debugging EC2:

```bash
aws ec2 authorize-security-group-ingress \
    --group-id $SG_ID \
    --protocol tcp \
    --port 8501 \
    --cidr 0.0.0.0/0 \
    --region us-east-1
```

> **Security note:** `0.0.0.0/0` is "the entire internet". For Lab A this is fine because (a) Fargate tasks get private IPs by default — only reachable from inside the VPC, and (b) we'll tear down at the end of the session. In Lab B you'll restrict 8501 to "only from the ALB".

---

## Step 5: Run the task as an ECS Service

A **service** is the long-running construct that keeps your task definition running. If a task crashes, the service starts a new one. If you change the task definition revision, the service does a rolling update.

> **Service vs Task:**
> - `run-task` launches one task once; if it crashes, you're done.
> - `create-service` keeps `desired-count` tasks running forever, replacing any that die.
>
> For a dashboard, you want a service. For a one-shot batch job, you'd use `run-task` (or the batch job equivalent).

### Create the service (CLI)

```bash
aws ecs create-service \
    --cluster m5-truck-delay-cluster \
    --service-name truck-delay-service \
    --task-definition truck-delay-task:1 \
    --desired-count 1 \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SG_ID],assignPublicIp=ENABLED}" \
    --region us-east-1
```

The `assignPublicIp=ENABLED` matters: it gives the Fargate task a public IP so it can pull the image from ECR. (Alternative: put the task in a private subnet with a NAT gateway. Public IP is simpler for Lab A; we'll add a NAT gateway / private subnets in a later module.)

Expected output: a JSON blob with `serviceArn`, `status: ACTIVE`, `desiredCount: 1`, `runningCount: 0` (it takes ~30-60 seconds to provision).

### Watch the service come up

```bash
aws ecs describe-services \
    --cluster m5-truck-delay-cluster \
    --services truck-delay-service \
    --query "services[0].{Desired:desiredCount, Running:runningCount, Pending:pendingCount, Events:events[0:3].message}" \
    --region us-east-1
```

Expected progression (re-run every 10 seconds):

```
Pending=1, Running=0   ← task is being provisioned (ENI attaching, image pulling)
Pending=0, Running=1   ← it's up
```

The `Events` field shows ECS's most recent service activity. Useful when things go wrong (e.g., "unable to pull image" or "task stopped due to OutOfMemory").

---

## Step 6: Find the task's public IP

Each Fargate task has its own ENI with a public IP (because we set `assignPublicIp=ENABLED`).

```bash
# Get the task ARN
TASK_ARN=$(aws ecs list-tasks \
    --cluster m5-truck-delay-cluster \
    --service-name truck-delay-service \
    --query "taskArns[0]" --output text \
    --region us-east-1)
echo "Task: $TASK_ARN"

# Find the ENI attached to this task
ENI_ID=$(aws ecs describe-tasks \
    --cluster m5-truck-delay-cluster \
    --tasks $TASK_ARN \
    --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value | [0]" \
    --output text \
    --region us-east-1)
echo "ENI: $ENI_ID"

# Get the ENI's public IP
PUBLIC_IP=$(aws ec2 describe-network-interfaces \
    --network-interface-ids $ENI_ID \
    --query "NetworkInterfaces[0].Association.PublicIp" \
    --output text \
    --region us-east-1)
echo "Public IP: $PUBLIC_IP"

echo ""
echo "==> Streamlit dashboard: http://$PUBLIC_IP:8501"
```

Open `http://$PUBLIC_IP:8501` in your browser. You should see the FreshBasket Delivery Delay Predictor — a 3-column form (🛣️ Trip & Route Info / 🚛 Driver & Truck Info / 🌤️ Weather Conditions) with a "Predict Delay Risk" button. Fill in sample values and submit to confirm the model returns a prediction.

`[SCREENSHOT: Browser showing the FreshBasket Delivery Delay Predictor at http://<PUBLIC_IP>:8501 with the form visible]`

> **Why no `DEMO_MODE` or external connections in this lab?** The M4 image is fully self-contained: the trained `.pkl` artifacts are baked into the image (`/app/artifacts/`), and the app loads them at startup with no AWS calls. So proving "the container runs on ECS and serves traffic" is just "submit the form and get a prediction back." Later modules add task-role permissions when the app actually needs to read S3 / RDS / MLflow.

---

## Step 7: View CloudWatch Logs

When something goes wrong, the logs are your first stop.

### Console

1. AWS Console → **CloudWatch** → **Log groups** (left sidebar).
2. Find `/ecs/truck-delay-service` (created automatically by the `awslogs-create-group: "true"` setting in the task definition).
3. Click into the group → click the most recent log stream (named like `ecs/truck-delay-app/<task-id>`).
4. You should see Streamlit's startup messages:
   ```
   You can now view your Streamlit app in your browser.
   URL: http://0.0.0.0:8501
   ```

`[SCREENSHOT: CloudWatch Log stream showing Streamlit startup output]`

### CLI

```bash
aws logs tail /ecs/truck-delay-service \
    --follow \
    --region us-east-1
```

The `--follow` flag tails in real-time. Hit Ctrl-C to stop. Useful when debugging "why does my task keep dying" — you'll see the Python traceback at task exit.

---

## Verification Checklist

Before you move on to Lab B:

- [ ] `aws ecs describe-services` shows `runningCount: 1, desiredCount: 1`
- [ ] Browser at `http://<PUBLIC_IP>:8501` shows the FreshBasket Delivery Delay Predictor form
- [ ] Submitting the form returns a prediction (on-time / at-risk + probability) — confirms the baked-in `.pkl` artifacts loaded correctly
- [ ] CloudWatch Logs at `/ecs/truck-delay-service` shows Streamlit's startup output
- [ ] You can run `aws ecs describe-task-definition --task-definition truck-delay-task` and see your registered task definition

If any of these fail, see the **Troubleshooting** section below before moving to Lab B.

---

## What's next — Lab B

The task is running, but reaching it requires looking up its public IP every time (which changes whenever the task restarts). Lab B puts an **Application Load Balancer** in front so:
1. There's a stable DNS name (`http://truck-delay-alb-xxxx.<region>.elb.amazonaws.com`) — survives task restarts
2. The ALB does health checks and routes traffic only to healthy tasks
3. You can scale `desired-count` to N and the ALB load-balances across them

Lab B also tightens the security group so only the ALB can reach port 8501 on the tasks (no longer `0.0.0.0/0`).

---

## Troubleshooting

| Symptom | Diagnosis | Fix |
|---|---|---|
| `pendingCount: 1` for more than 2 minutes | Image pull is failing (no internet, wrong URI, no ECR perms) | Check Events: `aws ecs describe-services ... --query "services[0].events"`. Common: subnet has no internet route → use `assignPublicIp=ENABLED` |
| Task starts, runs for ~30 s, then exits | App crashed | Check CloudWatch Logs for the Python traceback. Most common: missing `--server.address=0.0.0.0` in the Dockerfile CMD (revisit M4 Lab 1) |
| `CannotPullContainerError` in Events | ECS task can't reach ECR | Confirm the task execution role exists and is correctly named `ecsTaskExecutionRole`; confirm the image URI is exact |
| `ResourceInitializationError: ... no identity-based policy allows ...` | Missing IAM permissions for image pull | The execution role needs `AmazonECSTaskExecutionRolePolicy` attached |
| HTTP request to `<PUBLIC_IP>:8501` hangs | Security group blocks 8501 | Step 4 — `authorize-security-group-ingress` for port 8501 |
| `http://<PUBLIC_IP>:8501` returns "Forbidden" | Streamlit's host-header check rejecting non-localhost | The M3 image should already disable this; if it doesn't, set `--server.headless true --server.enableCORS false` in the container CMD |
| Task definition registration fails: "Invalid memory value" | Memory and CPU must be a valid Fargate pairing | 512 CPU → 1024/2048/3072/4096 MB. See [AWS Fargate compatibility matrix](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/fargate-task-defs.html#fargate-tasks-size) |

---

## Quick reference — commands used in this lab

```bash
# Cluster
aws ecs create-cluster --cluster-name m5-truck-delay-cluster --region us-east-1

# Task definition
aws ecs register-task-definition --cli-input-json file://truck-delay-task.json --region us-east-1

# Service
aws ecs create-service \
    --cluster m5-truck-delay-cluster \
    --service-name truck-delay-service \
    --task-definition truck-delay-task:1 \
    --desired-count 1 \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SG_ID],assignPublicIp=ENABLED}" \
    --region us-east-1

# Status
aws ecs describe-services --cluster m5-truck-delay-cluster --services truck-delay-service --region us-east-1

# Logs
aws logs tail /ecs/truck-delay-service --follow --region us-east-1

# Find public IP of running task (Step 6 script — paste into your shell)
```

Save this command list. Lab C's GitHub Actions workflow uses essentially these same commands.
