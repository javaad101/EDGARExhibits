# Stage 1: Build release binary with Swift 6.4 on Ubuntu 24.04
FROM swift:6.4-noble AS build
WORKDIR /src

COPY Package.swift Package.resolved ./
RUN swift package resolve

COPY Sources ./Sources
COPY Tests ./Tests
RUN swift build -c release --product EDGARExhibits

# Stage 2: Official slim Swift 6.4 runtime image + compiled React Observatory assets
FROM swift:6.4-noble-slim
WORKDIR /app

COPY --from=build /src/.build/release/EDGARExhibits /app/EDGARExhibits
COPY Public /app/Public

ENV PORT=8080
ENV WEB_ROOT=/app/Public
EXPOSE 8080

USER nobody
ENTRYPOINT ["/app/EDGARExhibits"]
