# k3s recipe — Client Extensions as real Kubernetes workloads

This recipe runs a lean, single-node [k3s](https://k3s.io) cluster alongside the
Liferay service and deploys the workspace's Client Extensions into it as real
Kubernetes workloads. It reproduces the Liferay Cloud CX deployment model (the
`PortalK8sAgent` / LXC metadata contract) locally, so CSEs can build, run and
debug **microservice** client extensions — including ones that talk to Liferay
over OAuth 2 — with cloud fidelity.

## Enable it

In `gradle.properties` (or `gradle-local.properties`):

```properties
lr.docker.environment.service.enabled[k3s]=true
```

With the service enabled, `lec start` brings up the cluster and auto-deploys every
Client Extension found under `client-extensions/` (see the **Liferay k8s** Gradle
task group). Nothing else in the workspace changes when k3s is disabled — the whole
integration is guarded by the service flag.

## What it deploys

For each CX (a directory containing `LCP.json`, or a supplied `*.zip`):

- an image is built and imported into the cluster's containerd,
- a **Deployment** (or **Job**, per `LCP.json` `kind`) + **Service** (NodePort) are applied,
- serving CX also get a Traefik **Ingress** at `<serviceId>.<virtualInstance>.localtest.me`,
- an **ext-provision** ConfigMap is written — the registration `PortalK8sAgent` reads.

## Networking

- **Liferay → CX**: via the auto-assigned NodePort (`k3s:<nodePort>`).
- **CX → Liferay**: OAuth CX expect the portal at `localhost:80`; a `socat` native
  sidecar bridges `localhost:80 → liferay:8080` (`liferay` resolves inside the
  cluster via the CoreDNS → docker-DNS `forwarder.sh`).
- **Browser → CX**: `http://<serviceId>.<virtualInstance>.localtest.me` (CORS-correct origin).

## PortalK8sAgent

The recipe exposes an unauthenticated `kubectl proxy` at `k3s:8001`. Point the agent
at it in the workspace's OSGi config
(`com.liferay.portal.k8s.agent.configuration.PortalK8sAgentConfiguration.config`):

```properties
apiServerHost="k3s"
apiServerPort="8001"
```

## Tailing CX logs

The `cx-logs` service streams pod logs into the `lec start` output using
[stern](https://github.com/stern/stern), baked into a small image (`cx-logs/Dockerfile`)
so the recipe carries no vendored binary.

## Tasks (`liferay k8s` group)

| Task | Purpose |
|---|---|
| `deployClientExtensions` | Build/unpack every CX and deploy it into k3s (runs on `start`). |
| `deployToK3s` (per CX module) | Rebuild just that CX and roll its pod. |
| `renderClientExtensions` | Print the manifests that would be applied (no docker, no cluster). |
| `clientExtensionStatus` | CRD-style status table for deployed CX. |
| `deployIngress` | Deploy the minimal Traefik ingress controller. |
| `k3sKubeconfig` | Write a host kubeconfig to `build/kubeconfig`. |
| `freshK3s` | **Manual**: wipe the k3s stack + state volume for a clean cluster. |