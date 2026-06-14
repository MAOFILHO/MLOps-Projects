# M5 Lab C — GitHub Actions CI/CD

**Module 5 — CI/CD & Production Deployment | Spine Project: Truck Delay Classification**

| Detail | Value |
|---|---|
| Duration | 60 minutes |
| Difficulty | Intermediate |
| Tools | GitHub repo, AWS CLI (one-time setup), browser (GitHub Settings) |
| AWS Services | IAM (for the CI user / OIDC role), ECR, ECS |
| Prerequisite | Lab B complete — ALB serving the dashboard |
| Builds Toward | Lab D (same outcome via AWS CodePipeline), M6+ (drift-triggered redeploys) |
| Cost Estimate | GitHub Actions free for public repos / 2,000 min/month for private. AWS charges = zero (uses ECR + ECS you already pay for). |

---

## Learning Objectives

By the end of this lab you will be able to:

1. Structure a GitHub Actions workflow (`.github/workflows/deploy.yml`) with jobs, steps, and `secrets`.
2. Authenticate GitHub Actions to AWS — **two paths**: static IAM keys (faster) vs OIDC federation (production-grade).
3. Build + tag + push a Docker image from a workflow.
4. Update an ECS service with a new task definition revision and wait for the rollout to complete.
5. Diagnose a failing workflow (job logs, AWS-side IAM errors, ECS rollout failures).

---

## Business Context

Last week Priya merged a Streamlit bug fix to `main`, then forgot to redeploy. The bug stayed live in production for three days. Arjun pushed a hotfix this morning and accidentally ran `docker push` against the wrong tag — ECS picked it up immediately and showed a broken dashboard to ops for 20 minutes before he caught it.

Both incidents have the same root cause: **deployment is manual and error-prone**. CI/CD removes the human from the loop — every commit to `main` becomes a deployment automatically, with the same exact build steps every time. If `main` is green, production is green. If you want to ship, you `git push`.

In this lab you'll wire that up.

---

## About GitHub Actions — first encounter

### What it is

**GitHub Actions is a CI/CD runner built into GitHub.** You drop a YAML file in `.github/workflows/` describing "when X happens to the repo, run these steps on a fresh VM". GitHub auto-provisions an ephemeral Ubuntu/Windows/macOS runner, executes your workflow, then throws the runner away.

Three vocabulary words:

| Word | What it is | Mental model |
|---|---|---|
| **Workflow** | A YAML file in `.github/workflows/` that describes a complete automation | A pipeline definition |
| **Job** | A unit of work that runs on one runner; workflow has one or many | A stage in the pipeline |
| **Step** | An atomic instruction inside a job (a shell command or a reusable "action") | One line of work |

An **action** is a reusable, versioned plug-in (e.g. `actions/checkout@v4`, `aws-actions/configure-aws-credentials@v4`). The community publishes thousands; AWS publishes the ECS/ECR ones we'll use.

### The problem it solves (specifically for this project)

The deploy chain you've been running by hand since M4 is exactly 5 steps:
```bash
docker build -t truck-delay-app:v2 .
docker tag  truck-delay-app:v2  <ECR>:v2
aws ecr get-login-password | docker login --username AWS --password-stdin <ECR>
docker push <ECR>:v2
aws ecs update-service --cluster ... --service ... --force-new-deployment
```

Five steps with multiple ways to mess up (wrong tag, missing login, wrong service name). CI/CD turns those five steps into a YAML file that runs identically every time. The human's only job is `git push`.

What GitHub Actions handles for you in this lab:

1. **Triggers automatically** on `push` to `main` (or a manual button click)
2. **Provisions a fresh Ubuntu runner** with Docker + AWS CLI pre-installed (no env to manage)
3. **Authenticates to AWS** using either secrets-stored keys (Strategy A) or short-lived OIDC tokens (Strategy B)
4. **Runs the 5-step deploy chain** in the same order every time
5. **Waits for the ECS rollout to finish** before reporting success — fails the workflow if the deploy times out

### Why we picked GitHub Actions over CodePipeline (for this lab)

The next lab (Lab D) rebuilds the same pipeline using AWS-native CodePipeline + CodeBuild. We do GitHub Actions first because:

