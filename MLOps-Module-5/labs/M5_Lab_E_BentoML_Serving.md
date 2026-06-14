# M5 Lab E — BentoML Serving

**Module 5 — CI/CD & Production Deployment | Alternative serving framework**

| Detail | Value |
|---|---|
| Duration | 45 minutes |
| Difficulty | Beginner-Intermediate |
| Tools | Python 3.10+, Docker Desktop, browser |
| AWS Services | None (local-only lab) |
| Prerequisite | Lab A complete (you have the Truck Delay XGBoost model from M3 Lab C); Docker Desktop installed |
| Builds Toward | M7 (alternative serving + Model Registry pattern) |
| Cost Estimate | ₹0 — fully local |

---

## Learning Objectives

By the end of this lab you will be able to:

1. Explain what BentoML solves and how it differs from hand-rolling a Streamlit/Flask container.
2. Save a scikit-learn / XGBoost model to BentoML's model store.
3. Write a **`Service`** definition (`service.py`) with API endpoints decorated by `@bentoml.api`.
4. Build a **Bento** (a self-contained model + service bundle) and inspect its contents.
5. Use `bentoml containerize` to produce a production-grade Docker image — without writing a Dockerfile yourself.
6. Compare BentoML against Streamlit (the M4 self-contained dashboard) and hand-rolled Flask + Gunicorn (Branch project).

---

## Business Context

The Truck Delay Streamlit dashboard is great for ops staff who want to *explore* predictions interactively. But the FreshBasket platform team has a second use case: **other internal services need to call the model as a REST API**. The fleet-routing service wants to query "given this truck + this route + this driver, what's the delay probability?" 50,000 times a day. Streamlit isn't built for that — it's a UI framework, not an API server.

You could write a Flask + Gunicorn API yourself (the branch project does exactly this). Or you could use BentoML, a Python framework purpose-built for ML serving that handles the boring parts: input validation, OpenAPI doc generation, batching, GPU memory management, and Docker image creation.

In this lab you'll BentoML-ize the M3 XGBoost model and see what changes.

---

## About BentoML — first encounter

### What it is

**BentoML is an open-source Python framework purpose-built for packaging + serving ML models.** You give it a saved model + a Python function that calls it, and BentoML emits:
- A REST API server (with auto-generated OpenAPI/Swagger docs)
- A Docker image with multi-stage build, non-root user, healthchecks — production-grade, no Dockerfile required
- A versioned artifact (the "Bento") containing the model + code + pinned dependencies

Two new vocabulary words:

| Word | What it is | Mental model |
|---|---|---|
| **Bento** | A self-contained directory bundling model + service code + Python deps + Dockerfile | A *deployable artifact* — like a Docker image but at the model+service layer |
| **Service** | A Python class (or in older API, a `bentoml.Service` instance) with `@bentoml.api` methods | The HTTP surface — each `@bentoml.api` becomes a REST endpoint |

Note: this lab uses the **0.4.x API** with `bentoml.Service(...)` + `@svc.api(...)`. BentoML 1.4+ introduced a newer `@bentoml.service` class decorator. The concepts are identical; the syntax shifted. We pin to `<1.4` so the lab code runs unchanged.

### The problem it solves (specifically for this project)

The M4 image is a Streamlit dashboard — a UI for humans. The fleet-routing service can't call it because it doesn't speak HTTP-with-JSON, it speaks Streamlit's WebSocket protocol with session state. So if you need an API instead of a UI, you have three real options:

| Approach | What you write | What you skip |
|---|---|---|
| **Hand-rolled Flask + Gunicorn** (Branch project) | Routes, JSON parsing, error handling, Pydantic schemas, Dockerfile, OpenAPI by hand | Nothing — you write it all |
| **FastAPI** | Same as Flask but with Pydantic + auto-OpenAPI built in | The OpenAPI generation; still write the Dockerfile + serving infra |
| **BentoML** (this lab) | One `service.py` file with `@svc.api` decorators | Dockerfile, OpenAPI spec, input validation, batching, model loading, health endpoints — all auto-generated |

For one model served once, the savings are modest. For a platform team standardising 20+ ML services, BentoML's "you write the prediction logic, we handle the rest" pays for itself in week one — same image template, same monitoring shape, same deployment story across every model.

### How BentoML differs from the other serving patterns you've seen

