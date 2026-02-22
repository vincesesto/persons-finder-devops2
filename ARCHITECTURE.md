# Persons Finder – Basic Architecture (Dev)

## Overview

This document describes the basic runtime architecture for the `persons-finder` service deployed to Kubernetes in the `persons-finder-dev` namespace.

The service:
- runs as a Kubernetes Deployment and is exposed internally by a ClusterIP Service
- is exposed to the public internet via an Ingress
- uses a Kubernetes Secret to provide `OPENAI_API_KEY` as an environment variable
- scales via an HPA based on CPU utilization (> 50%)
- calls an external AI/provider API, but **must not allow real names / PII to leave the cluster**
- uses a **PII Redaction Sidecar** pattern to sanitize/tokenize/redact outbound payloads before egress

---

## Logical Components

### In-cluster
- **Ingress Controller** (e.g., NGINX ingress): terminates inbound HTTP(S) and routes traffic to the Service
- **Service (ClusterIP)**: stable virtual IP/DNS pointing to Pods
- **Deployment / Pod**:
  - `persons-finder` application container (Java, `java -jar /app/app.jar`)
  - `pii-redaction-sidecar` proxy container (outbound gateway for external calls)
- **Secret**: `persons-finder-openai` storing `OPENAI_API_KEY`
- **HPA**: scales the Deployment between `minReplicas` and `maxReplicas` when average CPU > 50%

### External
- **End Users / Clients**: browsers or API consumers on the internet
- **External AI Provider API**: receives only redacted/tokenized content

---

## Architecture Diagram (high level)

```mermaid
flowchart TB
  %% Internet-facing path
  U[Internet Users / Clients] -->|HTTPS| I[Ingress Controller]
  I -->|HTTP 8080| SVC[Service: persons-finder (ClusterIP)]

  %% Pod internals
  subgraph NS[Namespace: persons-finder-dev]
    SVC --> PODS

    subgraph PODS[Deployment: persons-finder Pods]
      APP[Container: persons-finder app\n(java -jar /app/app.jar)]
      SIDE[Container: PII Redaction Sidecar\n(Outbound proxy/gateway)]
      SEC[(Secret: persons-finder-openai\nOPENAI_API_KEY)]
      HPA[HPA\nCPU > 50% scales replicas]

      SEC -->|env var| APP
      HPA -.-> PODS

      %% outbound control path
      APP -->|Outbound API calls (must go via proxy)| SIDE
    end
  end

  %% External provider
  SIDE -->|Redacted / tokenized payloads only| EXT[External Provider API]
```

---

## Data Flow Summary

### Inbound (Internet → Service)
1. Client sends a request to the public hostname handled by the **Ingress**.
2. Ingress routes traffic to the `persons-finder` **Service** on port 8080.
3. Service load-balances to one of the running Pods.

### Secret injection
1. `OPENAI_API_KEY` is stored in a Kubernetes **Secret** (`persons-finder-openai`).
2. The Deployment injects it into the app container as an environment variable via `valueFrom.secretKeyRef`.

### Outbound (Service → External Provider) with PII Redaction
1. The app prepares a request containing user data (names, bios).
2. The app sends outbound traffic to the **PII Redaction Sidecar** (e.g., via `HTTPS_PROXY` / `HTTP_PROXY` or a configured base URL).
3. The sidecar:
   - validates destination (allowlist of provider hostnames)
   - redacts or tokenizes PII fields (e.g., `name`, `bio`) according to policy
   - forwards only the sanitized request to the external provider

---

## PII Redaction Sidecar Responsibilities (baseline)

- **Egress allowlisting**
  - Only permit outbound traffic to the configured external provider(s).
- **Payload transformation**
  - Redact or tokenize PII fields before forwarding.
  - Recommended: deterministic tokenization for names (e.g., HMAC-based) so the provider never receives the true value.
- **Audit logging (recommended)**
  - Log decisions (redaction performed, destination, request IDs) without logging raw PII.

> Note: A sidecar pattern is most effective when paired with an **egress enforcement control** (e.g., NetworkPolicies default-deny egress, or a service mesh egress gateway) so the app cannot bypass the sidecar.

---

## Deployment/Scaling Notes

- The HPA uses CPU utilization. Ensure Metrics Server is installed in the cluster.
- The Service and Ingress provide stable routing regardless of replica count.
- The `persons-finder` image should be pulled from a registry (e.g., ECR) in non-local clusters.

---
```
