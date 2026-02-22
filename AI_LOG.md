# AI Log

A working log of tasks and notes while improving and containerising the `persons-finder-devops2` repository.

---

## 1) Initial request

- **Repository**: https://github.com/vincesesto/persons-finder-devops2.git
- **Goal**: Create a `Dockerfile` so I can build and run the service locally on my laptop, then transfer the same image to a Kubernetes environment.
- **Requirements**:
  - **Best practices**
  - **Secure**
  - **Small image**
  - **Fast builds and runtime**
  - **Application works correctly**

### Build & run commands

```sh
# Build the image
docker build -t persons-finder:local .

# Run the container (example)
docker run --rm -p 8080:8080 persons-finder:local sh -lc 'java -jar /app/app.jar'
```

---

## 2) Extra work on Dockerfile (build failure)

### Error observed

```text
=> ERROR [build 7/7] RUN --mount=type=cache,target=/root/.gradle     ./gradlew --no-daemon clean bootJar -x test           0.6s
------
> [build 7/7] RUN --mount=type=cache,target=/root/.gradle     ./gradlew --no-daemon clean bootJar -x test:
#0 0.469 Error: Could not find or load main class org.gradle.wrapper.GradleWrapperMain
#0 0.469 Caused by: java.lang.ClassNotFoundException: org.gradle.wrapper.GradleWrapperMain
------
ERROR: failed to solve: failed to solve with frontend dockerfile.v0: failed to solve with frontend gateway.v0:
rpc error: code = Unknown desc = failed to build LLB: executor failed running
[/bin/sh -c ./gradlew --no-daemon clean bootJar -x test]: runc did not terminate sucessfully
```

### Diagnosis

This typically means the **Gradle wrapper JAR is missing inside the image**.

- `./gradlew` exists
- but `gradle/wrapper/gradle-wrapper.jar` (and/or `gradle-wrapper.properties`) is not present in the build context or not copied into the build stage.

**Most common causes**:
- `.dockerignore` accidentally excludes `gradle/wrapper/**`
- the wrapper JAR isn’t committed into the repository

### Suggested fix (regenerate wrapper)

```sh
docker run --rm \
  -u "$(id -u)":"$(id -g)" \
  -v "$PWD":/workspace \
  -w /workspace \
  gradle:8.7-jdk21-alpine \
  gradle wrapper --gradle-version 8.7
```

---

## 3) Kubernetes deployment (namespace, secret, deployment, HPA, service, ingress)

### Prompt used

I have a working docker image that is now running with the command:

```sh
docker run --rm -p 8080:8080 -e OPENAI_API_KEY=<API_KEY> persons-finder:local sh -lc 'java -jar /app/app.jar'
```

I would like to deploy it to Kubernetes in a new namespace called `persons-finder-dev`. Can you please create the YAML files to create:

- the new namespace
- create a secret to store the value for `OPENAI_API_KEY`
- create the new deployment to run the image, but the value for `OPENAI_API_KEY` should be mounted as a secret
- create a HPA to scale based on CPU hitting over 50%
- create a service to allow access to this deployment

### Answer (summary)

Kubernetes YAML manifests were created to:
- deploy the image into a new namespace `persons-finder-dev`
- store `OPENAI_API_KEY` in a Kubernetes Secret
- run a Deployment that reads the env var from that Secret
- expose it via a Service
- autoscale via an HPA when CPU > 50%

### Apply commands

```sh
kubectl apply -f k8s/persons-finder-dev-namespace.yaml
kubectl apply -f k8s/persons-finder-dev-secret.yaml
kubectl apply -f k8s/persons-finder-dev-deployment.yaml
kubectl apply -f k8s/persons-finder-dev-service.yaml
kubectl apply -f k8s/persons-finder-dev-hpa.yaml
```

### Follow-up: inject secret value securely (avoid hard-coding)

**Update requested**: The secret manifest looked good, but the API key should not be committed in Git. Provide an easy but secure way to inject the secret at deploy time.

**Recommended approach**:
1. Commit a **template Secret** containing no secret material.
2. Create/update the real Secret at deploy time (from an environment variable on your terminal/CI runner).

Template (committed):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: persons-finder-openai
  namespace: persons-finder-dev
type: Opaque
# Intentionally no data/stringData in this template.
```

Deploy-time secret creation/update (not committed):

```sh
export OPENAI_API_KEY='...your real key...'

