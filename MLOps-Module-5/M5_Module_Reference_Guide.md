# Module 5 — Module Reference Guide

**The AWS services in M5: what they are, why they're there, and how they hang together as one production deployment pipeline.**

> This is the **conceptual KT document** for Module 5. The [Student Manual](M5_Student_Manual.md) tells you *what to click*. The [lab files](labs/) tell you *exactly how to click it*. **This document tells you why** — so when an interviewer asks "Why did you use ECS Fargate?" or "Why is there a load balancer in front of your container?", you can answer from first principles instead of "the curriculum said so".
>
> Read this once before Lab A. Refer back to the **decision tree** (§5) when you can't remember which service to pick. Refer to **interview justifications** (§6) before any deployment-architecture interview.

---

## Table of contents

1. [The one-paragraph problem M5 solves](#1-the-one-paragraph-problem-m5-solves)
2. [The deployment lifecycle as a mental model](#2-the-deployment-lifecycle-as-a-mental-model)
3. [Service-by-service KT (in pipeline order)](#3-service-by-service-kt-in-pipeline-order)
4. [The deployment sequence — what happens when, in order](#4-the-deployment-sequence--what-happens-when-in-order)
5. [The decision tree — when to use what](#5-the-decision-tree--when-to-use-what)
6. [Interview-ready justifications](#6-interview-ready-justifications)
7. [Services NOT in M5 (and which module they arrive in)](#7-services-not-in-m5-and-which-module-they-arrive-in)
8. [15 interview questions (with hints)](#8-15-interview-questions-with-hints)

---

## 1. The one-paragraph problem M5 solves

Coming out of M4, you have a Docker image sitting in ECR. **Nothing is running it.** If you `docker run` the image on your laptop, you get a Streamlit dashboard at `http://localhost:8501` that only you can see, that dies when you close the terminal, and that has no path to "Priya in ops can also reach this." Module 5 closes that gap: it turns the static ECR image into a **continuously running, publicly addressable, self-healing, auto-redeploying production service**. Every AWS service introduced in M5 exists to solve one specific failure mode in that journey — and they only make sense if you can name the failure mode each one prevents.

---

## 2. The deployment lifecycle as a mental model

A production container deployment has **six phases**. Every AWS service in M5 belongs to exactly one of them. If you understand which phase a service serves, you understand why it's there.

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                                                                              │
│   Phase 1          Phase 2          Phase 3          Phase 4                 │
│   ───────          ───────          ───────          ───────                 │
│   SOURCE     ─►    BUILD      ─►    REGISTRY   ─►    COMPUTE                 │
│                                                                              │
│   GitHub           GitHub Actions    ECR              ECS Fargate            │
│                    or CodeBuild      (M4-provided)    (Lab A)                │
│                    (Labs C, D)                                               │
│                                                                              │
│                                                              │               │
│                                                              ▼               │
│                                                                              │
│   Phase 5                              Phase 6                               │
│   ───────                              ───────                               │
│   NETWORKING & TRAFFIC          ─►     OBSERVABILITY & AUTOMATION           │
│                                                                              │
│   VPC + Subnets + Security              CloudWatch Logs (Lab A)              │
│   Groups + ALB + Target Group           IAM (everywhere)                     │
│   + Listener (Lab B)                    CodePipeline orchestration (Lab D)   │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

Every M5 lab is "fill in one phase":

| Lab | Fills phase | Result |
|---|---|---|
| **A** | Compute + (partial) Observability | Container running on Fargate, logs reaching CloudWatch |
| **B** | Networking & Traffic | Public URL via ALB + health checks |
| **C** | Build + (re)Compute via GitHub Actions | Every `git push` → new ECS rollout |
| **D** | Build + (re)Compute via AWS-native | Same thing, AWS-native CI/CD chain |
| **E** | (Alternative) Build + Compute via BentoML | Different packaging pattern for an ML API |
| **F** | (Alternative) Compute via Kubernetes | What the same job looks like on K8s |
| **Branch** | All six phases on a different project + Terraform | End-to-end repeat under a different IaC tool |

---

## 3. Service-by-service KT (in pipeline order)

Each section follows the same format:

- **What it is** — one-line definition
- **Problem it solves in M5** — the specific pain it removes
- **What hurts without it** — the failure mode you'd hit if you skipped it
- **Why this AWS service vs alternatives** — the choice you're defending
- **Where in M5** — exact lab reference
- **What it depends on / what depends on it** — its place in the chain

### 3.1 ECR — Elastic Container Registry

| Field | Value |
|---|---|
| **Phase** | 3 — Registry |
| **What it is** | A private, IAM-controlled Docker image registry, AWS-managed |
| **Problem it solves** | "Where does the production image live, such that ECS can pull it without leaking credentials?" |
| **Without it** | You'd push to Docker Hub (rate limits, public-by-default risk) or run your own registry (you maintain it) |
| **Why ECR vs Docker Hub / GHCR** | IAM-native pulls (no `docker login` secrets to manage), private by default, lives in the same account as ECS, no egress cost to ECS in the same region |
| **Where in M5** | Used by every spine lab. *Provisioned in M4 Lab 4 — M5 only consumes it.* |
| **Depends on** | IAM (for push/pull permissions) |
| **Depended on by** | ECS task definition (the `image` field), CI/CD (push step) |

### 3.2 IAM — Identity and Access Management

| Field | Value |
|---|---|
| **Phase** | Cross-cutting (every phase) |
| **What it is** | AWS's authentication + authorisation layer. Identities (users, roles) and policies (permissions). |
| **Problem it solves** | "Who/what is allowed to pull this image, push logs, update this service?" |
| **Without it** | Either everything fails (no permissions) or you grant `*:*` to everything (terrifying) |
| **Why IAM** | It's not optional. Every AWS API call resolves to IAM. The skill is choosing the *right* identity for each task. |
| **Where in M5** | Four distinct identities you create or use: |

The four IAM identities in M5 — *know what each one does and why they have to be different*:

| Identity | Created in | What it can do | Why it's separate |
|---|---|---|---|
| **`ecsTaskExecutionRole`** | Lab A Step 2 | Pull image from ECR + write logs to CloudWatch | Used by **ECS itself** (the control plane), not your app code |
| **Task Role** (optional, not in M5) | — | Whatever your app needs (S3, RDS, SNS, ...) | Used by **the app inside the container**. M5's app needs nothing, so this stays empty. M6 adds it. |
| **`github-actions-deploy` IAM user** | Lab C Step 1 | `ecr:Push*`, `ecs:UpdateService`, `ecs:RegisterTaskDefinition` | Used by **GitHub's runners** to deploy. Has long-lived access keys (less secure — the OIDC sidebar shows the better path). |
| **CodeBuild + CodePipeline service roles** | Lab D Steps 2 + 4 | Same actions, but consumed by AWS services, not external | Used by **AWS services calling other AWS services** — no access keys, just role assumption. |

**The principle**: each identity is scoped to the *fewest* permissions the task needs. The execution role can't push images. The CI user can't read your production database. If any one identity leaks, the blast radius is contained.

### 3.3 VPC + Subnets

| Field | Value |
|---|---|
| **Phase** | 5 — Networking |
| **What it is** | A private virtual network in your AWS account. Subnets are slices of it, each tied to one Availability Zone (AZ). |
| **Problem it solves** | "What network does my Fargate task live in, and how does the ALB reach it?" |
| **Without it** | Fargate has no choice — it needs to live somewhere. AWS won't let you skip the VPC. |
| **Why the *default* VPC?** | Class simplicity. The default VPC has one public subnet per AZ already created, with an internet gateway attached. No NAT gateway, no route table juggling. Real production = custom VPC with public subnets for the ALB and private subnets for the tasks. |
| **Where in M5** | Lab A Step 4 (look it up), Lab B Step 3 (place ALB in 2 of the subnets across AZs) |
| **Depends on** | Nothing |
| **Depended on by** | Everything in M5 that runs in AWS |

**Why "2 subnets across AZs" for the ALB**: ALBs are zonal — they live in a specific AZ. To survive an AZ outage, you need the ALB nodes spread across at least 2. That's also the AWS requirement (their API rejects a single-subnet ALB).

### 3.4 EC2 Security Groups

| Field | Value |
|---|---|
| **Phase** | 5 — Networking |
| **What it is** | Stateful virtual firewalls that wrap an ENI. Define which IPs/ports can talk to which IPs/ports. |
| **Problem it solves** | "How do I expose port 80 on the ALB to the world but NOT expose port 8501 on the tasks?" |
| **Without it** | Either nothing is reachable (default deny) or everything is reachable (terrifying) |
| **Why SGs vs NACLs** | SGs are stateful (reply traffic auto-allowed), reference each other (SG-to-SG rules — the "ALB SG → Task SG" pattern), and apply per-ENI. NACLs are stateless and subnet-wide. SGs are the right tool for service-level rules. |
| **Where in M5** | Lab A Step 4 (temporary wide-open rule for testing), Lab B Step 2 (ALB SG), Lab B Step 6 (lock task SG so only ALB can reach 8501) |
| **The pattern to remember** | `ALB SG: 0.0.0.0/0 → 80`. `Task SG: ALB-SG → 8501`. Tasks are never directly reachable from the internet. |

### 3.5 CloudWatch Logs

| Field | Value |
|---|---|
| **Phase** | 6 — Observability |
| **What it is** | Managed log aggregation. Containers write to stdout/stderr → ECS forwards to a log group. |
| **Problem it solves** | "When the task crashes at 3 AM, where do I find the Python traceback?" |
| **Without it** | The crashed task takes its logs to the grave. You stare at "task stopped" in the ECS Console with no idea why. |
| **Why CloudWatch Logs vs an ELK stack vs Loki** | Zero-setup. The `awslogs` log driver is built into ECS; one line of task-definition config (`awslogs-create-group: true`) and logs flow. ELK/Loki are better at scale but need operators. |
| **Where in M5** | Lab A Step 3 (task definition `logConfiguration`), Lab A Step 7 (tail the logs) |
| **Depends on** | `ecsTaskExecutionRole` having `logs:CreateLogStream` + `logs:PutLogEvents` (the managed policy grants both) |
| **Cost note** | Free tier covers small workloads. Watch out in M6+ when you'll have multiple services logging. |

### 3.6 ECS — Elastic Container Service (Fargate launch type)

| Field | Value |
|---|---|
| **Phase** | 4 — Compute |
| **What it is** | AWS's container orchestrator. Schedules containers, restarts crashed ones, does rolling updates. Fargate = the serverless launch type (no EC2 to manage). |
| **Problem it solves** | "Run this container as a service: keep N copies alive forever, restart any that die, and replace them when I push a new version." |
| **Without it** | You'd be running `docker run` on an EC2 instance, manually restarting it after crashes. Or running k8s. Or running Nomad. You need *something* to do this job. |
| **Why ECS vs EKS (Kubernetes)** | Lower ops burden, lower learning curve, sufficient for stateless web/API workloads, AWS-native (one less tool to install). EKS is the right call when you're multi-cloud or need the K8s ecosystem. See [Lab F](labs/M5_Lab_F_Kubernetes_Minikube.md). |
| **Why Fargate vs ECS-on-EC2** | No EC2 fleet to patch, autoscale, or pay for during idle. Pay per task-second only. Tradeoff: limited GPU support and ~10s cold-start vs warm EC2. For Streamlit, Fargate wins. |
| **Where in M5** | Lab A — cluster, task definition, service. Lab B — service updated to register with target group. |
| **Three concepts to keep straight** | **Cluster** = namespace. **Task definition** = the recipe (image, CPU, memory). **Service** = the long-running supervisor (desired count, rolling updates, auto-restart). A task by itself runs once and dies; a service keeps tasks alive. |

### 3.7 ELB v2 — ALB, Target Group, Listener

These are three resources but one job, so think of them as one unit.

| Field | Value |
|---|---|
| **Phase** | 5 — Networking |
| **What they are** | **ALB** = the L7 reverse proxy (HTTP/HTTPS). **Target Group** = the pool of backends. **Listener** = the rule that says "port 80 → forward to this target group". |
| **Problem they solve** | "Give my service a stable public DNS, distribute traffic across N tasks, remove unhealthy tasks from rotation, and survive AZ failures." |
| **Without them** | Every task has a different ephemeral public IP. Restarts change the IP. Two tasks = two URLs. No health-aware routing. |
| **Why ALB vs NLB vs CloudFront** | ALB is L7 (HTTP-aware) — can route by path, host, headers; native target-group health checks; supports WebSockets (Streamlit needs them); is the standard for ECS Fargate services. NLB is L4 (TCP only, faster, no routing logic). CloudFront is a CDN — different layer, often *in front of* an ALB. |
| **Where in M5** | Lab B (everything) |
| **The interlock with ECS** | When ECS launches a task, it auto-registers the task's private IP into the target group. When the task is stopped (rolling update, crash, scale-down), ECS auto-deregisters it. You never touch target-group membership manually. |

**Why `target type = ip` not `instance`**: Fargate runs on AWS-managed compute — there's no EC2 instance ID for the ALB to address. The ALB has to route to the task's private IP directly. `instance` target type only works for ECS-on-EC2.

**Why the health check path is `/_stcore/health`**: Streamlit's built-in health endpoint. Returns 200 immediately, no session state. If you used `/`, the health check would trigger Streamlit's full app render — slow on cold start, would mark targets unhealthy during legitimate slow renders. Pick the right health endpoint for the framework.

### 3.8 GitHub Actions (not AWS, but bridges into AWS)

| Field | Value |
|---|---|
| **Phase** | 2 — Build, plus triggers 4 — Compute (the redeploy) |
| **What it is** | GitHub's built-in CI/CD runner. YAML workflows in `.github/workflows/`. |
| **Problem it solves** | "Every `git push` to `main` should automatically rebuild the image, push to ECR, and roll out a new ECS task definition — without me clicking anything." |
| **Without it** | You're manually running `docker build && docker push && aws ecs update-service` every time you change a line of code. People forget. People mistype tags. People deploy to the wrong account. |
| **Why GH Actions vs CodePipeline** | Lower friction if your code already lives on GitHub. Free for public repos / 2000 min for private. Workflow file lives in the repo (code-reviewed). See the head-to-head in [Lab D §"GitHub Actions vs CodePipeline"](labs/M5_Lab_D_CodePipeline_Alternative.md#github-actions-vs-codepipeline--when-to-pick-which). |
| **Where in M5** | Lab C |
| **How it auths to AWS** | Either (a) static IAM access keys in GitHub Secrets — fast, less secure, or (b) OIDC federation via `sts:AssumeRoleWithWebIdentity` — production-grade. Strategy A is the main path in Lab C, Strategy B is the sidebar. |

### 3.9 CodePipeline — AWS-native CI/CD orchestrator

| Field | Value |
|---|---|
| **Phase** | 2 + 4 (orchestrates both) |
| **What it is** | AWS's CI/CD orchestration service. Stages (Source → Build → Deploy) with actions in each. |
| **Problem it solves** | Same problem as GitHub Actions, but for teams that want everything inside the AWS Console with IAM-role auth instead of stored secrets. |
| **Why CodePipeline vs GH Actions** | All-in-AWS teams; regulated environments where logs must live in CloudWatch; built-in manual approval actions; multi-account deploys via cross-account roles. |
| **Where in M5** | Lab D |
| **The 3 stages in M5's pipeline** | **Source**: poll GitHub via CodeStar Connection. **Build**: invoke CodeBuild project. **Deploy**: ECS deployer reads `imagedefinitions.json` from the build artifact and updates the service. |

### 3.10 CodeBuild — managed build service

| Field | Value |
|---|---|
| **Phase** | 2 — Build |
| **What it is** | A managed builder. Spins up a container, runs your `buildspec.yml`, throws the container away. |
| **Problem it solves** | "I need somewhere to run `docker build` + `docker push` in the cloud, with AWS IAM creds already on the container, so I'm not running it on my laptop." |
| **Why CodeBuild vs a self-hosted Jenkins** | Zero infra to maintain. Pay per minute of build time. IAM-native (no stored creds). |
| **Where in M5** | Lab D |
| **Three things that always trip people up** | (1) **"Privileged" must be enabled** or `docker build` can't talk to a daemon. (2) The auto-created service role doesn't include ECR push permissions — you have to attach them manually (Lab D Step 3). (3) The `buildspec.yml` must emit `imagedefinitions.json` — that's the artifact CodePipeline's deploy stage reads to know which image to deploy. |

### 3.11 CodeStar Connections

| Field | Value |
|---|---|
| **Phase** | 1 — Source (bridge to GitHub) |
| **What it is** | An AWS-managed OAuth link to GitHub (also Bitbucket, GitLab). |
| **Problem it solves** | "How does CodePipeline read commits from a private GitHub repo without me handing it a long-lived personal access token?" |
| **Why this vs a PAT** | OAuth, short-lived tokens under the hood, finer repo scoping (install the GitHub App on specific repos only), no secret to rotate. PATs are the old-style "GitHub V1" source and CodePipeline still supports them but you shouldn't. |
| **Where in M5** | Lab D Prerequisites + Step 4 (Source stage) |

### 3.12 S3 (for CodePipeline artifacts)

| Field | Value |
|---|---|
| **Phase** | 2/4 — handoff between stages |
| **What it is** | AWS object storage. |
| **Problem it solves** | "CodePipeline's Build stage produces an output (the image URI + the `imagedefinitions.json`) that the Deploy stage needs to read. They run in different runners — where does the file live between them?" |
| **Why S3** | It's the universal artifact store AWS uses internally. CodePipeline auto-creates the bucket on first run; you never touch it. |
| **Where in M5** | Lab D — implicit (auto-provisioned). Branch project — *explicit* use as the Terraform state backend. |
| **The cost gotcha** | Don't forget to empty + delete the auto-created bucket during teardown (Lab D Teardown step 3). |

### 3.13 KMS (default AWS Managed Key)

| Field | Value |
|---|---|
| **Phase** | Cross-cutting (encryption at rest) |
| **What it is** | AWS's key management service. The "default AWS Managed Key" is a free, AWS-owned key you don't manage. |
| **Problem it solves** | "The CodePipeline artifact bucket holds build outputs that might include sensitive paths/configs. Are those encrypted at rest?" |
| **Why default key vs Customer-Managed Key (CMK)** | Default is free, zero-config, sufficient for class. CMKs give you per-key audit trail and cross-account access control — real production for sensitive data. |
| **Where in M5** | Lab D Step 4 (pipeline settings — left as default). |

### 3.14 STS + IAM OIDC Identity Provider (Lab C sidebar — optional, but interview-relevant)

| Field | Value |
|---|---|
| **Phase** | Cross-cutting (auth) |
| **What they are** | **STS** = Security Token Service — vends short-lived credentials. **IAM OIDC Provider** = a trust relationship between AWS and an external OIDC issuer (GitHub Actions in this case). |
| **Problem they solve** | "How do I give GitHub Actions AWS permissions *without* storing a permanent access key in GitHub Secrets?" |
| **How it works** | GitHub Actions presents a signed JWT to AWS STS via `AssumeRoleWithWebIdentity`. STS verifies the JWT against the OIDC provider's public keys and returns 1-hour credentials. No long-lived secret anywhere. |
| **Why this matters** | Leaked GitHub Secrets are the #1 source of AWS account compromises in 2023–2025 breach reports. OIDC removes the long-lived secret entirely. |
| **Where in M5** | Lab C Step 7 sidebar |

### 3.15 Secrets Manager / SSM Parameter Store (mentioned, not used)

| Field | Value |
|---|---|
| **What they are** | Managed secret + config stores. The `ecsTaskExecutionRole` is pre-authorised to read from both into container environment variables. |
| **Why mentioned now** | So you know the slot exists in the task definition spec. M5's self-contained image needs no secrets, so the slot stays empty. |
| **First real use** | M6 — when the app starts calling RDS / MLflow / SNS, the connection strings will come from Parameter Store, *not* hard-coded into the task definition. |

### 3.16 Branch project (Terraform): additions

The Branch project re-implements the spine on a different domain (Customer Churn — Banking) using Terraform. Same services as the spine, with three additions worth knowing:

| Service | Purpose | Why it's in the Branch and not the spine |
|---|---|---|
| **S3 + Versioning** (`tf-state-churn-*`) | Terraform state backend | Spine uses CDK → state lives in CloudFormation, AWS-managed. Terraform's state is a file *you* manage; S3 + versioning is the standard backend for team use. |
| **ECS Capacity Providers** (`FARGATE` + `FARGATE_SPOT`) | Lets you mix Fargate Spot (~70% cheaper, can be interrupted) with on-demand Fargate | Demonstrates that Terraform exposes lower-level ECS controls than the AWS Console's "Create cluster" wizard. Spot is a real cost-optimisation lever in production. |
| **`aws_cloudwatch_log_group` resource** (explicit) | Log group created as a Terraform resource | Spine uses `awslogs-create-group: true` (implicit creation). Terraform-managed resources should be explicit — you want `terraform destroy` to clean them up. |

---

## 4. The deployment sequence — what happens when, in order

This is the chronological narrative. Memorise this sequence. If you can recite it in an interview without looking, you understand M5.

```
0. PREREQUISITE (from M4)
   The Truck Delay container image lives in ECR as
   <account>.dkr.ecr.<region>.amazonaws.com/truck-delay-app:v1

1. CREATE COMPUTE (Lab A, Step 1)
   ECS cluster `m5-truck-delay-cluster` — just a namespace. No compute yet.

2. CREATE THE IDENTITY ECS NEEDS (Lab A, Step 2)
   IAM role `ecsTaskExecutionRole` with the managed policy
   AmazonECSTaskExecutionRolePolicy. ECS uses this role to pull
   from ECR and write to CloudWatch.

3. DEFINE THE WORKLOAD (Lab A, Step 3)
   Task definition `truck-delay-task:1` — JSON document saying
   "0.5 vCPU, 1 GB, pull THIS image, expose port 8501, log to /ecs/truck-delay-service".

4. CONFIRM THE NETWORK (Lab A, Step 4)
   Note the default VPC, its subnets across AZs, default SG.

5. RUN IT AS A SERVICE (Lab A, Step 5)
   ECS service `truck-delay-service` with desired-count=1, launch-type=FARGATE,
   assigning public IPs so the task can pull from ECR.
   → A task starts. CloudWatch Logs start flowing. You can reach
     http://<task-public-ip>:8501 but the IP is ephemeral.

6. PUT A LOAD BALANCER IN FRONT (Lab B, Steps 1-3)
   Target group `truck-delay-tg` (ip-type, /_stcore/health check).
   ALB `truck-delay-alb` in 2 AZs with a listener on port 80 → target group.
   → ALB DNS exists but no tasks are registered yet.

7. WIRE ECS TO THE TARGET GROUP (Lab B, Step 4)
   `update-service --load-balancers` → ECS does a rolling deploy:
   start a new task that registers with the TG, wait for health, kill the old task.
   → The ALB now routes traffic to the task.

8. LOCK DOWN THE TASK NETWORK (Lab B, Step 6)
   Revoke the wide-open `0.0.0.0/0 → 8501` rule.
   Add `ALB-SG → 8501` instead. Tasks are no longer publicly reachable.

9. AUTOMATE THE REDEPLOY (Lab C — GH Actions, OR Lab D — CodePipeline)
   .github/workflows/deploy.yml (or CodePipeline + buildspec.yml):
     a. Code change pushed to main
     b. Workflow checks out the repo
     c. Auths to AWS (Secret or OIDC for GH; service role for CodePipeline)
     d. Logs into ECR, builds image with commit-SHA tag, pushes
     e. Downloads the current task definition
     f. Renders a new revision with the new image URI
     g. Registers the new revision
     h. Updates the service to use it (rolling deploy)
     i. Waits for steady state

10. THE LOOP NOW CLOSES
    Every subsequent `git push origin main` repeats steps 9b-9i.
    Browser at http://<ALB-DNS> always serves the latest version.
    Zero downtime, zero clicks.

11. TEARDOWN (end of session)
    Scale service to 0 → delete service → delete cluster → delete ALB
    + target group → delete CodePipeline + CodeBuild + artifact bucket.
    Keep ECR (small storage cost; needed in M6+).
```

This is the **only** sequence that matters for the spine. Labs E (BentoML) and F (Kubernetes) don't change this chain — they show *alternative implementations* of phases 2 and 4.

---

## 5. The decision tree — when to use what

When an architecture interview hits you with "we have a containerised ML model and we need to deploy it on AWS — what do you use?", these are the forks in the road.

### Fork 1: ECS vs EKS vs EC2-by-hand vs Lambda

```
Is the workload stateless? (no in-process state, no persistent volumes)
├─ NO  → ECS-on-EC2 / EKS / a bigger conversation
└─ YES
   │
   Is it long-running (>15 min per request) or event-driven (<15 min, sub-second startup OK)?
   ├─ EVENT-DRIVEN, SHORT  → Lambda (different course)
   └─ LONG-RUNNING
      │
      Will the team operate Kubernetes (write manifests, manage Helm, debug etcd)?
      ├─ NO  → ECS (M5's choice)
      └─ YES, AND multi-cloud / K8s ecosystem matters
         → EKS (M5 Lab F sets you up to read manifests)
```

### Fork 2: ECS Fargate vs ECS-on-EC2

```
Do you need GPUs, custom kernels, or persistent local storage?
├─ YES → ECS-on-EC2
└─ NO
   Is utilisation steady ≥70% so you can amortise EC2?
   ├─ YES → ECS-on-EC2 (cheaper per-hour)
   └─ NO  → Fargate (M5's choice — pay only while tasks run)
```

### Fork 3: ALB vs NLB vs CloudFront

```
Layer 7 routing needed (path-based, host-based, header-based)?
├─ YES → ALB (M5's choice — Streamlit needs WebSockets too, ALB supports them)
└─ NO
   Need <1ms latency or millions of RPS?
   ├─ YES → NLB (L4 only)
   └─ NO  → ALB is still fine
   
Is it a content/static workload globally distributed?
└─ Add CloudFront in front of the ALB
```

### Fork 4: GitHub Actions vs CodePipeline

```
Where does the team's source code live, and where do they work day-to-day?
├─ GitHub-centric team → GitHub Actions (M5 Lab C — lower friction)
└─ AWS-centric / regulated team → CodePipeline (M5 Lab D)

Need cross-account deploys + manual approval gates + everything in CloudWatch?
└─ CodePipeline wins
```

### Fork 5: Static IAM keys vs OIDC federation (for CI auth)

```
Is this a personal/learning project?
├─ YES → Static keys are fine (M5 Lab C Strategy A)
└─ NO
   Is this team / production / compliance-sensitive?
   └─ OIDC federation, always (M5 Lab C Strategy B / Step 7 sidebar)
```

### Fork 6: Streamlit vs BentoML vs Flask

See [Lab E §"When to pick BentoML vs hand-rolled Flask vs Streamlit"](labs/M5_Lab_E_BentoML_Serving.md#when-to-pick-bentoml-vs-hand-rolled-flask-vs-streamlit). Short version: framework follows the consumer. Interactive humans → Streamlit. Internal service-to-service APIs → BentoML. Custom routes / middleware → Flask.

### Fork 7: CDK vs Terraform

See the comparison table in [Branch README §"Phase 5"](labs/M5_Branch_Customer_Churn/README.md#phase-5-compare-cdk-vs-terraform-deliverable). Short version: AWS-only team → CDK (real programming language, no state file). Multi-cloud or portfolio-of-providers → Terraform.

---

## 6. Interview-ready justifications

These are sample answers to the questions you *will* be asked. Adapt them to your project but keep the structure: **problem → choice → reason → tradeoff acknowledged**.

### Q: "Why did you use ECS Fargate instead of EC2 or Kubernetes?"

> "The workload is stateless web serving — Streamlit at low-to-medium QPS. ECS Fargate removes the EC2 fleet management entirely: no patching, no autoscaling groups, no idle-time cost. I considered EKS but the team isn't multi-cloud and doesn't have Kubernetes ops experience — the operational overhead would dominate the benefit. EC2 launch type would be cheaper at sustained high utilisation, but our traffic is bursty, so per-second Fargate billing wins on cost. Tradeoff acknowledged: Fargate has ~10s cold-start and limited GPU support — neither matters for this workload."

### Q: "Why is there an ALB in front of your ECS service? Why not just point DNS at the tasks?"

> "Three reasons. **Stable address**: Fargate tasks have ephemeral public IPs that change on every restart — DNS would have to update constantly. The ALB has one persistent DNS name. **Health-aware routing**: the ALB target group hits `/_stcore/health` every 30s and removes unhealthy tasks from rotation automatically, which means a crashed task doesn't serve 503s for the next minute until ECS replaces it. **Multi-AZ**: the ALB lives in 2 AZs and load-balances across tasks in either, so an AZ outage doesn't take the service down. None of this is possible by just exposing task IPs."

### Q: "Why does your ECS task have two different IAM things — the execution role and the task role?"

> "They're for two different actors. The **execution role** is what ECS *itself* uses — pulling the image from ECR, writing container logs to CloudWatch, fetching secrets from Secrets Manager into env vars. The **task role** is what *application code inside the container* assumes when calling AWS APIs. They have to be separate because the principle of least privilege says ECS shouldn't have my app's permissions, and my app shouldn't have ECS-control-plane permissions. In M5 the app makes no AWS calls so the task role is empty. M6 adds it when the app starts reading from RDS."

### Q: "Walk me through what happens when a developer pushes to main."

> *Recite section 4 step 9 verbatim.* "GitHub Actions runner spins up, authenticates to AWS via OIDC, logs into ECR, builds the image with the commit SHA as the tag, pushes both `:sha` and `:latest`, downloads the current task definition, renders a new revision with the new image URI, registers it, calls `ecs:UpdateService` with the new revision and `wait-for-service-stability=true`. ECS does a rolling deploy: starts a new task with the new revision, waits for ALB health check to pass, drains the old task, stops it. End-to-end ~3-5 minutes from push to live. Zero downtime."

### Q: "What's the security boundary around your ECS tasks?"

> "Two layers. **Network**: the task security group only allows port 8501 from the ALB's security group, not from `0.0.0.0/0`. So the tasks have public IPs (to pull from ECR) but nothing on the internet can talk to them directly — only the ALB can. **Identity**: the task execution role has only `AmazonECSTaskExecutionRolePolicy` — image pull + log write, nothing else. No S3, no RDS. The app inside the container has no AWS credentials at all in M5 because it doesn't need any."

### Q: "If you had to redo this with Terraform instead of CLI, what would change?"

> "The end state is identical — ECR + ECS + ALB. What changes is the authoring model. Terraform makes the dependencies between resources explicit (`depends_on`, resource references). It tracks state in a file (in S3 with versioning for team use) so `terraform destroy` cleans everything up reliably. CDK has the same property via CloudFormation; AWS CLI doesn't — orphan resources are a real risk after CLI-only sessions. I'd also pick Terraform if the team were multi-cloud, but for AWS-only I'd lean CDK because Python beats HCL for anything beyond simple resource definitions."

---

## 7. Services NOT in M5 (and which module they arrive in)

Things people commonly *expect* in a production ML deployment that we haven't built yet — and where they come in:

| Service | Why not in M5 | Where it arrives |
|---|---|---|
| **SNS** (notifications) | Nothing to alert on yet | **M6** — drift detection raises alarms |
| **EventBridge** (event bus) | No event-driven flows yet | **M6** — schedule drift checks; **M8** — pipeline triggers |
| **Lambda** (serverless functions) | All compute is long-running | **M8** — capstone Lambda for SageMaker Pipeline orchestration |
| **CloudWatch Alarms** | Logs are flowing but no alarms wired | **M6** — alarm on RunningTaskCount, latency, drift |
| **RDS** (managed DB) | The M4 image is self-contained — no DB at runtime | **M6** — when the app reads recent rows for inference |
| **MLflow tracking server** | No (re)training happening in M5 | **M6/M7** — drift triggers retrain, MLflow logs runs |
| **Hopsworks feature store** | M5 is deployment, not feature engineering | **M7** |
| **SageMaker Pipelines** | Capstone material | **M8** |
| **ACM** (certs / HTTPS) | M5 is HTTP-only for simplicity | **M8** capstone, **Branch project stretch goal** |
| **Route 53** (custom DNS) | We use ALB's auto-generated DNS | **M8** if you wire a custom domain |
| **WAF** (web application firewall) | No public-facing real customers yet | Production hardening — outside the course |
| **Auto Scaling** for ECS | Class workload is steady | **Branch stretch goal** |

The point: M5's service list is exactly *enough* to ship a real production deployment, no more. Anything you'd add next (alerting, secrets, scaling, monitoring, HTTPS) belongs to a *later* phase, and we're adding them deliberately as we hit the use cases.

---

## 8. 15 interview questions (with hints)

These map roughly to the depth-progression interviewers use. **Hints, not answers** — work them out yourself before re-reading §3-§6.

1. **Conceptual.** What is the difference between an ECS task, task definition, and service? *(Hint: recipe vs instance vs supervisor.)*
2. **Conceptual.** Why does Fargate require `networkMode: awsvpc` and what does that give each task? *(Hint: dedicated ENI per task.)*
3. **Conceptual.** What problem does the `target type: ip` setting solve compared to `target type: instance`? *(Hint: who/what is being addressed?)*
4. **Conceptual.** Why is the Streamlit health check endpoint `/_stcore/health` and not `/`? *(Hint: what does hitting `/` actually do in Streamlit?)*
5. **Architecture.** Walk me through what happens, in order, from `git push origin main` to the new version being live on the ALB. *(Hint: §4 step 9.)*
6. **Architecture.** Where in your M5 architecture would you place a CDN, and what problem would it solve? *(Hint: CloudFront, edge caching of static assets; ALB stays the origin.)*
7. **Trade-offs.** I want to cut my Fargate bill by 70%. What can I do, and what's the risk? *(Hint: Fargate Spot — Branch project capacity providers; tasks can be interrupted with 2 min notice.)*
8. **Trade-offs.** Argue both sides: GitHub Actions vs CodePipeline for our team. *(Hint: §5 Fork 4 and Lab D's comparison table.)*
9. **Security.** Why are the task security group rules `source-group = ALB-SG` instead of `0.0.0.0/0`? Walk me through the attack you're preventing. *(Hint: anyone scanning the internet for port 8501 would find the tasks otherwise.)*
10. **Security.** What's wrong with storing AWS access keys in GitHub Secrets, and what's the alternative? *(Hint: long-lived secrets + OIDC federation.)*
11. **Reliability.** A user reports the dashboard returned 503 once last Tuesday. Where do you start investigating? *(Hint: ALB target health → ECS service events → CloudWatch Logs.)*
12. **Reliability.** Your CI/CD pipeline deployed a broken image. How do you roll back? *(Hint: `aws ecs update-service --task-definition truck-delay-task:<previous-revision>` — every revision is retained.)*
13. **Cost.** Why does the M5 teardown explicitly destroy the ALB even though tasks are scaled to zero? *(Hint: ALB charges ~₹2/hour regardless of traffic.)*
14. **IaC.** Compare CDK and Terraform for this exact M5 stack. Which would you pick and why? *(Hint: Branch project Phase 5 comparison table.)*
15. **Forward-looking.** M6 adds drift detection. Without seeing the lab, predict which AWS services M6 will introduce. *(Hint: SNS, EventBridge, CloudWatch Alarms, possibly Lambda.)*

---

## TL;DR — the one-page mental model

```
M4 ended with:    a Docker image sitting in ECR

M5 ends with:     git push → image rebuilt → ECS rolls out → ALB serves new version

The journey:
    ECR (already have it from M4)
        ↓ pull
    ECS Fargate    ← runs the container, kept alive by an ECS Service
        │
        ├── pulls image using → ecsTaskExecutionRole (IAM)
        ├── writes logs to    → CloudWatch Logs
        ├── lives in          → VPC subnets, locked by Security Groups
        │
        ↓ tasks registered into
    ALB Target Group  ← health checks /_stcore/health
        ↓ traffic from
    ALB Listener (port 80)
        ↓ public DNS
    Browser

Automation layer (Lab C OR Lab D):
    GitHub push  →  build image  →  push ECR  →  register task def revision  →  update ECS service
    (run by GitHub Actions runner OR CodePipeline + CodeBuild)
    Auth: IAM user keys OR OIDC role (GH) / service role (CodePipeline)
```

If you can draw that diagram from memory and name the failure mode each component prevents, you can defend M5 in any interview.
