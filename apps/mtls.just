
MTLS_DIR := "traefik/mtls-ca"

[private]
mtls-encrypt file:
    @sops encrypt --input-type binary --output-type binary --age {{SOPS_AGE_PUBLICKEY}} {{file}}

[private]
mtls-decrypt file:
    #!/usr/bin/env bash
    set -euo pipefail
    sops decrypt --input-type binary --output-type binary {{file}}

# One-time: generate the mTLS root CA. Safe to re-run (no-op if CA already exists)
[group('mtls')]
mtls-ca-init:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -f {{MTLS_DIR}}/ca.key.enc ]]; then
        echo "CA already exists at {{MTLS_DIR}}/ca.key.enc, skipping."
        exit 0
    fi
    mkdir -p {{MTLS_DIR}}/clients traefik/config/mtls
    WORKDIR=$(mktemp -d)
    trap 'rm -rf "$WORKDIR"' EXIT
    openssl genrsa -out "$WORKDIR/ca.key" 4096
    openssl req -x509 -new -nodes -key "$WORKDIR/ca.key" -sha256 -days 3650 \
        -out "$WORKDIR/ca.crt" -subj "/CN=Homelab Root CA"
    just mtls-encrypt "$WORKDIR/ca.key" > {{MTLS_DIR}}/ca.key.enc
    cp "$WORKDIR/ca.crt" traefik/config/mtls/ca.crt
    echo "Generated CA. Commit and push apps/traefik/mtls-ca/ca.key.enc and apps/traefik/config/mtls/ca.crt, then 'just docker-up traefik'."

