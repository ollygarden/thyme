# Docker Compose Deployment

This directory contains Docker Compose configuration for local development and testing of Thyme.

## Architecture

```
loggen (500 lines/sec)
    ↓ (writes to shared volume)
/var/log/app/app.log
    ↓ (filelog receiver)
thyme collector
    ↓ (OTLP exporter → nop-collector:4317)
nop-collector
    ↓ (nop exporter - discards data)
   ∅

Both collectors send internal telemetry → LGTM
```

## Components

- **loggen**: Generates 500 log lines/sec to `/var/log/app/app.log` on shared volume
- **thyme**: Reads logs via filelog receiver, processes (batch, memory_limiter, resource), exports via OTLP to nop-collector
- **nop-collector**: Receives OTLP, processes, exports to nop (discard)
- **LGTM**: Collects internal telemetry (metrics, traces) from both collectors

## Usage

Start the stack:

```bash
docker-compose up
```

Start in detached mode:

```bash
docker-compose up -d
```

View logs:

```bash
docker-compose logs -f thyme
docker-compose logs -f nop-collector
docker-compose logs -f loggen
```

Stop the stack:

```bash
docker-compose down
```

Clean up volumes:

```bash
docker-compose down -v
```

## Exposed Ports

- `3000` - Grafana (LGTM)
- `8080` - loggen metrics endpoint
- `55679` - nop-collector zpages
- `55680` - thyme zpages
- `1777` - nop-collector pprof
- `1778` - thyme pprof

## Accessing Services

### Grafana (LGTM)

Open http://localhost:3000 to view collector internal telemetry:
- Navigate to **Explore** → **Prometheus** datasource
- Query collector metrics like `otelcol_receiver_accepted_log_records`

### Zpages

Access collector zpages for debugging:
- Thyme: http://localhost:55680/debug/servicez
- nop-collector: http://localhost:55679/debug/servicez

### Pprof

Profile collectors:
```bash
# Thyme CPU profile
go tool pprof http://localhost:1778/debug/pprof/profile

# nop-collector CPU profile
go tool pprof http://localhost:1777/debug/pprof/profile
```

### Loggen Metrics

View log generator metrics:
```bash
curl http://localhost:8080/metrics
```

## Configuration

### Adjusting Log Generation Rate

Edit `docker-compose.yaml` and modify the loggen service:
- `--lines-per-second=500` - Adjust throughput
- `--duration=0` - Set to 0 for continuous operation

### Modifying Collector Configs

- **thyme**: Edit `../../distributions/thyme/config.yaml`
- **nop-collector**: Edit `nop-collector-config.yaml`

After modifying configs, restart containers:
```bash
docker-compose restart thyme
docker-compose restart nop-collector
```

## Troubleshooting

### Check if logs are being generated

```bash
docker-compose exec loggen ls -lh /var/log/app/
```

### Check if thyme is reading logs

```bash
docker-compose logs thyme | grep -i "filelog"
```

### Verify OTLP communication

```bash
docker-compose logs thyme | grep -i "otlp"
docker-compose logs nop-collector | grep -i "otlp"
```

### Check resource usage

```bash
docker stats
```
