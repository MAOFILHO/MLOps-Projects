# M5 Lab D — CodePipeline + CodeBuild Alternative

**Module 5 — CI/CD & Production Deployment | Spine Project: Truck Delay Classification**

| Detail | Value |
|---|---|
| Duration | 45 minutes |
| Difficulty | Intermediate |
| Tools | AWS Console + AWS CLI v2, GitHub repo |
| AWS Services | **CodePipeline**, **CodeBuild**, ECR, ECS, S3 (artifact store), IAM |
| Prerequisite | Lab B complete (ECS + ALB running); GitHub repo from Lab C |
| Builds Toward | M8 capstone uses CodePipeline + Lambda for full automation |
| Cost Estimate | CodeBuild: ~₹1.20 per 10-minute build (general1.small). CodePipeline: ₹85/month per active pipeline. ~₹15 for a class session. |

---

## Learning Objectives

By the end of this lab you will be able to:

1. Explain the three core CodePipeline stages (Source → Build → Deploy) and how they differ from GitHub Actions jobs.
2. Write a `buildspec.yml` that builds, tags, and pushes a Docker image, and produces an `imagedefinitions.json` artifact for the deploy stage.
3. Create a **CodeBuild project** with the right service role, environment image, and Docker support enabled.
4. Wire a **CodePipeline** that polls a GitHub source, runs the CodeBuild project, and deploys to ECS.
5. Compare GitHub Actions and CodePipeline along the dimensions of cost, ergonomics, AWS integration, and team fit.

---

## Business Context

Priya's team is mostly GitHub-centric, so Lab C's GitHub Actions workflow felt natural. But the FreshBasket platform team (responsible for the data pipeline) is all-in on AWS — they want CI/CD that lives inside the AWS Console, integrates with CloudWatch metrics out of the box, and uses IAM roles instead of stored access keys.

In this lab you'll rebuild the same Lab C pipeline using CodePipeline + CodeBuild. The end state is identical (push to `main` → image rebuilt → ECS rolling update). The infrastructure that gets you there is different — and worth knowing because some teams will only use AWS-native tools.

---

## About the AWS CodeSuite stack — first encounter

This lab introduces **three** new AWS services that work together:

### What each service is

| Service | What it is | One-line role in this lab |
|---|---|---|
| **CodePipeline** | A CI/CD *orchestrator* — defines stages (Source → Build → Deploy) and runs them in order | The "conductor" — decides what runs when, in what order |
| **CodeBuild** | A managed *build runner* — spins up a container, runs your commands, throws the container away | The "worker" — runs `docker build` + `docker push` |
| **CodeStar Connections** | An OAuth-based link between AWS and your GitHub account | The "source authenticator" — lets CodePipeline read your repo securely |

Plus two reused services in new roles:
- **S3** — CodePipeline auto-creates a bucket to hand artifacts between stages (Build's output → Deploy's input)
- **IAM** — service roles for CodePipeline and CodeBuild (not the same IAM user pattern as Lab C — these are *AWS-services-assuming-roles*, not external CI tools using long-lived keys)

### How the three pieces fit together

```
GitHub repo
   │  (CodeStar Connection's OAuth token grants read access)
   ▼
CodePipeline ─── Source stage ─── pulls latest commit, drops it in S3 as a zip
                       │
                       ▼
                  Build stage ─── invokes CodeBuild project ─── reads buildspec.yml,
                                          │                      runs `docker build`,
                                          │                      pushes to ECR,
                                          │                      writes imagedefinitions.json
                                          ▼
                                  Output artifact (imagedefinitions.json) → S3 again
                       │
                       ▼
                  Deploy stage ─── reads imagedefinitions.json, calls ecs:UpdateService
                                   with the new image URI → ECS does the rolling deploy
```

Three services, one continuous pipeline. Each has a distinct job.

### The problem this stack solves (specifically for this project)

Lab C wired the same end-to-end deploy using GitHub Actions. So why learn AWS-native CI/CD if the outcome is identical?