| Reason | Detail |
|---|---|
| **Lower friction** | Your repo already lives on GitHub; no Console clicking, no IAM roles to pre-create — just a YAML file + 3 secrets |
| **Free at this scale** | Public repos: unlimited minutes. Private repos: 2,000 free minutes/month for personal accounts |
| **Workflow lives in the repo** | The CI config is code-reviewed alongside the code it builds — single source of truth |
| **Faster feedback loop** | Push to `main` triggers in seconds (no polling); CodePipeline polling can lag up to 2 min |

Lab D will reverse the comparison and show you when CodePipeline wins (all-in-AWS teams, multi-account, compliance).

### Pricing

| Plan | Free quota | Beyond free |
|---|---|---|
| **Public repos** | Unlimited minutes on hosted runners | N/A — always free |
| **Private repos (personal Free/Pro)** | 2,000 minutes/month | $0.008/min (Linux 2-core) ≈ ₹0.66/min |
| **Private repos (organisation Team)** | 3,000 minutes/month | Same overage |
| **Self-hosted runners** | Unlimited (you bring the compute) | Whatever you pay for the host |

**For this lab**: each deploy run takes ~3–5 minutes. At 20 deploys/day on a private repo you'd use ~6 hours/month ≈ 360 minutes — well within the free 2,000. Effectively free for any solo learner or small team.

### What's a "GitHub Action" vs a "GitHub Actions"?

Linguistic trap that confuses everyone:

- **GitHub Actions** (plural, capitalised) = the *product* — the CI/CD service
- **A GitHub Action** (singular) = one *reusable plug-in* you use inside a workflow (e.g., `actions/checkout@v4` is "the checkout action")

Documentation flips between both freely. Pattern-match on context.

### About IAM users + access keys for CI (Strategy A in Step 1)

This lab creates a **dedicated IAM user** for the GitHub workflow with two AWS-managed policies (`AmazonEC2ContainerRegistryFullAccess` + `AmazonECS_FullAccess`) and stores its access keys in **GitHub Secrets**. That's the "fast path" — perfect for class.

The security tradeoff: those access keys are **long-lived**. If a workflow logs them by accident, a fork of your repo runs an evil PR that reads them, or your laptop's Git Bash history is compromised — those keys grant ECR + ECS access until you manually rotate. Step 7's optional sidebar walks through the production-grade alternative (OIDC federation), which trades 15 minutes of setup for never having a long-lived secret to leak.

### How GitHub Actions compares to what we've already used

| Tool | Where you saw it | What CI/CD changes |
|---|---|---|
| **Manual `docker push` + `aws ecs update-service`** (Lab A end / M4) | One-shot, by hand | Replaced — same commands, but now in YAML and triggered by a push event |
| **`docker compose up`** (M4 Lab 3) | Local-only orchestration | Different layer — Compose runs containers locally; GitHub Actions builds + ships them to AWS |
| **GitHub itself** (source control since day 1) | Where your code lives | GitHub Actions extends GitHub from "code storage" to "code storage + automation" — same login, same repo, no separate service to set up |

---

## Prerequisites

### From Lab B

```bash
# ALB DNS — note it for your end-to-end test
ALB_DNS=$(aws elbv2 describe-load-balancers \
    --names truck-delay-alb \
    --query "LoadBalancers[0].DNSName" --output text \
    --region us-east-1)
echo "Dashboard: http://$ALB_DNS"
```

The dashboard should load. If it doesn't, fix Lab B before proceeding.

### A GitHub repo with the M4 self-contained app

You need a repo that contains the build context from `Module 4/labs/M4_Lab3_Docker_Compose/app/`:

```
your-repo/
├── app.py               Self-contained Streamlit predictor (loads .pkl from artifacts/)
├── requirements.txt     Pinned Python deps (streamlit, xgboost, scikit-learn, joblib, ...)
├── Dockerfile           From M4 Lab 1 — layer-cached, Python-stdlib healthcheck
└── artifacts/           4 files (~1 MB) the app loads at startup
    ├── xgboost_model.pkl
    ├── encoder.pkl
    ├── scaler.pkl
    └── model_metadata.json
```

Easiest path: copy the entire `Module 4/labs/M4_Lab3_Docker_Compose/app/` folder into a fresh repo (e.g. `truck-delay-deploy`). The app is fully self-contained — no `config.py` / `utils.py` / external service dependencies — so any clone of those four entries plus `artifacts/` is sufficient to `docker build` and ship.

Verify it's pushable:
```bash
cd /path/to/your-repo
git remote -v          # confirms origin URL
git status             # confirms clean working tree on a branch you can push
```

