# PostgreSQL + pgvector. 초기화 스크립트를 이미지에 담아
# 바인드 마운트가 안 되는 환경에서도 동작하게 한다.
ARG PG_IMAGE=pgvector/pgvector:pg16
FROM ${PG_IMAGE}
COPY conf/postgres-init/ /docker-entrypoint-initdb.d/
