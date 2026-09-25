---
language:
  - ar
  - az
  - bg
  - bn
  - ca
  - cs
  - da
  - de
  - el
  - en
  - es
  - et
  - fa
  - fi
  - fr
  - he
  - hi
  - hr
  - hu
  - id
  - is
  - it
  - ja
  - ka
  - kk
  - km
  - ko
  - lt
  - lv
  - mr
  - ms
  - nl
  - "no"
  - pl
  - pt
  - ro
  - ru
  - sk
  - sl
  - sq
  - sr
  - sv
  - sw
  - te
  - th
  - tl
  - tr
  - uk
  - ur
  - uz
  - vi
  - zh
library_name: sentence-transformers
license: apache-2.0
pipeline_tag: feature-extraction
tags:
  - granite
  - embeddings
  - transformers
  - multilingual
  - mteb
  - feature-extraction
  - sentence-similarity
  - matryoshka
  - onnx
  - openvino
---

# Granite-Embedding-311M-Multilingual-R2

**Model Summary:** Granite-Embedding-311M-Multilingual-R2 is a 311M parameter dense embedding model from the Granite Embeddings collection for high-quality multilingual text embeddings. It produces 768-dimensional vectors with a context length of up to 32,768 tokens. The model supports **200+ languages** (based on the multilingual pretraining corpus of the underlying encoder), with enhanced support for 52 languages and programming code that receive explicit retrieval-pair and cross-lingual training. All training data uses permissive, enterprise-friendly licenses, plus IBM-collected and IBM-generated datasets.

