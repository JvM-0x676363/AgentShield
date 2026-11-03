#!/usr/bin/env bash
# Shared prerequisites and pinned scanner installation for install.sh/deploy.sh.
# Caller must define SCRIPT_DIR, DRY_RUN, info() and warn().

set -euo pipefail

ensure_codex_sandbox_prereqs_unix() {
    local os package_manager=""
    os="linux"
    [[ "$(uname)" == "Darwin" ]] && os="darwin"

    if [[ "$os" == "darwin" ]]; then
        info "Codex sandbox: macOS uses native Seatbelt; no additional requirements."
        return 0
    fi
    if command -v bwrap > /dev/null 2>&1; then
        info "Codex sandbox: Bubblewrap already installed."
        return 0
    fi
    if [[ $EUID -ne 0 ]]; then
        warn "Codex sandbox: Bubblewrap missing; run as root to install it."
        return 1
    fi

    for candidate in apt-get dnf yum zypper pacman apk; do
        if command -v "$candidate" > /dev/null 2>&1; then
            package_manager="$candidate"
            break
        fi
    done
    if [[ -z "$package_manager" ]]; then
        warn "Codex sandbox: Bubblewrap missing and no supported package manager was found."
        return 1
    fi

    if $DRY_RUN; then
        case "$package_manager" in
            apt-get) echo "  [dry-run] apt-get install -y bubblewrap" ;;
            dnf)     echo "  [dry-run] dnf install -y bubblewrap" ;;
            yum)     echo "  [dry-run] yum install -y bubblewrap" ;;
            zypper)  echo "  [dry-run] zypper --non-interactive install bubblewrap" ;;
            pacman)  echo "  [dry-run] pacman --noconfirm -Sy bubblewrap" ;;
            apk)     echo "  [dry-run] apk add bubblewrap" ;;
        esac
        return 0
    fi

    info "Codex sandbox: installing Bubblewrap via $package_manager..."
    case "$package_manager" in
        apt-get) apt-get install -y bubblewrap ;;
        dnf)     dnf install -y bubblewrap ;;
        yum)     yum install -y bubblewrap ;;
        zypper)  zypper --non-interactive install bubblewrap ;;
        pacman)  pacman --noconfirm -Sy bubblewrap ;;
        apk)     apk add bubblewrap ;;
    esac || { warn "Codex sandbox: failed to install Bubblewrap."; return 1; }

    if command -v bwrap > /dev/null 2>&1; then
        info "Codex sandbox: Bubblewrap installed."
        return 0
    fi
    warn "Codex sandbox: package manager completed, but bwrap is not in PATH."
    return 1
}

_tools_catalog_value() {
    local tool="$1" platform="$2" field="$3"
    "$PY" - "$SCRIPT_DIR/policy/tools.json" "$tool" "$platform" "$field" <<'PY'
import json, sys
path, tool, platform, field = sys.argv[1:]
with open(path, encoding="utf-8") as fh:
    catalog = json.load(fh)
record = catalog["tools"][tool]
if platform == "package":
    print(record[field])
else:
    print(record["assets"][platform][field])
PY
}

_tools_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

_install_pinned_binary_unix() {
    local tool="$1" platform="$2"
    local binary file checksum url tmp actual extracted repo
    binary=$(_tools_catalog_value "$tool" package binary)
    if command -v "$binary" >/dev/null 2>&1; then
        info "  OK $binary already installed"
        return 0
    fi
    file=$(_tools_catalog_value "$tool" "$platform" file)
    checksum=$(_tools_catalog_value "$tool" "$platform" sha256)
    case "$tool" in
        gitleaks) repo="gitleaks/gitleaks" ;;
        trivy)    repo="aquasecurity/trivy" ;;
        *)        warn "  Tool without approved repository: $tool"; return 1 ;;
    esac
    url="https://github.com/$repo/releases/download/v$(_tools_catalog_value "$tool" package version)/$file"
    info "  Installing $tool pinned at $(_tools_catalog_value "$tool" package version)..."
    if $DRY_RUN; then
        echo "  [dry-run] downloads $file, verifies SHA-256 and installs to /usr/local/bin"
        return 0
    fi
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/${tool}.XXXXXX")
    if ! curl --fail --location --silent --show-error "$url" --output "$tmp/$file"; then
        warn "  Failed to download $tool from pinned release"
        rm -rf "$tmp"
        return 1
    fi
    actual=$(_tools_sha256 "$tmp/$file")
    if [[ "$actual" != "$checksum" ]]; then
        warn "  Invalid SHA-256 for $tool; artifact discarded"
        rm -rf "$tmp"
        return 1
    fi
    tar -xzf "$tmp/$file" -C "$tmp"
    extracted=$(find "$tmp" -maxdepth 2 -type f -name "$binary" -print -quit)
    if [[ -z "$extracted" ]]; then
        warn "  Binary $binary not found in verified artifact"
        rm -rf "$tmp"
        return 1
    fi
    install -m 0755 "$extracted" "/usr/local/bin/$binary"
    rm -rf "$tmp"
    info "  OK $binary installed in /usr/local/bin (SHA-256 verified)"
}

install_security_tools_unix() {
    if [[ -z "${PY:-}" ]]; then
        warn "  Python 3 is required to read policy/tools.json; scanners were not installed"
        return 1
    fi
    local os="linux" arch="x64"
    [[ "$(uname)" == "Darwin" ]] && os="darwin"
    [[ "$(uname -m)" == "arm64" || "$(uname -m)" == "aarch64" ]] && arch="arm64"
    _install_pinned_binary_unix gitleaks "$os-$arch"
    _install_pinned_binary_unix trivy "$os-$arch"

    if command -v semgrep >/dev/null 2>&1; then
        info "  OK semgrep already installed"
    elif $DRY_RUN; then
        echo "  [dry-run] pip3 install semgrep==$(_tools_catalog_value semgrep package version)"
    elif command -v pip3 >/dev/null 2>&1; then
        pip3 install --disable-pip-version-check "semgrep==$(_tools_catalog_value semgrep package version)" \
            || warn "  Failed to install semgrep"
    else
        warn "  pip3 not found -- install Python 3 before semgrep"
    fi

    # Trivy's MCP plugin is a separate executable artifact. We do not download it without
    # a pinned version and provenance; MCP remains inactive until an approved enterprise
    # package is added to the catalog.
    warn "  trivy-mcp is not installed automatically: requires a versioned and verified package"
}