kubectl -n persons-finder-dev create secret generic persons-finder-openai \
  --from-literal=OPENAI_API_KEY="$OPENAI_API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Follow-up: add an Ingress rule (internet-accessible service)

**Update requested**: The service also needs to be accessible via the internet.

**Result**: A new ingress manifest was added:

- `k8s/persons-finder-dev-ingress.yaml`

---

## 4) GitHub Actions workflows

### 4.1) Build, scan, and push to ECR

#### Prompt used

We have our Dockerfile building and running successfully. I would like to create a GitHub Actions pipeline that:

- checks out our code
- builds the Docker image
- runs a security scan over the image to make sure there are no issues
- if the scan is successful, pushes the image to an ECR repo we can configure at a later time
- fails the workflow if the scan fails

#### Answer (summary)

A GitHub Actions workflow was created that:
- checks out the repo
- builds the Docker image
- runs an image vulnerability scan (**fails if findings exceed a threshold**)
- if scan passes, pushes to Amazon ECR
- keeps ECR configuration flexible via variables/secrets

**Used tooling**
- `aws-actions/configure-aws-credentials` (OIDC; avoids long-lived AWS keys)
- `aquasecurity/trivy-action` (image scanning)
- `docker/build-push-action` (build/push)

**Location**
- `gha_wf/docker-build-scan-push-ecr.yml`

**Items to configure later**
- **ECR repository name**: update `env.ECR_REPOSITORY` when known (or keep default if ECR repo will be `persons-finder`)
- **AWS region**: update `env.AWS_REGION`
- **AWS OIDC role**: create an IAM role trusted for GitHub OIDC with permissions to push to ECR  
  - store role ARN in GitHub Actions secret:
    - `AWS_ROLE_TO_ASSUME = arn:aws:iam::<account-id>:role/<role-name>`

### 4.2) Deploy workflow (deploy image to Kubernetes)

#### Prompt used

I'd like to also create a separate deployment GitHub Action that will deploy the new image to the deployment.

#### Answer (summary)

A new deployment workflow was added:

- `gha_wf/deploy-persons-finder-dev.yml`

**Key setup items to provide**
- `secrets.AWS_ROLE_TO_ASSUME`: same role used for ECR push (or a different one) with required access
- `secrets.AWS_ACCOUNT_ID`: AWS account ID (used to construct the ECR image URL)
- `secrets.KUBECONFIG_B64`: base64-encoded kubeconfig with access to the cluster/namespace

---

## 5) PII options (redaction sidecar / gateway)

### Prompt used

> I am just looking at the service and the app sends user PII (names, bios) to an external provider.  
> Can you think of an easy way to implement a “PII Redaction Sidecar” or gateway logic to prevent real names from leaving our cluster?

### Answer (summary)

A strong Kubernetes pattern is to **force all outbound traffic** to the external provider through a **local sidecar** (or a cluster egress gateway), which **redacts or tokenises PII** before it leaves the pod/cluster.

### Option 1: PII-redaction sidecar (easiest to drop in)

**How it works**
- Add a sidecar container (e.g., Envoy or a small custom proxy) to the same Pod.
- Configure the app to send requests to the provider **via the sidecar** by either:
  - Changing the provider base URL to `http://127.0.0.1:<port>` (*best*), or
  - Using proxy env vars: `HTTPS_PROXY`, `HTTP_PROXY`, `NO_PROXY`.
- Sidecar responsibilities:
  - allowlist outbound destinations (only the provider host)
  - redact `name`, `bio`, etc. in JSON before forwarding

**Pros**
- Minimal cluster dependencies
- Clear boundary: *nothing leaves the pod unredacted*

**Cons**
- The app must be able to use a proxy or configurable base URL
- Redaction must understand payload format/schemas

**Implementation notes**
- Prefer **schema-based JSON field redaction** if the payload structure is known/controlled.
- NLP/regex-based detection is possible but less reliable.

### Option 2: Service mesh egress gateway + redaction filter (best cluster-level control)

**How it works**
- Block direct egress from workloads using mesh policy.
- Allow egress only through an **egress gateway** that applies a redaction filter.

**Pros**
- Strong enforcement across workloads (harder to bypass)
- Central place for egress control and auditing

**Cons**
- Requires mesh install/configuration (more moving parts)

---

## 6) Architectural diagram

### Prompt used

> This is all great. From the information I have provided, can you please provide a basic Architectural diagram created as `ARCHITECTURE.md`.  
> Please provide the basic architecture of the service, and also include the PII-redaction sidecar.
````
