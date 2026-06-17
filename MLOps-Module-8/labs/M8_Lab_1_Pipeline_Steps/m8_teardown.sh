#!/bin/bash
# M8 Capstone — Full Teardown
# Run from the SageMaker notebook terminal (~/SageMaker/labs or anywhere).
set -uo pipefail

REGION=us-east-1
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
BUCKET="sagemaker-us-east-1-759316130780"
PIPELINE_NAME="TruckDelayClassification"
MODEL_PKG_GROUP="TruckDelayModelPackageGroup"

echo "=================================================="
echo "1. Stop the automation — delete EventBridge schedules"
echo "=================================================="
aws scheduler delete-schedule --name truck-delay-weekly-retrain --region $REGION 2>&1 || echo "(already gone or denied — check console)"
aws scheduler delete-schedule --name truck-delay-test-once --region $REGION 2>&1 || echo "(already gone — expected, auto-deleted)"

echo
echo "=================================================="
echo "2. Delete the Lambda function"
echo "=================================================="
aws lambda delete-function --function-name truck-delay-land-streaming --region $REGION 2>&1 || echo "(already gone or denied — check console)"

echo
echo "=================================================="
echo "3. Delete the SageMaker pipeline"
echo "=================================================="
aws sagemaker delete-pipeline --pipeline-name $PIPELINE_NAME --region $REGION 2>&1 || echo "(already gone)"

echo
echo "=================================================="
echo "4. Clean up the Model Registry (delete versions, then the group)"
echo "=================================================="
VERSIONS=$(aws sagemaker list-model-packages --model-package-group-name $MODEL_PKG_GROUP \
    --region $REGION --query "ModelPackageSummaryList[].ModelPackageArn" --output text 2>/dev/null || true)

if [ -n "$VERSIONS" ]; then
    for ARN in $VERSIONS; do
        echo "Deleting model package: $ARN"
        aws sagemaker delete-model-package --model-package-name "$ARN" --region $REGION
    done
fi

aws sagemaker delete-model-package-group --model-package-group-name $MODEL_PKG_GROUP --region $REGION 2>&1 || echo "(already gone)"

echo
echo "=================================================="
echo "5. Clean up S3 — truck-delay/ prefix (keeping nothing here is reproducible from labs/data/)"
echo "=================================================="
aws s3 rm s3://$BUCKET/truck-delay/ --recursive --region $REGION

echo
echo "=================================================="
echo "6. Stop the SageMaker notebook instance"
echo "=================================================="
NB_NAME=$(aws sagemaker list-notebook-instances --region $REGION \
    --query "NotebookInstances[?contains(NotebookInstanceName,'module-8') || contains(NotebookInstanceName,'osqr')].NotebookInstanceName" \
    --output text)

if [ -n "$NB_NAME" ]; then
    echo "Found notebook instance: $NB_NAME"
    aws sagemaker stop-notebook-instance --notebook-instance-name "$NB_NAME" --region $REGION
    echo "Stop requested. To fully delete after it reaches 'Stopped' status, run:"
    echo "  aws sagemaker delete-notebook-instance --notebook-instance-name $NB_NAME --region $REGION"
else
    echo "No module-8/osqr notebook instance found — check name manually:"
    aws sagemaker list-notebook-instances --region $REGION --query "NotebookInstances[].{Name:NotebookInstanceName,Status:NotebookInstanceStatus}"
fi

echo
echo "=================================================="
echo "MANUAL STEPS REQUIRED (Console — IAM role deletion blocked from this role)"
echo "=================================================="
echo "IAM Console -> Roles -> delete these two roles (detach/remove inline policies first):"
echo "  - truck-delay-lambda-role"
echo "  - truck-delay-scheduler-role"
echo
echo "Sleeping 15s before verification (allow deletes to propagate)..."
sleep 15

echo
echo "=================================================="
echo "VERIFICATION SWEEP — everything below should be empty / gone"
echo "=================================================="

echo
echo "--- EventBridge schedules (expect: empty) ---"
aws scheduler list-schedules --region $REGION --query "Schedules[?contains(Name,'truck-delay')].{Name:Name,State:State}" --output table

echo
echo "--- Lambda function (expect: error 'ResourceNotFoundException') ---"
aws lambda get-function --function-name truck-delay-land-streaming --region $REGION 2>&1 | head -1

echo
echo "--- SageMaker pipeline (expect: error 'does not exist') ---"
aws sagemaker describe-pipeline --pipeline-name $PIPELINE_NAME --region $REGION 2>&1 | head -1

echo
echo "--- Model package group (expect: error 'does not exist') ---"
aws sagemaker describe-model-package-group --model-package-group-name $MODEL_PKG_GROUP --region $REGION 2>&1 | head -1

echo
echo "--- S3 truck-delay/ prefix (expect: empty) ---"
aws s3 ls s3://$BUCKET/truck-delay/ --recursive --region $REGION

echo
echo "--- SageMaker notebook instance status (expect: Stopping/Stopped, or gone if deleted) ---"
aws sagemaker list-notebook-instances --region $REGION --query "NotebookInstances[].{Name:NotebookInstanceName,Status:NotebookInstanceStatus}" --output table

echo
echo "--- SageMaker endpoints — MUST be empty (these bill hourly) ---"
aws sagemaker list-endpoints --region $REGION --query "Endpoints[].EndpointName" --output text

echo
echo "--- IAM roles still present (manual deletion reminder if non-empty) ---"
aws iam get-role --role-name truck-delay-lambda-role --region $REGION 2>&1 | head -1
aws iam get-role --role-name truck-delay-scheduler-role --region $REGION 2>&1 | head -1

echo
echo "=================================================="
echo "DONE. Review each section above:"
echo "  - 'empty' / 'NotFound' / 'does not exist' / 'ResourceNotFoundException' = GREEN"
echo "  - anything still listed (especially endpoints!) = needs follow-up"
echo "=================================================="
