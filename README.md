# infra

Shared infrastructure stack — Redis, RabbitMQ, Garage (S3-compatible).

## Services

| Service | Image | Purpose |
| --- | --- | --- |
| RabbitMQ | `rabbitmq:4-management-alpine` | Message broker, one vhost per project |
| Redis | `redis:8-alpine` | Cache / queue backend |
| Garage | `dss0/garage:v1.0.2` | S3-compatible object storage |

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

Edit `.env` and set a strong `REDIS_PASSWORD`.

### 3. Configure RabbitMQ

```bash
cp rabbitmq/definitions.example.json rabbitmq/definitions.json
```

Generate a password hash for each user (admin, ocr, urlshortener):

```bash
docker run --rm rabbitmq:4-management-alpine rabbitmqctl hash_password <password>
```

Paste each hash into `rabbitmq/definitions.json` in place of `CHANGE_ME`.

### 4. Configure Garage

```bash
cp garage/garage.example.toml garage/garage.toml
```

Generate the required secrets:

```bash
openssl rand -hex 32      # → rpc_secret (must be exactly 64 hex chars)
openssl rand -base64 32   # → admin_token
```

Paste them into `garage/garage.toml`.

### 5. Start the stack

```bash
docker compose up -d
```

### 6. Initialize Garage (once)

Garage requires a one-time cluster layout setup after the first start:

```bash
# Get the node ID
docker exec garage-prod garage status

# Assign capacity (adjust -c to the available disk in GB)
docker exec garage-prod garage layout assign -z dc1 -c 50 <NODE_ID>
docker exec garage-prod garage layout apply --version 1
```

Then create buckets and access keys via the [Garage admin API](https://garagehq.deuxfleurs.fr/documentation/reference-manual/admin-api/) or the CLI:

```bash
docker exec garage-prod garage bucket create my-bucket
docker exec garage-prod garage key create my-key
docker exec garage-prod garage bucket allow my-bucket --read --write --key my-key
```

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
