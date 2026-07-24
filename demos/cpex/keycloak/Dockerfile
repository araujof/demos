# Keycloak image for the CPEX HR demo, with the CIBA HTTP authentication-channel
# SPI compiled from source (keycloak/ciba-spi/). Self-contained: a plain
# `docker compose build` compiles the SPI — no host JDK/Maven, no prebuilt jar
# in the repo.

# Stage 1 — build the SPI jar.
FROM maven:3.9-eclipse-temurin-17 AS spi-build
WORKDIR /build
COPY ciba-spi/pom.xml .
COPY ciba-spi/src ./src
RUN mvn -q -e -B clean package

# Stage 2 — Keycloak with the SPI dropped into providers/. `start-dev`
# (see docker-compose) rebuilds on start and picks it up under the id
# `http-authentication-channel`.
#
# 26.6.x for the native SPIFFE identity provider (providerId: spiffe,
# feature spiffe:v1, added 26.4). The generic OIDC broker can't validate a
# JWT-SVID in a token exchange — it falls back to the (nonexistent) UserInfo
# endpoint — so the native SPIFFE provider is required. The CIBA SPI is
# compiled against keycloak.version 26.0.0 with `provided` scope against a
# stable SPI, so it loads unchanged across the 26.x line.
FROM quay.io/keycloak/keycloak:26.6.1
COPY --from=spi-build /build/target/keycloak-ciba-http-channel.jar \
     /opt/keycloak/providers/keycloak-ciba-http-channel.jar
