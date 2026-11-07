"""Finite descriptor source normalization; no registry or runtime admission."""
import hashlib,re
from pathlib import Path

if not __debug__:
    raise RuntimeError("Docling provenance validation must not run with Python optimization enabled.")
CLIENT='Packages/TractandaClient/Sources/TractandaClient/GeneratedLinuxDocumentConverterDigests.swift'
CONVERTER='Packages/TractandaDocuments/Sources/TractandaDocumentConverter/GeneratedLinuxDocumentClosure.swift'
REGISTRY='debian/linux-runtime-inputs.json'
PLACEHOLDERS={'amd64':'0'*64,'arm64':'1'*64,'kali-amd64':'2'*64,'kali-arm64':'3'*64}
EXCLUDED={REGISTRY:'Generated packaging output index binds resulting component manifests; not a converter compiler input.'}
SELECTION_PROFILE='tractanda.linux-docling-compiler-inputs.v3'
SOURCE_ROOTS=(
    'Packages/TractandaClient/Package.swift',
    'Packages/TractandaClient/Sources/TractandaClient',
    'Packages/TractandaDocuments/Package.swift',
    'Packages/TractandaDocuments/Package.resolved',
    'Packages/TractandaDocuments/Sources/DoclingRGB',
    'Packages/TractandaDocuments/Sources/DoclingRaster',
    'Packages/TractandaDocuments/Sources/TractandaDocumentConverter',
    'Packages/TractandaDocuments/Sources/CDoclingRaster',
    'Packages/TractandaDocuments/RuntimePatches',
    'Packages/TractandaDocuments/ThirdPartyNotices',
    'config/model-artifacts.json',
    'scripts/build-linux-ml-component.py',
    'scripts/produce-linux-payload.py',
    'scripts/package-linux.py',
    'scripts/package-macos.py',
    'scripts/validate-docling-model.py',
    'scripts/export-linux-ml-component.py',
    'scripts/build-docling-linux-native.py',
    'scripts/build-docling-native.py',
    'scripts/linux-docling-provenance.py',
    'scripts/generate-linux-docling-binding.py',
    'scripts/assemble-linux-docling-component.py',
    'scripts/prepare-kali-linux-component.py',
)


def normalize(relative,data):
    text=data.decode('utf-8'); assert text.encode()==data and relative in (CLIENT,CONVERTER)
    if relative==CLIENT:
        patterns={'amd64':r'(static let amd64: String\? = ")([0-9a-f]{64})(")','arm64':r'(static let arm64: String\? = ")([0-9a-f]{64})(")'}
    else:
        patterns={'amd64':r'(#if arch\(x86_64\)\s+static let sha256: String\? = ")([0-9a-f]{64})(")','arm64':r'(#elseif arch\(arm64\)\s+static let sha256: String\? = ")([0-9a-f]{64})(")'}
        assert len(re.findall(r'static let sha256: String\?',text))==3 and 'static let sha256: String? = nil' in text
    actual={}
    for arch,pattern in patterns.items():
        matches=list(re.finditer(pattern,text));assert len(matches)==1,(relative,arch,len(matches));actual[arch]=matches[0].group(2)
        text=re.sub(pattern,lambda m:m.group(1)+PLACEHOLDERS[arch]+m.group(3),text,count=1)
    for arch, name in [('kali-amd64','kaliAMD64'), ('kali-arm64','kaliARM64')]:
        pattern=rf'(static let {name}: String\? = )(nil|"[0-9a-f]{{64}}")(?=\n)'
        matches=list(re.finditer(pattern,text));assert len(matches)==1,(relative,arch,len(matches))
        value=matches[0].group(2)
        actual[arch]=None if value=='nil' else value[1:-1]
        text=re.sub(pattern,lambda m:m.group(1)+'"'+PLACEHOLDERS[arch]+'"',text,count=1)
    text_without_digest=text
    for digest in PLACEHOLDERS.values():
        assert text.count(digest)==1,(relative,digest)
        text_without_digest=text_without_digest.replace(digest,'')
    assert not re.search(r'(?<![0-9a-f])[0-9a-f]{64}(?![0-9a-f])',text_without_digest)
    return text.encode(),actual

def normalized_rows(P,C,source,expected_templates):
    for name in SOURCE_ROOTS:
        p=source/name;assert p.exists() and not p.is_symlink(),name
    rows=P.rows(source,roots=SOURCE_ROOTS,skip=P.SKIP);out=[];actual={};seen=set()
    for row in rows:
        name=row['path']
        if name in (CLIENT,CONVERTER):
            original=(source/name).read_bytes();data,digests=normalize(name,original);h=hashlib.sha256(data).hexdigest();assert h==expected_templates[name],(name,h)
            actual[name]={'sha256':row['sha256'],'digests':digests};row=dict(row);row['sha256']=h;row['size']=len(data);seen.add(name)
        out.append(row)
    assert seen=={CLIENT,CONVERTER},seen
    assert actual[CLIENT]['digests']==actual[CONVERTER]['digests']
    return out,actual
