# Multi-arch (amd64 + arm64), so it runs on Oracle's Ampere A1 free tier.
FROM savonet/liquidsoap:v2.4.6-minimal
USER root
RUN mkdir -p /data && chown liquidsoap:liquidsoap /data
USER liquidsoap
COPY radio.liq /radio/radio.liq
COPY www/ /radio/www/
# Baked in: edit playlist.json, then `docker compose up -d --build`.
COPY playlist.json /radio/playlist.json
EXPOSE 8000
CMD ["/radio/radio.liq"]