# List client certificates
[group('mtls')]
mtls-client-list:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p traefik/config/mtls/clients
    for cert in traefik/config/mtls/clients/*.intermediate.crt; do
        [[ -e "$cert" ]] || continue
        echo "          - /config/mtls/clients/$(basename $cert)"
    done
    COUNT=$(find traefik/config/mtls/clients -maxdepth 1 -name '*.intermediate.crt' | wc -l | tr -d ' ')
    echo "There are $COUNT trusted client cert(s)."
    if [[ "$COUNT" -eq 0 ]]; then
        echo "WARNING: no clients left — mtls-clients@file now trusts nothing, locking out all mTLS routers." >&2
    fi


# Regenerate tls-options.yml's caFiles list from whatever client intermediate certs are currently present. Called by mtls-client-add and mtls-client-revoke — this file is fully generated, don't hand-edit it
[private]
mtls-rebuild-tls-options:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p traefik/config/mtls/clients
    OUT=traefik/config/tls-options.yml
    {
        echo "tls:"
        echo "  options:"
        echo "    mtls-clients:"
        echo "      minVersion: VersionTLS12"
        echo "      clientAuth:"
        echo "        caFiles:"
        for cert in traefik/config/mtls/clients/*.intermediate.crt; do
            [[ -e "$cert" ]] || continue
            echo "          - /config/mtls/clients/$(basename "$cert")"
        done
        echo "        clientAuthType: RequireAndVerifyClientCert"
    } > "$OUT"
    COUNT=$(find traefik/config/mtls/clients -maxdepth 1 -name '*.intermediate.crt' | wc -l | tr -d ' ')
    echo "Rebuilt $OUT listing $COUNT trusted client cert(s)."
    if [[ "$COUNT" -eq 0 ]]; then
        echo "WARNING: no clients left — mtls-clients@file now trusts nothing, locking out all mTLS routers." >&2
    fi

# Issue a client certificate under its own per-client intermediate CA, signed by the root. 
[group('mtls')]
mtls-client-add NAME:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ ! -f {{MTLS_DIR}}/ca.key.enc ]]; then
        echo "No CA found — run 'just mtls-ca-init' first." >&2
        exit 1
    fi
    WORKDIR=$(mktemp -d)
    trap 'rm -rf "$WORKDIR"' EXIT
    just mtls-decrypt {{MTLS_DIR}}/ca.key.enc > "$WORKDIR/ca.key"
    cp traefik/config/mtls/ca.crt "$WORKDIR/ca.crt"

    # Per-client intermediate CA, signed by the root. Traefik lists these directly in
    # caFiles (never the root), so dropping one client's line revokes just that client
    printf 'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n' > "$WORKDIR/intermediate.ext"
    openssl genrsa -out "$WORKDIR/{{NAME}}-intermediate.key" 4096
    openssl req -new -key "$WORKDIR/{{NAME}}-intermediate.key" -out "$WORKDIR/{{NAME}}-intermediate.csr" \
        -subj "/CN={{NAME}} Intermediate CA"
    openssl x509 -req -in "$WORKDIR/{{NAME}}-intermediate.csr" -CA "$WORKDIR/ca.crt" -CAkey "$WORKDIR/ca.key" \
        -CAcreateserial -out "$WORKDIR/{{NAME}}-intermediate.crt" -days 1825 -sha256 \
        -extfile "$WORKDIR/intermediate.ext"

    # Leaf client cert, signed by this client's own intermediate (not the root)
    printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\n' > "$WORKDIR/leaf.ext"
    openssl genrsa -out "$WORKDIR/{{NAME}}.key" 2048
    openssl req -new -key "$WORKDIR/{{NAME}}.key" -out "$WORKDIR/{{NAME}}.csr" -subj "/CN={{NAME}}"
    openssl x509 -req -in "$WORKDIR/{{NAME}}.csr" -CA "$WORKDIR/{{NAME}}-intermediate.crt" -CAkey "$WORKDIR/{{NAME}}-intermediate.key" \
        -CAcreateserial -out "$WORKDIR/{{NAME}}.crt" -days 1825 -sha256 \
        -extfile "$WORKDIR/leaf.ext"

    PASS=$(openssl rand -base64 12)
    openssl pkcs12 -export -inkey "$WORKDIR/{{NAME}}.key" -in "$WORKDIR/{{NAME}}.crt" \
        -certfile "$WORKDIR/{{NAME}}-intermediate.crt" -out "$WORKDIR/{{NAME}}.p12" -passout "pass:$PASS"
    printf 'PASS=%s\n' "$PASS" > "$WORKDIR/{{NAME}}.env"

    mkdir -p {{MTLS_DIR}}/clients traefik/config/mtls/clients
    just mtls-encrypt "$WORKDIR/{{NAME}}.p12" > {{MTLS_DIR}}/clients/{{NAME}}.p12.enc
    just mtls-encrypt "$WORKDIR/{{NAME}}-intermediate.key" > {{MTLS_DIR}}/clients/{{NAME}}.intermediate.key.enc
    just encrypt "$WORKDIR/{{NAME}}.env" > {{MTLS_DIR}}/clients/{{NAME}}.pass.enc.env
    cp "$WORKDIR/{{NAME}}-intermediate.crt" traefik/config/mtls/clients/{{NAME}}.intermediate.crt

    just mtls-rebuild-tls-options

    echo "Commit and push:"
    echo "  {{MTLS_DIR}}/clients/{{NAME}}.p12.enc"
    echo "  {{MTLS_DIR}}/clients/{{NAME}}.intermediate.key.enc"
    echo "  {{MTLS_DIR}}/clients/{{NAME}}.pass.enc.env"
    echo "  traefik/config/mtls/clients/{{NAME}}.intermediate.crt"
    echo "  traefik/config/tls-options.yml"
    echo "Then run 'just mtls-client-export {{NAME}}' for a usable .p12 + password for the device,"
    echo "and 'just docker-up traefik' to apply the updated caFiles list."

# Revoke a previously issued client
[group('mtls')]
mtls-client-revoke NAME:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ ! -f traefik/config/mtls/clients/{{NAME}}.intermediate.crt ]]; then
        echo "No active client found for {{NAME}} (traefik/config/mtls/clients/{{NAME}}.intermediate.crt missing)." >&2
        exit 1
    fi
    STAMP=$(date -u +%Y%m%dT%H%M%SZ)
    mkdir -p "traefik/config/mtls/revoked/{{NAME}}-$STAMP" "{{MTLS_DIR}}/clients/revoked/{{NAME}}-$STAMP"

    mv "traefik/config/mtls/clients/{{NAME}}.intermediate.crt" "traefik/config/mtls/revoked/{{NAME}}-$STAMP/"

    for f in "{{MTLS_DIR}}/clients/{{NAME}}.p12.enc" "{{MTLS_DIR}}/clients/{{NAME}}.intermediate.key.enc" "{{MTLS_DIR}}/clients/{{NAME}}.pass.enc.env"; do
        if [[ -f "$f" ]]; then
            mv "$f" "{{MTLS_DIR}}/clients/revoked/{{NAME}}-$STAMP/"
        fi
    done

    just mtls-rebuild-tls-options

    echo "Revoked {{NAME}}. Archived to traefik/config/mtls/revoked/{{NAME}}-$STAMP/"
    echo "and {{MTLS_DIR}}/clients/revoked/{{NAME}}-$STAMP/."
    echo "Commit and push these changes, then run 'just docker-up traefik' to apply the updated caFiles list."

# Decrypt a client bundle to a local .p12 file, ready to transfer to the device.
[group('mtls')]
mtls-client-export NAME:
    #!/usr/bin/env bash
    set -euo pipefail
    OUT="{{NAME}}.p12"
    just mtls-decrypt {{MTLS_DIR}}/clients/{{NAME}}.p12.enc > "$OUT"
    PASS=$(sops decrypt --input-type dotenv --output-type dotenv {{MTLS_DIR}}/clients/{{NAME}}.pass.enc.env | grep '^PASS=' | cut -d= -f2-)
    echo "Decrypted to ./$OUT — transfer it to the device, then delete this local copy."
    echo "Import password: $PASS"

