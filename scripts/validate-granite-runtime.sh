#!/bin/sh
set -eu

# Focused black-box runtime proof for the pinned Granite host. It exercises the
# exact local payload, ModernBERT CLS pooling, L2 normalization, Unicode and
# cross-lingual retrieval. Requires Python 3, lsof, curl and jq; all HTTP is loopback.
if [ "$#" -ne 2 ]; then
    echo "usage: $0 HOST_EXECUTABLE MODEL_DIRECTORY" >&2
    exit 64
fi

host=$1
model=$2
if ! command -v lsof >/dev/null 2>&1; then
    echo "lsof is required to discover the owned loopback listener." >&2
    exit 1
fi
temporary=$(mktemp -d "${TMPDIR:-/tmp}/tractanda-granite-validate.XXXXXX")
process=
request=
cleanup() {
    if [ -n "$request" ]; then
        kill "$request" 2>/dev/null || true
        wait "$request" 2>/dev/null || true
    fi
    if [ -n "$process" ]; then
        kill "$process" 2>/dev/null || true
        wait "$process" 2>/dev/null || true
    fi
    rm -rf "$temporary"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

"$host" --describe >"$temporary/descriptor.json"
jq -e '
    .alias == "tractanda-granite-embedding-311m-multilingual-r2-vmlx-fp32-44399559"
    and .dimensions == 768 and .pooling == "cls" and .normalization == "l2"
    and .maximumInputTokens == 32768 and .maximumBatchTokens == 32768
    and (.assets | length) == 9
' "$temporary/descriptor.json" >/dev/null

start_host() {
    # The helper CLI accepts only ports >=1024. Reserve an ephemeral candidate
    # briefly; subsequent child-only listener and PID checks handle any bind race.
    candidate=$(python3 - <<'PYPORT'
import socket
with socket.socket() as probe:
    probe.bind(('127.0.0.1', 0))
    port = probe.getsockname()[1]
    if not 1024 <= port <= 65535:
        raise SystemExit('Kernel selected an unsupported Granite port.')
    print(port)
PYPORT
)
    "$host" --model "$model" --port "$candidate" >"$temporary/host.log" 2>&1 &
    process=$!
}
start_host
while :; do
    if ! kill -0 "$process" 2>/dev/null; then
        cat "$temporary/host.log" >&2
        echo "Granite host exited before readiness." >&2
        exit 1
    fi
    # Only the child PID's IPv4 loopback LISTEN socket is eligible. lsof -F n
    # supplies one n127.0.0.1:PORT record; ignore headers and unrelated addresses.
    lsof -nP -a -p "$process" -iTCP@127.0.0.1 -sTCP:LISTEN -Fn >"$temporary/listeners" 2>/dev/null || true
    port=$(sed -n 's/^n127[.]0[.]0[.]1:\([0-9][0-9]*\)$/\1/p' "$temporary/listeners")
    case "$port" in
        '')
            # Restart only after this owned host reports a real address-in-use
            # wait and has no listener. No healthy startup/inference cutoff.
            if grep -F "Embedding listener waiting for 127.0.0.1:$candidate: address already in use;" "$temporary/host.log" >/dev/null; then
                echo "Owned Granite validation port raced; retiring that helper and selecting another candidate." >&2
                kill "$process" 2>/dev/null || true
                wait "$process" 2>/dev/null || true
                process=
                start_host
            fi
            sleep 1
            continue
            ;;
        *[!0-9]*) echo "Ambiguous owned Granite listener." >&2; exit 1 ;;
    esac
    if [ "$port" != "$candidate" ]; then
        echo "Owned Granite listener differs from its selected candidate." >&2
        exit 1
    fi
    if curl --max-time 2 --fail --silent "http://127.0.0.1:$port/health" >"$temporary/health.json"; then
        if ! jq -e --argjson expected_pid "$process" '.pid == $expected_pid' "$temporary/health.json" >/dev/null; then
            echo "Granite health PID differs from the owned host." >&2
            exit 1
        fi
        kill -0 "$process" 2>/dev/null || { echo "Granite host exited before validation." >&2; exit 1; }
        break
    fi
    sleep 1
done

curl --fail --silent --show-error -H 'content-type: application/json' \
    --data '{"model":"tractanda-granite-embedding-311m-multilingual-r2-vmlx-fp32-44399559","input":["What is the tallest mountain in Japan?","Wer hat das Lied Achy Breaky Heart geschrieben?","ドイツの首都はどこですか？","富士山は、静岡県と山梨県にまたがる活火山で、標高3776.12 mで日本最高峰の独立峰である。","Achy Breaky Heart is a country song written by Don Von Tress.","Berlin ist die Hauptstadt und ein Land der Bundesrepublik Deutschland.","  \t  ","देवनागरी में संयुक्ताक्षर और मात्रा: क्षि","বাংলা যুক্তাক্ষর ও স্বরচিহ্ন: শ্রদ্ধা","                                let durableStore = try await openStore()"]}' \
    "http://127.0.0.1:$port/v1/embeddings" >"$temporary/embeddings.json" &
request=$!
while kill -0 "$request" 2>/dev/null; do
    if ! kill -0 "$process" 2>/dev/null; then
        echo "Granite host exited during inference." >&2
        exit 1
    fi
    sleep 1
done
if wait "$request"; then
    request=
else
    request=
    echo "Granite inference request failed." >&2
    exit 1
fi

jq -e '
    def dot($a; $b): reduce range(0; $a | length) as $i (0; . + ($a[$i] * $b[$i]));
    .data as $d
    | (.model == "tractanda-granite-embedding-311m-multilingual-r2-vmlx-fp32-44399559")
    and (.model_revision | contains(":weights-bf16:compute-f32:"))
    and ($d | length == 10)
    and ($d | all(.embedding | length == 768 and all(.[]; isfinite)))
    and ($d | all(.embedding | ((map(. * .) | add | sqrt) > 0.999 and (map(. * .) | add | sqrt) < 1.001)))
    and (dot($d[0].embedding; $d[3].embedding) > dot($d[0].embedding; $d[4].embedding) and dot($d[0].embedding; $d[3].embedding) > dot($d[0].embedding; $d[5].embedding))
    and (dot($d[1].embedding; $d[4].embedding) > dot($d[1].embedding; $d[3].embedding) and dot($d[1].embedding; $d[4].embedding) > dot($d[1].embedding; $d[5].embedding))
    and (dot($d[2].embedding; $d[5].embedding) > dot($d[2].embedding; $d[3].embedding) and dot($d[2].embedding; $d[5].embedding) > dot($d[2].embedding; $d[4].embedding))
' "$temporary/embeddings.json" >/dev/null

jq '{model, model_revision, usage, dimensions: [.data[].embedding | length]}' "$temporary/embeddings.json"
