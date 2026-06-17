#!/bin/bash
set -e

# ── Config ────────────────────────────────────────────────────────────────
REGION="us-east-1"
BUCKET="sagemaker-us-east-1-759316130780"
MODEL_PKG_GROUP="TruckDelayModelPackageGroup"
F1_THRESHOLD="0.55"
XGB_VERSION="1.7-1"

echo "=== 1. Install local deps (container deps not present on notebook) ==="
pip install -q xgboost scikit-learn pandas numpy

echo "=== 2. Set up /opt/ml/processing dirs ==="
sudo mkdir -p /opt/ml/processing/{input,train,validation,test,model,evaluation}
sudo mkdir -p /opt/ml/model
sudo chown -R $(whoami) /opt/ml

cp data/reference/final_features.csv /opt/ml/processing/input/

echo "=== 3. Run processing.py ==="
python code/processing.py

echo "=== 4. Run training.py ==="
python code/training.py \
    --max-depth 5 --eta 0.2 --num-round 200 \
    --subsample 0.9 --scale-pos-weight 1.8 \
    --train /opt/ml/processing/train \
    --validation /opt/ml/processing/validation \
    --model-dir /opt/ml/model

echo "=== 5. Package model.tar.gz (mimics SageMaker training output) ==="
cd /opt/ml/model
tar -czvf model.tar.gz xgboost-model
cp model.tar.gz /opt/ml/processing/model/
cd -

echo "=== 6. Run evaluation.py ==="
python code/evaluation.py

echo "=== 7. Upload model artifact + evaluation report to S3 ==="
aws s3 cp /opt/ml/processing/model/model.tar.gz \
    s3://$BUCKET/truck-delay/model/model.tar.gz --region $REGION

aws s3 cp /opt/ml/processing/evaluation/evaluation.json \
    s3://$BUCKET/truck-delay/evaluation/evaluation.json --region $REGION

echo "=== 8. Conditional registration (gate: f1 >= $F1_THRESHOLD) ==="
python3 << EOF
import json
import boto3
import sagemaker

REGION = "$REGION"
BUCKET = "$BUCKET"
MODEL_PKG_GROUP = "$MODEL_PKG_GROUP"
F1_THRESHOLD = float("$F1_THRESHOLD")
XGB_VERSION = "$XGB_VERSION"

with open("/opt/ml/processing/evaluation/evaluation.json") as f:
    report = json.load(f)

f1 = report["f1"]
print(f"[gate] f1 = {f1:.4f}  threshold = {F1_THRESHOLD}")

if f1 < F1_THRESHOLD:
    print(f"[gate] FAIL — f1 ({f1:.4f}) below threshold ({F1_THRESHOLD}). "
          f"Model NOT registered (mirrors pipeline FailStep).")
else:
    print("[gate] PASS — registering model version...")

    sm = boto3.client("sagemaker", region_name=REGION)
    xgb_image = sagemaker.image_uris.retrieve("xgboost", REGION, version=XGB_VERSION)

    response = sm.create_model_package(
        ModelPackageGroupName=MODEL_PKG_GROUP,
        ModelApprovalStatus="PendingManualApproval",
        InferenceSpecification={
            "Containers": [{
                "Image": xgb_image,
                "ModelDataUrl": f"s3://{BUCKET}/truck-delay/model/model.tar.gz",
            }],
            "SupportedContentTypes": ["text/csv"],
            "SupportedResponseMIMETypes": ["text/csv"],
            "SupportedRealtimeInferenceInstanceTypes": ["ml.t2.medium", "ml.m5.large"],
            "SupportedTransformInstanceTypes": ["ml.m5.large"],
        },
        ModelMetrics={
            "ModelQuality": {
                "Statistics": {
                    "ContentType": "application/json",
                    "S3Uri": f"s3://{BUCKET}/truck-delay/evaluation/evaluation.json",
                }
            }
        },
    )
    print(f"[gate] Registered: {response['ModelPackageArn']}")
EOF

echo "=== Done ==="
