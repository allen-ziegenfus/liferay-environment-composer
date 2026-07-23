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

## Network paths

The environment spans two networks — the Docker Compose network (Liferay, the
database, the `k3s` container) and the in-cluster pod network — so four distinct
paths are wired up. All browser traffic and all CX ingress share the `k3s`
container's published `:80` (traefik); Liferay's `:8080` is also published for
direct/admin access.

```
[4] browser ── http://localhost ─────────────────▶ traefik :80 ──▶ liferay (ExternalName svc) ──▶ liferay:8080
[3] browser ── http://<sid>.<vid>.localtest.me ──▶ traefik :80 ──▶ CX Service ──▶ CX pod
[1] liferay ── http://k3s:<nodePort> ────────────▶ CX Service (NodePort) ──▶ CX pod
[2] CX pod  ── http://localhost:80 ──(socat)─────▶ liferay:8080
```

**[1] Liferay → CX** — server-side webhooks (object actions). Liferay's backend
calls the CX at its NodePort, reachable on the Docker network via the `k3s` alias
(`http://k3s:<nodePort>`, which is the CX's `.serviceAddress`). This is **not** the
ingress URL: `…localtest.me` resolves to `127.0.0.1`, which inside the Liferay
container is Liferay itself, and a `baseURL` cannot carry a `Host` header for
traefik to route on. Server-side calls have no CORS/browser concern, so the direct
NodePort is correct.

**[2] CX → Liferay** — server-side calls from a CX pod (OAuth token requests,
headless API calls). The `dxp-metadata` advertises the portal at `localhost` over
`http` (port 80), so CX call `localhost:80`. A `socat` **native sidecar**
(an initContainer with `restartPolicy: Always`) in each CX pod bridges
`localhost:80 → liferay:8080`. `liferay` resolves from inside the cluster because
`forwarder.sh` points CoreDNS at Docker's embedded DNS. It is a native sidecar so
it does not block `Job`/`CronJob` completion.

**[3] Browser → CX** — a CX's static assets (custom-element bundles, CSS, JS). The
browser loads them from the CX ingress host
`http://<serviceId>.<virtualInstance>.localtest.me` (→ `127.0.0.1:80` → traefik →
CX pod). A browser-facing CX's registered `baseURL` (which its `urls`/`cssURLs`
resolve against) is this ingress URL.

**[4] Browser → Liferay** — and the CORS link. Liferay is *also* fronted by traefik
on host `localhost` (an ExternalName Service → the `liferay` compose service).
**Open Liferay at `http://localhost`, not `http://localhost:8080`.** A CX's static
server (Caddy) uses the domains the `PortalK8sAgent` advertises
(`com.liferay.lxc.dxp.domains`) as its CORS allow-list, and the agent advertises
the bare virtual host `localhost` with **no port** (it has no port awareness).
Serving Liferay on `:80` via traefik makes the browser's page origin exactly
`http://localhost`, which matches — so a custom element loaded cross-origin from
`…localtest.me` passes CORS. Reaching Liferay on `:8080` would make the origin
`http://localhost:8080` and CX CORS would fail.

### `baseURL` is address-type-aware

Because paths [1] and [3] need different addresses, the plugin rewrites each CX
config's `baseURL` by type when it renders the ext-provision ConfigMap:

| CX config type | `baseURL` | reached by |
|---|---|---|
| `objectAction` (server-side webhook) | `http://k3s:<nodePort>` | Liferay backend — path [1] |
| everything else (custom element, …) | `http://<sid>.<vid>.localtest.me` | browser — path [3] |

## PortalK8sAgent

The agent talks to the k3s API server **directly with a ServiceAccount bearer
token** — the same model as production Liferay Cloud (no unauthenticated proxy).
The `k3s-agent-credentials` one-shot applies `agent-rbac.yaml` (a ServiceAccount
+ Role scoped to `configmaps` — modeled on cloud's `liferay-dxp-agent`
ClusterRole — + a long-lived token Secret), then hot-deploys the generated
config into Liferay's `/opt/liferay/deploy` (a shared volume):

```properties
apiServerHost="k3s"
apiServerPort="6443"
apiServerSSL="true"
caCertData="<cluster CA>"
saToken="<ServiceAccount token>"
```

The k3s server runs with `--tls-san=k3s` so the API serving cert covers the
`k3s` hostname (TLS verification succeeds). Nothing static is baked into the
workspace — the token + CA are generated per cluster at start.

## Roadmap / TODO

- **PaaS (CRD) mode.** Today the agent uses the ConfigMap contract (the DXP
  agent is ConfigMap-based). Liferay Cloud's PaaS pipeline instead uses the
  `k8s.liferay.com` CRDs (`LiferayExtensionProvision` / `Init` /
  `VirtualInstance`). Emulating that would mean installing those CRDs + a small
  controller to materialize CRs into the ConfigMaps the agent reads — deferred
  as a larger, separate piece.

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