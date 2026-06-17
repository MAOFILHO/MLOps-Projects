import os, sys, json
import boto3
import sagemaker

# ── Step 1: setup ────────────────────────────────────────────────────────
region = boto3.Session().region_name or "us-east-1"
sm_session = sagemaker.Session()
role = sagemaker.get_execution_role()
bucket = os.environ.get("PIPELINE_BUCKET", sm_session.default_bucket())
account = boto3.client("sts").get_caller_identity()["Account"]
print("region :", region)
print("account:", account)
print("bucket :", bucket)
print("role   :", role)

sm = boto3.client("sagemaker", region_name=region)
MPG = "TruckDelayModelPackageGroup"
try:
    sm.create_model_package_group(
        ModelPackageGroupName=MPG,
        ModelPackageGroupDescription="Truck Delay capstone model registry")
    print("Created model package group:", MPG)
except sm.exceptions.ClientError:
    print("Model package group already exists (fine):", MPG)

# ── Step 2: data already uploaded in Lab 1, but confirm/upload again (idempotent) ──
local_csv = os.path.join("data", "reference", "final_features.csv")
assert os.path.exists(local_csv), f"Real data missing at {local_csv}"
input_data_uri = sm_session.upload_data(local_csv, bucket=bucket, key_prefix="truck-delay/input")
print("Uploaded ->", input_data_uri)

# ── Step 3: build the pipeline ──────────────────────────────────────────
sys.path.insert(0, "M8_Lab_1_Pipeline_Steps")
from pipeline import get_pipeline  # noqa: E402

pipeline = get_pipeline(
    region=region, role=role, default_bucket=bucket,
    input_data_uri=input_data_uri,
    pipeline_name="TruckDelayClassification",
    model_package_group_name=MPG,
)
print("Pipeline built with steps:", [s.name for s in pipeline.steps])

steps = json.loads(pipeline.definition())["Steps"]
for s in steps:
    print(f"  {s['Name']:28s} type={s['Type']}")

# ── Step 4: upsert ───────────────────────────────────────────────────────
pipeline.upsert(role_arn=role)
print("Pipeline upserted -> visible in SageMaker Studio -> Pipelines -> TruckDelayClassification")

# ── Step 5: start and watch ─────────────────────────────────────────────
execution = pipeline.start()
print("Started execution:", execution.arn)

execution.wait(delay=30, max_attempts=60)
for step in execution.list_steps():
    print(f"  {step['StepName']:28s} {step['StepStatus']}")
