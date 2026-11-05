import os

const DEFAULT_DB* = "host=localhost port=5432 dbname=asyncpg user=postgres"

proc dbConnStr*(): string =
  let fromEnv = getEnv("ASYNCPG_DB")
  if fromEnv.len > 0:
    fromEnv
  else:
    DEFAULT_DB

let connStr* = dbConnStr()
