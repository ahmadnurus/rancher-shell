ARG ALPINE_VERSION=3.22
ARG GO_IMAGE=rancher/hardened-build-base:v1.26.8b1

# Image that provides cross compilation tooling.
FROM --platform=$BUILDPLATFORM rancher/mirrored-tonistiigi-xx:1.6.1 AS xx

FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS helm

# Clone repository once, and reuse it for target archs.
ARG HELM_VERSION
ADD --keep-git-dir=true https://github.com/helm/helm.git#${HELM_VERSION} /helm
RUN --mount=type=cache,target=/go/pkg/mod \
    cd /helm && go mod download

COPY --from=xx / /

# Cross-compile instead of emulating the compilation on the target arch.
ARG TARGETPLATFORM
RUN xx-go --wrap && mkdir -p /run/lock
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    make -C /helm

RUN xx-verify --static /helm/bin/helm

FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS kubectl

ARG KUBECTL_VERSION
ADD https://github.com/kubernetes/kubernetes/archive/refs/tags/${KUBECTL_VERSION}.tar.gz /src.tar.gz
RUN mkdir /src && tar -xzf /src.tar.gz -C /src --strip-components=1 && rm /src.tar.gz

COPY --from=xx / /
ARG TARGETPLATFORM
RUN xx-go --wrap
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    cd /src && \
    KUBE_GIT_VERSION=${KUBECTL_VERSION} \
    KUBE_GIT_COMMIT=unknown \
    KUBE_GIT_TREE_STATE=clean \
    KUBE_BUILD_PLATFORMS=$(xx-info os)/$(xx-info arch) \
    GOFLAGS="-tags=providerless" \
    CGO_ENABLED=0 \
    make WHAT=cmd/kubectl && \
    cp /src/_output/local/bin/$(xx-info os)/$(xx-info arch)/kubectl /kubectl
RUN xx-verify --static /kubectl

FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS k9s

ARG K9S_VERSION
ADD https://github.com/derailed/k9s/archive/refs/tags/${K9S_VERSION}.tar.gz /src.tar.gz
RUN mkdir /src && tar -xzf /src.tar.gz -C /src --strip-components=1 && rm /src.tar.gz

COPY --from=xx / /
ARG TARGETPLATFORM
RUN xx-go --wrap
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    cd /src && \
    CGO_ENABLED=0 go build -trimpath \
    -ldflags="-s -w -X github.com/derailed/k9s/cmd.version=${K9S_VERSION}" \
    -o /k9s .
RUN xx-verify --static /k9s

# Provides the runtime rootfs along with the shell tooling. Alpine is built
# for the x86-64 baseline (v1), therefore it runs on hosts that do not expose
# the x86-64-v2 feature set (SSE4.1, SSE4.2, POPCNT, ...), unlike the BCI
# images which require x86-64-v2 and abort with
# "Fatal glibc error: CPU does not support x86-64-v2".
FROM alpine:${ALPINE_VERSION} AS rootfs

# Packages are installed into the rootfs of this stage, which is then copied
# over to the scratch image. GNU coreutils/grep/sed/awk/find replace the
# busybox applets, so the shell tooling behaves as it did on the previous
# base, and vim replaces the busybox vi applet.
RUN apk add --no-cache \
    bash \
    bash-completion \
    ca-certificates \
    coreutils \
    curl \
    findutils \
    gawk \
    grep \
    jq \
    sed \
    vim \
    && rm -f /usr/bin/vi /usr/bin/view /usr/bin/vimdiff \
    && ln -sf /usr/bin/vim /usr/bin/vi \
    && rm -rf /var/cache/apk/*

RUN echo 'shell:x:1000:1000:shell,,,:/home/shell:/bin/bash' > /etc/passwd && \
    echo 'shell:x:1000:' > /etc/group && \
    mkdir -p /home/shell/.kube && \
    echo '. /usr/share/bash-completion/bash_completion' >> /home/shell/.bashrc && \
    echo 'alias k="kubectl"' >> /home/shell/.bashrc && \
    echo 'alias ks="kubectl -n kube-system"' >> /home/shell/.bashrc && \
    echo 'source <(kubectl completion bash)' >> /home/shell/.bashrc && \
    echo 'complete -o default -F __start_kubectl k' >> /home/shell/.bashrc && \
    echo 'LANG=en_US.UTF-8' >> /home/shell/.bashrc && \
    echo 'PS1="> "' >> /home/shell/.bashrc && \
    mkdir -p /tmp && \
    chmod 1777 /tmp && \
    chown -R 1000:1000 /home/shell

FROM scratch

COPY --from=rootfs / /
COPY --chown=root:root --chmod=0755 --from=kubectl /kubectl /usr/local/bin/
COPY --chown=root:root --chmod=0755 --from=helm /helm/bin/helm /usr/local/bin/
COPY --chown=root:root --chmod=0755 --from=k9s /k9s /usr/local/bin/
COPY --chown=root:root --chmod=0755 scripts/package/helm-cmd scripts/package/welcome scripts/package/kustomize /usr/local/bin/

USER 1000

WORKDIR /home/shell
CMD ["welcome"]
