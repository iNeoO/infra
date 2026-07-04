#!/usr/bin/env bash
set -euo pipefail
umask 077

: "${REDIS_INFRA_ADMIN_PASSWORD:?REDIS_INFRA_ADMIN_PASSWORD must be set}"
: "${REDIS_HEALTHCHECK_PASSWORD:?REDIS_HEALTHCHECK_PASSWORD must be set}"
: "${REDIS_OCR_PASSWORD:?REDIS_OCR_PASSWORD must be set}"
: "${REDIS_URLSHORTENER_PASSWORD:?REDIS_URLSHORTENER_PASSWORD must be set}"
: "${REDIS_EXPORTER_PASSWORD:?REDIS_EXPORTER_PASSWORD must be set}"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
output_file="${REDIS_ACL_FILE:-${script_dir}/users.acl}"

hash_password() {
	local password="$1"

	if [[ "${password}" == *$'\n'* || "${password}" == *$'\r'* ]]; then
		echo "Redis passwords must not contain newline characters." >&2
		exit 1
	fi

	printf '%s' "${password}" | sha256sum | awk '{print $1}'
}

admin_password_hash="$(hash_password "${REDIS_INFRA_ADMIN_PASSWORD}")"
healthcheck_password_hash="$(hash_password "${REDIS_HEALTHCHECK_PASSWORD}")"
ocr_password_hash="$(hash_password "${REDIS_OCR_PASSWORD}")"
urlshortener_password_hash="$(hash_password "${REDIS_URLSHORTENER_PASSWORD}")"
exporter_password_hash="$(hash_password "${REDIS_EXPORTER_PASSWORD}")"

mkdir -p -- "$(dirname -- "${output_file}")"
output_tmp="$(mktemp "${output_file}.tmp.XXXXXX")"
trap 'rm -f -- "${output_tmp}"' EXIT

cat >"${output_tmp}" <<EOF
user default reset off
user infra-admin reset on #${admin_password_hash} ~* &* +@all
user healthcheck reset on #${healthcheck_password_hash} +ping
user ocr reset on #${ocr_password_hash} ~ocr:prod:* &ocr:prod:* +ping +hello +quit +info +client|setinfo +get +set +setex +del +keys +publish +subscribe +unsubscribe
user urlshortener reset on #${urlshortener_password_hash} ~urlshortener:prod:* +ping +hello +quit +info +client|setinfo +get +set +del +hgetall +hset +hincrby +expire +multi +exec +discard
user exporter reset on #${exporter_password_hash} +ping +hello +info +config|get +client|list +client|setname +latency|history +latency|latest +latency|histogram +slowlog|get +slowlog|len
EOF

chmod 644 "${output_tmp}"
mv -- "${output_tmp}" "${output_file}"
trap - EXIT

echo "Redis ACL file generated at ${output_file}." >&2
