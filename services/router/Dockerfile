FROM python:3.12-slim
WORKDIR /app
COPY render.py /app/render.py
CMD ["python3", "/app/render.py", "--routes", "/app/routes.yaml", "--out", "/app/out/Caddyfile", "--watch"]
