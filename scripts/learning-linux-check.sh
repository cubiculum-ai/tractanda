#!/bin/sh
set -eu
export CLANG_MODULE_CACHE_PATH=/build/module-cache
swift --version > /results/swift-version.txt
swift test --filter LSMTests --scratch-path /build --cache-path /build/cache --config-path /build/config --security-path /build/security --disable-sandbox
swiftc -swift-version 6 -O Sources/TractandaLearning/*.swift experiments/category-learning/AppleBinaryLSM.swift \
  experiments/category-learning/NaiveBayes.swift experiments/category-learning/main.swift -o /results/learner
python3 experiments/category-learning/run.py --binary /results/learner --out /results/documents --backends portable-lsm --dimension 32
python3 experiments/category-learning/run.py --binary /results/learner --out /results/label-totals --backends portable-label-totals --dimension 32

python3 experiments/category-learning/run.py --binary /results/learner --out /results/balanced-labels --backends portable-balanced-labels --dimension 32
