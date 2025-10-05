-- Redshift/Spectrum integration and sample analytics

-- Option A: Use Spectrum external schema backed by Glue Catalog
CREATE EXTERNAL SCHEMA IF NOT EXISTS spectrum_clickstream
FROM DATA CATALOG
DATABASE 'clickstream_processed'
IAM_ROLE 'arn:aws:iam::<account-id>:role/RedshiftSpectrumRole'
CREATE EXTERNAL DATABASE IF NOT EXISTS;

-- External tables already defined in Athena/Glue; simply query them from Redshift
-- Example: daily clicks per user
SELECT f.user_id,
       DATE_TRUNC('day', f.event_time) AS day,
       COUNT(*) AS clicks
FROM spectrum_clickstream.fact_clicks f
WHERE f.year='2025' AND f.month='10' AND f.day='04'
GROUP BY 1,2
ORDER BY 2 DESC, 1
LIMIT 100;

-- Option B: Load hot data into Redshift for faster joins/BI
CREATE TABLE IF NOT EXISTS public.dim_users (
  user_id varchar(64) ENCODE zstd,
  first_seen timestamp ENCODE zstd,
  last_seen timestamp ENCODE zstd,
  user_agent varchar(1024) ENCODE zstd,
  ip varchar(64) ENCODE zstd
) DISTSTYLE ALL; -- small dimension

CREATE TABLE IF NOT EXISTS public.fact_clicks (
  click_id varchar(128) ENCODE zstd,
  event_time timestamp ENCODE zstd,
  user_id varchar(64) ENCODE zstd,
  session_id varchar(64) ENCODE zstd,
  action varchar(64) ENCODE zstd,
  page_url varchar(2048) ENCODE zstd,
  attrs super ENCODE zstd
) DISTKEY(user_id) SORTKEY(event_time);

-- COPY from Parquet in S3 (partitioned folders)
COPY public.fact_clicks
FROM 's3://company-processed/clickstream/fact_clicks/'
IAM_ROLE 'arn:aws:iam::<account-id>:role/RedshiftCopyRole'
FORMAT AS PARQUET
REGION 'us-east-1';

-- Join example
SELECT u.user_id,
       DATE_TRUNC('day', f.event_time) AS day,
       COUNT(*) FILTER (WHERE f.action = 'click') AS clicks,
       COUNT(*) FILTER (WHERE f.action = 'purchase') AS purchases
FROM public.fact_clicks f
JOIN public.dim_users u USING (user_id)
WHERE f.event_time >= DATEADD(day, -7, GETDATE())
GROUP BY 1,2
ORDER BY 2 DESC, 1;

-- Trade-offs (summary):
-- Spectrum: cheaper storage, elastic, ideal for large cold data; queries scan S3, higher latency.
-- Redshift COPY: faster queries, better join performance and sort keys, but ingest/maintenance cost and cluster sizing matter.
