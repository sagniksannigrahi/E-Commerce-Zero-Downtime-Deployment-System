# ShopFlow application image - small, non-root, with a built-in health check.
FROM python:3.12-slim

# Release information is baked into the image at build time by deploy.sh
ARG APP_VERSION=
ARG BUILD_SHA=local
ARG RELEASE_ID=local
# Only used to demonstrate a broken release (health check returns 503)
ARG SIMULATE_UNHEALTHY=false

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    APP_VERSION=${APP_VERSION} \
    BUILD_SHA=${BUILD_SHA} \
    RELEASE_ID=${RELEASE_ID} \
    SIMULATE_UNHEALTHY=${SIMULATE_UNHEALTHY}

WORKDIR /app

# Install dependencies first so this layer is cached between releases
COPY requirements.txt .
RUN pip install -r requirements.txt \
 && useradd --create-home --uid 10001 shopflow

COPY app.py VERSION ./
COPY templates ./templates
COPY static ./static

USER shopflow
EXPOSE 5000

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:5000/health', timeout=2)" || exit 1

# 2 workers x 2 threads is plenty for a t3.micro running two copies of the app
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", "--threads", "2", \
     "--timeout", "30", "--graceful-timeout", "20", "--access-logfile", "-", "app:app"]
