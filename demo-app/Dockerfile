# Kestrel demo-app — single container: React build served by the FastAPI backend.
#
# Stage 1 builds the Vite/React frontend to static assets. Stage 2 is the Python
# API that serves those assets AND talks to kafka/clickhouse/pgd.

# ---------------------------------------------------------------------------
# Stage 1 — frontend build
# ---------------------------------------------------------------------------
FROM node:22-alpine AS frontend
WORKDIR /ui
COPY frontend/package.json frontend/package-lock.json* ./
RUN npm install
COPY frontend/ ./
RUN npm run build          # -> /ui/dist

# ---------------------------------------------------------------------------
# Stage 2 — backend + static
# ---------------------------------------------------------------------------
FROM python:3.12-slim
WORKDIR /app
COPY backend/requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY backend/ /app/
COPY --from=frontend /ui/dist /app/static

ENV STATIC_DIR=/app/static PYTHONUNBUFFERED=1
EXPOSE 8080
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
