# Mini AWS Data Pipeline – Architecture

```mermaid
flowchart LR
    subgraph Source
        App[Web App]
        S3Raw[(S3 Bucket\ncompany-raw/clickstream/)]
    end

    subgraph Catalog & Query
        GlueDB[(Glue Data Catalog)]
        Crawler[Glue Crawler]
        Athena[Athena]
    end

    subgraph ETL & Processed
        GlueJob[Glue ETL Job\n(PySpark)]
        S3Proc[(S3 Bucket\ncompany-processed/clickstream/\nParquet partitioned)]
    end

    subgraph Warehouse & BI
        Spectrum[Redshift Spectrum\nExternal Schema]
        Redshift[(Redshift)]
        BI[Reporting/BI]
    end

    subgraph Event-Driven
        CloudTrail[CloudTrail Data Events]
        EVB[Amazon EventBridge Rule\n(S3 PutObject events)]
        Lambda[Lambda Handler\n(purchase detector)]
        SNS[SNS Topic\nalerts]
        S3Alerts[(S3 Bucket\ncompany-alerts/)]
    end

    App -->|hourly JSON dumps| S3Raw
    S3Raw -->|catalog| Crawler --> GlueDB
    GlueDB --- Athena
    Athena -->|ad-hoc queries| BI

    S3Raw -->|read JSON| GlueJob -->|write Parquet| S3Proc
    S3Proc --- GlueDB

    GlueDB --- Spectrum
    Spectrum --> Redshift
    Redshift --> BI

    S3Raw -->|PutObject| CloudTrail --> EVB --> Lambda
    Lambda --> SNS
    Lambda --> S3Alerts
```

Notes:
- Raw events land hourly under `s3://company-raw/clickstream/YYYY/MM/DD/HH/`.
- Glue Crawler populates partitions in Glue Data Catalog; Athena queries raw and processed.
- Glue ETL normalizes to star schema (`fact_clicks`, `dim_users`) and writes Parquet partitioned by `year/month/day`.
- Redshift consumes via Spectrum external tables or COPY for hot data.
- EventBridge uses CloudTrail S3 data events to trigger Lambda on new objects; Lambda scans for `action = purchase` and sends alerts.
