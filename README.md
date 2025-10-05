# Mini Data Pipeline on AWS – Design Note

## Assumptions
- Hourly NDJSON drops to `s3://company-raw/clickstream/YYYY/MM/DD/HH/`.
- Typical event fields: `event_time`, `user_id`, `session_id`, `action`, `page_url`, `user_agent`, `ip`, `attributes`.
- Query engines: Athena for data lake, Redshift (optionally Spectrum) for warehouse.
- Event-driven alerts on purchases; near–real-time acceptable as file-level (on object creation) processing.

## Architecture Overview
<img width="1016" height="698" alt="image" src="https://github.com/user-attachments/assets/32105753-5a62-40ff-ad69-f65c9f8c6db4" />

- Raw zone: S3 (`company-raw`) partitioned by `year/month/day/hour`. Enables partition pruning and independent retries.
- Catalog: Glue Data Catalog + optional Glue Crawler or partition projection in Athena to avoid `MSCK` overhead.
- Transform: Glue ETL (PySpark) normalizes to star schema and writes Parquet+Snappy in processed zone (`company-processed`).
- Serve: Athena external tables for ad hoc. Redshift uses Spectrum over processed S3 or ingests hot data via `COPY`.
- Events: CloudTrail data events + EventBridge rule trigger a Lambda to scan new objects for purchases and alert via SNS/write to S3.

## S3 Organization & Partitioning
- Raw: `s3://company-raw/clickstream/<YYYY>/<MM>/<DD>/<HH>/part-*.json[.gz]`.
- Processed: `s3://company-processed/clickstream/{dim_users|fact_clicks}/year=<YYYY>/month=<MM>/day=<DD>/part-*.parquet`.
- Rationale:
  - Time-based partitions match arrival cadence and reporting granularity.
  - Supports backfills and late-arriving data. Athena and Spectrum prune by partitions.

## Schema Design
- `dim_users(user_id, first_seen, last_seen, user_agent, ip)`
  - Small, slowly changing attributes gleaned from events; `DISTSTYLE ALL` in Redshift.
- `fact_clicks(click_id, event_time, user_id, session_id, action, page_url, attrs)`
  - Wide fact with semi-structured `attrs` for flexibility. Deterministic `click_id` from a hash.
- Parquet + Snappy: columnar, compressed, splittable; 10–30x scan reduction vs JSON.

## Transformation Logic (Glue PySpark)
- Read raw JSON for a specific partition (`Y/M/D/H`), normalize timestamps, and persist two outputs.
- `dim_users`: first/last seen per `user_id`, last observed UA/IP.
- `fact_clicks`: one row per event; write partitioned by `year/month/day`.
- Dynamic partition overwrite to allow idempotent reruns; atomic at partition granularity.

## Athena Considerations
- Prefer partition projection to avoid slow `MSCK REPAIR`.
- Use `count_if`, column pruning, and date filters to minimize scans.
- Enforce consistent serialization (newline-delimited JSON) in raw.

## Redshift vs Spectrum
- Spectrum advantages: minimal ingestion; scales to large cold datasets; low storage cost.
- Spectrum drawbacks: higher query latency, limited sort/distribution tuning, depends on S3/Glue.
- Redshift COPY advantages: fast joins/aggregations, sort keys, dist keys, materialized views.
- COPY drawbacks: ETL complexity and cost; requires sizing (or serverless credits) and orchestration.
- Strategy: Spectrum for most historical analytics; COPY recent 7–30 days of hot data.

## Event-Driven Design
- S3 PutObject generates CloudTrail data events; EventBridge rule forwards to Lambda.
- Lambda streams the new object, detects `action = purchase`, and publishes to SNS and/or writes alert records to `s3://company-alerts/`.
- Trade-off: event detection at file granularity (not per-event streaming). For sub-minute latency, consider Kinesis Data Streams/Firehose.

## Security
- IAM roles per service (least privilege):
  - Glue job role: read `company-raw`, write `company-processed`, Glue permissions.
  - Athena workgroup role: read processed/raw, access to Glue catalog.
  - Redshift roles: Spectrum (`GetData` on S3, Glue), COPY role for processed S3.
  - Lambda role: read specific raw prefixes, publish to SNS, write to alerts bucket.
- Encryption: SSE-KMS on all buckets; KMS key with key policies scoped to roles.
- Network: For Glue/Redshift private access, place in VPC subnets with VPC endpoints (S3, Glue, STS, CloudWatch, KMS). Lambda can use VPC only if accessing private resources; otherwise keep out for simpler egress.

## Cost Awareness
- Storage classes: raw in S3 Standard for first 30 days, transition to Standard-IA at 30 days and Glacier at 90+ via lifecycle.
- Optimize Parquet file sizes (~128–512 MB) via repartitioning to reduce small files.
- Athena: partition projection to reduce metadata calls; use `SELECT` with partition filters.
- Redshift: right-size cluster or use Serverless; consider WLM and Concurrency Scaling; use reserved instances/RA3 credits.
- Eventing: CloudTrail data events incur cost; scope to specific bucket/prefix.

## Data Quality
- Schema validation in Glue job (expected columns, types).
- Basic checks: non-null `user_id`, parseable `event_time`, permissible `action` values.
- Bad records to quarantine prefix `s3://company-processed/quarantine/YYYY/MM/DD/`.
- Deduplication strategy: deterministic `click_id` allows idempotent loads.

## Monitoring & Logging
- CloudWatch metrics/alerts for Glue job failures, duration, and data skews.
- Athena query metrics via Workgroup; set bytes scanned thresholds.
- Redshift: query monitoring rules, disk usage, WLM queue health.
- Lambda: structured logs; failure DLQ (SQS) and retries; metric filter for purchase counts.
- CloudTrail: audit access to buckets and sensitive actions.

## Orchestration
- AWS Glue Workflows or Amazon Managed Airflow for daily/hourly runs.
- Alternatively, EventBridge Scheduler to trigger Glue job with path parameters (Y/M/D/H).

## Infrastructure as Code (Terraform)
- Buckets, KMS keys, IAM roles/policies, Glue DB/Crawler/Job, Athena workgroup, optional Redshift, CloudTrail, EventBridge rule/target, Lambda, SNS.
- CI/CD to package Lambda zip and push Glue script to S3.

## Trade-offs & Alternatives
- Streaming alternative: Kinesis Data Streams + Lambda for per-event low-latency processing, or Kinesis Firehose to S3 Parquet directly.
- Cataloging alternative: Lake Formation for fine-grained permissions and governance.
- Warehouse alternative: Redshift Serverless to avoid cluster management.

## Risks and Mitigations
- Small files: mitigate via Spark coalesce/repartition to target file sizes.
- Skewed keys (`user_id` heavy hitters): use salt or session-based partitioning if needed.
- Late/duplicate data: partition overwrite with deterministic IDs; maintain a backfill runbook.

## Conclusion
This design provides a pragmatic, low-ops baseline: raw-to-processed in S3 with Glue/Athena, optional Redshift acceleration, and an event-driven path for purchases. It balances cost and performance while remaining flexible to evolve toward streaming or lakehouse patterns as needs grow.

