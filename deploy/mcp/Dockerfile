# leanfm-mcp: LeanFM's MCP endpoint alone, for remote hosting (clause selfhost.mcp.hosting).
# Build from the repository root:   docker build -f deploy/mcp/Dockerfile -t leanfm-mcp .
# Run:                               docker run --rm -p 8090:8090 leanfm-mcp
# Put TLS in front (the platform's load balancer, Caddy or nginx); the container speaks plain HTTP.

FROM debian:bookworm-slim AS build
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git build-essential \
 && rm -rf /var/lib/apt/lists/*
RUN curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh \
      | sh -s -- -y --default-toolchain none
ENV PATH=/root/.elan/bin:$PATH
WORKDIR /src
COPY lean-toolchain lakefile.toml lake-manifest.json ./
COPY LeanFM ./LeanFM
COPY LeanFM.lean McpServer.lean ./
RUN lake build leanfm-mcp

FROM debian:bookworm-slim
RUN useradd --system --create-home --home-dir /app leanfm
WORKDIR /app
COPY --from=build /src/.lake/build/bin/leanfm-mcp /app/leanfm-mcp
# Files served as MCP resources, read relative to the working directory.
COPY book/main.pdf book/main-dark.pdf /app/book/
COPY LeanFM/LLMGenerated/Requirements.lean LeanFM/LLMGenerated/Requirements.proto \
     LeanFM/LLMGenerated/Implementation.lean LeanFM/LLMGenerated/SelfHosting.lean \
     LeanFM/LLMGenerated/McpLogicImplementation.lean LeanFM/LLMGenerated/SessionImplementation.lean \
     /app/LeanFM/LLMGenerated/
USER leanfm
ENV LEANFM_MCP_BIND=0.0.0.0 \
    LEANFM_MCP_PORT=8090
EXPOSE 8090
CMD ["/app/leanfm-mcp"]
