# Module 5 — Student Manual

**CI/CD & Production Deployment** | 7 hours total

> This is the **deep-dive manual** for Module 5. It tells you what you'll build, the lab sequence, how Module 5 picks up from M4, and exactly how to run each lab end-to-end. Read this before class. Refer back during labs when something feels confusing.

> For a one-page repo overview see [README.md](README.md). The branch project briefing lives in [labs/M5_Branch_Customer_Churn/README.md](labs/M5_Branch_Customer_Churn/README.md). **For the conceptual "why each AWS service is here" KT** — read **[M5_Module_Reference_Guide.md](M5_Module_Reference_Guide.md)** first; this Student Manual covers the *how*, the Reference Guide covers the *why*.

> **Joining at Module 5?** You need three things: a working AWS account, the **Module 4 ECR repository populated with the Truck Delay image** (you can pull a course-supplied prebuilt image if you didn't do M4 — see §2 below), and a GitHub account. M3 is **not** a hard prerequisite; the deployment labs work against the M4 image regardless of how it was built. Skim §1 and §3 of this manual (~5 min) for context.

---

## Table of contents

1. [What you'll build](#1-what-youll-build)
2. [Before you start — prerequisites](#2-before-you-start--prerequisites)
3. [Module 5 lab roadmap](#3-module-5-lab-roadmap)
4. [How M5 picks up from M4 (and where it hands off to M6)](#4-how-m5-picks-up-from-m4-and-where-it-hands-off-to-m6)
5. [Lab A — ECS cluster + task definition + service](#5-lab-a--ecs-cluster--task-definition--service)
6. [Lab B — Application Load Balancer](#6-lab-b--application-load-balancer)
7. [Lab C — GitHub Actions CI/CD](#7-lab-c--github-actions-cicd)
8. [Lab D — CodePipeline alternative](#8-lab-d--codepipeline-alternative)
9. [Lab E — BentoML serving](#9-lab-e--bentoml-serving)
10. [Lab F — Kubernetes on Minikube](#10-lab-f--kubernetes-on-minikube)
11. [Branch project — Customer Churn (Banking, Terraform)](#11-branch-project--customer-churn-banking-terraform)
12. [Learning outcomes](#12-learning-outcomes)
13. [Teardown — destroy everything](#13-teardown--destroy-everything)
14. [Troubleshooting](#14-troubleshooting)

---

## 1. What you'll build

By the end of Module 5 you'll have:

- A **production-grade ECS Fargate deployment** of the Truck Delay Streamlit dashboard, fronted by an Application Load Balancer with a public URL.
- A **GitHub Actions CI/CD pipeline** in your M3 repo that rebuilds + redeploys on every push to `main` — zero manual steps from `git push` to "new version live".
- A second deployment of the same workload via **AWS CodePipeline + CodeBuild**, so you've seen both the GitHub-native and AWS-native CI/CD paths and know when to pick which.
- A **BentoML-packaged version** of the model — same predictions, different serving framework (purpose-built for ML APIs with auto-generated OpenAPI docs).
- Working knowledge of **Kubernetes manifests** (Pod, Service, Deployment) running locally on **Minikube**, so the M5-to-K8s conversation isn't a black box.
- (Branch take-home) An **independent end-to-end deployment** of a Customer Churn classifier (banking domain) using **Terraform** as the IaC tool — the deliberate "second IaC tool" moment of the course.

This is **spine phase 3**: the Truck Delay app went from notebook (M3) → containerised (M4) → **production-deployed with CI/CD (M5)** → drift-monitored (M6) → feature-store-driven (M7) → fully automated SageMaker Pipeline (M8).

---

## 2. Before you start — prerequisites

### From earlier modules

| What | Why | Status check |
|---|---|---|
| ECR repository from M4 | Lab A pulls the image from here | `aws ecr describe-repositories --region <region>` lists your repo |
| Truck Delay image pushed to ECR | The thing we're deploying | `aws ecr describe-images --repository-name <repo-name>` shows at least one image |
| AWS CLI v2 configured | All labs use the CLI | `aws sts get-caller-identity` returns your account ID |
| GitHub account + a repo with the M4 self-contained app | Lab C wires CI/CD against this repo. The app source is in `Module 4/labs/M4_Lab3_Docker_Compose/app/` (`app.py`, `requirements.txt`, `Dockerfile`, `artifacts/`). | https://github.com/<you>/<m4-repo> |

> **Joining at M5 only?** Two options for the ECR prerequisite:
> 1. **Run M4 Lab 4** quickly — Docker build + `docker push` takes about 20 minutes total, and you understand what's deployed.
> 2. **Use a course-supplied image** — your instructor will provide a public ECR image URI you can pull. You won't have CI control over its content, but the deploy labs will work end-to-end.

### Local tooling

| Tool | Why | Install |
|---|---|---|
| Docker Desktop | Lab D's CodeBuild verification, Lab E's BentoML, Lab F's Minikube | https://www.docker.com/products/docker-desktop/ |
| `kubectl` | Lab F manifests | `brew install kubectl` (mac), choco (win), or download from K8s docs |
| Minikube | Lab F local Kubernetes | https://minikube.sigs.k8s.io/docs/start/ |
| BentoML | Lab E | `pip install bentoml` (Python 3.10+) |
| Terraform | Branch project | https://developer.hashicorp.com/terraform/install |

### AWS permissions

Your IAM user needs (in addition to ECR from M4):
- `AmazonECS_FullAccess`
- `ElasticLoadBalancingFullAccess`
- `IAMFullAccess` (for creating ECS task execution role)
- `AmazonVPCFullAccess` (for ALB and ECS networking)
- `AWSCodeBuildAdminAccess` + `AWSCodePipeline_FullAccess` (Lab D only)

If you used `AdministratorAccess` for M3/M4 you already have all of these.

### Estimated cost per session

| Resource | Rate (ap-south-1) | Cost for 4-hour session |
|---|---|---|
| ECS Fargate task (0.5 vCPU, 1 GB) | ~₹3/hour | ~₹12 |
| Application Load Balancer | ~₹2/hour + ~₹0.6/LCU-hour | ~₹10 |
| Data transfer out | First 100 GB/month free | ~₹0 |
| **Total per session** | | **~₹25** |

Always teardown at end of session. ALB charges accrue per hour whether or not anyone visits the URL.

---

## 3. Module 5 lab roadmap

| Lab | Title | Format | Duration | What you do |
|---|---|---|---|---|
| **A** | ECS cluster + task definition + service | Hands-on (AWS Console + CLI) | 60 min | Create an ECS Fargate cluster, register a task definition that points at your M4 ECR image, and run it as a service. |
| **B** | Application Load Balancer | Hands-on (AWS Console) | 45 min | Create an ALB + target group + listener. Update the ECS service to register tasks behind the ALB. Test the public URL. |
| **C** | GitHub Actions CI/CD | Hands-on (GitHub repo + local) | 60 min | Write `.github/workflows/deploy.yml`. Set up GitHub Secrets (AWS credentials). Trigger a deploy by pushing a code change. |
| **D** | CodePipeline alternative | Hands-on (AWS Console + CLI) | 45 min | Create the same Source → Build → Deploy flow using AWS-native services. Compare with GitHub Actions. |
| **E** | BentoML serving | Hands-on (local Python) | 45 min | Save the XGBoost model as a Bento, generate a Docker image automatically, run it locally. |
| **F** | Kubernetes on Minikube | Hands-on (local) | 45 min | Start Minikube, write Pod + Service + Deployment YAMLs, deploy the Truck Delay image. |
| **Branch** | Customer Churn (Banking, Terraform) | Take-home | 3-4 hours | End-to-end deployment in your own AWS account using Terraform IaC. |

Total in-class time: ~5 hours of labs + 1 hour Kubernetes concept session + 1 hour branch briefing = 7 hours.

---

## 4. How M5 picks up from M4 (and where it hands off to M6)

```
M4 endpoint:
    s3://docker-hub-replacement-of-sorts
    <account>.dkr.ecr.<region>.amazonaws.com/truck-delay-app:v1   ← M4 pushed this
        └── Image in ECR, never pulled anywhere yet

M5 spine progression:
    Lab A:  ECS Fargate pulls the image, runs it as a task
    Lab B:  ALB routes public traffic → ECS service → tasks
    Lab C:  git push → GH Actions → docker build → ECR push → ECS deploy
    Lab D:  (alternative) git push → CodePipeline → CodeBuild → ECR push → ECS deploy
                                                                            ↓
M6 will:
    Add Evidently AI drift detection + SNS alerts WHEN the deployed model's
    predictions diverge from training distribution. The M5 ECS service stays
    running; M6 adds an observation layer on top of it.
```

The spine is **continuous** — the same Truck Delay image runs through M5, M6, M7, M8. M5 is where it becomes a "real" deployment for the first time.

The labs D, E, F are **alternatives + concepts** — they don't change the spine state. After Lab D you have two CI/CD pipelines deploying to the same ECS service. After Lab E you have a separately-runnable Bento image (not deployed to ECS). After Lab F you have local Kubernetes pods (not connected to AWS).

---

## 5. Lab A — ECS cluster + task definition + service

**File:** [labs/M5_Lab_A_ECS_Cluster_Setup.md](labs/M5_Lab_A_ECS_Cluster_Setup.md)

ECS = Elastic Container Service. You'll use the **Fargate** launch type (serverless containers — no EC2 to manage). The lab walks you through:
1. Creating an ECS cluster
2. Creating an IAM execution role (`ecsTaskExecutionRole`)
3. Writing a task definition JSON (CPU, memory, the ECR image URI, port mapping)
4. Running the task as a **service** with desired-count = 1
5. Verifying the task is running via CloudWatch Logs

**Output:** a running ECS service named `truck-delay-service` in cluster `m5-truck-delay-cluster`.

---

## 6. Lab B — Application Load Balancer

**File:** [labs/M5_Lab_B_ALB_and_Target_Groups.md](labs/M5_Lab_B_ALB_and_Target_Groups.md)

Until Lab B, the ECS task is reachable only by its private IP inside the VPC. The ALB gives it a **stable public DNS name**, **HTTP routing**, and **health checks** (auto-restart unhealthy tasks).

You'll:
1. Create a target group (`ip` type — required for Fargate)
2. Create an ALB in public subnets, listener on port 80
3. Update the ECS service to register tasks into the target group
4. Hit the ALB's public DNS in your browser — you should see the Streamlit dashboard

**Output:** a public URL of the form `http://truck-delay-alb-<random>.<region>.elb.amazonaws.com` serving the dashboard.

---

## 7. Lab C — GitHub Actions CI/CD

**File:** [labs/M5_Lab_C_GitHub_Actions_CICD.md](labs/M5_Lab_C_GitHub_Actions_CICD.md)

You'll add a `.github/workflows/deploy.yml` to your M3 (or M4) repo that:
1. Checks out the code on every push to `main`
2. Logs into ECR using AWS credentials from GitHub Secrets
3. Builds + tags + pushes the Docker image
4. Registers a new ECS task definition revision
5. Updates the ECS service to use the new revision (rolling deploy)

**Output:** every `git push` triggers a deploy. ECS Fargate's blue/green strategy gives you zero-downtime rollouts.

> **Why GitHub Actions before CodePipeline?** Most teams use GitHub for source control already; GitHub Actions has lower setup friction and is free for public repos / 2,000 min/month for private. CodePipeline (Lab D) is the right call when you're all-in on AWS and want everything inside the AWS Console.

---

## 8. Lab D — CodePipeline alternative

**File:** [labs/M5_Lab_D_CodePipeline_Alternative.md](labs/M5_Lab_D_CodePipeline_Alternative.md)

Same end-state as Lab C, AWS-native services:
- **Source stage:** CodePipeline polls GitHub (or AWS CodeCommit)
- **Build stage:** CodeBuild runs `docker build` + `docker push` in the cloud
- **Deploy stage:** CodePipeline updates the ECS service

You'll write a `buildspec.yml` (CodeBuild instructions) and create the pipeline via the Console.

**Output:** the same CI/CD outcome as Lab C, just orchestrated entirely within AWS.

---

## 9. Lab E — BentoML serving

**File:** [labs/M5_Lab_E_BentoML_Serving.md](labs/M5_Lab_E_BentoML_Serving.md)

BentoML is a Python framework that packages ML models for serving. You give it a model + a Python function that calls it, and BentoML:
- Generates an OpenAPI/Swagger spec automatically
- Builds a Docker image with the model baked in (you don't write a Dockerfile)
- Provides a REST API + a CLI for testing

In this lab you'll save the Truck Delay XGBoost model as a Bento, generate the Docker image, and `docker run` it locally. The output port serves predictions via REST.

**Why this matters:** BentoML is one of three serving-framework patterns you'll see in the course. The others are Streamlit (the M4 self-contained dashboard) and a hand-rolled Flask+Gunicorn (Branch project). BentoML's auto-everything is appealing; the cost is less flexibility.

---

## 10. Lab F — Kubernetes on Minikube

**File:** [labs/M5_Lab_F_Kubernetes_Minikube.md](labs/M5_Lab_F_Kubernetes_Minikube.md)

The 1-hour Kubernetes session in M5 is **concept-focused**, with a small hands-on Minikube exercise so the terms aren't abstract:
- What is a Pod? A Deployment? A Service?
- How does K8s differ from ECS conceptually? (Kubernetes is the open standard; ECS is the AWS-native alternative.)
- When would you pick K8s over ECS?

You'll start Minikube locally, write three YAML manifests (Pod, Service, Deployment), apply them, and verify the Truck Delay image runs as a K8s deployment with one replica.

**Output:** running K8s pods on local Minikube. Not deployed to AWS — this lab is conceptual exposure.

---

## 11. Branch project — Customer Churn (Banking, Terraform)

**Folder:** [labs/M5_Branch_Customer_Churn/](labs/M5_Branch_Customer_Churn/)

**Format:** Take-home (3-4 hours). Self-paced.

You'll re-implement the deployment flow you learned in Labs A-D on a **different project** (Customer Churn classifier for a bank) using a **different IaC tool** (Terraform instead of CDK).

**What's included in the branch folder:**
- A trained Customer Churn classifier (Random Forest)
- A Flask + Gunicorn web app that serves it (`app.py`)
- A Terraform configuration that provisions ECR + ECS + ALB + IAM
- A `.github/workflows/deploy.yml` adapted to use `terraform apply` instead of CDK / AWS CLI

**Why Terraform here?** The course's main IaC tool is AWS CDK (M3, M4, M8). Terraform is the industry standard outside the AWS ecosystem (multi-cloud, larger community, more job postings). The Customer Churn branch is the **deliberate Terraform exposure moment** — students get hands-on with the second major IaC tool, see the tradeoffs, and can defend either choice in an interview.

Full briefing in [labs/M5_Branch_Customer_Churn/README.md](labs/M5_Branch_Customer_Churn/README.md).

---

## 12. Learning outcomes

By the end of M5 you can:

**ECS + ALB deployment:**
1. Write an ECS task definition JSON (CPU/memory/image/port mapping/log config)
2. Choose between Fargate and EC2 launch types and explain when each is right
3. Configure an ALB with a target group + listener + health check
4. Diagnose why an ECS task is failing (CloudWatch Logs, task status, ALB target health)

**CI/CD pipelines:**
5. Write a GitHub Actions workflow that builds, pushes to ECR, and deploys to ECS
6. Store AWS credentials securely in GitHub Secrets and reference them in workflows
7. Use OIDC federation (alternative to long-lived secrets) — bonus material in Lab C
8. Build the same pipeline using CodePipeline + CodeBuild + `buildspec.yml`
9. Pick GitHub Actions vs CodePipeline based on team context (GitHub-centric vs AWS-centric)

**Serving alternatives:**
10. Package a model as a Bento and generate a serving image
11. Compare BentoML, Streamlit, and Flask+Gunicorn for ML serving

**Kubernetes concepts:**
12. Define a Pod, a Deployment, and a Service in YAML
13. Explain when K8s is the right choice vs ECS (multi-cloud, vendor-neutral)

**IaC comparison:**
14. Use Terraform to provision the same AWS resources you previously provisioned with CDK
15. Compare CDK vs Terraform: language, state management, cloud-portability, community

---

## 13. Teardown — destroy everything

Run at the end of every session. ALB + ECS tasks accrue cost per hour.

> **🪟 Windows users:** the commands below are written for bash (Git Bash, WSL, macOS, Linux). On native PowerShell, `xargs -I {}` and `cat <<EOF` aren't available — either (a) run the teardown inside Git Bash / WSL, or (b) replace each pipeline with an explicit two-step variant: capture the ARN into a variable, then pass it as a positional argument. Example for the ALB delete:
> ```powershell
> $albArn = aws elbv2 describe-load-balancers --names truck-delay-alb `
>     --query "LoadBalancers[0].LoadBalancerArn" --output text
> aws elbv2 delete-load-balancer --load-balancer-arn $albArn
> ```

```bash
# 1. Scale the ECS service to zero (terminates running tasks immediately)
aws ecs update-service \
    --cluster m5-truck-delay-cluster \
    --service truck-delay-service \
    --desired-count 0

# 2. Delete the service
aws ecs delete-service \
    --cluster m5-truck-delay-cluster \
    --service truck-delay-service \
    --force

# 3. Delete the cluster
aws ecs delete-cluster --cluster m5-truck-delay-cluster

# 4. Delete the ALB (via Console: EC2 → Load Balancers → select → Delete)
#    Or CLI:
aws elbv2 describe-load-balancers --names truck-delay-alb \
    --query "LoadBalancers[0].LoadBalancerArn" --output text \
    | xargs -I {} aws elbv2 delete-load-balancer --load-balancer-arn {}

# 5. Delete the target group
aws elbv2 describe-target-groups --names truck-delay-tg \
    --query "TargetGroups[0].TargetGroupArn" --output text \
    | xargs -I {} aws elbv2 delete-target-group --target-group-arn {}

# 6. (Lab D only) Delete the CodePipeline + CodeBuild project
aws codepipeline delete-pipeline --name truck-delay-pipeline
aws codebuild delete-project --name truck-delay-build

# 7. ECR repo from M4 — keep it (small storage cost; you'll want the image in M6)

# 8. (Lab F only) Stop Minikube
minikube stop
minikube delete
```

**What's left after teardown:** the ECR repo (~₹12/month, keep it for M6) and the IAM `ecsTaskExecutionRole` (free, also keep it).

---

## 14. Troubleshooting

| Symptom | Diagnosis | Fix |
|---|---|---|
| ECS task stuck in "Provisioning" | Subnet has no route to the internet (can't pull from ECR) | Make sure the ECS service is in a subnet with a NAT gateway, or use public subnets with `assignPublicIp: ENABLED` |
| ECS task starts then exits immediately | Streamlit needs `--server.address=0.0.0.0` (binds 127.0.0.1 by default) | Check the Dockerfile CMD; revisit M4 Lab 1 |
| ALB target unhealthy | Health check path mismatch | Streamlit's health endpoint is `/_stcore/health` — set this on the target group |
| GitHub Actions can't auth to AWS | `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` not set in Secrets | Repo → Settings → Secrets and variables → Actions → New repository secret |
| `terraform apply` says "AccessDenied" | IAM user lacks `iam:PassRole` on the ECS execution role | Add `IAMReadOnlyAccess` + scoped `iam:PassRole` for the specific role |
| Minikube won't start | Hyper-V / VirtualBox / Docker driver conflict | `minikube start --driver=docker` is usually the safest on Windows |

For deeper issues, check CloudWatch Logs (Log groups → `/ecs/truck-delay-service`) and the ECS Service Events tab.
