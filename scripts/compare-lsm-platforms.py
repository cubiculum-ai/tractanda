#!/usr/bin/env python3
"""Compare identical portable LSM requests on macOS and Linux, including abstentions."""
import argparse
import json
from pathlib import Path


def compare(mac, linux):
    results = {f"{r['task']}-{r['budget']}-{r['seed']}-{r['backend']}.json": r
               for r in json.loads((mac / 'results.json').read_text())}
    other = {f"{r['task']}-{r['budget']}-{r['seed']}-{r['backend']}.json": r
             for r in json.loads((linux / 'results.json').read_text())}
    assert results.keys() == other.keys()
    summary = dict(runs=len(results), predictions=0, available=0,
                   maximumScoreDifference=0.0, availabilityDifferences=0,
                   fixedThresholdDecisionDifferences=0, thresholdBoundaryDifferences=0,
                   confusionMatrixDifferences=0)
    for name, run in results.items():
        assert run['requestSHA256'] == other[name]['requestSHA256']
        a = json.loads((mac / 'predictions' / name).read_text())['predictions']
        b = json.loads((linux / 'predictions' / name).read_text())['predictions']
        assert len(a) == len(b)
        for x, y in zip(a, b):
            assert (x['id'], x['split'], x['positive']) == (y['id'], y['split'], y['positive'])
            summary['predictions'] += 1
            xs, ys = x.get('score'), y.get('score')
            if (xs is None) != (ys is None):
                summary['availabilityDifferences'] += 1
            if xs is not None and ys is not None:
                summary['available'] += 1
                summary['maximumScoreDifference'] = max(summary['maximumScoreDifference'], abs(xs - ys))
                threshold = run['validationThreshold']
                if threshold is not None and (xs >= threshold) != (ys >= threshold):
                    summary['fixedThresholdDecisionDifferences'] += 1
                    if min(abs(xs-threshold), abs(ys-threshold)) <= 1e-10:
                        summary['thresholdBoundaryDifferences'] += 1
        for split in ['validation', 'test']:
            if any(run[split][k] != other[name][split][k] for k in ['tp', 'fp', 'tn', 'fn', 'unavailable']):
                summary['confusionMatrixDifferences'] += 1
    assert summary['availabilityDifferences'] == 0, summary
    assert summary['maximumScoreDifference'] < 1e-9, summary
    assert summary['fixedThresholdDecisionDifferences'] == summary['thresholdBoundaryDifferences'], summary
    return summary


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mac', type=Path)
    parser.add_argument('linux', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    summary = compare(args.mac, args.linux)
    args.output.write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2))
