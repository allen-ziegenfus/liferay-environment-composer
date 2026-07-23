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

## Supplying Client Extensions

CX are discovered **recursively** under `client-extensions/`, in either input form:

| Input form | What it is | How it is handled |
|---|---|---|
| `*.zip` | a built CX artifact — the usual LEC input (e.g. the `dist/*.zip` a `liferay-portal` workspace produces) | unpacked into `build/cx/<name>/`, then imaged |
| a directory with `LCP.json` at its root | an unpacked or hand-authored CX (`LCP.json` + `Dockerfile` + assets + `*.client-extension-config.json`) | imaged in place |

Both forms converge on the same thing — a directory with an `LCP.json` — so a zip
and its unpacked equivalent deploy identically. **Subfolders are organizational
only** (group by vendor, team, etc.); they do *not* set the virtual instance (see
[Multiple virtual instances](#multiple-virtual-instances)). You can mix zips and
directories, at any depth:

```
client-extensions/
  liferay.com/
    liferay-sample-custom-element-1.zip   # a built artifact
    liferay-sample-batch.zip
  my-service/                             # an unpacked / source CX
    LCP.json
    Dockerfile
    ...
```

To build the official samples and stage them, for example:

```bash
(cd liferay-sample-workspace && ./gradlew build)
cp liferay-sample-workspace/client-extensions/*/dist/*.zip \
	my-lec-workspace/client-extensions/liferay.com/
```

## What it deploys

For each CX an image is built and imported into the cluster's containerd, then a
workload is applied per its `LCP.json` `kind` (and whether it serves a port):

| CX kind (`LCP.json`) | k8s workload | extras |
|---|---|---|
| `Deployment` **with a port** (custom element, CSS/JS, theme, static assets, config servers) | **Deployment** + **Service** (NodePort) | a Traefik **Ingress** at `<sid>.<vid>.localtest.me`; a **socat** native sidecar if the CX calls Liferay over OAuth |
| `Deployment` without a port | **Deployment** | — |
| `Job` (batch, site initializer) | **Job** | — |
| `CronJob` (with a `schedule`) | **CronJob** | runs on the schedule |

Every CX — serving, batch, cron, or config-only — also gets an **ext-provision**
ConfigMap: the registration the `PortalK8sAgent` reads to surface the CX in Liferay.

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

## Multiple virtual instances

Each CX is registered against a Liferay **virtual instance**. The resolved vid is
woven through the CX's manifests — the ingress host (`<sid>.<vid>.localtest.me`),
the `dxp.lxc.liferay.com/virtualInstanceId` annotation, and the CX's own
`virtualInstanceId` — so several instances are addressable side by side.

A built archive only carries the placeholder `default`. Override it — per CX or
workspace-wide — by this precedence (first match wins):

1. `client-extensions/virtual-instances.properties`, with `<name-or-sid> = <vid>`
   lines (relocate the file with `-PviMapping=<path>`)
2. `-PvirtualInstance.<name>=<vid>` or `-PvirtualInstance.<sid>=<vid>` (per CX)
3. `-PvirtualInstanceId=<vid>` (workspace default)
4. `default`

The `<name>` is the CX's directory/zip name; the `<sid>` is its `LCP.json` `id`.
For example, to split two CX across instances:

```properties
# client-extensions/virtual-instances.properties
liferay-sample-custom-element-1 = acme
liferay-sample-custom-element-2 = beta
```

The metadata ConfigMaps the agent reads are named by the instance **webId**
(`company.getWebId()`), resolved independently: `-PwebId=<id>` >
`company.default.web.id` in `configs/common/portal-ext.properties` > `liferay.com`.
The target instance must exist in Liferay for the agent to register the CX there.

## PortalK8sAgent

The agent talks to the k3s API server **directly with a ServiceAccount bearer
token** — the same model as production Liferay Cloud (no unauthenticated proxy).
The `deployAgentCredentials` Gradle task applies `agent-rbac.yaml` (a
ServiceAccount + Role scoped to `configmaps` — modeled on cloud's
`liferay-dxp-agent` ClusterRole — + a long-lived token Secret), mints the token,
reads the cluster CA, and writes the config:

```properties
apiServerHost="k3s"
apiServerPort="6443"
apiServerSSL="true"
caCertData="<cluster CA>"
saToken="<ServiceAccount token>"
```

The config is written into Liferay's OSGi configs dir (`/opt/liferay/osgi/configs`,
watched by Felix fileinstall) via `docker exec` — directly, so there is no shared
volume to race the image's trial-license population. The k3s server runs with
`--tls-san=k3s` so the API serving cert covers the `k3s` hostname (TLS
verification succeeds). Nothing static is baked into the workspace — the token +
CA are generated per cluster at start (`deployAgentCredentials` runs on `start`,
before CX deploy).

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