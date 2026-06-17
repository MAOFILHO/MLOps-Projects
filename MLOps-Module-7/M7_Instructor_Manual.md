# Module 7 — Instructor Manual
## Feature Stores, Experiment Management & Explainability

Teaching guide: pre-class checklist, Tier-2 demo SOP, per-lab talking points, timing, and troubleshooting. Pairs with
the student-facing [M7_Guide.md](M7_Guide.md) (walkthrough + concepts + interview questions).

---

## Pre-class checklist (the day before / morning of)

- [ ] **SageMaker notebook** `m6-truck-delay-monitoring` is **Started** (it auto-stopped overnight). Same VPC, ap-south-1.
- [ ] **MLflow server** *(optional but recommended for the shared-registry demo)*: `cd Module 7/instructor_setup &&
      cdk deploy -c mlflow_ui_cidr=<classroom-ip>/32`. Copy the `MlflowTrackingUri` output → students set
      `MLFLOW_TRACKING_URI`. Verify the UI loads (~2 min post-deploy). **If the server isn't up, Lab 2 still runs** — it
      falls back to a local `sqlite:///mlflow.db` (registry-capable). The UI demo is nicer on the shared server, though.
- [ ] **Hopsworks project** pre-created at app.hopsworks.ai; have a project name ready for the Tier-2 demo. Confirm
      students can self-register (free Serverless tier).
