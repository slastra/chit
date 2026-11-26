# The web app, built with the Flutter the app is developed on (cirruslabs'
# images stop short of it, so clone it at that tag).
FROM debian:bookworm-slim AS web
RUN apt-get update \
 && apt-get install -y --no-install-recommends git curl unzip xz-utils ca-certificates \
 && rm -rf /var/lib/apt/lists/*
ARG FLUTTER=3.50.1
RUN git clone --depth 1 --branch "$FLUTTER" https://github.com/flutter/flutter.git /opt/flutter
ENV PATH=/opt/flutter/bin:$PATH
RUN flutter config --no-analytics --enable-web >/dev/null && flutter precache --web
WORKDIR /src/app
COPY app/pubspec.yaml app/pubspec.lock ./
COPY app/third_party ./third_party
RUN flutter pub get
COPY app/ ./
RUN flutter build web --release

FROM golang:1.27-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -buildvcs=false -ldflags="-s -w" -o /out/chit-server ./cmd/chit-server

FROM alpine:3.22
RUN apk add --no-cache ca-certificates tzdata
COPY --from=build /out/chit-server /usr/local/bin/chit-server
# served at the root by chit-server (CHIT_WEB)
COPY --from=web /src/app/build/web /srv/web
VOLUME /pb_data
EXPOSE 8090
HEALTHCHECK --interval=30s --timeout=5s CMD wget -qO- http://127.0.0.1:8090/api/health || exit 1
CMD ["chit-server", "serve", "--http=0.0.0.0:8090", "--dir=/pb_data"]