| Need | Pattern | Where in M5 |
|---|---|---|
| **Interactive UI for ops staff** | Streamlit | M4 Lab 3, deployed in M5 Labs A-D |
| **REST API for internal services with auto-docs + batching** | **BentoML** | This lab |
| **Custom UI with full control over routes / templating / middleware** | Flask + Gunicorn | M5 Branch project |
| **gRPC services at very high QPS** | BentoML's gRPC mode, or hand-rolled gRPC | Out of scope for this course |
| **Real-time / streaming predictions** | Kafka consumer + custom service | Out of scope |

The takeaway: **the serving framework should follow the consumer**. Pick BentoML when machines are the consumer; Streamlit when humans are; Flask when you need full control.

### What you DON'T provision in this lab

This is intentionally a **local-only lab**. BentoML produces a Docker image; you run it on your laptop with `docker run`. **No AWS services are touched.** The optional Step 6 sketches how you'd push the image to ECR and run it on ECS (the same pattern as Labs A-D), but doesn't execute it.

Why local-only? The deployment story (ECR → ECS → ALB) is identical to what you've already done in Labs A-D — re-doing it for the BentoML image adds zero new learning. The lab's job is to teach you the *packaging* shift; deployment is a strict subset of what you already know.

### Pricing

BentoML itself is **open-source and free**. The only cost is what you use to run the Bento:

