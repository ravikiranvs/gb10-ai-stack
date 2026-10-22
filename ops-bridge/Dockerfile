FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
WORKDIR /app

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY app.py .

# Runs as root on purpose: the Docker socket is root-equivalent whoever owns it, so a user switch would only hide that.
# The hardening is in compose.yaml (read-only filesystem, no capabilities) and in what the service accepts (actions.yaml).
EXPOSE 9200
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "9200", "--no-server-header"]
