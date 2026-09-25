#!/bin/sh
set -eu

# Focused black-box runtime proof for the pinned Granite host. It exercises the
# exact local payload, ModernBERT CLS pooling, L2 normalization, Unicode and
# cross-lingual retrieval; it does not require Python or a network connection.
if [ "$#" -ne 2 ]; then
    echo "usage: $0 HOST_EXECUTABLE MODEL_DIRECTORY" >&2
    exit 64
fi

host=$1
model=$2
port=48731
temporary=$(mktemp -d "${TMPDIR:-/tmp}/tractanda-granite-validate.XXXXXX")
process=
cleanup() {
    if [ -n "$process" ]; then
        kill "$process" 2>/dev/null || true
        wait "$process" 2>/dev/null || true
    fi
    rm -rf "$temporary"
}
trap cleanup EXIT HUP INT TERM

"$host" --describe >"$temporary/descriptor.json"
jq -e '
    .alias == "tractanda-granite-embedding-311m-multilingual-r2-vmlx-fp32-44399559"
    and .dimensions == 768 and .pooling == "cls" and .normalization == "l2"
    and .maximumInputTokens == 32768 and .maximumBatchTokens == 32768
    and (.assets | length) == 9
' "$temporary/descriptor.json" >/dev/null

"$host" --model "$model" --port "$port" >"$temporary/host.log" 2>&1 &
process=$!
for attempt in $(seq 1 90); do
    if curl --max-time 2 --fail --silent --show-error "http://127.0.0.1:$port/health" >"$temporary/health.json"; then
        if kill -0 "$process" 2>/dev/null && jq -e --argjson expected_pid "$process" '.pid == $expected_pid' "$temporary/health.json" >/dev/null; then
            break
        fi
    fi
    if [ "$attempt" -eq 90 ]; then
        cat "$temporary/host.log" >&2
        exit 1
    fi
    sleep 1
done

curl --max-time 180 --fail --silent --show-error -H 'content-type: application/json' \
    --data '{"model":"tractanda-granite-embedding-311m-multilingual-r2-vmlx-fp32-44399559","input":["What is the tallest mountain in Japan?","Wer hat das Lied Achy Breaky Heart geschrieben?","ドイツの首都はどこですか？","富士山は、静岡県と山梨県にまたがる活火山で、標高3776.12 mで日本最高峰の独立峰である。","Achy Breaky Heart is a country song written by Don Von Tress.","Berlin ist die Hauptstadt und ein Land der Bundesrepublik Deutschland.","  \t  ","देवनागरी में संयुक्ताक्षर और मात्रा: क्षि","বাংলা যুক্তাক্ষর ও স্বরচিহ্ন: শ্রদ্ধা","                                let durableStore = try await openStore()"]}' \
    "http://127.0.0.1:$port/v1/embeddings" >"$temporary/embeddings.json"

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
