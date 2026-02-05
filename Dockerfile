FROM golang:1.24-alpine AS builder
WORKDIR /app
COPY . .

# Download OCB
ARG OCB_VERSION=0.144.0
RUN wget -qO /usr/bin/builder "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/cmd%2Fbuilder%2Fv${OCB_VERSION}/ocb_${OCB_VERSION}_linux_amd64" && \
    chmod +x /usr/bin/builder

# Build the distribution
WORKDIR /app/distributions/thyme
RUN CGO_ENABLED=0 builder --config=manifest.yaml

FROM alpine:latest

ARG USER_UID=10001
USER ${USER_UID}

COPY --from=builder /app/distributions/thyme/build/thyme /thyme
COPY --from=builder /app/distributions/thyme/config.yaml /etc/thyme/config.yaml

ENTRYPOINT ["/thyme"]
CMD ["--config", "/etc/thyme/config.yaml"]
EXPOSE 4317 4318
