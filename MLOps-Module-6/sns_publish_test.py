# sns_publish_test.py
"""Smoke-test the M6 SNS topic with a structured JSON alert message.

Run: python sns_publish_test.py
"""
import json
import os
from datetime import datetime, timezone

import boto3

TOPIC_ARN = os.environ["TOPIC_ARN"]  # exported in your shell

sns = boto3.client("sns", region_name=os.environ.get("AWS_REGION", "ap-south-1"))

payload = {
    "schema_version": "1.0",
    "alert_type":     "drift",                    # drift | data_validation | model_error
    "severity":       "warning",                  # info | warning | critical
    "service":        "truck-delay-classifier",
    "environment":    "production",
    "detected_at":    datetime.now(timezone.utc).isoformat(),
    "summary":        "Test alert -- ignore. Lab 1 smoke test.",
    "details": {
        "drifted_features":   [],
        "validation_errors":  [],
    },
    "runbook_url":  "https://wiki.freshbasket.in/runbooks/truck-delay-drift",
}

response = sns.publish(
    TopicArn=TOPIC_ARN,
    # Subject is shown as the email subject line for email subscribers
    Subject=f"[{payload['severity'].upper()}] Truck Delay {payload['alert_type']} -- TEST",
    Message=json.dumps(payload, indent=2),
    # MessageAttributes let downstream subscribers (e.g., a Lambda) filter
    # without parsing the body
    MessageAttributes={
        "alert_type": {"DataType": "String", "StringValue": payload["alert_type"]},
        "severity":   {"DataType": "String", "StringValue": payload["severity"]},
        "service":    {"DataType": "String", "StringValue": payload["service"]},
    },
)

print(f"Published. MessageId = {response['MessageId']}")
