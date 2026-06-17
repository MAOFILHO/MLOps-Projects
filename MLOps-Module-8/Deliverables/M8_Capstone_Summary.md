# Module 8 Capstone — Truck Delay Classification: Full Automation

**Project:** Truck Delay Classification (spine project, M3–M8)
**Module:** M8 — SageMaker Pipelines + Lambda + EventBridge
**Account:** AWS Sandbox (AWSLAB, us-east-1)
**Date:** June 15, 2026

## Summary

This capstone automates the Truck Delay Classification model end-to-end: a SageMaker Pipeline processes the real
12,308-row feature frame, trains an XGBoost model, evaluates it against a quality gate (f1 ≥ 0.55), and registers
passing models into a governed Model Package Group. A Lambda function simulates new data arriving on a schedule, and
an EventBridge Scheduler triggers the pipeline automatically — closing the loop with no human in it.

## Environment constraint and how it was handled

Early in the lab, `ProcessTruckDelayData` (the pipeline's first Processing step) failed with:

> `ResourceLimitExceeded: The account-level service limit 'ml.m5.large for processing job usage' is 0 Instances`

Investigation via Service Quotas showed that **every** SageMaker managed-compute instance type (processing and
training, across `ml.c4.*`, `ml.c5.*`, `ml.m5.*`, etc.) is capped at `0` at the account level — including cases where
AWS's own published default is nonzero (e.g. `ml.c4.2xlarge for spot training job usage` shows AWS default `4` but
applied `0`). This indicates an org-level Service Quota Template or SCP deliberately zeroes out managed compute for
this sandbox account, which a user-level AWS Support case cannot override.

**Resolution:** the three pipeline step scripts (`processing.py`, `training.py`, `evaluation.py`) were executed
**locally** on the notebook instance's own `ml.m5.large` compute, using the exact same hyperparameters and
`/opt/ml/processing/...` directory conventions the managed jobs would use. The resulting model artifact and
evaluation report were uploaded to S3, and the same f1 ≥ 0.55 condition-gate logic was applied manually via a boto3
`create_model_package` call — registering the model into `TruckDelayModelPackageGroup` exactly as the pipeline's
`ConditionStep` → `ModelStep` would have.

This is functionally equivalent to the pipeline's DAG, executed step-by-step rather than orchestrated, and is called
out explicitly here as a deliberate adaptation to an environment constraint — not a shortcut around the ML logic.

## Lab 1 — Pipeline steps, local execution, and model registry

**Pipeline design** (`pipeline.py`): `Process → Train → Evaluate → Condition(f1 ≥ 0.55) → Register | Fail`, built with
`PipelineSession`, run-time `properties` references between steps, and a `PropertyFile`-based `JsonGet` for the
condition gate — the standard SageMaker Pipelines pattern.

**Local execution results:**

| Metric | Value |
|---|---|
| Accuracy | 0.7764 |
| Precision | 0.6954 |
| Recall | 0.6382 |
| **F1** | **0.6656** |
| ROC AUC | 0.7667 |

F1 (0.6656) cleared the 0.55 gate → model registered.

**Registry:** `TruckDelayModelPackageGroup`, Version 1, status `Approved`. Lineage graph shows Image → Approval →
Version 1 → Model Group, with full activity history (`PendingManualApproval` → `Approved`). Container: XGBoost 1.7-1
inference image; model artifact at `s3://sagemaker-us-east-1-759316130780/truck-delay/model/model.tar.gz`; supported
instances `ml.m5.large` (realtime) and `ml.t2.medium` / `ml.m5.large` (batch transform).

**Managed-pipeline attempt:** the official notebook (`M8_Lab_1_Build_And_Run_Pipeline.ipynb`, converted to a script
and run from the terminal) was also executed against the real managed pipeline. It built, upserted, and started
`TruckDelayClassification` successfully — confirming the pipeline definition itself is correct — but
`ProcessTruckDelayData` failed with the same quota error, as expected.

## Lab 2 — Lambda: land streaming data

A pandas-free Lambda (`truck-delay-land-streaming`, Python 3.12, stdlib + boto3 only) reads
`truck-delay/input/final_features.csv` from S3, samples 500 random rows, and writes a timestamped batch to
`s3://sagemaker-us-east-1-759316130780/truck-delay/streaming/batch_<timestamp>.csv`.

- Execution role `truck-delay-lambda-role`: `AWSLambdaBasicExecutionRole` + inline S3 read/write policy scoped to the
  pipeline bucket.
- Test invoke returned `{"statusCode": 200, "rows": 500, "key": "truck-delay/streaming/batch_20260615T194121.csv"}`.
- Confirmed via `aws s3 ls` — the batch file exists in `truck-delay/streaming/`.

