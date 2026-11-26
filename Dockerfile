FROM golang:1.27-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -buildvcs=false -ldflags="-s -w" -o /out/chit-server ./cmd/chit-server

FROM alpine:3.22
RUN apk add --no-cache ca-certificates tzdata
COPY --from=build /out/chit-server /usr/local/bin/chit-server
VOLUME /pb_data
EXPOSE 8090
HEALTHCHECK --interval=30s --timeout=5s CMD wget -qO- http://127.0.0.1:8090/api/health || exit 1
CMD ["chit-server", "serve", "--http=0.0.0.0:8090", "--dir=/pb_data"]
