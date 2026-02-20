# syntax=docker/dockerfile:1.7

############################
# Build stage (Gradle + JDK)
############################
FROM gradle:8.7-jdk21-alpine AS build
WORKDIR /workspace

COPY gradlew gradlew.bat build.gradle.kts settings.gradle.kts ./
COPY gradle ./gradle

RUN --mount=type=cache,target=/home/gradle/.gradle \
    chmod +x ./gradlew && \
    ./gradlew --no-daemon dependencies || true

COPY src ./src

RUN --mount=type=cache,target=/home/gradle/.gradle \
    ./gradlew --no-daemon clean bootJar -x test

############################
# Runtime stage (Alpine + installed JRE)
############################
FROM alpine:3.20

# Install Java (and certs) explicitly
RUN apk add --no-cache openjdk21-jre ca-certificates && update-ca-certificates

# Non-root user
RUN addgroup -S app && adduser -S app -G app

WORKDIR /app
COPY --from=build /workspace/build/libs/*.jar /app/app.jar

USER app:app
EXPOSE 8080

ENV JAVA_OPTS="-XX:MaxRAMPercentage=75 -XX:InitialRAMPercentage=25 -Djava.security.egd=file:/dev/./urandom"

CMD ["sh", "-lc", "java $JAVA_OPTS -jar /app/app.jar"]
