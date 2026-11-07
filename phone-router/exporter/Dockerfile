FROM docker.io/library/python:3.12-alpine
RUN apk add --no-cache android-tools
COPY phone_exporter.py /app/phone_exporter.py
ENV HOME=/root PYTHONUNBUFFERED=1
ENTRYPOINT ["python3", "/app/phone_exporter.py"]
