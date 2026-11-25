# Multi-arch (amd64 + arm64), so it runs on Oracle's Ampere A1 free tier.
FROM savonet/liquidsoap:v2.4.6-minimal
USER root
RUN mkdir -p /data && chown liquidsoap:liquidsoap /data
USER liquidsoap
COPY radio.liq /radio/radio.liq
COPY www/ /radio/www/
# Stations live in the /data volume and are set via POST /playlist. The token's MD5
# comes from the PLAYLIST_TOKEN_MD5 environment variable at run time (see README).
EXPOSE 8000
CMD ["/radio/radio.liq"]