---

## Step 1: Pick your auth strategy

There are two ways to let GitHub Actions deploy to AWS:

| Strategy | Setup time | Security | When to pick |
|---|---|---|---|
| **A. Static IAM access keys in GitHub Secrets** | 5 min | OK for class / personal projects. Keys never rotate; if leaked they grant full AWS access. | Quick start. Anything you're building solo for learning. |
| **B. OIDC federation (no long-lived keys)** | 15 min | Production-grade. GitHub Actions assumes an IAM role per workflow run via short-lived tokens. No secrets to rotate or leak. | Production deployments. Team workflows. Anything in a corporate AWS account. |

This lab uses **Strategy A as the main path** (faster, gets you to the CI/CD outcome quickly) and **Strategy B as a sidebar** at the end (because that's what you should use in real life).

### Strategy A — Create an IAM user for CI

```bash
# Create user
aws iam create-user --user-name github-actions-deploy

# Attach the minimum policies needed (ECR push + ECS update)
aws iam attach-user-policy \
    --user-name github-actions-deploy \
    --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess

aws iam attach-user-policy \
    --user-name github-actions-deploy \
    --policy-arn arn:aws:iam::aws:policy/AmazonECS_FullAccess

# Create access keys
aws iam create-access-key --user-name github-actions-deploy
```

Output:
```json
{
  "AccessKey": {
    "UserName": "github-actions-deploy",
    "AccessKeyId": "AKIA....",
    "SecretAccessKey": "abc123...",
    ...
  }
}
```

**🚨 Security warning — read before you run the command above.**
> `aws iam create-access-key` prints the secret in **plaintext** to stdout. It will land in:
> - Your terminal scrollback
> - Your shell's history file (`~/.bash_history`, PowerShell history, tmux scrollback)
> - Any screen recording / Zoom share running at the time
> - Any chat tool you paste the output into
>
> AWS only shows the secret **once** — there's no API to retrieve it later. If it leaks (or you even suspect it might have), immediately rotate:
> ```bash
> aws iam delete-access-key --user-name github-actions-deploy --access-key-id <leaked-id>
> aws iam create-access-key --user-name github-actions-deploy
> ```
>
> **Safer pattern for live demos / recordings** — pipe the output through `jq` or Python and only echo the AccessKeyId, then put the secret directly into the file you'll paste into GitHub Secrets without it ever crossing the terminal:
> ```bash
> AK=$(aws iam create-access-key --user-name github-actions-deploy --output json)
> echo "AccessKeyId: $(echo "$AK" | python -c "import sys,json;print(json.load(sys.stdin)['AccessKey']['AccessKeyId'])")"
> echo "$AK" | python -c "import sys,json;print(json.load(sys.stdin)['AccessKey']['SecretAccessKey'])" > /tmp/secret.txt
> # Now paste contents of /tmp/secret.txt into the GitHub Secret form, then `rm /tmp/secret.txt`
> ```

**Copy `AccessKeyId` and `SecretAccessKey` to a temporary file** — you'll paste them into GitHub Secrets in Step 2.

> **Principle of least privilege:** `AmazonECS_FullAccess` is overly broad — it lets the CI user delete clusters. For a tighter scope, write a custom policy granting only `ecs:UpdateService`, `ecs:DescribeServices`, `ecs:RegisterTaskDefinition`, and `iam:PassRole` for the task execution role. Worth doing for production; overkill for class.

---

## Step 2: Add GitHub Secrets

1. Go to your repo on GitHub → **Settings** (top tab) → **Secrets and variables** (left sidebar) → **Actions** → **New repository secret**.

2. Add three secrets (the names are exact — the workflow file references them):

| Name | Value |
|---|---|
| `AWS_ACCESS_KEY_ID` | The `AccessKeyId` from Step 1 |
| `AWS_SECRET_ACCESS_KEY` | The `SecretAccessKey` from Step 1 |
| `AWS_REGION` | `us-east-1` (or whatever region your ECR + ECS are in) |

`[SCREENSHOT: GitHub repo Settings → Secrets → Actions page showing the three secrets configured]`

### Optional: also add the resource names as repo variables

Variables are like secrets but plain-text (visible in workflow logs). Useful for things you might tweak per environment.

1. Same page → **Variables** tab → **New repository variable**.

| Name | Value |
|---|---|
| `ECR_REPOSITORY` | `truck-delay-app` |
| `ECS_CLUSTER` | `m5-truck-delay-cluster` |
| `ECS_SERVICE` | `truck-delay-service` |
| `CONTAINER_NAME` | `truck-delay-app` |

The workflow file below references these as `${{ vars.NAME }}`. Hard-coding them in the YAML works too — variables just make multi-environment setups easier.

---

## Step 3: Write the Workflow

Create `.github/workflows/deploy.yml` in your repo:

```yaml
name: Build + Push to ECR + Deploy to ECS

on:
  push:
    branches: [ main ]                       # Deploy on every push to main
  workflow_dispatch:                          # Also allow manual trigger from Actions tab

env:
  AWS_REGION: ${{ secrets.AWS_REGION }}
  ECR_REPOSITORY: ${{ vars.ECR_REPOSITORY || 'truck-delay-app' }}
  ECS_CLUSTER: ${{ vars.ECS_CLUSTER || 'm5-truck-delay-cluster' }}
  ECS_SERVICE: ${{ vars.ECS_SERVICE || 'truck-delay-service' }}
  CONTAINER_NAME: ${{ vars.CONTAINER_NAME || 'truck-delay-app' }}
  TASK_DEFINITION_FAMILY: truck-delay-task

jobs:
  deploy:
    name: Build + Deploy
    runs-on: ubuntu-latest

    steps:
      # 1. Get the source code into the runner
      - name: Checkout
        uses: actions/checkout@v4

      # 2. Authenticate to AWS using the credentials from GitHub Secrets
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id:     ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region:            ${{ env.AWS_REGION }}

      # 3. Log in to ECR
      - name: Log in to Amazon ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2

      # 4. Build, tag, and push the image. Two tags: the commit SHA (immutable, traceable) and 'latest'.
      - name: Build, tag, and push image to ECR
        id: build-image
        env:
          ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
          IMAGE_TAG:    ${{ github.sha }}
          # Build context = the folder containing the Dockerfile + app.py + requirements.txt + artifacts/.
          # The Prerequisites section above tells you to copy `Module 4/labs/M4_Lab3_Docker_Compose/app/`
          # to the REPO ROOT, so `.` is the default. Override `BUILD_CONTEXT` as a repo variable
          # (Settings → Variables) if you've nested it deeper in the repo.
          BUILD_CONTEXT: ${{ vars.BUILD_CONTEXT || '.' }}
        run: |
          docker build -t $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG "$BUILD_CONTEXT"
          docker tag  $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG  $ECR_REGISTRY/$ECR_REPOSITORY:latest

          docker push $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:latest

          # Export the full image URI for the next step
          echo "image=$ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG" >> $GITHUB_OUTPUT

      # 5. Download the current task definition so we can swap the image URI
      - name: Download current task definition
        run: |
          aws ecs describe-task-definition \
            --task-definition $TASK_DEFINITION_FAMILY \
            --query taskDefinition > task-definition.json

      # 6. Inject the new image URI into the task definition JSON
      - name: Render task definition with new image
        id: render
        uses: aws-actions/amazon-ecs-render-task-definition@v1
        with:
          task-definition: task-definition.json
          container-name:  ${{ env.CONTAINER_NAME }}
          image:           ${{ steps.build-image.outputs.image }}

      # 7. Register the new revision + update the ECS service + wait for rollout
      - name: Deploy to ECS
        uses: aws-actions/amazon-ecs-deploy-task-definition@v2
        with:
          task-definition: ${{ steps.render.outputs.task-definition }}
          service:         ${{ env.ECS_SERVICE }}
          cluster:         ${{ env.ECS_CLUSTER }}
          wait-for-service-stability: true     # Blocks until ECS confirms the rollout succeeded

      # 8. Print a friendly summary
      - name: Print deployment summary
        run: |
          echo "Deployed image: ${{ steps.build-image.outputs.image }}"
          echo "Cluster:        ${{ env.ECS_CLUSTER }}"
          echo "Service:        ${{ env.ECS_SERVICE }}"
          echo ""
          ALB_DNS=$(aws elbv2 describe-load-balancers --names truck-delay-alb \
                     --query "LoadBalancers[0].DNSName" --output text \
                     --region ${{ env.AWS_REGION }})
          echo "Dashboard URL: http://$ALB_DNS"
```

### What each step does (in plain English)

| Step | What | Why |
|---|---|---|
| Checkout | Clones your repo onto the GitHub runner | The runner needs the Dockerfile + source code |
| Configure AWS credentials | Sets env vars that the AWS CLI auto-uses | All subsequent AWS calls in the workflow are authenticated |
| Log in to ECR | `aws ecr get-login-password \| docker login ...` wrapped in an action | Docker can now push to ECR |
| Build image | `docker build` with two tags: commit SHA + `latest` | SHA tag is the immutable traceable artifact; `latest` is convenient for manual pulls |
| Push image | `docker push` both tags | ECR now has the new version |
| Download task definition | Fetches the latest revision of `truck-delay-task` as JSON | We need the current shape to modify it |
| Render task definition | Mutates the JSON to use the new image URI | The render action handles the "swap one container's image, keep everything else" surgery |
| Deploy to ECS | Registers a new task def revision + updates the service to use it + waits for steady state | This is the actual rollout |
| Print summary | Shows the ALB URL to verify the deploy | Convenience |

---

## Step 4: Commit and Push

```bash
cd /path/to/your-repo
git add .github/workflows/deploy.yml
git commit -m "Add CI/CD workflow for ECS"
git push origin main
```

Go to your repo on GitHub → **Actions** tab. You should see the workflow running:

`[SCREENSHOT: GitHub Actions tab showing the workflow in progress with green checkmarks for completed steps]`

Expected progression:
1. Checkout — 5 sec
2. Configure AWS credentials — 2 sec
3. Log in to ECR — 5 sec
4. Build, tag, push — 60-90 sec (Docker build is the slow step)
5. Download task definition — 3 sec
6. Render task definition — 1 sec
7. Deploy to ECS — 90-180 sec (waits for rollout)
8. Print summary — 2 sec

Total: ~3-5 minutes per deploy.

---

## Step 5: Verify the Deploy

After the workflow succeeds:

```bash
# Confirm a new task definition revision exists
aws ecs describe-task-definition \
    --task-definition truck-delay-task \
    --query "taskDefinition.{Revision:revision, Image:containerDefinitions[0].image}" \
    --region us-east-1
```

Expected: a higher revision number than before (e.g. `Revision: 2`) and the new image URI with your commit SHA.

```bash
# Confirm the service is using the new revision
aws ecs describe-services \
    --cluster m5-truck-delay-cluster \
    --services truck-delay-service \
    --query "services[0].{TaskDef:taskDefinition, Running:runningCount, Desired:desiredCount}" \
    --region us-east-1
```

Expected: the `TaskDef` ARN ends in `:2` (or whatever new revision number).

Refresh the ALB URL in your browser — it should still show the dashboard. If you changed something visible (e.g., the title), you should see the new version.

---

## Step 6: Trigger a Real Deploy

Time to prove the CI/CD loop actually closes. Edit something visible:

```python
# In app.py (or wherever the title is set)
st.title("🚛 FreshBasket Truck Delay Prediction Dashboard — v2")  # Add the "— v2"
```

Then:
```bash
git add app.py
git commit -m "Bump title to v2"
git push origin main
```

Watch the Actions tab. ~3-5 minutes later, refresh the ALB URL. The title now reads "v2".

**This is the moment CI/CD pays for itself:** you wrote one workflow file once, and every code change ships automatically forever.

---

## Step 7 (optional sidebar): OIDC federation — the production-grade way

Long-lived IAM access keys in GitHub Secrets are the #1 source of leaked AWS credentials. OIDC federation removes them entirely: GitHub Actions presents a signed JWT to AWS STS, which exchanges it for short-lived credentials (1-hour validity).

### Setup overview (high level)

1. Add GitHub as an OIDC identity provider in IAM:
   ```bash
   aws iam create-open-id-connect-provider \
       --url https://token.actions.githubusercontent.com \
       --client-id-list sts.amazonaws.com \
       --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
   ```

2. Create an IAM role with a trust policy that says "GitHub Actions running in repo X branch Y can assume this role":
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Effect": "Allow",
       "Principal": { "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com" },
       "Action": "sts:AssumeRoleWithWebIdentity",
       "Condition": {
         "StringEquals": {
           "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
         },
         "StringLike": {
           "token.actions.githubusercontent.com:sub": "repo:<GITHUB_OWNER>/<REPO>:ref:refs/heads/main"
         }
       }
     }]
   }
   ```

3. Attach the same ECR/ECS policies as Strategy A to this role.

4. Update the workflow to assume the role via OIDC:
   ```yaml
   permissions:
     id-token: write   # Required for OIDC
     contents: read

   jobs:
     deploy:
       runs-on: ubuntu-latest
       steps:
         - uses: actions/checkout@v4
         - uses: aws-actions/configure-aws-credentials@v4
           with:
             role-to-assume: arn:aws:iam::<ACCOUNT_ID>:role/github-actions-deploy-role
             aws-region: us-east-1
         # ... rest of the workflow unchanged
   ```

5. **Delete the IAM user from Strategy A and remove the access-key secrets from GitHub.** That's the whole point.

Full walkthrough: [GitHub Actions OIDC docs](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services).

---

## Verification Checklist

- [ ] `.github/workflows/deploy.yml` exists on `main`
- [ ] Three GitHub Secrets (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`) are set
- [ ] The latest workflow run on the Actions tab is green
- [ ] `aws ecs describe-task-definition` shows revision ≥ 2
- [ ] Browser at the ALB URL shows the updated dashboard ("v2" in the title)
- [ ] Triggering a second push deploys a new revision within ~5 minutes

