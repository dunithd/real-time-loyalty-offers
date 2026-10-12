# Clickstream + engagement event generator. A data source, not a pipeline.
FROM python:3.12-slim

RUN pip install --no-cache-dir kafka-python tomli

WORKDIR /app
COPY generator.py /app/generator.py
ENV PYTHONPATH=/app:/common \
    PYTHONUNBUFFERED=1

ENTRYPOINT ["python", "/app/generator.py"]
