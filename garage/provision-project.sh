#!/usr/bin/env bash
set -euo pipefail
umask 077

if [[ "$#" -ne 3 ]]; then
	echo "Usage: $0 <key-name> <bucket> <env-file>" >&2
	exit 1
fi

key_name="$1"
bucket="$2"
env_file="$3"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
infra_dir="$(cd -- "${script_dir}/.." && pwd)"
compose_file="${infra_dir}/docker-compose.yml"

garage() {
	docker compose -f "${compose_file}" exec -T garage /garage "$@"
}

if key_output="$(garage key info --show-secret "${key_name}" 2>/dev/null)"; then
	echo "Garage key '${key_name}' already exists." >&2
else
	echo "Creating Garage key '${key_name}'." >&2
	key_output="$(garage key create "${key_name}")"
fi

access_key="$(
	printf '%s\n' "${key_output}" |
		sed -nE 's/^Key ID:[[:space:]]+([^[:space:]]+).*$/\1/p' |
		head -n 1
)"
secret_key="$(
	printf '%s\n' "${key_output}" |
		sed -nE 's/^Secret key:[[:space:]]+([^[:space:]]+).*$/\1/p' |
		head -n 1
)"

if [[ -z "${access_key}" || -z "${secret_key}" ]]; then
	echo "Unable to read the Garage credentials for '${key_name}'." >&2
	exit 1
fi

if garage bucket info "${bucket}" >/dev/null 2>&1; then
	echo "Garage bucket '${bucket}' already exists." >&2
else
	echo "Creating Garage bucket '${bucket}'." >&2
	garage bucket create "${bucket}" >/dev/null
fi

garage bucket allow --read --write --key "${access_key}" "${bucket}" >/dev/null

mkdir -p -- "$(dirname -- "${env_file}")"
touch -- "${env_file}"
env_tmp="$(mktemp "${env_file}.tmp.XXXXXX")"
trap 'rm -f -- "${env_tmp}"' EXIT

grep -Ev \
	'^(S3_ACCESS_KEY|S3_SECRET_KEY|S3_ENDPOINT|S3_BUCKET|S3_REGION|S3_FORCE_PATH_STYLE|MINIO_ROOT_USER|MINIO_ROOT_PASSWORD|MINIO_ENDPOINT|MINIO_BUCKET|MINIO_REGION|MINIO_FORCE_PATH_STYLE)=' \
	"${env_file}" >"${env_tmp}" || true

if [[ -s "${env_tmp}" ]]; then
	printf '\n' >>"${env_tmp}"
fi

{
	printf 'S3_ACCESS_KEY=%s\n' "${access_key}"
	printf 'S3_SECRET_KEY=%s\n' "${secret_key}"
	printf 'S3_ENDPOINT=http://garage-prod:3900\n'
	printf 'S3_BUCKET=%s\n' "${bucket}"
	printf 'S3_REGION=garage\n'
	printf 'S3_FORCE_PATH_STYLE=true\n'
} >>"${env_tmp}"

chmod 600 "${env_tmp}"
mv -- "${env_tmp}" "${env_file}"
trap - EXIT

echo "Garage project '${key_name}' is provisioned for bucket '${bucket}'." >&2
echo "Updated ${env_file}." >&2