**Because some teams won't use anything outside AWS.** Reasons you'll hit in industry:
1. **Compliance**: regulated environments (banking, healthcare, defence) require every audit log, every IAM action, every build artifact to live inside AWS — third-party CI runners are blocked.
2. **Cross-account deploys**: enterprises with separate dev/staging/prod AWS accounts use CodePipeline's native cross-account role assumption — bolt-on with GitHub Actions, native with CodePipeline.
3. **Approval gates**: CodePipeline has a built-in *Manual Approval* action (a human clicks "approve" between stages); doing this in GitHub Actions requires a separate GitHub "Environment" + reviewer config.
4. **No long-lived secrets**: CodePipeline + CodeBuild use IAM service roles — no access keys to leak, no GitHub Secrets to rotate.

For Priya's FreshBasket setup, GitHub Actions is the better default. For the platform team next door (compliance-regulated), CodePipeline is the *only* acceptable choice. Knowing both makes you portable.

### CodePipeline vs CodeBuild — when to use each (or both)

A trap: people sometimes try to use just CodeBuild without CodePipeline. That works for a one-shot build but misses the point of pipelines.

| Capability | CodeBuild alone | CodeBuild + CodePipeline |
|---|---|---|
| Run a build on-demand | ✅ | ✅ |
| Auto-trigger on git push | ❌ (you'd need a webhook + Lambda) | ✅ (CodePipeline subscribes to the source) |
| Chain multiple build/test/deploy steps | ❌ | ✅ (multi-stage pipeline) |
| Manual approval between stages | ❌ | ✅ |
| Cross-account deploys | ❌ | ✅ |
| Cost | $0.005 / build-min | + $1 / active pipeline / month (after the first free) |

Rule of thumb: **CodeBuild = the worker, CodePipeline = the conductor.** You almost always want both.

### Pricing (us-east-1)

| Service | Rate | Cost for a 4-hour class session |
|---|---|---|
| **CodeBuild** (`general1.small`, 3 GB / 2 vCPU) | $0.005 / build-minute ≈ ₹0.41/min | 10 builds × ~3 min = 30 build-min ≈ **~₹12** |
| **CodePipeline** | $1 / active pipeline / month (first one free per account/month) | Free for the first pipeline; **~₹83/month** per additional |
| **CodeStar Connection** | Free | ₹0 |
| **S3 artifact bucket** | $0.025 / GB-month + per-request | Negligible at class scale (~₹1) |
| **Total per session** | | **~₹15** |
| **Monthly idle cost** (one pipeline, no builds) | | **₹0** (first pipeline free) or **₹83/month** for the second pipeline onwards |

> The CodePipeline "first pipeline free" rule is per AWS account per month, not per region — so if you have a real production pipeline in another region, this class pipeline costs ₹83/month while it exists.

### CodePipeline vs GitHub Actions — when to pick which

This is the central question of Lab D. After both labs you'll have built the same pipeline two ways; you should be able to defend either choice.

| Dimension | **GitHub Actions** (Lab C) | **CodePipeline + CodeBuild** (this lab) |
|---|---|---|
| **Setup time** | 15 min (one YAML file + 3 secrets) | 60 min (3 AWS services + IAM + connection) |
| **Where the config lives** | `.github/workflows/*.yml` (in the repo, code-reviewed) | AWS Console (or CFN/CDK if you define-pipelines-as-code) |
| **Auth to AWS** | Stored access keys *or* OIDC | Native IAM service roles (no creds anywhere) |
| **Free at this scale** | Yes (2000 min/month private) | Yes for the first pipeline; ₹83/month for the next |
| **Approval gates** | Build via "Environments" + reviewer | Built-in `Manual approval` action |
| **Cross-account deploys** | Bolt-on (assume role per workflow) | Native (pipeline targets multiple account IDs) |
| **Vendor lock-in** | Runs anywhere via self-hosted runners (Linux/Mac/Win) | AWS-only |
| **Best for** | GitHub-centric teams, OSS, fast iteration | AWS-only teams, regulated industries, multi-account orgs |

**My recommendation for FreshBasket**: GitHub Actions for spine project. CodePipeline becomes relevant if/when (a) regulators require all CI logs in CloudWatch, (b) deploys need to span multiple AWS accounts, or (c) the team wants Console-only operation.

### A heads-up on `buildspec.yml` (the CodeBuild config file)

CodeBuild's equivalent of GitHub Actions' `.github/workflows/deploy.yml` is **`buildspec.yml`** at the repo root. Same idea (a YAML pipeline definition), different syntax. You'll write it in Step 1.

The mental mapping if you know GitHub Actions:

| GitHub Actions | CodeBuild |
|---|---|
| `jobs.<id>.steps[]` | `phases.<phase>.commands[]` |
| `actions/checkout@v4` | (implicit — source is pre-mounted at `/codebuild/output/src.../src`) |
| `secrets.MY_KEY` | `env:` block — supports Parameter Store + Secrets Manager refs |
| `outputs.image` | `artifacts:` block — produces files (like `imagedefinitions.json`) for downstream stages |
| `runs-on: ubuntu-latest` | Configured on the CodeBuild *project*, not in the YAML |

### How this stack compares to what we've already used

| Tool | Where you saw it | Why this lab adds CodePipeline anyway |
|---|---|---|
| **Manual `docker push` + `aws ecs update-service`** | M4 Lab 4 + Lab A end | One-shot, by hand — the very thing CI/CD removes |
| **GitHub Actions** (Lab C) | YAML in your repo triggers a deploy | Same outcome; this lab shows the AWS-native alternative for teams that need it |
| **CodePipeline + CodeBuild** (this lab) | All-in-AWS CI/CD | Required option for compliance / multi-account / "no third-party CI runners" environments |

---

## Prerequisites

### Lab B is still running

```bash
aws ecs describe-services \
    --cluster m5-truck-delay-cluster \
    --services truck-delay-service \
    --query "services[0].{Running:runningCount, Desired:desiredCount, LB:loadBalancers[0].targetGroupArn}" \
    --region us-east-1
```

Expected: `Running: 1, Desired: 1`, with the `LB` field populated.

### GitHub connection (CodePipeline needs read access to your repo)

Unlike GitHub Actions (which runs *inside* GitHub), CodePipeline runs *outside* and needs an authorised channel to your repo. The modern way is an **AWS CodeStar Connection** — an OAuth-based, long-lived link to GitHub that you authorise once. **You don't need a personal access token.**

You can pre-create the connection now, or let the Pipeline-creation wizard prompt you in Step 4. To pre-create:

1. AWS Console → search **Developer Tools** → **Settings** → **Connections** → **Create connection**.
2. Provider: **GitHub**. Name: `truck-delay-github-connection`. Click **Connect to GitHub**.
3. A browser tab opens; **Install a new app** → select your repo (or *All repositories* if you trust the account). Approve.
4. Back in the AWS Console, the connection status flips from `PENDING` to `AVAILABLE`. Copy its ARN — Step 4 will let you select it from a dropdown anyway, but the ARN is handy for CLI/CDK use later.

> **Why not a PAT?** GitHub V1 source providers in CodePipeline used PATs (and that's what older tutorials show). **GitHub V2 / Connections is the current best practice** — short-lived OAuth tokens, finer-grained repo scoping, and no secret to rotate. This lab uses V2 throughout.

---

## Step 1: Write `buildspec.yml`

CodeBuild reads a `buildspec.yml` from the repo root to know what to build. Add this to your repo:

```yaml
# buildspec.yml
version: 0.2

phases:
  pre_build:
    commands:
      - echo "==> Logging in to ECR..."
      - aws ecr get-login-password --region $AWS_DEFAULT_REGION | docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_DEFAULT_REGION.amazonaws.com
      - REPOSITORY_URI=$AWS_ACCOUNT_ID.dkr.ecr.$AWS_DEFAULT_REGION.amazonaws.com/$IMAGE_REPO_NAME
      - COMMIT_HASH=$(echo $CODEBUILD_RESOLVED_SOURCE_VERSION | cut -c 1-7)
      - IMAGE_TAG=${COMMIT_HASH:=latest}
      - echo "    Repository: $REPOSITORY_URI"
      - echo "    Tag:        $IMAGE_TAG"

  build:
    commands:
      - echo "==> Building Docker image..."
      # Build context = the folder containing Dockerfile + app.py + requirements.txt + artifacts/.
      # Lab C's Prerequisites section tells you to copy M4's `app/` folder to the REPO ROOT,
      # so the default `.` is correct. Override the BUILD_CONTEXT env var on the CodeBuild
      # project (Step 2) if you've placed the Dockerfile elsewhere.
      - BUILD_CONTEXT=${BUILD_CONTEXT:-.}
      - docker build -t $REPOSITORY_URI:$IMAGE_TAG "$BUILD_CONTEXT"
      - docker tag  $REPOSITORY_URI:$IMAGE_TAG  $REPOSITORY_URI:latest

  post_build:
    commands:
      - echo "==> Pushing image to ECR..."
      - docker push $REPOSITORY_URI:$IMAGE_TAG
      - docker push $REPOSITORY_URI:latest

      # CodePipeline's ECS deploy action expects this file: it tells ECS
      # which container in the task definition gets the new image URI.
      - echo "==> Writing imagedefinitions.json for the deploy stage..."
      - printf '[{"name":"%s","imageUri":"%s"}]' $CONTAINER_NAME $REPOSITORY_URI:$IMAGE_TAG > imagedefinitions.json
      - cat imagedefinitions.json

artifacts:
  files:
    - imagedefinitions.json
```

### What the env vars are

You'll set these on the CodeBuild project in Step 2 — they're NOT in the YAML:

| Env var | Value (example) |
|---|---|
| `AWS_DEFAULT_REGION` | `us-east-1` (auto-set by CodeBuild) |
| `AWS_ACCOUNT_ID` | Your 12-digit account ID |
| `IMAGE_REPO_NAME` | `truck-delay-app` (matches your ECR repo) |
| `CONTAINER_NAME` | `truck-delay-app` (matches `containerDefinitions[].name` in the task definition) |

### Commit + push

```bash
git add buildspec.yml
git commit -m "Add CodeBuild buildspec"
git push origin main
```

---

## Step 2: Create the CodeBuild Project

### Console clicks

1. AWS Console → **CodeBuild** → **Build projects** → **Create build project**.

2. **Project configuration:**

| Field | Value |
|---|---|
| Project name | `truck-delay-build` |
| Description | `Build + push truck-delay-app to ECR` |
| Build badge | Off |

3. **Source:**

| Field | Value |
|---|---|
| Source provider | **GitHub** |
| Repository | **Repository in my GitHub account** (then click **Connect using OAuth** if first time, or **Manage connections** to use an existing connection) |
| Repository | `your-username/your-repo` |
| Source version | `main` |

4. **Primary source webhook events:** leave the section blank (CodePipeline triggers the build, not GitHub webhooks).

5. **Environment:**

| Field | Value | Why |
|---|---|---|
| Environment image | **Managed image** | AWS provides curated builders |
| Operating system | **Amazon Linux 2** | |
| Runtime(s) | **Standard** | |
| Image | `aws/codebuild/amazonlinux2-x86_64-standard:5.0` (or latest) | |
| Image version | Always use the latest image | |
| Environment type | **Linux** | |
| Privileged | **Enabled** ⚠️ | **REQUIRED for `docker build`.** Without this checkbox, the build will fail with "Cannot connect to the Docker daemon". |
| Service role | New service role (let AWS create one named `codebuild-truck-delay-build-service-role`) | We'll add ECR permissions in Step 3 |

6. **Environment variables** — click **Add environment variable** four times:

| Name | Value | Type |
|---|---|---|
| `AWS_ACCOUNT_ID` | (your 12-digit account ID) | Plaintext |
| `IMAGE_REPO_NAME` | `truck-delay-app` | Plaintext |
| `CONTAINER_NAME` | `truck-delay-app` | Plaintext |
| `AWS_DEFAULT_REGION` | `us-east-1` | Plaintext |

7. **Buildspec:** leave as **Use a buildspec file** (default — reads `buildspec.yml` from repo root).

8. **Artifacts:** leave as **No artifacts** for now (we'll handle this in the CodePipeline; CodeBuild standalone doesn't need artifacts).

9. **Logs:** keep CloudWatch logs enabled — group `/aws/codebuild/truck-delay-build`.

10. **Create build project**.

### Test the CodeBuild project standalone

Click **Start build** on the project page. Watch the **Build logs** tab. Expected progression:

```
Submitted -> Queued -> Provisioning (~30 s) -> Downloading source -> 
PRE_BUILD -> BUILD (~60 s) -> POST_BUILD -> Succeeded
```

If it fails at the `docker build` step, the most common cause is **forgetting to tick "Privileged"** — go back to **Edit project** → **Environment** → check the box → save → retry.

`[SCREENSHOT: CodeBuild Build logs tab showing a green "Succeeded" status and the pushed image URI]`

---

## Step 3: Grant CodeBuild Permissions to Push to ECR

The auto-created service role can read source and write logs, but can't push to ECR. Add the ECR permissions:

```bash
# Find the auto-created role name
CB_ROLE=$(aws iam list-roles \
    --query "Roles[?contains(RoleName, 'codebuild-truck-delay-build')].RoleName" \
    --output text)
echo "CodeBuild role: $CB_ROLE"

# Attach ECR full access (or write your own scoped policy)
aws iam attach-role-policy \
    --role-name $CB_ROLE \
    --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess
```

Re-run the build (CodeBuild → project → **Start build**). It should now `docker push` successfully.

---

## Step 4: Create the CodePipeline

CodePipeline orchestrates the three-stage flow: GitHub (Source) → CodeBuild (Build) → ECS (Deploy).

### Console clicks

1. AWS Console → **CodePipeline** → **Create pipeline**.

2. **Choose creation option:** Build custom pipeline.

3. **Pipeline settings:**

| Field | Value |
|---|---|
| Pipeline name | `truck-delay-pipeline` |
| Execution mode | **Superseded** (cancels in-flight runs when a newer one starts — good default) |
| Service role | New service role |
| Advanced settings → Artifact store | Default location (CodePipeline creates an S3 bucket automatically) |
| Encryption key | Default AWS Managed Key |

4. **Source stage:**

| Field | Value |
|---|---|
| Source provider | **GitHub (Version 2)** |
| Connection | **Connect to GitHub** — opens an OAuth flow. Authorize the **AWS Connector for GitHub** app on your account/repo. |
| Repository name | `your-username/your-repo` |
| Default branch | `main` |
| Trigger | Push in: Branch → `main` |
| Output artifact format | `CodePipeline default` |

5. **Build stage:**

| Field | Value |
|---|---|
| Build provider | **AWS CodeBuild** |
| Project name | `truck-delay-build` (from Step 2) |
| Build type | Single build |

6. **Deploy stage:**

| Field | Value |
|---|---|
| Deploy provider | **Amazon ECS** |
| Cluster name | `m5-truck-delay-cluster` |
| Service name | `truck-delay-service` |
| Image definitions file | `imagedefinitions.json` (matches the artifact your buildspec produces) |

7. **Review** → **Create pipeline**.

The pipeline will automatically run once after creation — it polls the latest commit on `main`, builds it, and deploys.

`[SCREENSHOT: CodePipeline showing all three stages green: Source, Build, Deploy]`

---

## Step 5: Trigger a Real Deploy

Make a visible change to confirm the pipeline works end-to-end:

```python
# In app.py
st.title("🚛 FreshBasket Truck Delay Dashboard — deployed by CodePipeline")
```

Commit + push:
```bash
git add app.py
git commit -m "Bump title to mark CodePipeline deploy"
git push origin main
```

Watch the CodePipeline Console — within ~30 seconds it should detect the push and start running. Total time end-to-end: ~5-7 minutes (~2 min slower than Lab C's GitHub Actions because CodePipeline polls less aggressively).

Refresh the ALB URL. New title visible.

---

## GitHub Actions vs CodePipeline — when to pick which

Now that you've built both, you can speak to the tradeoffs:

| Dimension | GitHub Actions (Lab C) | CodePipeline (Lab D) |
|---|---|---|
| **Setup time** | 15 min (write one YAML file + secrets) | 60 min (CodeBuild + IAM + Pipeline) |
| **Cost** | Free for public, 2000 min/month free for private | ~₹85/month per active pipeline + per-build CodeBuild cost |
| **Where logs live** | GitHub Actions tab | CloudWatch + CodePipeline / CodeBuild Console |
| **AWS integration** | Need to store AWS creds (or set up OIDC) | Native — uses IAM roles directly |
| **Approval gates** | Need a separate job + repository environment | Built-in **Manual approval action** |
| **Multi-env deploys** | Matrix strategy / multiple workflow files | Multiple pipelines or branches in one pipeline |
| **Team fit** | GitHub-centric teams | AWS-centric / regulated teams |
| **Vendor lock-in** | None (GH Actions runs anywhere) | High (CodePipeline only runs on AWS) |
| **Source of truth** | `.github/workflows/*.yml` (in repo, code-reviewed) | Console-configured (some teams use CFN/CDK to define pipelines as code) |

**My recommendation for FreshBasket:** GitHub Actions for the spine project (already GitHub-centric, lower friction). CodePipeline becomes relevant when you have a multi-account AWS setup with cross-account deploys, manual approval gates, or strict compliance requirements forcing all CI/CD into AWS.

For this course, you've now seen both — pick what fits your job context when you graduate.

---

## Verification Checklist

- [ ] `buildspec.yml` exists in the repo root
- [ ] `truck-delay-build` CodeBuild project shows a green "Last build status: Succeeded"
- [ ] CodeBuild service role has `AmazonEC2ContainerRegistryFullAccess` attached
- [ ] `truck-delay-pipeline` CodePipeline shows all three stages green
- [ ] Pushing a new commit triggers the pipeline within ~30 sec
- [ ] After a deploy, `aws ecs describe-task-definition` shows a new revision
- [ ] Both pipelines (GH Actions from Lab C + CodePipeline from Lab D) point at the same ECS service — you can pick which one deploys by which branch you push to (or disable one)

---

## What's next — Lab E

You've covered the core CI/CD story for the spine project. Labs E and F are **alternative-comparison labs**:

- **Lab E: BentoML** — see a fundamentally different way to package an ML model for serving (purpose-built ML framework vs the hand-rolled Streamlit container)
- **Lab F: Kubernetes on Minikube** — see what the K8s equivalent of ECS looks like, so the "should we move to K8s?" conversation isn't a black box

Neither E nor F touches the live ECS deployment. Both are local-only.

---

## Troubleshooting

| Symptom | Diagnosis | Fix |
|---|---|---|
| CodeBuild fails at `docker build` with "Cannot connect to the Docker daemon" | "Privileged" checkbox not ticked on the build project | Edit project → Environment → tick **Privileged** → save → retry |
| `denied: User is not authorized to perform: ecr:GetAuthorizationToken` | CodeBuild service role lacks ECR permissions | Step 3 — attach `AmazonEC2ContainerRegistryFullAccess` to the role |
| CodePipeline Source stage fails: "Could not find any commit reference" | Branch name typo, or the CodeStar Connection doesn't have access to this repo | Verify the branch is `main`; in Console → Developer Tools → Settings → Connections, click your connection → **Update pending connection** and re-authorise the GitHub app for this repo |
| Deploy stage fails: "ECSDeployActionFailed: One or more containers are not running with the desired image" | The `imagedefinitions.json` was malformed or empty | Check the CodeBuild logs for the `cat imagedefinitions.json` line — output should be `[{"name":"truck-delay-app","imageUri":"..."}]` |
| Deploy stage waits forever and times out | ECS rolling update is stuck (e.g., target group health check failing) | Check ECS service Events tab; check ALB target group health |
| CodePipeline takes >10 min between push and start | Polling-based source — CodePipeline polls every 30 sec to 2 min | The webhook should be set up; verify in your GitHub repo Settings → Webhooks (you should see an `aws-codepipeline-codecommit-*` entry) |

---

## Teardown (Lab D only — keeps Labs A, B, C intact)

```bash
# 1. Delete the pipeline (removes the webhook automatically)
aws codepipeline delete-pipeline \
    --name truck-delay-pipeline \
    --region us-east-1

# 2. Delete the CodeBuild project
aws codebuild delete-project \
    --name truck-delay-build \
    --region us-east-1

# 3. Empty + delete the artifact bucket (created automatically by CodePipeline)
BUCKET=$(aws s3 ls | grep codepipeline | awk '{print $3}')
aws s3 rm s3://$BUCKET --recursive
aws s3 rb s3://$BUCKET

# 4. (Optional) Delete the CodeStar Connection to GitHub
aws codestar-connections list-connections --region us-east-1 \
    --query "Connections[?ConnectionName=='truck-delay-github-connection'].ConnectionArn" \
    --output text \
    | xargs -I {} aws codestar-connections delete-connection \
        --connection-arn {} --region us-east-1
```

ECS service + ALB + GitHub Actions workflow remain untouched.
