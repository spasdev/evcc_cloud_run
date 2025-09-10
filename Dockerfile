# STEP 1 build ui
FROM --platform=linux/amd64 node:22-alpine AS node

RUN apk update && apk add --no-cache make

WORKDIR /build

# install node tools
COPY package*.json ./
RUN npm ci

# build ui
COPY Makefile .
COPY .*.js ./
COPY *.js ./
COPY assets assets
COPY i18n i18n

RUN make ui


# STEP 2 build executable binary
FROM --platform=linux/amd64 golang:1.25-alpine AS builder

# Install git + SSL ca certificates.
# Git is required for fetching the dependencies.
# Ca-certificates is required to call HTTPS endpoints.
RUN apk update && apk add --no-cache git make patch tzdata ca-certificates && update-ca-certificates

# define RELEASE=1 to hide commit hash
ARG RELEASE=0

WORKDIR /build

# Copy start.sh into the builder stage so it's available for the final stage
# Make sure your start.sh file is in the root of your project directory
COPY start.sh .

# download modules
COPY go.mod .
COPY go.sum .
RUN go mod download

# install tools
COPY Makefile .
COPY cmd/decorate/ cmd/decorate/
COPY cmd/openapi/ cmd/openapi/
COPY api/ api/
RUN make install

# prepare
COPY . .
RUN make patch-asn1
RUN make assets

# copy ui
COPY --from=node /build/dist /build/dist

# build
ARG TARGETOS=linux
ARG TARGETARCH=amd64
ARG TARGETVARIANT=""
ARG GOARM=""

RUN RELEASE=${RELEASE} GOOS=${TARGETOS} GOARCH=${TARGETARCH} GOARM=${GOARM} make build

# --- ADD THESE TEMPORARY DEBUGGING LINES IMMEDIATELY AFTER make build ---
RUN echo "--- Debugging: Listing contents of /build after make build ---"
RUN ls -lha /build
RUN echo "--- Debugging: Checking for 'evcc' file ---"
RUN find /build -name "evcc" || echo "evcc not found by find command"
RUN echo "--- Debugging: Checking for files with common Go binary names (e.g., 'main') ---"
RUN find /build -type f -exec file {} + | grep -i "executable" || true # List executables
RUN echo "--- End Debugging ---"
# -----------------------------------------------------------------------


# STEP 3 build a small image including module support
FROM alpine:3.22

WORKDIR /app

ENV TZ=Europe/Berlin

# Import from builder
COPY --from=builder /usr/share/zoneinfo /usr/share/zoneinfo
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
RUN /bin/true # This command does nothing, but creates a new layer, which might bust cache
COPY --from=builder /build/evcc /usr/local/bin/evcc # Your EVCC binary will be at /usr/local/bin/evcc

# Copy start.sh from the builder stage
COPY --from=builder /build/start.sh /app/start.sh

# Copy Tailscale binaries from the tailscale image on Docker Hub.
COPY --from=docker.io/tailscale/tailscale:stable /usr/local/bin/tailscaled /app/tailscaled
COPY --from=docker.io/tailscale/tailscale:stable /usr/local/bin/tailscale /app/tailscale

# Create necessary directories for Tailscale
RUN mkdir -p /var/run/tailscale /var/cache/tailscale /var/lib/tailscale

COPY packaging/docker/bin/* /app/ # Keep your existing copy

# mDNS
EXPOSE 5353/udp
# EEBus
EXPOSE 4712/tcp
# UI and /api
EXPOSE 7070/tcp
# KEBA charger
EXPOSE 7090/udp
# OCPP charger
EXPOSE 8887/tcp
# Modbus UDP
EXPOSE 8899/udp
# SMA Energy Manager
EXPOSE 9522/udp

HEALTHCHECK --interval=60s --start-period=60s --timeout=30s --retries=3 CMD [ "evcc", "health" ]

# Change ENTRYPOINT to run start.sh
ENTRYPOINT [ "/app/start.sh" ]
# CMD instruction is ignored if ENTRYPOINT is an exec form, but for clarity,
# the evcc binary execution will be handled by start.sh.
CMD [] # Clear original CMD, as start.sh will handle the main process
