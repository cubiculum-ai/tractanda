#!/usr/bin/env python3
"""Reject historical Docling recomposition without an actual compiler receipt.

Copying an admitted wrapper and replacing its converter cannot establish a new
execution-source binding. Use the receipt-bound current Kali preparation route.
"""
import argparse
from pathlib import Path
def prepare(arch,baseline,manifest,converter,descriptor,provenance,output,output_manifest):
    raise ValueError(
        "Historical Docling recomposition lacks an actual compiler input receipt; "
        "use build-linux-ml-component.py and prepare-kali-linux-component.py "
        "with a fresh bound compiler result. New Debian components require a "
        "reviewed receipt-bound preparation route for that baseline.")

def main():
    a=argparse.ArgumentParser(description=__doc__);a.add_argument('--arch',required=True,choices=('amd64','arm64'));a.add_argument('--baseline',required=True,type=Path);a.add_argument('--manifest',required=True,type=Path);a.add_argument('--converter',required=True,type=Path);a.add_argument('--descriptor',required=True,type=Path);a.add_argument('--provenance',required=True,type=Path);a.add_argument('--output',required=True,type=Path);a.add_argument('--output-manifest',required=True,type=Path);x=a.parse_args();prepare(x.arch,x.baseline,x.manifest,x.converter,x.descriptor,x.provenance,x.output,x.output_manifest)
if __name__=='__main__':main()
