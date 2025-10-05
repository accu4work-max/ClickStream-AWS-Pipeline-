-- Athena DDL for raw JSON with Hive-style partitions
-- Assumptions: JSON is newline-delimited (one event per line)
-- Sample event fields: event_time, user_id, session_id, action, page_url, user_agent, ip, attributes (map)

CREATE DATABASE IF NOT EXISTS clickstream_raw;

CREATE EXTERNAL TABLE IF NOT EXISTS clickstream_raw.events (
  event_time string,
  user_id string,
  session_id string,
  action string,
  page_url string,
  user_agent string,
  ip string,
  attributes map<string,string>
)
PARTITIONED BY (
  year string,
  month string,
  day string,
  hour string
)
ROW FORMAT SERDE 'org.openx.data.jsonserde.JsonSerDe'
WITH SERDEPROPERTIES (
  'ignore.malformed.json'='true'
)
LOCATION 's3://company-raw/clickstream/'
TBLPROPERTIES (
  'projection.enabled'='true',
  'projection.year.type'='integer',
  'projection.year.range'='2020,2035',
  'projection.month.type'='integer',
  'projection.month.range'='1,12',
  'projection.day.type'='integer',
  'projection.day.range'='1,31',
  'projection.hour.type'='integer',
  'projection.hour.range'='0,23',
  'storage.location.template'='s3://company-raw/clickstream/${year}/${month}/${day}/${hour}/'
);

-- If not using partition projection, run crawler or add partitions manually:
-- ALTER TABLE clickstream_raw.events ADD PARTITION (year='2025', month='10', day='04', hour='05')
--   LOCATION 's3://company-raw/clickstream/2025/10/04/05/';
-- MSCK REPAIR TABLE clickstream_raw.events; -- when using Hive-style partitions

-- Query with partition pruning
SELECT user_id, action, count(*) AS cnt
FROM clickstream_raw.events
WHERE year='2025' AND month='10' AND day='04'
GROUP BY user_id, action
ORDER BY cnt DESC
LIMIT 100;

-- Processed layer (Parquet) external tables
CREATE DATABASE IF NOT EXISTS clickstream_processed;

CREATE EXTERNAL TABLE IF NOT EXISTS clickstream_processed.dim_users (
  user_id string,
  first_seen timestamp,
  last_seen timestamp,
  user_agent string,
  ip string
)
PARTITIONED BY (year string, month string, day string)
STORED AS PARQUET
LOCATION 's3://company-processed/clickstream/dim_users/';

CREATE EXTERNAL TABLE IF NOT EXISTS clickstream_processed.fact_clicks (
  click_id string,
  event_time timestamp,
  user_id string,
  session_id string,
  action string,
  page_url string,
  attrs map<string,string>
)
PARTITIONED BY (year string, month string, day string)
STORED AS PARQUET
LOCATION 's3://company-processed/clickstream/fact_clicks/';

-- Example query across processed tables
SELECT f.user_id,
       date_trunc('day', f.event_time) AS day,
       count_if(f.action = 'click') AS clicks,
       count_if(f.action = 'purchase') AS purchases
FROM clickstream_processed.fact_clicks f
WHERE f.year='2025' AND f.month='10' AND f.day='04'
GROUP BY 1,2
ORDER BY 2,1;

-- Notes for Athena
-- - Prefer partition projection to avoid MSCK overhead.
-- - Convert to Parquet for 10-30x scan reduction vs JSON.
-- - Use compression (Snappy) and column pruning.