---

## What's next — Lab D

You now have GitHub-native CI/CD. Lab D rebuilds the same flow using **AWS-native services**: CodePipeline orchestrates Source → Build → Deploy, CodeBuild runs the Docker build, and the deployment step uses the same `ecs:UpdateService` call you wrote into the GitHub workflow.

After Lab D you'll have two CI/CD pipelines pointing at the same ECS service — useful for understanding both ecosystems, and a real choice you'll face in industry depending on whether your team is GitHub-centric or AWS-centric.

---

## Troubleshooting

| Symptom | Diagnosis | Fix |
|---|---|---|
| Workflow fails at "Configure AWS credentials" | Secret name typo or value pasted with leading/trailing spaces | Re-add the secret, copy-paste carefully |
| `denied: Your authorization token has expired` during push | ECR login token expired mid-build (workflow took >12 h — unlikely) | Re-run the workflow |
| `User: arn:aws:iam::xxx:user/github-actions-deploy is not authorized to perform: ecs:UpdateService` | The CI user doesn't have ECS permissions | Re-do Strategy A's `attach-user-policy` for `AmazonECS_FullAccess` |
| `Service can't be updated. New deployment can't be started.` | Previous deployment still in progress | Wait 2 min and retry; or scale to 0, scale back to 1 |
| Build step takes >10 min | First-build pip install pulls everything | Subsequent builds use Docker layer cache and run in ~30 sec. First build is slow — normal. |
| `Resource: ... not found` for the task definition | The task definition family name in the workflow doesn't match what you registered in Lab A | Confirm `TASK_DEFINITION_FAMILY: truck-delay-task` matches Lab A's `family` field |
| `aws-actions/amazon-ecs-deploy-task-definition` says "service does not exist" | ECS service name mismatch | Confirm `ECS_SERVICE` env var matches Lab A's service name |
| Dockerfile not found in workflow | Repo doesn't have the Dockerfile at the build context | The workflow defaults `BUILD_CONTEXT` to `.` (repo root). If your Dockerfile lives elsewhere, override it: Settings → Variables → Actions → add `BUILD_CONTEXT` = `labs/M4_Lab3_Docker_Compose/app` (or wherever you put it) |

---

## Quick reference — files added

```
your-repo/
└── .github/
    └── workflows/
        └── deploy.yml          ← single file; this is the entire CI/CD config
```

No other code changes required. The IAM user + GitHub Secrets are one-time AWS-side setup.

---

## What you've built

```
git push origin main
       │
       ▼
GitHub Actions runner spins up
       │
       ├── docker build  ───────►  truck-delay-app:<sha> (~2 min)
       │
       ├── docker push  ────────►  ECR: <account>.dkr.ecr.<region>.amazonaws.com/truck-delay-app:<sha>
       │
       ├── Register task def    ─►  truck-delay-task:N (auto-increments revision)
       │
       └── Update ECS service   ─►  Rolling deploy:
                                    1. Start new task with new revision
                                    2. ALB target group health check
                                    3. Deregister old task
                                    4. Stop old task
                                    Total: ~90 sec, zero downtime
       │
       ▼
   http://<ALB_DNS>  →  new version live
```

Lab D builds the same picture with CodePipeline as the orchestrator. The deploy step is identical — only the "what triggers the deploy" part changes.
