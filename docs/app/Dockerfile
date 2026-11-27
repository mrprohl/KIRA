# KIRA document services (docs-sync, docs-search, docs-download) – one image, built by /opt/kira/setup.sh as
# kira/docs:<hash of this folder>. Tesseract (German) and poppler for scans; Python packages pinned in requirements.txt.
ARG PYTHON_IMAGE=python:3.13-slim-bookworm
FROM ${PYTHON_IMAGE}
RUN apt-get update \
 && apt-get install -y --no-install-recommends tesseract-ocr tesseract-ocr-deu tesseract-ocr-eng poppler-utils \
 && rm -rf /var/lib/apt/lists/*
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir --no-deps -r /app/requirements.txt
COPY kiradocs /app/kiradocs
# /data and /logs belong to the service user – new named volumes take over this owner
RUN useradd --system --uid 10001 --home-dir /data --no-create-home kiradocs \
 && mkdir -p /data /logs && chown 10001:10001 /data /logs \
 && python -m compileall -q /app/kiradocs
WORKDIR /app
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
USER 10001