> Granite Embedding 311M Multilingual R2 shows strong performance across multilingual information retrieval benchmarks, code retrieval, long-document search, conversational multi-turn, and reasoning retrieval tasks. The multilingual R2 model scores **65.2** on [Multilingual MTEB Retrieval (18 tasks)](https://huggingface.co/spaces/mteb/leaderboard) — a **+13 point improvement** over granite-embedding-278m-multilingual (52.2) — and averages **56.3** across all retrieval benchmarks, representing a **+14.5 point gain** over the previous generation. It supports Matryoshka dimension reduction, 32k-token context, and ships with ONNX and OpenVINO models for production deployment.

### What's New in R2

- **Architecture upgrade:** ModernBERT replaces XLM-RoBERTa, bringing alternating attention, GeGLU activations, and rotary position embeddings.
- **Extended context:** 32,768 tokens (up from 512 in R1), enabling long-document and multi-passage retrieval.
- **Expanded vocabulary:** 262K multilingual tokenizer trained on text and code across 200+ languages.
- **Matryoshka support:** Truncate embeddings to 512, 384, 256, or 128 dimensions with graceful degradation.
- **Broader code coverage:** Code retrieval supported for Python, Go, Java, JavaScript, PHP, Ruby, SQL, C, C++.
- **Training advances:** Knowledge distillation from multiple teachers, contrastive fine-tuning, and model merging yield +14.5 points on average retrieval benchmarks.
- **Deployment flexibility:** Released with ONNX and OpenVINO models; compatible with vLLM and llama.cpp (GGUF).

The model uses a bi-encoder architecture to generate high-quality embeddings from text inputs such as queries, passages, code, and documents, enabling seamless comparison through cosine similarity. Built using contrastive fine-tuning, knowledge distillation, and model merging, the Granite Embedding 311M Multilingual R2 model is optimized to ensure strong alignment between query and passage embeddings across many languages.

The Granite Embedding Multilingual R2 release consists of two multilingual embedding models, both based on the ModernBERT architecture:

- **_granite-embedding-311m-multilingual-r2_** (**311M** parameters): with an output embedding size of _768_, replacing _granite-embedding-278m-multilingual_.
- _granite-embedding-97m-multilingual-r2_ (**97M** parameters): A reduced-size multilingual model with a smaller output embedding size (_384_) for latency-sensitive deployments. See [granite-embedding-97m-multilingual-r2](https://huggingface.co/ibm-granite/granite-embedding-97m-multilingual-r2).

## Model Details

- **Developed by:** Granite Embedding Team, IBM
- **Repository:** [ibm-granite/granite-embedding-models](https://github.com/ibm-granite/granite-embedding-models)
- **Project Page:** [IBM Granite](https://www.ibm.com/granite)
- **Paper:** [Granite Embedding Multilingual R2 Models](https://huggingface.co/papers/2605.13521)
- **Language(s) (NLP):** 200+ languages supported, with enhanced support for 52 languages and programming code (see [full language list](#supported-languages))
- **Release Date**: April 29, 2026
- **License:** [Apache 2.0](https://www.apache.org/licenses/LICENSE-2.0)

### Supported Languages

The underlying encoder was pretrained on text from **200+ languages**, and we report general-purpose embeddings for any of them. In addition, we provide **enhanced support for 52 languages and programming code** that receive explicit retrieval-pair and cross-lingual training data, producing higher-quality embeddings on retrieval tasks.

<details>
<summary>Click to expand the list of 52 enhanced-support languages</summary>

Albanian (sq), Arabic (ar), Azerbaijani (az), Bengali (bn), Bulgarian (bg), Catalan (ca), Chinese (zh), Croatian (hr), Czech (cs), Danish (da), Dutch (nl), English (en), Estonian (et), Finnish (fi), French (fr), Georgian (ka), German (de), Greek (el), Hebrew (he), Hindi (hi), Hungarian (hu), Icelandic (is), Indonesian (id), Italian (it), Japanese (ja), Kazakh (kk), Khmer (km), Korean (ko), Latvian (lv), Lithuanian (lt), Malay (ms), Marathi (mr), Norwegian (no), Persian (fa), Polish (pl), Portuguese (pt), Romanian (ro), Russian (ru), Serbian (sr), Slovak (sk), Slovenian (sl), Spanish (es), Swahili (sw), Swedish (sv), Tagalog (tl), Telugu (te), Thai (th), Turkish (tr), Ukrainian (uk), Urdu (ur), Uzbek (uz), Vietnamese (vi).

Additionally, the models are trained on **programming code** (Python, Go, Java, JavaScript, PHP, Ruby, SQL, C, C++) and support cross-lingual code retrieval.

</details>

### When to Use This Model

- **Use granite-embedding-311m-multilingual-r2** when accuracy is the priority across multilingual retrieval, search, and similarity tasks, and you can afford the throughput of a 311M-parameter model.
- **Use [granite-embedding-97m-multilingual-r2](https://huggingface.co/ibm-granite/granite-embedding-97m-multilingual-r2)** for latency-sensitive production workloads, edge deployment, or when you need maximum encoding throughput with competitive multilingual quality.
- **Use [granite-embedding-english-r2](https://huggingface.co/ibm-granite/granite-embedding-english-r2) or [granite-embedding-small-english-r2](https://huggingface.co/ibm-granite/granite-embedding-small-english-r2)** when your data is predominantly English, as these English-specific models offer optimized performance for monolingual English use cases.

## Usage

**Intended Use:** The model is designed to produce fixed-length vector representations for a given text, which can be used for text similarity, retrieval, and search applications across multiple languages.

For efficient inference, these models support Flash Attention 2. Installing it is optional but can lead to faster encoding:

```shell
pip install flash_attn
```

**Usage with Sentence Transformers:**

The model is compatible with the SentenceTransformer library and is very easy to use:

First, install the sentence transformers library

```shell
pip install sentence_transformers
```

The model can then be used to encode pairs of text and find the similarity between their representations

```python
from sentence_transformers import SentenceTransformer, util

model_path = "ibm-granite/granite-embedding-311m-multilingual-r2"
# Load the Sentence Transformer model
model = SentenceTransformer(model_path)

input_queries = [
    'What is the tallest mountain in Japan?',          # English query
    'Wer hat das Lied Achy Breaky Heart geschrieben?', # German query
    'ドイツの首都はどこですか？',                            # Japanese query
    ]

input_passages = [
    "富士山は、静岡県と山梨県にまたがる活火山で、標高3776.12 mで日本最高峰の独立峰である。",  # Japanese passage
    "Achy Breaky Heart is a country song written by Don Von Tress. Originally titled Don't Tell My Heart and performed by The Marcy Brothers in 1991.",  # English passage
    "Berlin ist die Hauptstadt und ein Land der Bundesrepublik Deutschland. Die Stadt ist mit rund 3,7 Millionen Einwohnern die bevölkerungsreichste Kommune Deutschlands.",  # German passage
    ]

# Cross-lingual retrieval: each query should score highest with its matching passage in a different language
query_embeddings = model.encode(input_queries)
passage_embeddings = model.encode(input_passages)

# calculate cosine similarity — expect high scores on the diagonal (EN→JA, DE→EN, JA→DE)
print(util.cos_sim(query_embeddings, passage_embeddings))
# output: tensor([[0.9393, 0.6899, 0.7627],
#                 [0.6780, 0.9598, 0.7062],
#                 [0.7818, 0.7342, 0.9172]])
```

**Matryoshka Representation Learning:**

This model supports [Matryoshka Representation Learning (MRL)](https://arxiv.org/abs/2205.13147), which allows you to truncate embeddings to smaller dimensions (e.g., 512, 384, 256, 128) with graceful performance degradation. This is useful for reducing storage and memory requirements.

```python
from sentence_transformers import SentenceTransformer

model = SentenceTransformer("ibm-granite/granite-embedding-311m-multilingual-r2")

# Full 768-dimensional embeddings
full_embeddings = model.encode(["example text"])
print(full_embeddings.shape)  # (1, 768)

# Truncated to 256 dimensions — still effective for many retrieval tasks
truncated_embeddings = model.encode(["example text"], truncate_dim=256)
print(truncated_embeddings.shape)  # (1, 256)
```

**Usage with Hugging Face Transformers:**

This is a simple example of how to use the granite-embedding-311m-multilingual-r2 model with the Transformers library and PyTorch. For a complete retrieval workflow including passage encoding and cosine similarity, see the Sentence Transformers example above.

First, install the required libraries

```shell
pip install transformers torch
```

The model can then be used to encode text

```python
import torch
from transformers import AutoModel, AutoTokenizer

model_path = "ibm-granite/granite-embedding-311m-multilingual-r2"

# Load the model and tokenizer
model = AutoModel.from_pretrained(model_path)
tokenizer = AutoTokenizer.from_pretrained(model_path)
model.eval()

input_queries = [
    'What is the tallest mountain in Japan?',          # English query
    'Wer hat das Lied Achy Breaky Heart geschrieben?', # German query
    'ドイツの首都はどこですか？',                            # Japanese query
    ]

# tokenize inputs
tokenized_queries = tokenizer(input_queries, padding=True, truncation=True, return_tensors='pt')

# encode queries
with torch.no_grad():
    model_output = model(**tokenized_queries)
    # Perform pooling. granite-embedding-311m-multilingual-r2 uses CLS Pooling
    query_embeddings = model_output[0][:, 0]

# normalize the embeddings
query_embeddings = torch.nn.functional.normalize(query_embeddings, dim=1)
```

### Optimized Inference and Deployment

**ONNX and OpenVINO:**

Pre-converted ONNX and OpenVINO models are released alongside the PyTorch weights for production deployment. These can be loaded directly via the `backend` parameter in Sentence Transformers:

```python
from sentence_transformers import SentenceTransformer

# ONNX backend
model = SentenceTransformer("ibm-granite/granite-embedding-311m-multilingual-r2", backend="onnx")
embeddings = model.encode(["example text"])

# OpenVINO backend
model = SentenceTransformer("ibm-granite/granite-embedding-311m-multilingual-r2", backend="openvino")
embeddings = model.encode(["example text"])

# OpenVINO INT8 quantized backend (smaller & faster on CPU)
model = SentenceTransformer(
    "ibm-granite/granite-embedding-311m-multilingual-r2",
    backend="openvino",
    model_kwargs={"file_name": "openvino/openvino_model_qint8_quantized.xml"},
)
embeddings = model.encode(["example text"])
```

The ONNX model is compatible with any ONNX Runtime backend (CPU, CUDA, TensorRT, DirectML). The OpenVINO model is optimized for Intel hardware including CPUs and integrated GPUs.

**vLLM:**

The model can be served as an embedding endpoint using [vLLM](https://docs.vllm.ai/):

```shell
vllm serve ibm-granite/granite-embedding-311m-multilingual-r2 --task embed
```

**llama.cpp (GGUF):**

The model can be converted to GGUF format for use with [llama.cpp](https://github.com/ggerganov/llama.cpp):

```shell
# Convert to GGUF
python convert_hf_to_gguf.py ibm-granite/granite-embedding-311m-multilingual-r2 \
    --outfile granite-embedding-311m-multilingual-r2.gguf

# Generate embeddings
llama-embedding -m granite-embedding-311m-multilingual-r2.gguf -p "example text"
```

Note: Ollama does not currently support ModernBERT-based models.

## Evaluation Results

Granite-Embedding-311M-Multilingual-R2 is in the top three in the under-500M multilingual class on average across retrieval, code search,
long-document, and reasoning benchmarks, with a **+14.5 point** average gain over the previous-generation
Granite-Embedding-278M-Multilingual.

### Multilingual Retrieval Performance

Performance on Multilingual MTEB Retrieval, MTEB English Retrieval, MTEB Code Retrieval, long-document search (LongEmbed), and Reasoning as Retrieval (RaR-b) benchmarks. Scores are averages across tasks; higher is better. Throughput (documents per second) is measured on a single NVIDIA H100 GPU with batches of 1024 sequences at 512 tokens.

Granite-Embedding-311M-Multilingual-R2 scores 65.2 on MTEB Multilingual Retrieval — a **+13 point improvement** over its R1 predecessor — while encoding nearly 2,000 documents per second at comparable speed.

| Model                                      | Parameters (M) | Embedding Size | MTEB ML Retrieval (18) | MTEB Retrieval (eng, v2) (10) | MTEB (Code, v1) (12) | LongEmbed (6) | RaR-b (17) | **AVG**  | Throughput (docs/s) |
| ------------------------------------------ | -------------- | -------------- | ---------------------- | ----------------------------- | -------------------- | ------------- | ---------- | -------- | ------------------: |
| granite-embedding-107m-multilingual        | 107            | 384            | 48.1                   | 47.9                          | 40.7                 | 34.3          | 17.1       | 37.6     |               3,113 |
| granite-embedding-278m-multilingual        | 278            | 768            | 52.2                   | 51.5                          | 48.5                 | 37.7          | 18.9       | 41.8     |               2,164 |
| granite-embedding-97m-multilingual-r2      | 97             | 384            | 60.3                   | 50.1                          | 60.4                 | 65.5          | 24.9       | 52.2     |               2,534 |
| **granite-embedding-311m-multilingual-r2** | **311**        | **768**        | **65.2**               | **52.6**                      | **63.8**             | **71.7**      | **28.0**   | **56.3** |           **1,828** |

### Matryoshka Embeddings Performance

This model supports Matryoshka Embeddings, which allow for reduced embedding dimensions without a reduction in performance:

| Model                                  | Embedding Size | MTEB (eng, v2) | MTEB (Code, v1) | ML MTEB Retrieval |
| -------------------------------------- | -------------- | -------------- | --------------- | ----------------- |
| granite-embedding-311m-multilingual-r2 | 768            | 52.6           | 63.9            | 63.9              |
|                                        | 512            | 52.5           | 63.8            | 63.9              |
|                                        | 384            | 52.1           | 63.7            | 63.8              |
|                                        | 256            | 51.6           | 63.4            | 63.5              |
|                                        | 128            | 50.4           | 62.3            | 62.5              |

## Model Architecture and Key Features

The `granite-embedding-311m-multilingual-r2` model is based on the ModernBERT architecture with expanded multilingual vocabulary:

| Feature                   | granite-embedding-311m-multilingual-r2 |
| :------------------------ | :------------------------------------: |
| Embedding size            |                  768                   |
| Number of layers          |                   22                   |
| Number of attention heads |                   12                   |
| Intermediate size         |                  1152                  |
| Activation Function       |                 GeGLU                  |
| Vocabulary Size           |                262,152                 |
| Max. Sequence Length      |                 32,768                 |
| Matryoshka Dimensions     |        768, 512, 384, 256, 128         |
| # Parameters              |                 ~311M                  |

## Training and Optimization

The Granite Embedding Multilingual R2 model incorporates key enhancements from the ModernBERT architecture, including:

- Alternating attention lengths to accelerate processing
- Rotary position embeddings for extended sequence length
- A multilingual tokenizer with 262K vocabulary, derived from the [Gemma 3](https://ai.google.dev/gemma/terms) tokenizer and further trained on code and text data across 200+ languages (see [Tokenizer Attribution](#tokenizer-attribution) below)
- Flash Attention 2.0 for improved efficiency
- Streamlined parameters, eliminating unnecessary bias terms
- Matryoshka Representation Learning for flexible embedding dimensionality

The model was trained using knowledge distillation with multiple teacher models, contrastive fine-tuning, and Matryoshka Representation Learning.

## Data Collection

All training data is sourced under permissive, commercial-friendly licenses, making Granite Embedding R2 suitable for unrestricted
enterprise deployment.

Training data comes from four key sources:

1. Unsupervised title-body paired data scraped from the web
2. Publicly available paired data with permissive, enterprise-friendly licenses
3. IBM-internal paired data targeting specific technical domains
4. IBM-generated multilingual synthetic data including long-document pairs

For governance, all our data undergoes a data clearance process subject to technical, business, and governance review. This comprehensive process captures critical information about the data, including but not limited to their content description, ownership, intended use, data classification, licensing information, usage restrictions, how the data will be acquired, as well as an assessment of sensitive information (e.g., personal information).

## Tokenizer Attribution

The multilingual tokenizer used by this model is derived from the **Gemma 3** tokenizer by Google. The original Gemma 3 tokenizer vocabulary was used as a starting point and further trained on multilingual text and code data to produce the 262K-token vocabulary used in this model. Use of the Gemma tokenizer is subject to the [Gemma Terms of Use](https://ai.google.dev/gemma/terms). The Gemma model family and associated resources are described at [ai.google.dev/gemma](https://ai.google.dev/gemma).

## Infrastructure

We trained the Granite Embedding Multilingual R2 model using IBM's computing cluster, BlueVela Cluster, which is outfitted with NVIDIA H100 80GB GPUs. This cluster provides a scalable and efficient infrastructure for training our models over multiple GPUs.

## Ethical Considerations and Limitations

Granite Embedding 311M Multilingual R2 leverages both permissively licensed open-source and select proprietary data for enhanced performance. The training data for the base language model was filtered to remove text containing hate, abuse, and profanity, though the effectiveness of such filtering may vary across language families.

Performance varies across languages: higher-resource languages and those in the 52-language enhanced-support set generally achieve better results, while low-resource languages rely on cross-lingual transfer from the pretraining stage and may exhibit lower retrieval quality. Synthetic training data, while effective for improving multilingual coverage, may introduce distributional biases not present in naturally occurring text. Longer texts will be truncated to the 32,768-token context limit.

## Resources

- Learn about the latest updates with Granite: https://www.ibm.com/granite
- Get started with tutorials, best practices, and prompt engineering advice: https://www.ibm.com/granite/docs/
- Learn about the latest Granite learning resources: https://ibm.biz/granite-learning-resources

## Citation

```
@misc{awasthy2026graniteembeddingmultilingualr2,
      title={Granite Embedding Multilingual R2 Models}, 
      author={Parul Awasthy and Aashka Trivedi and Yushu Yang and Ken Barker and Yulong Li and Bhavani Iyer and Martin Franz and Juergen Bross and Meet Doshi and Vignesh P and Vishwajeet Kumar and Todd Ward and Abraham Daniels and Madison Lee and Luis Lastras and Jaydeep Sen and Radu Florian},
      year={2026},
      eprint={2605.13521},
      archivePrefix={arXiv},
      primaryClass={cs.IR},
      url={https://arxiv.org/abs/2605.13521}, 
}
```
