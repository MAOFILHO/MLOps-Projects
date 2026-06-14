# MLOps Module 5 — CI/CD & Production Deployment

**ECS + ALB + GitHub Actions CI/CD + CodePipeline alternative + BentoML + Kubernetes (Minikube)** — taking the M4 Docker image and turning it into a production deployment with full CI/CD automation, plus a Customer Churn branch project as the deliberate Terraform learning moment.

> **New to this module?** Start with **[M5_Student_Manual.md](M5_Student_Manual.md)** — the comprehensive walkthrough. The rest of this README is a quick-reference index.
>
> **Want to understand *why* each AWS service is here, not just how to click it?** Read **[M5_Module_Reference_Guide.md](M5_Module_Reference_Guide.md)** — the conceptual KT that maps every service to the problem it solves, the deployment lifecycle phase it belongs to, and the interview justification you'd give for picking it. Read once before Lab A; refer back when an architecture question lands.
>
> **Joining at Module 5?** You need the Module 4 ECR image pushed to your AWS account. Either run M4 Lab 4 (push to ECR) yourself, or pull the prebuilt image from the course-supplied ECR repo. See [M5_Student_Manual.md §2](M5_Student_Manual.md#2-before-you-start--prerequisites).

---

## What you'll build

Take the **Truck Delay Streamlit container image** that you pushed to ECR in M4 Lab 4 and:

1. Deploy it as a **highly-available ECS service** behind an **Application Load Balancer**, so the dashboard survives container crashes and scales horizontally.
2. Wire it to a **GitHub Actions CI/CD pipeline** — every push to `main` builds a new image, pushes to ECR, and rolls out a new ECS task definition with zero downtime.
3. Compare the GitHub Actions workflow to the **AWS-native equivalent (CodePipeline + CodeBuild)** so you can pick the right tool for your team.
4. See **BentoML** as an alternative serving framework (purpose-built for ML APIs, generates its own container).
5. Get conceptual exposure to **Kubernetes** via a local **Minikube** lab (so the M5 → K8s conversation isn't a black box).
6. (Branch take-home) Re-implement the deployment for a **Customer Churn classifier (banking domain)** using **Terraform instead of CDK** — the deliberate two-IaC-tools moment of the course.

---

## Repo map

```
.
├── README.md                                       ← you're here
├── M5_Student_Manual.md                            ← THE manual — read this first
│
└── labs/
    ├── M5_Lab_A_ECS_Cluster_Setup.md               ECS cluster + task def + service for Truck Delay
    ├── M5_Lab_B_ALB_and_Target_Groups.md           ALB front-end + listener + target group
    ├── M5_Lab_C_GitHub_Actions_CICD.md             .github/workflows/deploy.yml for the spine project
    ├── M5_Lab_D_CodePipeline_Alternative.md        Same deploy via CodePipeline + CodeBuild
    ├── M5_Lab_E_BentoML_Serving.md                 Containerise the model with BentoML
    ├── M5_Lab_F_Kubernetes_Minikube.md             Local Minikube — pod, service, deployment
    └── M5_Branch_Customer_Churn/                   Take-home: Flask + Gunicorn + Terraform + ECS
        ├── README.md                                  Branch briefing
        ├── app/                                       Flask app + Dockerfile + requirements
        ├── terraform/                                 IaC: ECR, ECS, ALB, IAM, S3 backend
        └── .github/workflows/                         Optional CI/CD on the branch repo
```

---

## After M4 — run the 6 labs + branch

The order matters. Labs A → B → C form the **spine deployment story** (this is what M6, M7, M8 build on). Labs D, E, F are alternative-comparison labs. The Branch project consolidates everything into a from-scratch deployment on a different domain.

| Lab | What | Where to run | Output |
|---|---|---|---|
| **A** | [ECS cluster + task definition + service](labs/M5_Lab_A_ECS_Cluster_Setup.md) | AWS Console + AWS CLI | Truck Delay container running on Fargate |
| **B** | [ALB + target group + listener](labs/M5_Lab_B_ALB_and_Target_Groups.md) | AWS Console | Public ALB URL serving the dashboard |
| **C** | [GitHub Actions CI/CD](labs/M5_Lab_C_GitHub_Actions_CICD.md) | GitHub repo + local | `.github/workflows/deploy.yml`, automatic deploys on push to `main` |
| **D** | [CodePipeline alternative](labs/M5_Lab_D_CodePipeline_Alternative.md) | AWS Console + CLI | Same deploy automated by CodePipeline + CodeBuild |
| **E** | [BentoML serving](labs/M5_Lab_E_BentoML_Serving.md) | Local (Docker) | A bento'd version of the Truck Delay model |
| **F** | [Kubernetes on Minikube](labs/M5_Lab_F_Kubernetes_Minikube.md) | Local (Minikube) | Pod + Service + Deployment YAMLs |
| **Branch** | [Customer Churn — Banking (Terraform + ECS)](labs/M5_Branch_Customer_Churn/) | Take-home — your own AWS account | Independent end-to-end deployment |

Full per-lab walkthrough is in **[M5_Student_Manual.md](M5_Student_Manual.md)**.

---

## AWS services introduced in M5

All are **first-encounter** (Tier 3 hands-on — students provision them, no CDK pre-provisioning for M5):

| Service | What it does | First introduced in lab |
|---|---|---|
| **ECS (Elastic Container Service)** | Runs your container as a managed service (Fargate launch type — no EC2 management) | Lab A |
| **ALB (Application Load Balancer)** | Layer-7 load balancer in front of ECS tasks; gives you a stable public DNS | Lab B |
| **CodeBuild** | AWS-managed build server (runs `docker build` + `docker push` in the cloud) | Lab D |
| **CodePipeline** | AWS-native CI/CD orchestrator (Source → Build → Deploy) | Lab D |
| **Terraform** | Branch-only — second IaC tool exposure (vs CDK in M3/M4/M8) | Branch project |

ECR is reused from M4 (no new provisioning needed).

---

## Teardown

ECS + ALB are not free. Run teardown at the end of every session to avoid surprise bills.

```bash
# 1. Stop the ECS service (terminates tasks)
aws ecs update-service --cluster m5-truck-delay-cluster \
    --service truck-delay-service --desired-count 0

# 2. Delete the ECS service + cluster
aws ecs delete-service --cluster m5-truck-delay-cluster \
    --service truck-delay-service --force
aws ecs delete-cluster --cluster m5-truck-delay-cluster

# 3. Delete the ALB + target group + listener (via Console or CLI)
# See M5_Student_Manual.md §13 for the full teardown
```

Full teardown procedure (Console + CLI variants) is in **[M5_Student_Manual.md §13](M5_Student_Manual.md)**.

---

## What you'll learn

- Deploy a container image to **ECS Fargate** with a task definition + service
- Front a service with an **Application Load Balancer** and route traffic via a target group + listener
- Write a **GitHub Actions workflow** that builds, pushes to ECR, and updates ECS on every commit
- Compare GitHub Actions with **AWS-native CodePipeline + CodeBuild**
- Use **BentoML** to package an ML model as a serving container (alternative to hand-rolled Streamlit/Flask)
- Read + write **Kubernetes manifests** (Pod, Service, Deployment) and run them on local Minikube
- Re-implement the whole deployment using **Terraform** (branch project) — the deliberate IaC-comparison moment of the course

Full learning outcomes are in **[M5_Student_Manual.md §11](M5_Student_Manual.md)**.

---

## License + credits

Course content built for the **AWS MLOps Master Course** (48 hours, 8 modules). Module 5 is **spine phase 3** — Truck Delay Classification continues into M6 (drift detection), M7 (Hopsworks feature store), and M8 (SageMaker Pipelines).

Branch project ("Customer Churn — Banking Domain") based on the source materials in `Projects Repo/Customer Churn Prediction - Banking Domain/`.
