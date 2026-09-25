#!/bin/sh
set -eu

# Fetch precisely the local files used by Tractanda's Granite embedding host.
# The Hub revision and SHA-256 table make this safe to rerun without trusting
# a mutable model tag or leaving partially downloaded files at the destination.
if [ "$#" -ne 1 ]; then
    echo "usage: $0 DESTINATION" >&2
    exit 64
fi

destination=$1
if [ -e "$destination" ]; then
    echo "destination already exists: $destination" >&2
    exit 73
fi
repository=ibm-granite/granite-embedding-311m-multilingual-r2
revision=44399559930365213510b1ee2eb15ded83374f0e
temporary=$(mktemp -d "${TMPDIR:-/tmp}/tractanda-granite.XXXXXX")
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        echo "SHA-256 utility is required." >&2
        exit 69
    fi
}

fetch() {
    path=$1
    expected=$2
    mkdir -p "$temporary/$(dirname "$path")"
    curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --silent --show-error \
        "https://huggingface.co/$repository/resolve/$revision/$path?download=true" \
        -o "$temporary/$path"
    actual=$(sha256 "$temporary/$path")
    if [ "$actual" != "$expected" ]; then
        echo "SHA-256 mismatch for $path" >&2
        exit 65
    fi
}

fetch '1_Pooling/config.json' '781299da695e58439d70d491840da22ea0935d1d57d9646eb9725f1f19754e89'
fetch 'config.json' 'e1e3fc842a8e0537e25d6e4c93879698b92ae96722e8c162bef334b57978a3b0'
fetch 'config_sentence_transformers.json' 'f09adf93fcf868bb2fc3976a435d810b2ecdffa953d1da091d2a91168abab44b'
fetch 'model.safetensors' 'dcb6431bfa6e817fe100a2b0521360cec3383963b03fa966b685de18ca310d31'
fetch 'modules.json' '84e40c8e006c9b1d6c122e02cba9b02458120b5fb0c87b746c41e0207cf642cf'
fetch 'sentence_bert_config.json' '967ef958285e4a7a37d8ff1832473d967edd913b4e48572f31c3d3ea361d5327'
fetch 'special_tokens_map.json' 'cb9e60dcf4d8d314315cb3e761fe4c2e664fda8dbf66d7815372b2639e381182'
fetch 'tokenizer.json' '0087c868b33bad550a78a08d19798cfd7f713cde4f020803b8f51f405503e15f'
fetch 'tokenizer_config.json' '7947bdf0378520e69ca412b8c4dacd1cffa8aef099f851fdd5c65aa27c6b36a0'

mkdir -p "$(dirname "$destination")"
mv "$temporary" "$destination"
trap - EXIT HUP INT TERM
printf 'verified Granite runtime assets at %s\n' "$destination"
