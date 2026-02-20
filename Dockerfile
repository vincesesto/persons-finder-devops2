# syntax=docker/dockerfile:1.7

############################
# Build stage
############################
FROM eclipse-temurin:21-jdk-alpine AS build
WORKDIR /workspace

# Copy only Gradle wrapper + build files first (better Docker layer caching)
COPY gradlew build.gradle.kts settings.gradle.kts ./
COPY gradle ./gradle

# Pre-download dependencies (cacheable layer)
# If tests are slow/flaky in container, keep -x test; otherwise remove it.
RUN --mount=type=cache,target=/root/.gradle \
    chmod +x ./gradlew && \
    ./gradlew --no-daemon clean build -x test || true

# Now copy source
COPY src ./src

# Build the application JAR
RUN --mount=type=cache,target=/root/.gradle \
    ./gradlew --no-daemon clean bootJar -x test

############################
# Runtime stage
############################
FROM eclipse-temurin:21-jre-alpine AS runtime

# Create a non-root user
RUN addgroup -S app && adduser -S app -G app

WORKDIR /app

# Copy the built jar (Spring Boot bootJar output)
COPY --from=build /workspace/build/libs/*.jar /app/app.jar

USER app:app

# Spring Boot default port is often 8080; adjust if your app differs
EXPOSE 8080

# Good defaults for containers; you can override in k8s via env
ENV JAVA_OPTS="-XX:MaxRAMPercentage=75 -XX:InitialRAMPercentage=25 -Djava.security.egd=file:/dev/./urandom"

# Optional healthcheck (works if you expose /actuator/health)
# If you don't have actuator, remove this block.
# HEALTHCHECK --interval=30s --timeout=3s --start-period=30s --retries=3 \
#   CMD wget -qO- http://127.0.0.1:8080/actuator/health | grep -q '"status":"UP"' || exit 1

ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar /app/app.jar"]
