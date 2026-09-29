# 한국어 PII 가드레일. 표준 라이브러리만 쓰므로 패키지 설치가 없다(폐쇄망 빌드 가능).
ARG PY_IMAGE=python:3.12-slim
FROM ${PY_IMAGE}
COPY addons/pii-guard/app.py /app/app.py
USER nobody
EXPOSE 8080
CMD ["python", "-u", "/app/app.py"]
