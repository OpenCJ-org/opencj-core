# Site generator: reads the database and game server, writes static pages.
FROM python:3.12.7-slim

# A fixed non-root user; the output volume is created owned by it.
ARG WEB_USER_ID=10001
RUN useradd --uid "${WEB_USER_ID}" --no-create-home --shell /usr/sbin/nologin web \
    && mkdir -p /srv/output \
    && chown web:web /srv/output

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --no-compile -r requirements.txt
COPY opencj_web ./opencj_web

USER web
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
CMD ["python", "-m", "opencj_web.build"]
