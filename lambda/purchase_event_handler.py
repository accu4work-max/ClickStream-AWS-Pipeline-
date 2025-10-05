"""
Lambda pseudocode for purchase event detection triggered by EventBridge
Trigger: EventBridge rule for S3 PutObject events (via CloudTrail data events)
Action: scan the newly created object for purchase actions, publish alerts
"""

# Pseudocode (not full AWS SDK imports for brevity)
import json
import gzip
import io
from typing import Iterable

# Assume environment variables:
# ALERTS_BUCKET=s3://company-alerts/
# SNS_TOPIC_ARN=arn:aws:sns:us-east-1:123456789012:clickstream-alerts


def read_s3_object(bucket: str, key: str) -> Iterable[str]:
    """Stream lines from S3 object; handle gzip and plain text."""
    # s3 = boto3.client('s3')
    # obj = s3.get_object(Bucket=bucket, Key=key)
    # body = obj['Body'].read()
    # if key.endswith('.gz'):
    #     with gzip.GzipFile(fileobj=io.BytesIO(body)) as gz:
    #         for line in gz:
    #             yield line.decode('utf-8')
    # else:
    #     for line in body.splitlines():
    #         yield line.decode('utf-8') if isinstance(line, bytes) else line
    pass


def handle_record(rec: dict) -> dict | None:
    """Return an alert payload if record indicates a purchase."""
    try:
        if rec.get('action') == 'purchase':
            return {
                'user_id': rec.get('user_id'),
                'session_id': rec.get('session_id'),
                'event_time': rec.get('event_time'),
                'amount': rec.get('attributes', {}).get('amount'),
                'page_url': rec.get('page_url'),
                'raw': rec,
            }
    except Exception:
        return None
    return None


def lambda_handler(event, context):
    # EventBridge -> S3 PutObject
    # bucket = event['detail']['requestParameters']['bucketName']
    # key = event['detail']['requestParameters']['key']

    # for line in read_s3_object(bucket, key):
    #     try:
    #         rec = json.loads(line)
    #     except Exception:
    #         continue
    #     alert = handle_record(rec)
    #     if alert:
    #         # s3.put_object(Bucket=ALERTS_BUCKET, Key=f"purchases/{key}.json", Body=json.dumps(alert))
    #         # sns.publish(TopicArn=SNS_TOPIC_ARN, Message=json.dumps(alert))
    #         pass
    return {"status": "ok"}
