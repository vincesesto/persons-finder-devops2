# AI Log

A working log of tasks and notes while improving and containerising the `persons-finder-devops2` repository.

---

## 1) Initial request

**Repository**:  
https://github.com/vincesesto/persons-finder-devops2.git

**Goal**: Create a `Dockerfile` so I can build and run the service locally on my laptop, then transfer the same image to a Kubernetes environment.

**Requirements**:
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

## 3) PII options (redaction sidecar / gateway)

### Prompt used

> I am just looking at the service and the app sends user PII (names, bios) to an external provider.  
> Can you think of an easy way to implement a “PII Redaction Sidecar” or gateway logic to prevent real names from leaving our cluster?

### Answer (summary)

An effective Kubernetes pattern is to **force all outbound traffic** to the external provider through a **local sidecar** (or a cluster egress gateway), which **redacts or tokenises PII** before it leaves the pod/cluster.

#### Option 1: PII-redaction sidecar (easiest to drop in)

**How it works**
- Add a sidecar container (e.g., Envoy or a small custom proxy) to the same Pod.
- Configure the app to send requests to the provider **via the sidecar** by either:
  - Changing the provider base URL to `http://127.0.0.1:<port>` (*best*), or
  - Using proxy env vars: `HTTPS_PROXY`, `HTTP_PROXY`, `NO_PROXY`.
- Sidecar responsibilities:
  - Allowlist outbound destinations (only the provider host).
  - Redact `name`, `bio`, etc. in JSON before forwarding.

**Pros**
- Minimal cluster dependencies.
- Clear boundary: *nothing leaves the pod unredacted*.

**Cons**
- The app must be able to use a proxy or configurable base URL.
- Redaction must understand payload format/schemas.

**Implementation notes**
- Prefer **schema-based JSON field redaction** if the payload structure is known/controlled.
- NLP/regex detection is possible but less reliable.

#### Option 2: Service mesh egress gateway + redaction filter (best cluster-level control)

**How it works**
- Block direct egress from workloads using mesh policy.
- Allow egress only through an **egress gateway** that applies a redaction filter.

**Pros**
- Strong enforcement across workloads (harder to bypass).
- Central place for egress control and auditing.

**Cons**
- Requires service mesh installation/configuration (more moving parts).

---

## 4) Architectural diagram

### Prompt used

> This is all great. From the information I have provided, can you please provide a basic Architectural diagram created as `ARCHITECTURE.md`.  
> Please provide the basic architecture of the service, and also include the PII-redaction sidecar.
````
