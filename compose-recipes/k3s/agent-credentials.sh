#!/bin/sh
# One-shot: give the Liferay PortalK8sAgent real credentials for the k3s API
# server, replacing the unauthenticated kubectl proxy. Applies the agent
# ServiceAccount + RBAC (agent-rbac.yaml), waits for the long-lived token
# Secret, reads the token + cluster CA, and drops a PortalK8sAgentConfiguration
# .config into Liferay's hot-deploy folder (a shared volume) so Liferay loads it
# at runtime. The agent then talks to the API server directly at k3s:6443 with
# the bearer token (apiServerSSL=true) -- no proxy process to crash.
set -e

export KUBECONFIG=/var/lib/rancher/k3s/server/cred/admin.kubeconfig

kubectl apply -f /agent-rbac.yaml

# k8s 1.24+ populates the token Secret asynchronously; wait for it.
i=0

while [ -z "$(kubectl get secret liferay-portal-k8s-agent-token -n default -o jsonpath='{.data.token}' 2>/dev/null)" ]; do
	i=$((i + 1))

	if [ "${i}" -ge 30 ]; then
		echo "timed out waiting for the ServiceAccount token" >&2

		exit 1
	fi

	sleep 2
done

token="$(kubectl get secret liferay-portal-k8s-agent-token -n default -o jsonpath='{.data.token}' | base64 -d)"
caCertData="$(kubectl get secret liferay-portal-k8s-agent-token -n default -o jsonpath='{.data.ca\.crt}')"

# Liferay hot-deploys .config files dropped here (world-writable so the liferay
# user can move it into osgi/configs).
deployDir=/liferay-deploy

mkdir -p "${deployDir}"
chmod 777 "${deployDir}"

configFile="${deployDir}/com.liferay.portal.k8s.agent.configuration.PortalK8sAgentConfiguration.config"

cat > "${configFile}" <<EOF
active="true"
apiServerHost="k3s"
apiServerPort="6443"
apiServerSSL="true"
caCertData="${caCertData}"
enabled="true"
namespace="default"
saToken="${token}"
portalK8sConfigurationPropertiesMutators.cardinality.minimum=I"2"
EOF

chmod 666 "${configFile}"

# Disable the BaseURL mutator's company lookup so it does not overwrite the
# baseURL the deploy plugin already sets (ingress host for browser CX, NodePort
# for objectAction). This leaves the Annotations + Labels mutators, satisfying
# the agent's cardinality.minimum=2.
mutatorFile="${deployDir}/com.liferay.portal.k8s.agent.internal.mutator.BaseURLPortalK8sConfigurationPropertiesMutator.config"

cat > "${mutatorFile}" <<'EOF'
_companyLocalService.target="(service.vendor=this.is.the.only.way.to.disable.this.component.i.could.find)"
EOF

chmod 666 "${mutatorFile}"

echo "PortalK8sAgent credentials deployed: direct API access at k3s:6443 (no proxy)"