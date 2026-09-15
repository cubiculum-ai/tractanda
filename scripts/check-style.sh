#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
set -- Sources Tests Package.swift Packages/TractandaClient/Sources Packages/TractandaClient/Tests \
    Packages/TractandaClient/Package.swift Packages/TractandaEmbeddings/Sources Packages/TractandaEmbeddings/Package.swift
# Local research checkouts are intentionally absent from a public source checkout.
for optional in experiments/category-learning experiments/declarative-client/Sources \
    experiments/declarative-client/Package.swift experiments/declarative-web/Sources \
    experiments/declarative-web/Package.swift experiments/declarative-web/Shims/SwiftOpenUIWeb/Package.swift; do
    if [ -e "$optional" ]; then set -- "$@" "$optional"; fi
done
swift format lint --strict --configuration .swift-format --recursive "$@"
