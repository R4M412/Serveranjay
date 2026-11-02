FROM python:3.12-alpine
LABEL org.opencontainers.image.title="Pusat Kendali" \
      org.opencontainers.image.description="Dashboard ringan untuk server pribadi"
WORKDIR /app
COPY app.py ./
COPY static ./static
RUN adduser -D -H -u 10001 panel
USER panel
ENV PYTHONDONTWRITEBYTECODE=1
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8000/healthz || exit 1
CMD ["python", "-u", "app.py"]
