CREATE DATABASE IF NOT EXISTS pg_logtap;

CREATE TABLE IF NOT EXISTS pg_logtap.logs
(
    `seq` UInt64,
    `timestamp` DateTime64(6, 'UTC'),
    `level` LowCardinality(String),
    `message` String,
    `detail` Nullable(String),
    `hint` Nullable(String),
    `context` Nullable(String),
    `sqlerrcode` FixedString(5),
    `filename` Nullable(String),
    `lineno` UInt32,
    `funcname` Nullable(String),
    `database` Nullable(String),
    `user` Nullable(String),
    `app` Nullable(String),
    `client_host` Nullable(String),
    `host` Nullable(String),
    `cluster` Nullable(String),
    `pgdata` Nullable(String),
    `pid` Int32,
    `backend_type` Nullable(String),
    `query` Nullable(String),
    `truncated` Array(String),
    `redacted` Array(String)
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(`timestamp`)
ORDER BY (ifNull(`host`, ''), ifNull(`cluster`, ''), `seq`);
