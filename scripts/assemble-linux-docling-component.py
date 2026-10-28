#!/usr/bin/env python3
"""Assemble a descriptor-bound Docling component for review, without admission.

Inputs are a currently admitted component, an independently prepared descriptor
and provenance, and a newly compiled converter with the final source pins.
The result is an unadmitted component tree and normalized manifest; updating the
packaging registry and runtime/model tests remain separate explicit steps.
"""
import argparse, hashlib, importlib.util, json, shutil, stat
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
if not __debug__: raise RuntimeError('Docling component validation must not run with Python optimization enabled.')
def load(name, path):
    spec=importlib.util.spec_from_file_location(name,path);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
P=load('producer',ROOT/'scripts/produce-linux-payload.py');B=P.B;N=load('normalization',ROOT/'scripts/linux-docling-provenance.py');G=load('binding',ROOT/'scripts/generate-linux-docling-binding.py')
def digest(p):
    with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def prepare(arch,baseline,manifest,converter,descriptor,provenance,output,output_manifest):
    assert arch in ('amd64','arm64') and not output.exists() and not output_manifest.exists()
    assert converter.is_file() and not converter.is_symlink() and descriptor.is_file() and provenance.is_file()
    oldhash=P.require_admitted(arch)['documents'];old=P.component(manifest,baseline,'documents',arch,oldhash)
    desc=B.read_json(descriptor);prov=B.read_json(provenance);assert desc['architecture']==arch and desc['buildProvenanceSHA256']==digest(provenance)
    assert prov['sourceSelectionProfile']==N.SELECTION_PROFILE and prov['sourceSelectionRoots']==list(N.SOURCE_ROOTS)
    rows,generated=N.normalized_rows(P,G.C,ROOT,G.TEMPLATES);assert rows==prov['sourceFiles'],'Compiler source does not match descriptor provenance'
    assert prov['normalizationRecipeSHA256']==digest(ROOT/'scripts/linux-docling-provenance.py') and prov['descriptorRecipeSHA256']==digest(ROOT/'scripts/generate-linux-docling-binding.py') and prov['componentRecipeSHA256']==digest(ROOT/'scripts/build-linux-ml-component.py')
    assert prov['architecture']==arch and prov['toolchain']==old['toolchain'] and prov['buildFlags']==G.C.build_arguments('/usr/bin/swift',[],arch,'tractanda-document-converter')
    if arch=='amd64':slot='amd64'
    else:slot='arm64'
    actual=[]
    for rel in (N.CLIENT,N.CONVERTER):
        _,values=N.normalize(rel,(ROOT/rel).read_bytes());actual.append(values)
    assert actual[0]==actual[1] and actual[0][slot]==digest(descriptor),'Source pins must match the descriptor'
    with converter.open('rb') as stream:
        assert actual[0][slot].encode() in stream.read(),'Bound converter does not contain the selected descriptor identity'
    recorded=next(x for x in desc['privateDependencies'] if x['path']=='bin/tractanda-document-converter');elf=B.elf(converter,arch)
    assert elf['needed']==recorded['needed'] and elf['soname']==recorded['soname'] and elf['searchPaths']==recorded['runpath'],'Bound converter dynamic closure changed'
    allowed={x['soname']:set(x['requiredSymbolVersions']) for x in desc['osDependencies']};previous=G.required_versions(baseline/'bin/tractanda-document-converter')
    for soname,versions in G.required_versions(converter).items():assert versions<=allowed.get(soname,previous.get(soname,set())),soname
    output.mkdir(mode=0o700)
    replaced={'bin/tractanda-document-converter':converter,'lib/tractanda/document-native-closure.json':descriptor,'licenses/Docling/linux-build-provenance.json':provenance}
    for row in old['files']:
        name=B.safe_path(row['path']);target=output/name
        if name in replaced:
            p=replaced[name];entry={'path':name,'size':p.stat().st_size,'sha256':digest(p),'mode':0o755 if name.startswith('bin/') else 0o644};B.copy_verified(p,target,entry,8*1024**3)
        else:B.copy_verified(baseline/name,target,row,8*1024**3)
    wrapper=dict(old);wrapper['files']=P.rows(output,maximum=8*1024**3);wrapper['sourceInputsSHA256']=P.sha(B.canonical(prov));wrapper['recipe']={'path':'scripts/assemble-linux-docling-component.py','sha256':digest(Path(__file__).resolve())};document=dict(wrapper['documentExtraction']);identity=dict(document['identity']);identity['converter']=identity['converter'].rsplit('.',1)[0]+'.'+digest(descriptor);document['identity']=identity;wrapper['documentExtraction']=document
    output_manifest.write_text(json.dumps(wrapper,sort_keys=True,indent=2)+'\n');newhash=P.sha(B.canonical(wrapper));P.component(output_manifest,output,'documents',arch,newhash)
    result={'status':'COMPONENT_ASSEMBLED_NOT_RUNTIME_ADMITTED','architecture':arch,'manifestSHA256':newhash,'descriptorSHA256':digest(descriptor),'converterSHA256':digest(converter),'provenanceSHA256':digest(provenance),'generatedFileSHA256':{n:digest(ROOT/n) for n in (N.CLIENT,N.CONVERTER)}}
    print(json.dumps(result,indent=2));return result

def main():
    a=argparse.ArgumentParser();a.add_argument('--arch',required=True,choices=('amd64','arm64'));a.add_argument('--baseline',required=True,type=Path);a.add_argument('--manifest',required=True,type=Path);a.add_argument('--converter',required=True,type=Path);a.add_argument('--descriptor',required=True,type=Path);a.add_argument('--provenance',required=True,type=Path);a.add_argument('--output',required=True,type=Path);a.add_argument('--output-manifest',required=True,type=Path);x=a.parse_args();prepare(x.arch,x.baseline,x.manifest,x.converter,x.descriptor,x.provenance,x.output,x.output_manifest)
if __name__=='__main__':main()