(Note: IAM role creation for this function required the AWS Console, since the SageMaker notebook's execution role
lacks `iam:CreateRole`/`AttachRolePolicy`/`PutRolePolicy` — another instance of the sandbox's locked-down IAM surface.)

## Lab 3 — EventBridge: schedule the loop

Two schedules were created via EventBridge Scheduler (console — `scheduler:CreateSchedule` is similarly restricted
for the notebook role):

- **`truck-delay-weekly-retrain`** — recurring, `cron(0 6 ? * MON *)`, `America/Toronto`. Target:
  `aws-sdk:sagemaker:startPipelineExecution` with `{"PipelineName": "TruckDelayClassification"}`, executed under
  `truck-delay-scheduler-role` (inline policy: `sagemaker:StartPipelineExecution` +
  `lambda:InvokeFunction` scoped to the relevant ARNs). `Action after completion: NONE` (correct for a recurring
  schedule).
- **`truck-delay-test-once`** — one-time proof schedule, fired at 16:45 ET. `Action after completion: DELETE`.

**Proof of automation:** `aws sagemaker list-pipeline-executions` shows execution `vm1m9ffk0hhq`
(`StartTime: 1781556327` ≈ 16:45 ET) appearing with no manual `start()` call — triggered entirely by EventBridge.
Immediately afterward, `truck-delay-test-once` disappeared from the schedules list (its `DELETE`-after-completion
firing), independently corroborating that the schedule executed. As expected, the execution failed at
`ProcessTruckDelayData` for the same quota reason — the deliverable here is the **trigger**, not the compute.

## Trace: one shipment through the system

A new shipment record arrives via the **Lambda** (M8) landing a streaming batch in S3, sampled from the same feature
schema engineered in **M3** (one-hot encoded categoricals, scaled continuous features, binary/ordinal passthroughs —
`processing.py`). On the **EventBridge weekly schedule** (M8), the **SageMaker Pipeline** (M8) would pick up fresh
data, re-run **M3's** training logic via script-mode **XGBoost** (M8 `training.py`), and evaluate it
(`evaluation.py`) against the **f1 ≥ 0.55 condition gate** — the automated equivalent of the manual quality checks
introduced in **M3** and the drift monitoring established in **M6**. A model clearing the bar is registered as a new
version in **`TruckDelayModelPackageGroup`** (the **M7** registry concept), inheriting the approval workflow
(`PendingManualApproval` → `Approved`) first established there. That registered model is the artifact that **M5's**
ECS service (`truck-delay-service`, behind the `truck-delay-app` ECR image) would serve for real-time predictions —
closing the loop from raw shipment data to a deployable, governed, automatically-retrained model.

## What I'd say in an interview

- I designed and validated a complete SageMaker Pipeline (Process → Train → Evaluate → Condition → Register/Fail)
  using run-time `properties` and `PropertyFile`/`JsonGet` references — the SDK confirmed the pipeline definition was
  correct end-to-end (`upsert()` + `start()` succeeded).
- When the environment's compute quotas blocked managed Processing/Training jobs, I diagnosed it as an account-wide
  policy (not a per-instance-type limit) by checking Service Quotas systematically, and adapted by running the
  identical step logic locally — preserving hyperparameters, data splits, and the f1 gate — and registering the
  result through the same Model Registry API the pipeline would use.
- I built the serverless data-landing piece (Lambda, stdlib-only, no layer) and the EventBridge Scheduler automation,
  and proved the trigger fired autonomously via CLI evidence and schedule-lifecycle behavior (`DELETE`
  after completion).
- Throughout, I worked around least-privilege IAM boundaries (no `iam:*`, no `scheduler:CreateSchedule` from the
  SageMaker execution role) by using console-based role/schedule creation where the CLI path was blocked — a common
  real-world pattern when execution roles are intentionally scoped tighter than a human operator's console access.

## Deliverable checklist

- [x] Pipeline steps read and understood; `pipeline.py` built and upserted successfully (managed-pipeline path
      validated; execution blocked only by account-wide compute quota).
- [x] Model registered in `TruckDelayModelPackageGroup` (v1, Approved, f1=0.6656) via local execution mirroring the
      pipeline's logic and gate.
- [x] Lambda `truck-delay-land-streaming` created and verified — lands timestamped batches in S3.
- [x] EventBridge schedules created (`truck-delay-weekly-retrain` recurring + `truck-delay-test-once` proof);
      autonomous trigger confirmed via `list-pipeline-executions` and schedule auto-deletion.
- [x] Shipment trace across all 8 modules documented above.
