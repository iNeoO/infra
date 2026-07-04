# infra

Shared infrastructure stack — Redis, RabbitMQ, Garage (S3-compatible).

## Services

| Service | Image | Purpose |
| --- | --- | --- |
| RabbitMQ | `rabbitmq:4-management-alpine` | Message broker, one vhost per project |
| Redis | `redis:8-alpine` | Cache / queue backend |
| Garage | `dxflrs/garage:v2.3.0` | S3-compatible object storage |

## First-time setup

### 1. Create Docker networks

These networks are external so they can be shared with other stacks.

```bash
docker network create rabbitmq-network
docker network create redis-network
docker network create garage-network
docker network create monitoring-shared
```

### 2. Configure secrets

```bash
cp .env.example .env
```

Retrieve the five Redis passwords from the secret vault and set them in
`.env`:

```dotenv
REDIS_INFRA_ADMIN_PASSWORD=...
REDIS_HEALTHCHECK_PASSWORD=...
REDIS_OCR_PASSWORD=...
REDIS_URLSHORTENER_PASSWORD=...
REDIS_EXPORTER_PASSWORD=...
```

Load the environment file and generate the untracked ACL file:

```bash
set -a
source .env
set +a
./redis/generate-users-acl.sh
unset REDIS_INFRA_ADMIN_PASSWORD REDIS_HEALTHCHECK_PASSWORD REDIS_OCR_PASSWORD REDIS_URLSHORTENER_PASSWORD REDIS_EXPORTER_PASSWORD
```

Apply the generated ACL file by recreating Redis:

```bash
docker compose up -d --force-recreate redis
docker compose ps redis
```

The script writes only SHA-256 password hashes to the untracked
`redis/users.acl` file. The file is readable by the unprivileged `redis` user in
the container. Use strong, randomly generated passwords from the secret vault,
because Redis ACL hashes are shared-secret hashes rather than slow password
hashes. It creates:

- `infra-admin`, with full administrative access;
- `healthcheck`, restricted to `PING`;
- `ocr`, restricted to `ocr:prod:*` keys and channels and the commands used by
  Better Auth and OCR process-status Pub/Sub.
- `urlshortener`, restricted to `urlshortener:prod:*` keys and the cache,
  statistics, transaction, and lock commands used by URL Shortener. It has no
  Pub/Sub access.
- `exporter`, used by `redis_exporter` for Prometheus scraping. Restricted to
  server-introspection commands (`PING`, `INFO`, `CONFIG GET`, `CLIENT LIST`,
  `LATENCY`, `SLOWLOG`) — no access to any key.

The `default` user is disabled. The secret vault remains the source of truth.
Copy `REDIS_OCR_PASSWORD` to the OCR `.env.docker` file and set
`REDIS_OCR_USERNAME=ocr`.
Copy `REDIS_URLSHORTENER_PASSWORD` to the URL Shortener `.env.docker` file and
set `REDIS_URLSHORTENER_USERNAME=urlshortener`.

### 3. Configure RabbitMQ

```bash
cp rabbitmq/definitions.example.json rabbitmq/definitions.json
```

Generate a password hash for each user (admin, ocr, urlshortener):

```bash
docker run --rm rabbitmq:4-management-alpine rabbitmqctl hash_password <password>
```

Paste each hash into `rabbitmq/definitions.json` in place of `CHANGE_ME`.

The `rabbitmq_prometheus` plugin is enabled via `rabbitmq/enabled_plugins` and
exposes metrics on port 15692 (reachable as `rabbitmq-prod:15692` on
`monitoring-shared`, not published to the host).

### 4. Configure Garage

```bash
cp garage/garage.example.toml garage/garage.toml
```

Generate the required secrets:

```bash
openssl rand -hex 32      # → rpc_secret (must be exactly 64 hex chars)
openssl rand -base64 32   # → admin_token
openssl rand -base64 32   # → metrics_token
```

Paste them into `garage/garage.toml`. `metrics_token` scopes Prometheus to the
`/metrics` endpoint only, without granting the full admin API that
`admin_token` allows.

### 5. Start the stack

```bash
docker compose up -d
```

### 6. Initialize Garage (once)

Garage requires a one-time cluster layout setup after the first start:

```bash
# Get the node ID
docker exec garage-prod /garage status

# Assign capacity (adjust -c to the available disk in GB)
docker exec garage-prod /garage layout assign -z dc1 -c 50GB <NODE_ID>
docker exec garage-prod /garage layout apply --version 1
```

Then create buckets and access keys via the [Garage admin API](https://garagehq.deuxfleurs.fr/documentation/reference-manual/admin-api/) or the CLI:

```bash
docker exec garage-prod /garage bucket create my-bucket
docker exec garage-prod /garage key create my-key
docker exec garage-prod /garage bucket allow my-bucket --read --write --key my-key
```

For an application deployed on the same host, use the idempotent provisioning
script. It creates or reuses the Garage key and bucket, grants read/write access,
and updates only the S3 variables in the application's ignored environment file:

```bash
./garage/provision-project.sh ocr-prod ocr-prod ../ocr/.env.docker
```

The generated secret is written with `0600` permissions and is never printed.

## Day-to-day operations

### Add a new RabbitMQ vhost

1. Edit `rabbitmq/definitions.json` — add a vhost, a user, and permissions (see `definitions.example.json` for the structure).
2. Reload without restarting:

```bash
docker exec rabbitmq-prod rabbitmqctl import_definitions /etc/rabbitmq/definitions.json
```

### RabbitMQ management UI

Available at [http://localhost:15673](http://localhost:15673) (bound to localhost only).

### Garage S3 API

Available at `http://localhost:3900` for local CLI access:

```bash
aws s3 --endpoint-url http://localhost:3900 ls
```

## Monitoring

All three services expose Prometheus-compatible metrics on `monitoring-shared`,
scraped by the `observability` stack:

| Service | Target | Auth |
| --- | --- | --- |
| RabbitMQ | `rabbitmq-prod:15692/metrics` | none (internal network only) |
| Redis | `redis-exporter-prod:9121/metrics` | none (internal network only) |
| Garage | `garage-prod:3903/metrics` | `Authorization: Bearer <metrics_token>` |

## Networking

All services bind ports to `127.0.0.1` only. Inter-service communication goes through Docker networks — no ports are exposed for Redis or the RabbitMQ AMQP port.

| Network | Used by |
| --- | --- |
| `rabbitmq-network` | RabbitMQ + consumer/producer apps |
| `redis-network` | Redis + apps |
| `garage-network` | Garage + apps |
| `monitoring-shared` | All services + Prometheus |

To connect an app to a service, add the corresponding network to its `docker-compose.yml`:

```yaml
networks:
  redis-network:
    name: redis-network
    external: true
```

Then reach Redis at `redis-prod:6379`.
