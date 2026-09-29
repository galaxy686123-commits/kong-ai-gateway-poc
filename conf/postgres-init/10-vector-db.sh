#!/bin/bash
# 최초 기동 시 1회 실행: 벡터 저장소용 데이터베이스를 만들고 pgvector 확장을 설치한다.
# Kong 설정용 데이터베이스(kong)는 POSTGRES_DB 로 자동 생성된다.
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-SQL
  CREATE DATABASE "kong-pgvector" OWNER "$POSTGRES_USER";
SQL
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "kong-pgvector" <<-SQL
  CREATE EXTENSION IF NOT EXISTS vector;
SQL
