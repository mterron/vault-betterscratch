#!/bin/ash
log() {
	printf "start_vault.sh %s\n" "$@"
}
loge() {
	printf "start_vault.sh [ERR] %s\n" "$@" >&2
}

# Add the Consul CA to the trusted list
if [ ! -e /etc/ssl/certs/ca-consul.done ]; then
	cat /etc/tls/ca.pem >> /etc/ssl/certs/ca-certificates.crt &&\
	touch /etc/ssl/certs/ca-consul.done
fi

# Acquire Consul master token
log "Waiting for Consul token"
until [ -e /tmp/CT ]; do
	sleep 2
done
log "Consul token found!"
export CONSUL_HTTP_TOKEN=$(cat /tmp/CT)
rm -rf /tmp/CT

set -e

# Allow service & node discovery without a token
log "Setting anonymous ACL for service discovery"
su-exec consul curl -sS --unix-socket /data/consul.http.sock --header "X-Consul-Token: $CONSUL_HTTP_TOKEN" --data '{"ID": "anonymous",  "Type": "client",  "Rules": "node \"\" { policy = \"read\" } service \"\" { policy = \"read\" }"}' -XPUT http://consul/v1/acl/update >/dev/null

# Get Vault service name from the environment or config file. If both are empty
# it will default to "vault" as per
# https://www.vaultproject.io/docs/config/index.html#service
if [ -z "$VAULT_SERVICE_NAME" ]; then
	if [ "$(su-exec vault jq -cr '.storage.consul.service' /etc/vault/config.json)" != 'null' ]; then
		VAULT_SERVICE_NAME="$(su-exec vault jq -cr '.storage.consul.service' /etc/vault/config.json)}"
	else
		VAULT_SERVICE_NAME=vault
	fi
else
	VAULT_SERVICE_NAME="$VAULT_SERVICE_NAME"
fi
export VAULT_SERVICE_NAME

# Get Vault storage path in Consul KV
export VAULT_PATH=$(su-exec vault jq -cr '.storage.consul.path' /etc/vault/config.json)

# Remove old Vault service registrations
if [ "${SERVICEID:-$(su-exec consul curl -s --unix-socket /data/consul.http.sock http://consul/v1/agent/services | jq -cr '.[].ID|select(. == "consul"|not)|select(.|contains(env.HOSTNAME)|not)')}" ]; then
	su-exec consul curl -sS --unix-socket /data/consul.http.sock --header "X-Consul-Token: $CONSUL_HTTP_TOKEN" -XPUT http://consul/v1/agent/service/deregister/"$SERVICEID" >/dev/null
fi

# If VAULT_CONSUL_TOKEN environment variable is not set and there's no token on
# the Vault configuration file, create an ACL in Consul with access to Vault's
# "path" on the K/V store and the "vault" service key and acquire a token
# associated with that ACL. Else use the environment variable if it exists or
# the existing token (from the config file)
if [ -z "$VAULT_CONSUL_TOKEN" ]; then
	if [ "$(su-exec vault jq -cr '.storage.consul.token' /etc/vault/config.json)" == 'null' ]; then
#		log 'Acquiring a Consul token for Vault'
#		export VAULT_CONSUL_TOKEN=$(su-exec consul curl -sS --unix-socket /data/consul.http.sock --header "X-Consul-Token: $CONSUL_HTTP_TOKEN" --data @/etc/consul/vault.policy -XPUT http://consul/v1/acl/create | jq -cre '.Token')
		export VAULT_CONSUL_TOKEN=$CONSUL_HTTP_TOKEN
	else
		export VAULT_CONSUL_TOKEN=$(su-exec vault jq -cr '.storage.consul.token' /etc/vault/config.json)
	fi
fi


# Set Consul token & Datacenter in the config file
su-exec vault sh -c "{ rm /etc/vault/config.json; jq '.storage.consul.service = env.VAULT_SERVICE_NAME | .storage.consul.token = env.VAULT_CONSUL_TOKEN | .storage.consul.datacenter = env.CONSUL_DC_NAME' > /etc/vault/config.json; } < /etc/vault/config.json"


# Fix privileges
if [ "$(uname -v)" = 'BrandZ virtual linux' ]; then # Joyent Triton (Illumos)
	# Assign a privilege spec to the process that allows it to lock memory
	/native/usr/bin/ppriv -s LI+PROC_LOCK_MEMORY $$
else
	# Assign a linux capability to the Vault binary that allows it to lock memory
	setcap 'cap_ipc_lock=+ep' /usr/local/bin/vault
fi

# Vault redirect address
export VAULT_REDIRECT_ADDR="https://${HOSTNAME}.node.${CONSUL_DOMAIN:-consul}:${VAULT_PORT:-8200}"
export VAULT_ADDR="https://active.${VAULT_SERVICE_NAME}.service.${CONSUL_DOMAIN:-consul}:${VAULT_PORT:-8200}"

# Unset local variables
unset VAULT_PATH
unset VAULT_CONSUL_TOKEN
unset VAULT_SERVICE_NAME
unset CONSUL_HTTP_TOKEN

exec su-exec vault:consul vault server -config=/etc/vault/config.json -log-level=warn
