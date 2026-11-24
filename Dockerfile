# Multi-arch (amd64 + arm64), so it runs on Oracle's Ampere A1 free tier.
FROM savonet/liquidsoap:v2.4.6-minimal
USER root
RUN mkdir -p /data && chown liquidsoap:liquidsoap /data
USER liquidsoap
COPY radio.liq /radio/radio.liq
COPY www/ /radio/www/
# Playlist lives in the /data volume and is set via POST /playlist.
# Only the token's MD5 is baked in (image is public; the token is not).
ARG PLAYLIST_TOKEN_MD5=""
ENV PLAYLIST_TOKEN_MD5=$PLAYLIST_TOKEN_MD5
EXPOSE 8000
CMD ["/radio/radio.liq"]