- [ ] **W&B**: confirm students can sign up at wandb.ai (free). No instructor infra.
- [ ] Confirm `labs/data/` (real `final_features.csv` + artifacts) is present on each notebook instance (clone the repo or
      it's baked into the instance volume).

## Tier-2 demo SOP (first 20 min)
1. **MLflow server (5 min):** open the UI. "This tracking server has conceptually run since M3 — here's the CDK that
      deploys it (`m7_stack.py`), and here's the CloudFormation stack. You'll register the real model into it in Lab 2."
2. **Hopsworks project (10 min):** open app.hopsworks.ai → the project → Feature Store. "This is pre-created. In Lab 1 you
      register the real M3 features here. Note the online vs offline stores."
3. **Frame the day (5 min):** the four tools = the four things that turn a model into a managed asset (show the through-line
      table in [M7_Guide.md §3.1](M7_Guide.md#3-the-concepts--the-why)). Everything uses the **real** M3 artifacts — no synthetic data.

---

## Per-lab teaching notes

### Lab 1 — Hopsworks Feature Store (90 min)
- **Concept-first notebook:** the lab now opens with ~6 markdown cells (0a–0e) on *what a feature store is*, training/serving
  skew, offline-vs-online, the popular tools (open-source vs cloud-managed), and the 5 key terms. These can be **pre-read**;
  in class, recap them in ~5 min so the hands-on lands. Each hands-on step has a "what we're doing" intro **and** a
  "✅ Result — read it" cell, so students who fall behind can self-recover.
- **Talking point:** the surrogate `trip_id` + `event_time` are *store metadata*, not model features — pre-empt "where did
  trip_id come from?". The model still trains on the same 36 columns.
- **New steps to call out:** feature **descriptions** (governance metadata in the Schema tab) and **statistics /
  histograms** (Statistics tab) — explicitly tie statistics back to M6 drift baselines. The **read-back**
  (`select_all().read()`) proves the round-trip.
- **Watch for:** free-tier insert jobs + `compute_statistics()` are slow (shared compute) — `wait_for_job=True` blocks; tell
  students to be patient. The API-key cell is portable (env var / Colab secret / hidden prompt) — no key in the notebook.
- **Land the concept:** online vs offline **parity**. Ask: "what breaks if training reads one CSV and serving recomputes
  the feature slightly differently?" → training/serving skew. The `get_feature_vector` step is where parity becomes concrete.

### Lab 2 — MLflow Model Registry (60 min hands-on; concepts 0a–0e are a pre-read)
- **Concept-first notebook:** opens with *why a registry vs `joblib.dump`*, **tracking vs registry**, the tracking-store
  anatomy (**why the registry needs a DB backend**, hence SQLite/server not the `./mlruns` file store), the **lifecycle**,
  and the **stages-vs-aliases** caveat. Recap in ~5 min.
- **Portability fix (important):** the setup cell that was previously **commented out** is now active — that was the
  "mlflow import error." The lab **pins `mlflow==2.14.1`** (MLflow 3 removed stages) and **falls back to
  `sqlite:///mlflow.db`** if `MLFLOW_TRACKING_URI` is unset, so every student can finish even without the server.
- **Talking point:** we log the *real* model + its true metrics + a signature — no retraining. The registry is about
  *governance*, not training.
- **New steps:** a real **rollback drill** (register v2 → promote → revert to v1, both retained) and **governance
  metadata** (model/version descriptions + tags) — mirrors Lab 1's feature descriptions.
- **Watch for:** `Connection refused` on an `http://` URI = server down → tell students to **unset** `MLFLOW_TRACKING_URI`
  and rerun (local SQLite). `transition_model_version_stage` errors = MLflow 3 got installed → `pip install "mlflow<3"`.
- **Land the concept:** promotion to Production is an **approval gate**, loading is **by stage** (not file path), and
  rollback is **one call**. In M8 the promotion becomes a pipeline condition step.

### Lab 3 — W&B Sweeps (60 min hands-on; concepts 0a–0e are a pre-read)
- **Pre-empt "we already tuned in M2":** the notebook opens (0a) by answering exactly this — Optuna/PyCaret *optimize*;
  W&B *tracks, visualizes, orchestrates, shares*. They compose (Optuna can be the sampler inside a W&B sweep). Make this
  the framing of the whole lab; the M2 runs being un-trackable is the gap.
- **Tracking before sweeping:** Step 3 logs a single baseline run (`val_f1 ≈ 0.686`) so students see one run in the UI
  before the sweep — and it's the yardstick the sweep must beat (best ≈ 0.7048, +0.019 F1).
- **Talking point:** Bayesian search *learns* — point out in the agent log how it shifts to `max_depth: 8` after shallow
  trees score low. Open the parallel-coordinates + parameter-importance panels live (Step 9).
- **Results read three ways:** programmatic best-run (Step 6), a pandas leaderboard + correlation (Step 7), the dashboard
  (Step 9). Step 8 logs the winner as a W&B **Artifact** — the handoff to Lab 2's MLflow registry.
- **Watch for:** API-key setup eats time — have everyone `wandb.login` before the sweep cell.
- **Land the concept:** sweep in W&B → register the winner in MLflow → M8 promotes it. Tools compose, they don't compete.

### Lab 4 — SHAP (60 min hands-on; concepts 0a–0f are a pre-read)
- **Concept-first notebook:** opens with *what explainability is & why*, the **techniques map** (intrinsic vs post-hoc,
  global vs local, model-specific vs agnostic), **LIME vs SHAP**, **how Shapley values are computed** (incl. a 2-feature toy
  example + the explainer table), and a plot-reading cheat-sheet. Recap in ~5 min; the rest is hands-on.
- **The additivity demo (Step 3) is the centrepiece:** `base + Σ(SHAP) = predict_proba`. This is what makes SHAP "explain
  the label" rather than give vague importance — land it before the plots.
- **Two concrete records:** Step 5 explains a predicted-**delayed** shipment, Step 6 a predicted-**on-time** one, each as a
  feature/value/SHAP table reducible to one sentence. The local waterfall is "the chart you show the ops lead / regulator."
- **Numeric outputs by design:** global importance is a **table** (mean |SHAP|) before the beeswarm, so results are
  inspectable even without rendering the images.
- **Watch for:** modern `shap` (≥0.44) works with **numpy 2** — no `numpy<2` pin needed; just `pip install -U shap`.
- **Land the concept (the day's climax):** SHAP importance × M6 drift = a *prioritised* alert (Step 8 computes it). This is
  the bridge to M8, where the pipeline encodes "retrain when a high-SHAP feature drifts."

---

## Timing (7-hour)
| Time | Block |
|---|---|
| 0:00–0:20 | Tier-2 demos (MLflow + Hopsworks) |
| 0:20–1:50 | Lab 1 — Hopsworks (concepts recap + hands-on) |
| 1:55–2:55 | Lab 2 — MLflow Registry |
| 2:55–3:35 | Lunch |
| 3:35–4:35 | Lab 3 — W&B sweeps |
| 4:45–5:45 | Lab 4 — SHAP |
| 5:45–6:30 | Synthesis (feature store ↔ registry ↔ SHAP ↔ M6 drift) + bridge to M8 |
| 6:30–7:00 | Buffer / Q&A |

## Common failure modes (and fixes)
| Symptom | Cause | Fix |
|---|---|---|
| MLflow UI won't load | SG not open to classroom IP / userdata still installing | re-deploy with `-c mlflow_ui_cidr=`; wait 2 min |
| Hopsworks `access denied` | API key scope | regenerate with featurestore scope |
| W&B sweep stalls | bad hyperparameter range | guard ranges; restart agent |
| SHAP import error | stale shap build | `pip install -U shap` (≥0.44 supports numpy 2; pin `numpy<2` only for very old shap) |
| "I didn't do M3" | — | reassure: real data + model ship in `labs/data/`; nothing synthetic needed |

## Cost & teardown
SageMaker notebook (auto-stop) + MLflow `t3.small` (~₹1.5/h). **2-day SOP:** keep both across M7→M8; stop the EC2 overnight
if desired; `cdk destroy` (M7 + M8 stacks) only after M8. Hopsworks/W&B are free — nothing to tear down.
