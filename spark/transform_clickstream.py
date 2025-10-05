# PySpark (Glue) job to normalize raw JSON to star schema and write Parquet
# Assumptions:
# - Input: s3://company-raw/clickstream/YYYY/MM/DD/HH/*.json (NDJSON)
# - Output: s3://company-processed/clickstream/{dim_users|fact_clicks}/year=YYYY/month=MM/day=DD/
# - Glue 4.0+ (Spark 3), Python 3.10

import sys
from pyspark.sql import SparkSession
from pyspark.sql.functions import (
    col, from_unixtime, to_timestamp, lit, year, month, dayofmonth,
    sha2, concat_ws, first, last, coalesce
)
from pyspark.sql.types import (
    StructType, StructField, StringType, MapType
)

RAW_BASE = "s3://company-raw/clickstream/"
PROC_BASE = "s3://company-processed/clickstream/"


def build_spark(app_name: str = "clickstream_etl") -> SparkSession:
    return (
        SparkSession.builder.appName(app_name)
        .config("spark.sql.sources.partitionOverwriteMode", "dynamic")
        .config("spark.sql.parquet.compression.codec", "snappy")
        .config("spark.sql.shuffle.partitions", "200")
        .getOrCreate()
    )


def read_raw(spark: SparkSession, y: str, m: str, d: str, h: str):
    schema = StructType([
        StructField("event_time", StringType(), True),  # epoch seconds or ISO8601
        StructField("user_id", StringType(), True),
        StructField("session_id", StringType(), True),
        StructField("action", StringType(), True),
        StructField("page_url", StringType(), True),
        StructField("user_agent", StringType(), True),
        StructField("ip", StringType(), True),
        StructField("attributes", MapType(StringType(), StringType()), True),
    ])

    path = f"{RAW_BASE}{y}/{m}/{d}/{h}/"
    df = spark.read.schema(schema).json(path)

    # Normalize event_time to timestamp if epoch string
    ts = (
        to_timestamp(col("event_time"))
    )
    # If epoch, override with from_unixtime cast
    ts = coalesce(ts, to_timestamp(from_unixtime(col("event_time").cast("long"))))

    df = df.withColumn("event_ts", ts)
    df = df.withColumn("year", lit(y)).withColumn("month", lit(m)).withColumn("day", lit(d))
    return df


def write_dim_users(df, y, m, d):
    # Aggregate first/last seen per user; capture last observed UA/IP
    dim = (
        df.groupBy("user_id")
          .agg(
              first(col("event_ts"), ignorenulls=True).alias("first_seen"),
              last(col("event_ts"), ignorenulls=True).alias("last_seen"),
              last(col("user_agent"), ignorenulls=True).alias("user_agent"),
              last(col("ip"), ignorenulls=True).alias("ip")
          )
          .withColumn("year", lit(y)).withColumn("month", lit(m)).withColumn("day", lit(d))
    )

    (
        dim.repartition(1, "year", "month", "day")
           .write.mode("overwrite")
           .partitionBy("year", "month", "day")
           .parquet(f"{PROC_BASE}dim_users/")
    )


def write_fact_clicks(df, y, m, d):
    fact = (
        df.select(
            # deterministic click_id
            sha2(concat_ws("::",
                            col("user_id"), col("session_id"), col("event_ts").cast("string"), col("action"), col("page_url")), 256
                ).alias("click_id"),
            col("event_ts").alias("event_time"),
            "user_id", "session_id", "action", "page_url",
            col("attributes").alias("attrs"),
        )
        .withColumn("year", lit(y)).withColumn("month", lit(m)).withColumn("day", lit(d))
    )

    (
        fact.repartition(8, "year", "month", "day")
            .write.mode("overwrite")
            .partitionBy("year", "month", "day")
            .parquet(f"{PROC_BASE}fact_clicks/")
    )


def main(args):
    if len(args) != 4:
        print("Usage: transform_clickstream.py YEAR MONTH DAY HOUR", file=sys.stderr)
        sys.exit(2)
    y, m, d, h = args

    spark = build_spark()

    raw = read_raw(spark, y, m, d, h)

    write_dim_users(raw, y, m, d)
    write_fact_clicks(raw, y, m, d)

    spark.stop()


if __name__ == "__main__":
    main(sys.argv[1:])
