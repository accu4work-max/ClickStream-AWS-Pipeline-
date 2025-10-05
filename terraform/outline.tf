# Terraform outline (not fully runnable; illustrates key resources)

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" { default = "us-east-1" }
variable "raw_bucket" { default = "company-raw" }
variable "processed_bucket" { default = "company-processed" }
variable "alerts_bucket" { default = "company-alerts" }

resource "aws_s3_bucket" "raw" { bucket = var.raw_bucket }
resource "aws_s3_bucket" "processed" { bucket = var.processed_bucket }
resource "aws_s3_bucket" "alerts" { bucket = var.alerts_bucket }

# KMS for SSE-KMS
resource "aws_kms_key" "data" {
  description = "Data at rest encryption"
}

# Glue
resource "aws_glue_catalog_database" "raw" {
  name = "clickstream_raw"
}

resource "aws_glue_crawler" "raw" {
  name          = "clickstream-raw-crawler"
  database_name = aws_glue_catalog_database.raw.name
  role          = aws_iam_role.glue.arn
  s3_target {
    path = "s3://${var.raw_bucket}/clickstream/"
  }
  configuration = jsonencode({
    Version  = 1.0,
    CrawlerOutput = { Partitions = { AddOrUpdateBehavior = "InheritFromTable" } }
  })
}

# Glue ETL job (PySpark)
resource "aws_glue_job" "etl" {
  name     = "clickstream-etl"
  role_arn = aws_iam_role.glue.arn
  command {
    name            = "glueetl"
    python_version  = "3"
    script_location = "s3://${var.processed_bucket}/jobs/transform_clickstream.py"
  }
  default_arguments = {
    "--job-language" = "python"
  }
}

# Athena workgroup
resource "aws_athena_workgroup" "wg" {
  name = "clickstream"
  configuration {
    enforce_workgroup_configuration = true
    result_configuration {
      output_location = "s3://${var.processed_bucket}/athena-results/"
    }
  }
}

# Redshift (example: serverless or provisioned placeholder)
# resource "aws_redshift_cluster" "this" { ... }

# CloudTrail to send S3 data events to EventBridge
resource "aws_cloudtrail" "data_events" {
  name                          = "s3-data-events"
  s3_bucket_name                = aws_s3_bucket.alerts.bucket
  include_global_service_events = false
  event_selector {
    read_write_type           = "WriteOnly"
    include_management_events = false
    data_resource {
      type   = "AWS::S3::Object"
      values = ["arn:aws:s3:::${var.raw_bucket}/clickstream/"]
    }
  }
}

# EventBridge rule for S3 PutObject
resource "aws_cloudwatch_event_rule" "s3_put" {
  name        = "clickstream-s3-put"
  description = "Trigger on new raw objects"
  event_pattern = jsonencode({
    source = ["aws.s3"],
    detail = { eventName = ["PutObject", "CompleteMultipartUpload"] }
  })
}

resource "aws_iam_role" "lambda" {
  name = "clickstream-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_lambda_function" "purchase_handler" {
  function_name = "purchase-event-handler"
  role          = aws_iam_role.lambda.arn
  handler       = "purchase_event_handler.lambda_handler"
  runtime       = "python3.11"
  filename      = "build/purchase_event_handler.zip" # Provided via CI
  environment {
    variables = {
      ALERTS_BUCKET = var.alerts_bucket
      SNS_TOPIC_ARN = aws_sns_topic.alerts.arn
    }
  }
}

resource "aws_cloudwatch_event_target" "target" {
  rule      = aws_cloudwatch_event_rule.s3_put.name
  target_id = "lambda"
  arn       = aws_lambda_function.purchase_handler.arn
}

resource "aws_lambda_permission" "allow_evb" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.purchase_handler.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.s3_put.arn
}

resource "aws_sns_topic" "alerts" { name = "clickstream-alerts" }
