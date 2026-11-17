"""Small FastAPI service: JSON logs, Prometheus metrics, env-based config."""
import json
import logging
import os
import sys
import time
from datetime import datetime, timezone

import uvicorn
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

# ---- Configuration (environment variables only) ----
PORT = int(os.getenv("PORT", "8080"))
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO").upper()
APP_ENV = os.getenv("APP_ENV", "local")
APP_VERSION = os.getenv("APP_VERSION", "0.1.0")


class JsonFormatter(logging.Formatter):
    """One JSON object per line on stdout. Extra fields are passed via `extra={'fields': {...}}`."""

    def format(self, record: logging.LogRecord) -> str:
        entry = {
            "ts": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
            "level": record.levelname.lower(),
            "msg": record.getMessage(),
            "env": APP_ENV,
            "version": APP_VERSION,
        }
        entry.update(getattr(record, "fields", {}))
        if record.exc_info:
            entry["exc"] = self.formatException(record.exc_info)
        return json.dumps(entry)


def configure_logging() -> logging.Logger:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(LOG_LEVEL)
    return logging.getLogger("app")


logger = configure_logging()

# ---- Metrics ----
# `path` uses the route template (e.g. "/"), never the raw URL, to keep cardinality bounded.
REQUESTS = Counter("http_requests_total", "Total HTTP requests", ["method", "path", "status"])
ERRORS = Counter("http_errors_total", "Total HTTP 5xx responses", ["method", "path"])
LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency in seconds",
    ["method", "path"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5),
)

app = FastAPI(title="devops-task", version=APP_VERSION)


@app.middleware("http")
async def observe(request: Request, call_next):
    start = time.perf_counter()
    status = 500
    try:
        response = await call_next(request)
        status = response.status_code
        return response
    except Exception:
        logger.exception("unhandled exception", extra={"fields": {"path": request.url.path}})
        raise
    finally:
        duration = time.perf_counter() - start
        route = request.scope.get("route")
        template = route.path if route else "unmatched"
        REQUESTS.labels(request.method, template, str(status)).inc()
        LATENCY.labels(request.method, template).observe(duration)
        if status >= 500:
            ERRORS.labels(request.method, template).inc()
        # Probe/scrape noise goes to DEBUG so it doesn't drown real traffic.
        if status >= 500:
            level = logging.ERROR
        elif template in ("/health", "/metrics"):
            level = logging.DEBUG
        else:
            level = logging.INFO
        logger.log(
            level,
            "request",
            extra={
                "fields": {
                    "method": request.method,
                    "path": request.url.path,
                    "status": status,
                    "duration_ms": round(duration * 1000, 2),
                }
            },
        )


@app.get("/")
def root():
    return {"message": "Hello from DevOps Task!", "status": "running", "version": APP_VERSION}


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/debug/error", include_in_schema=False)
def debug_error():
    # Off by default (404). Enable with ENABLE_FAULT_INJECTION=true to generate
    # error spikes for the observability walkthrough. Never enable in production.
    if os.getenv("ENABLE_FAULT_INJECTION", "false").lower() != "true":
        raise HTTPException(status_code=404, detail="Not Found")
    raise HTTPException(status_code=500, detail="injected failure")


if __name__ == "__main__":
    # log_config=None keeps our JSON handler; uvicorn handles SIGTERM by draining
    # in-flight requests for up to timeout_graceful_shutdown seconds, then exiting 0.
    uvicorn.run(
        app,
        host="0.0.0.0",  # noqa: S104 - container listens on all interfaces
        port=PORT,
        log_config=None,
        access_log=False,
        timeout_graceful_shutdown=10,
    )
