FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
WORKDIR /app

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY app.py devices.py .
COPY templates ./templates
COPY static ./static
RUN useradd -r -u 10001 app
USER app

EXPOSE 9000
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "9000", "--root-path", "/admin", "--proxy-headers", "--forwarded-allow-ips", "*"]
