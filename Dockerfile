# Stage 1: build bằng Maven
FROM maven:3.6.3-jdk-8 AS build
WORKDIR /build
COPY pom.xml .
COPY src ./src
RUN mvn -q -DskipTests package

# Stage 2: chạy bằng JRE 8 CŨ (nhiều CVE tầng runtime) để test image scanning
FROM openjdk:8u191-jre
LABEL maintainer="security-test"
LABEL description="Intentionally vulnerable Java app (Log4Shell + XXE) for scanner validation. DO NOT use in production."

WORKDIR /app
COPY --from=build /build/target/vuln-java-app.jar ./app.jar

# Cố ý chạy root, không HEALTHCHECK, không giới hạn tài nguyên
EXPOSE 8080
CMD ["java", "-jar", "app.jar"]
