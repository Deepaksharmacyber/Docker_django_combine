# syntax=docker/dockerfile:1
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential libpq-dev curl \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /code

# Install deps early for better cache
COPY requirements.txt /code/
RUN pip install --no-cache-dir -r requirements.txt

# Entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Project (initially empty; we mount app/ during dev)
COPY . /code/

EXPOSE 8000
ENTRYPOINT ["/entrypoint.sh"]
