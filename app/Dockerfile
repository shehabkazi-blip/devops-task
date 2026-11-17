# syntax=docker/dockerfile:1.7

# ---- Build stage: install deps into an isolated venv ----
FROM python:3.12.8-alpine3.21 AS builder
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
COPY requirements.txt .
RUN pip install -r requirements.txt

# ---- Final stage: runtime only, no pip, no build tools ----
FROM python:3.12.8-alpine3.21
ARG APP_VERSION=0.1.0
ARG GIT_SHA=unknown
LABEL org.opencontainers.image.title="devops-task" \
      org.opencontainers.image.description="FastAPI demo service with metrics and JSON logs" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.licenses="MIT"

# Fixed non-root UID/GID so Kubernetes runAsUser can match it.
RUN addgroup -g 10001 -S app && adduser -u 10001 -S -G app -H -s /sbin/nologin app
COPY --from=builder /opt/venv /opt/venv
WORKDIR /app
COPY --chown=app:app main.py .

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PORT=8080 \
    LOG_LEVEL=INFO \
    APP_ENV=production \
    APP_VERSION=${APP_VERSION}

USER 10001:10001
EXPOSE 8080

# No curl in the image; use the Python stdlib. Reads $PORT so it follows config.
HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
  CMD python -c "import os,urllib.request,sys; sys.exit(0 if urllib.request.urlopen(f'http://127.0.0.1:{os.environ[\"PORT\"]}/health', timeout=2).status==200 else 1)"

# Exec form: python is PID 1 and receives SIGTERM directly.
CMD ["python", "main.py"]