| Where you run it | Cost |
|---|---|
| **Your laptop** (this lab) | ₹0 |
| **ECS Fargate** (optional Step 6 — if you do the full deployment) | Same ~₹2/hour as Lab A's Streamlit task |
| **BentoCloud** (BentoML's hosted SaaS — not used in this lab) | Pay-as-you-go; ~$0.10-0.40/hour per replica depending on size |

There's also a managed product, **BentoCloud**, that hosts the Bento for you (skip ECS entirely). Not in this lab; mentioned so you know it exists.

### How BentoML compares to the tools we've already used

| Tool | What it does | Why BentoML is different |
|---|---|---|
| **Streamlit** (M4 / M5 spine) | Interactive UI framework | Not an API server — built for humans, not service-to-service calls |
| **Docker / `docker build` + Dockerfile** (M4 Labs 1-2) | Generic container packaging | BentoML *generates* the Dockerfile + image for you; you don't write either |
| **ECR** (M4 Lab 4) | Image registry | Compatible — BentoML's image pushes to ECR the same way; ECR doesn't care what tool built the image |
| **ECS Fargate** (Lab A) | Container runtime | Compatible — the BentoML image runs on ECS unchanged; you'd just create a second task definition pointing at the BentoML image instead of the Streamlit one |

The progression: M4 packaged a UI (Streamlit container). This lab packages an API for the same model. M5 Branch packages the UI's underlying model behind a hand-rolled Flask API. Three serving patterns for the same XGBoost model — you'll know when to reach for each.

---

## Prerequisites

### Trained XGBoost model

You need the trained XGBoost model artifact. Three sources, easiest first:

1. **From M4 (recommended).** The M4 self-contained app ships the trained model alongside the code:
   ```bash
   cp "Module 4/labs/M4_Lab3_Docker_Compose/app/artifacts/xgboost_model.pkl" ./xgb-truck-model.pkl
   ```
   This is the same XGBoost model used by the M4 Streamlit dashboard and the M5 spine deployment.
2. **From your M3 S3 bucket** (if you ran M3 Lab C end-to-end and uploaded the model):
   ```bash
   aws s3 cp s3://<your-bucket>/models/xgb-truck-model.pkl ./xgb-truck-model.pkl
   ```
3. **Toy model fallback.** If neither M3 nor M4 artifacts are available, use the synthetic-data snippet in Step 1 — predictions will be nonsense, but the BentoML deployment shape is identical.

### Local environment

> **🚨 Python version matters.** Use **Python 3.12.10 exactly** (the course standard). The `scikit-learn==1.4.0` pin below has no Python 3.13 / 3.14 wheel — pip will fall back to a source build that fails. Per-OS guidance for explicitly invoking Python 3.12:
>
> - **🪟 Windows**: `/c/Users/<you>/AppData/Local/Programs/Python/Python312/python.exe -m venv .venv-bentoml` (Git Bash) or `& "C:\Users\<you>\AppData\Local\Programs\Python\Python312\python.exe" -m venv .venv-bentoml` (PowerShell).
> - **🍎 macOS via Homebrew**: `brew install python@3.12` once, then `python3.12 -m venv .venv-bentoml`. The binary lives at `/opt/homebrew/bin/python3.12` (Apple Silicon) or `/usr/local/bin/python3.12` (Intel).
> - **🍎 macOS via pyenv** (preferred if you juggle multiple Python versions): `pyenv install 3.12.10 && pyenv shell 3.12.10 && python -m venv .venv-bentoml`.
> - **🐧 Linux**: `sudo apt install python3.12 python3.12-venv` (Ubuntu 22.04+) or your distro equivalent, then `python3.12 -m venv .venv-bentoml`.
>
> Verify with `.venv-bentoml/bin/python --version` (macOS/Linux) or `.venv-bentoml/Scripts/python.exe --version` (Windows) — it must print exactly `Python 3.12.x`.

```bash
# Create a fresh venv for BentoML so it doesn't fight with the Streamlit env
python3.12 -m venv .venv-bentoml
source .venv-bentoml/bin/activate          # Windows: .venv-bentoml\Scripts\activate

# Note the setuptools<80 pin: BentoML's transitive dep `fs` still imports `pkg_resources`,
# which setuptools 80+ removed. Without this pin, `bentoml save_model` errors with
# ModuleNotFoundError: No module named 'pkg_resources'.
pip install -q \
    "bentoml>=1.2,<1.4" \
    "setuptools<80" \
    "xgboost==2.0.3" \
    "scikit-learn==1.4.0" \
    "numpy<2.0" \
    "pandas==2.2.0"

bentoml --version
# Expected: bentoml, version 1.2.x or 1.3.x (we pin <1.4 because the lab uses the
# IO-descriptor API from bentoml.io, which 1.4+ replaced with a new @bentoml.service
# decorator. If you want to see the new API, the BentoML quickstart docs cover it.)
```

### Docker Desktop running

```bash
docker --version
docker info | grep -i "server version"     # confirms daemon is reachable
```

---

## Step 1: Save the Model to BentoML's Model Store

BentoML maintains a local registry of saved models (`~/bentoml/models/`). Each save gets a tag like `<model_name>:<version>`. The framework can load any saved model by tag, regardless of how/where you trained it.

```python
# save_model_to_bentoml.py
import bentoml
import joblib

# Load your M3 XGBoost model. If you don't have it, see the fallback below.
model = joblib.load("xgb-truck-model.pkl")

# Save into BentoML's local store
saved = bentoml.xgboost.save_model(
    "truck_delay_xgb",        # model name in the store
    model,
    signatures={
        "predict": {"batchable": True, "batch_dim": 0},
        "predict_proba": {"batchable": True, "batch_dim": 0},
    },
    metadata={
        "source_lab": "M3 Lab C",
        "n_features": 36,
        "f1_baseline": 0.679,
    },
)

print(f"Saved: {saved}")
# Expected: Model(tag="truck_delay_xgb:abc123def...", ...)
```

Run it:

```bash
python save_model_to_bentoml.py
```

### Fallback: train a toy model if you don't have the real one

```python
# toy_train.py
import xgboost as xgb
import numpy as np
import bentoml

X = np.random.rand(1000, 36)
y = (X.sum(axis=1) > 18).astype(int)

model = xgb.XGBClassifier(n_estimators=50, eval_metric="logloss")
model.fit(X, y)

bentoml.xgboost.save_model(
    "truck_delay_xgb",
    model,
    signatures={
        "predict":       {"batchable": True, "batch_dim": 0},
        "predict_proba": {"batchable": True, "batch_dim": 0},
    },
)
```

This gives BentoML something to bundle for the rest of the lab — the predictions will be nonsense, but the deployment shape is identical.

### Inspect the BentoML model store

```bash
bentoml models list
```

Expected output:
```
 Tag                          Module             Size       Creation Time
 truck_delay_xgb:abc123def... bentoml.xgboost    140.32 KiB 2026-05-23 11:42:33
```

```bash
bentoml models get truck_delay_xgb:latest
```

Shows the model's metadata, signatures, and on-disk path.

---

## Step 2: Write the Service (`service.py`)

A BentoML **Service** wraps the model + your prediction logic and defines the API surface (endpoints, input validation, output format).

```python
# service.py
import bentoml
import numpy as np
from bentoml.io import JSON, NumpyNdarray

# Load the model handle (lazy — BentoML loads on first request)
truck_delay_runner = bentoml.xgboost.get("truck_delay_xgb:latest").to_runner()

# Create the service — name it; BentoML uses this for the OpenAPI title + image name
svc = bentoml.Service(
    name="truck_delay_service",
    runners=[truck_delay_runner],
)


@svc.api(input=NumpyNdarray(dtype="float32", shape=(-1, 36)), output=JSON())
async def predict(features: np.ndarray) -> dict:
    """Return delay predictions for a batch of trips.

    Input
    -----
    features : np.ndarray shape (n_trips, 36)
        Feature matrix in the same order Lab C used during training.

    Output
    ------
    {
      "predictions": [0, 1, 0, ...],          # 0 = on-time, 1 = delayed
      "probabilities": [0.23, 0.67, 0.12, ...] # delay probability per trip
    }
    """
    probs = await truck_delay_runner.predict_proba.async_run(features)
    preds = (probs[:, 1] >= 0.5).astype(int)
    return {
        "predictions":   preds.tolist(),
        "probabilities": probs[:, 1].round(4).tolist(),
    }


@svc.api(input=JSON(), output=JSON())
async def predict_single(payload: dict) -> dict:
    """Single-trip prediction, accepts the feature dict directly.

    Input JSON example:
      {"truck_age": 12, "distance": 450, "route_avg_precip": 5.2, ...}
    """
    # Convert payload dict to feature matrix in training order
    feature_order = payload.get("_feature_order") or list(payload.keys())
    if "_feature_order" in payload:
        del payload["_feature_order"]
    x = np.array([[payload[k] for k in feature_order]], dtype="float32")

    probs = await truck_delay_runner.predict_proba.async_run(x)
    return {
        "delay_pred": int(probs[0, 1] >= 0.5),
        "delay_prob": float(probs[0, 1].round(4)),
    }
```

### What's interesting here

- **`runners`** — BentoML separates "API server" from "model server". Runners run as separate processes; you can scale them independently. For low traffic this is invisible; for high traffic you can give the runner 4 CPU + 8 GB RAM while the API server stays on 1 CPU.
- **`async`** — BentoML uses asyncio under the hood. `async_run` returns a coroutine, letting the API server handle hundreds of concurrent requests with one thread.
- **`NumpyNdarray(dtype="float32", shape=(-1, 36))`** — input validation. BentoML rejects requests that don't match this shape, automatically, with a clean 400 error.
- **`@svc.api(... output=JSON())`** — return values are serialised to JSON automatically. No `jsonify(...)` boilerplate.

---

## Step 3: Test the Service Locally (Hot-Reload Dev Mode)

```bash
bentoml serve service.py:svc --reload
```

`--reload` watches for file changes and restarts. Expected startup output:

```
[INFO]  Starting development BentoServer from "service.py:svc"
[INFO]  Service loaded from Python module: service:svc
[INFO]  Starting production HTTP BentoServer from "service.py:svc"
running on http://0.0.0.0:3000 (Press CTRL+C to quit)
```

In another terminal, hit the `/predict` endpoint:

```bash
# 5 random feature vectors of shape (5, 36)
curl -X POST http://localhost:3000/predict \
  -H "Content-Type: application/json" \
  -d "$(python -c 'import numpy as np; import json; print(json.dumps(np.random.rand(5, 36).astype(float).tolist()))')"
```

Expected:
```json
{
  "predictions":   [0, 1, 0, 1, 0],
  "probabilities": [0.23, 0.67, 0.18, 0.71, 0.34]
}
```

### Inspect the auto-generated OpenAPI / Swagger doc

Open `http://localhost:3000/` in a browser. BentoML serves an interactive Swagger UI listing every `@svc.api` endpoint with the input schema, example payloads, and a "Try it out" button. **You didn't write any of this** — it's generated from the type hints.

`[SCREENSHOT: Browser at http://localhost:3000 showing the BentoML Swagger UI with /predict and /predict_single endpoints]`

Compare this to the M3 Streamlit dashboard: same model, totally different surface. Streamlit gives you a UI; BentoML gives you a programmatic API with auto-docs. Pick the right one for the consumer.

---

## Step 4: Build the Bento

A **Bento** is BentoML's deployable artifact — a self-contained directory with the model, the service code, the Python dependencies, and a generated Dockerfile.

Create `bentofile.yaml` in the same folder as `service.py`:

```yaml
service: "service:svc"

include:
  - "service.py"

python:
  requirements_txt: ./requirements.txt
  # or pin packages inline:
  # packages:
  #   - "bentoml>=1.2"
  #   - "xgboost==2.0.3"
  #   - "numpy<2.0"

docker:
  python_version: "3.12"
  distro: "debian"
  cuda_version: null         # CPU-only — change for GPU workloads
```

Create the `requirements.txt` (pins match Step 1 — `bentoml<1.4` for the IO-descriptor API; `setuptools<80` because BentoML's `fs` transitive dep still imports `pkg_resources`):

```txt
bentoml>=1.2,<1.4
setuptools<80
xgboost==2.0.3
scikit-learn==1.4.0
numpy<2.0
pandas==2.2.0
```

Build:

```bash
bentoml build
```

Expected output:

```
Building BentoML service "truck_delay_service:abc123..."

✓ Inferring model "truck_delay_xgb:latest"
✓ Locking python package versions
✓ Bundling service code and dependencies

Successfully built Bento(tag="truck_delay_service:abc123...")
```

### What's inside a Bento?

```bash
bentoml list
```

Find your tag, then:

```bash
ls -la $(bentoml get truck_delay_service:latest --output path)
```

Inside, you'll see:
- `apis/` — your service.py
- `env/python/` — pinned dependencies
- `models/` — the saved model artifact
- `Dockerfile` — auto-generated, multi-stage, production-grade

The Bento is the **immutable artifact** — same idea as a Docker image, but at the model+service layer.

---

## Step 5: Containerize the Bento

This is the "BentoML killer feature": one command, no Dockerfile to write.

> **🍎 Apple Silicon (M1/M2/M3/M4) — read this before running `bentoml containerize`.** Docker on Apple Silicon builds **ARM64** images by default. That's fine for local `docker run` on your Mac. But if you push the image to ECR and try to run it on default ECS Fargate (which is **x86_64**), the task will crash with `exec format error`. Two options:
> - **Local-only run** (most of this lab) — leave the default. Your Mac runs ARM64 images natively. No change needed.
> - **You plan to push to ECR + run on Fargate** (Step 6 optional) — force an x86_64 build by passing the BentoML `--platform` flag (which threads through to `docker build`):
>   ```bash
>   bentoml containerize truck_delay_service:latest --platform=linux/amd64
>   ```
>   The build will be slower (QEMU emulation), but the resulting image runs on default Fargate without changes. Alternative: pass `--opt platform=linux/arm64` and configure the ECS task definition's `runtimePlatform.cpuArchitecture: ARM64` — Fargate supports ARM64 task definitions natively.
>
> Intel Mac / Windows / Linux users — ignore this callout, your host is already x86_64.

```bash
bentoml containerize truck_delay_service:latest
```

Expected output (takes ~2-3 min):

```
Building OCI-compliant image for truck_delay_service:abc123 ...
Step 1/15 : FROM python:3.12-slim
...
Successfully tagged truck_delay_service:abc123def...
```

Verify:

```bash
docker images | grep truck_delay_service
# truck_delay_service   abc123def...   ...   ~1.1 GB

# Apple Silicon users: confirm the architecture you built for
docker image inspect truck_delay_service:latest --format '{{.Architecture}}'
# Expected: amd64 (if you used --platform=linux/amd64) or arm64 (default on Apple Silicon)
```

### Run the container locally

```bash
docker run -d -p 3000:3000 --name bentoml-truck-delay truck_delay_service:latest
```

Wait 5 seconds for startup, then:

```bash
curl http://localhost:3000/healthz
# Expected: {"status":"healthy"}
```

Hit the prediction endpoint:

```bash
curl -X POST http://localhost:3000/predict \
  -H "Content-Type: application/json" \
  -d "$(python -c 'import numpy as np; import json; print(json.dumps(np.random.rand(2, 36).astype(float).tolist()))')"
```

Same response as Step 3, but now coming from a production-grade container that's:
- Multi-stage (small final image — only runtime deps)
- Non-root user (security)
- Configured with a graceful shutdown hook
- Equipped with `/healthz` and `/livez` endpoints out of the box
- OpenTelemetry traces wired up if you want them

You didn't write a single line of Dockerfile.

---

## Step 6 (optional): Push the BentoML Image to ECR

To deploy the BentoML container to ECS the same way you deployed Streamlit, you'd push it to ECR:

```bash
# 1. Tag for ECR (replace <ACCOUNT_ID>)
docker tag truck_delay_service:latest \
    <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/truck-delay-bentoml:v1

# 2. Push
aws ecr create-repository --repository-name truck-delay-bentoml --region us-east-1
aws ecr get-login-password --region us-east-1 \
    | docker login --username AWS --password-stdin <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com
docker push <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/truck-delay-bentoml:v1
```

You'd then create a second ECS task definition + service for the BentoML container (port 3000 instead of 8501) and put it behind the ALB at a path like `/api/*` while keeping Streamlit at `/`. That's a "good for you to try at home" extension; this lab stops at the local Docker run.

---

## When to pick BentoML vs hand-rolled Flask vs Streamlit

| Need | Best framework |
|---|---|
| **Interactive UI for ops staff** | Streamlit (M4 self-contained dashboard) |
| **REST API for internal services** with auto-generated docs + batching + minimal boilerplate | **BentoML** |
| **Custom UI with full control over routes / templating / middleware** | Flask + Gunicorn (Branch project) |
| **gRPC services at very high QPS** | BentoML (supports gRPC) or a hand-rolled gRPC server |
| **Real-time / streaming predictions** | gRPC or Kafka consumer — not the focus of M5 |

The takeaway: **the framework should follow the consumer**. Don't BentoML-ize a model that only an ops dashboard ever uses — Streamlit is fewer moving parts.

---

## Verification Checklist

- [ ] `bentoml models list` shows `truck_delay_xgb:<version>`
- [ ] `bentoml serve service.py:svc` starts and `curl http://localhost:3000/predict` returns valid JSON
- [ ] `bentoml build` produced a Bento; `bentoml list` shows it
- [ ] `bentoml containerize` produced a Docker image; `docker images` shows it (~1 GB)
- [ ] `docker run` of the BentoML image returns 200 from `/healthz`
- [ ] You understand the difference between a Bento (artifact) and the BentoML image (deployment unit)

---

## What's next — Lab F

Lab F switches gears to **Kubernetes via Minikube** — local-only, focused on understanding K8s primitives (Pod, Service, Deployment). It's the conceptual counterweight to ECS: same kind of problem (run containers as a service), totally different abstractions. After Lab F you'll be able to read a K8s manifest without flinching.

---

## Troubleshooting

| Symptom | Diagnosis | Fix |
|---|---|---|
| `bentoml.exceptions.NotFound: model 'truck_delay_xgb' not found` | The model store doesn't have this name | Run `save_model_to_bentoml.py` again. Check with `bentoml models list`. |
| `ImportError: No module named 'xgboost'` during `bentoml serve` | xgboost not in the active venv | `pip install xgboost==2.0.3` and retry |
| `bentoml containerize` fails: "Cannot connect to the Docker daemon" | Docker Desktop isn't running | Start Docker Desktop; wait for the whale icon |
| `bentoml build` fails: "service:svc not found" | `service.py` not in the current directory or the variable name is wrong | Run from the same folder; `service:svc` means file `service.py`, variable `svc` |
| Container starts but `/predict` returns 500 | Often a serialization issue — input shape mismatch | Check `bentoml serve` logs for the Python traceback; verify the `NumpyNdarray(shape=...)` annotation matches your input |
| `numpy.dtype size changed` warning at import | NumPy 2.x is installed but xgboost/scikit-learn were built against 1.x | `pip install "numpy<2.0"` and reinstall xgboost |
| `ModuleNotFoundError: No module named 'pkg_resources'` on `bentoml save_model` or `bentoml serve` | `setuptools>=80` removed the bundled `pkg_resources` module; BentoML's `fs` transitive dep still imports it | `pip install "setuptools<80"` in the venv (already in our Step 1 install line) |
| `pip install scikit-learn==1.4.0` fails to build (`error: command ... failed`) | You're on Python 3.13 or 3.14; sklearn 1.4.0 only has wheels through 3.12 | Re-create the venv with Python 3.12.10 explicitly. See the Local-environment warning at the top of this section. |
| Fargate task crashes with `exec format error` after you pushed the BentoML image to ECR | You built the image on Apple Silicon (ARM64), but Fargate's default architecture is x86_64 | Rebuild with `bentoml containerize ... --platform=linux/amd64`, re-push, redeploy. See the Apple Silicon callout in Step 5. |

---

## Teardown

```bash
# Stop + remove the local container
docker stop bentoml-truck-delay
docker rm bentoml-truck-delay

# (Optional) Remove the BentoML image
docker rmi truck_delay_service:latest

# (Optional) Clear BentoML's local store
bentoml delete truck_delay_service:latest -y
bentoml models delete truck_delay_xgb:latest -y
```

ECR cleanup (if you did Step 6 optional):
```bash
aws ecr delete-repository --repository-name truck-delay-bentoml --force --region us-east-1
```
