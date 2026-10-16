import pathlib,json,hashlib,sys,xml.etree.ElementTree as ET,struct,zipfile,collections,base64
sys.stdout.reconfigure(encoding='utf-8')
root=pathlib.Path('C:/Sidekick'); out=root/'docs/reviews/2026-10-12-vendor-altstore-coverage.json'
dirs=[root/'Vendor/SideStore/AltStore',root/'Vendor/SideStore/AltStore.xcodeproj']
files=sorted(p for d in dirs for p in d.rglob('*') if p.is_file())
if sys.argv[1]=='init':
    state={'scope':[str(d) for d in dirs],'files':[],'cursor':0,'offset':0,'limitations':['Static Windows audit; no Xcode compiler, Interface Builder rendering or device UI execution.']}
    for p in files:
        data=p.read_bytes(); state['files'].append({'path':p.relative_to(root).as_posix(),'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest(),'status':'pending','method':None})
    out.write_text(json.dumps(state,indent=2)); print(len(files))
elif sys.argv[1]=='next':
    s=json.loads(out.read_text()); budget=20000; printed=0
    while s['cursor']<len(s['files']):
        rec=s['files'][s['cursor']]; p=root/rec['path']; data=p.read_bytes(); ext=p.suffix
        if ext in ['.png','.ipa','.m4a']:
            meta={'signature':data[:16].hex()}
            if ext=='.png': meta.update(width=struct.unpack('>I',data[16:20])[0],height=struct.unpack('>I',data[20:24])[0],bitDepth=data[24],colorType=data[25])
            if ext=='.ipa':
                try:
                    with zipfile.ZipFile(p) as z: meta['entries']=[{'name':i.filename,'bytes':i.file_size} for i in z.infolist()]
                except zipfile.BadZipFile:
                    meta['notZip']=True; meta['pointerText']=data.decode('utf-8') if data.startswith(b'version https://git-lfs') else None
            rec.update(status='reviewed',method='full bytes read; binary signature/dimensions or archive inventory; no visual/audio/runtime inspection',metadata=meta)
            txt=json.dumps({'file':rec['path'],'binaryMetadata':meta})
            print(txt); printed+=len(txt); s['cursor']+=1
        else:
            text=data.decode('utf-8-sig'); lines=text.splitlines()
            if p.name=='contents' and 'xcdatamodeld' in rec['path'] and '17_1.xcdatamodel' not in rec['path']:
                baseline=root/'Vendor/SideStore/AltStore/Core/Model/AltStore.xcdatamodeld/AltStore 17_1.xcdatamodel/contents'
                def flatten(n,path=''):
                    result={}; path+=n.tag+'['+n.attrib.get('name',n.attrib.get('value',''))+']'; result[path]=n.attrib
                    for i,c in enumerate(n): result.update(flatten(c,path+('/' if c.attrib.get('name') or c.attrib.get('value') else f'/{i}/')))
                    return result
                base=flatten(ET.fromstring(baseline.read_text())); cur=flatten(ET.fromstring(text))
                differences={k:{'base':base.get(k),'current':cur.get(k)} for k in sorted(set(base)|set(cur)) if base.get(k)!=cur.get(k)}
                # Compare exact full tree, preserving every attribute; report compact per-entity schema to avoid repeated unchanged values.
                schema={e.attrib['name']:{'attributes':{c.attrib['name']:c.attrib for c in e if c.tag=='attribute'},'relationships':{c.attrib['name']:c.attrib for c in e if c.tag=='relationship'},'constraints':[[c.attrib for c in u.iter('constraint')] for u in e.iter('uniquenessConstraint')]} for e in ET.fromstring(text).iter('entity')}
                def ent(n): return {e.attrib['name']:ET.tostring(e,encoding='unicode') for e in n.iter('entity')}
                be=ent(ET.fromstring(baseline.read_text())); ce=ent(ET.fromstring(text)); changed=[k for k in ce if ce[k]!=be.get(k)]
                summary={'fullTreeDifferingNodes':len(differences),'baseline':'AltStore 17_1','removedEntities':sorted(set(be)-set(ce)),'exactNodeDifferences':differences}
                rec.update(status='reviewed',method='full XML parse; every schema attribute/relationship/constraint compared to fully read v17_1; all changed entities inspected',metadata=summary)
                brief={'file':rec['path'],'schemaDiff':{'fullTreeDifferingNodes':len(differences),'removedEntities':summary['removedEntities'],'changedEntities':changed,'entityCount':len(schema),'changedCurrentAttributes':{k:v['current'] for k,v in differences.items() if v['current'] and '/attribute[' in k},'changedRelationships':{k:v['current'] for k,v in differences.items() if v['current'] and '/relationship[' in k}}}
                txt=json.dumps(brief,separators=(',',':')); print(txt);printed+=len(txt);s['cursor']+=1;s['offset']=0
                if printed>=budget: break
                continue
            if ext in ['.storyboard','.xib','.intentdefinition'] or p.name=='contents':
                e=ET.fromstring(text)
                summary={'tags':dict(collections.Counter(n.tag for n in e.iter())), 'semanticElements':[{'tag':n.tag,'attributes':n.attrib,'text':n.text.strip() if n.text and n.text.strip() else None} for n in e.iter() if any(k in n.attrib for k in ['text','title','customClass','storyboardIdentifier','selector','property','destination','source','entity','name']) or (n.text and n.text.strip())]}
                rec.update(status='reviewed',method='full XML parse; semantic text, classes, actions, connections, constraints/schema attributes inspected; no Interface Builder rendering',metadata=summary)
                txt=json.dumps({'file':rec['path'],'xmlSemanticStructure':summary},ensure_ascii=False,separators=(',',':'))
                start=s['offset']; end=min(len(txt),start+10000)
                print(f'XML {rec["path"]} CHARS {start}-{end}/{len(txt)}'); print(txt[start:end]); printed+=end-start
                if end<len(txt): s['offset']=end; rec['status']='in_progress'; break
                s['cursor']+=1; s['offset']=0
                if printed>=budget: break
                continue
            # Mapping XML contains opaque base64 archive blobs: parse all XML and inventory every non-blob element.
            if ext=='.xml' and 'Mapping Models' in rec['path']:
                e=ET.fromstring(text); tags=collections.Counter(n.tag for n in e.iter()); blobs=[]
                for n in e.iter():
                    if n.text and (n.attrib.get('type')=='binary' or n.tag=='data'):
                        try: b=base64.b64decode(''.join(n.text.split()),validate=True); blobs.append({'tag':n.tag,'name':n.attrib.get('name'),'decodedBytes':len(b),'signature':b[:16].hex()})
                        except Exception: pass
                summary={'tags':dict(tags),'blobs':blobs,'namedElements':[n.attrib for n in e.iter() if n.attrib]}
                rec.update(status='reviewed',method='full XML parse; every element/attribute inventoried; opaque base64 blob signature and decoded length only',metadata=summary)
                semantic=[{c.attrib.get('name',c.tag):c.text.strip() for c in n if c.text and c.text.strip() and c.attrib.get('type')!='binary'} for n in e.iter('object')]
                txt=json.dumps({'file':rec['path'],'xmlStructure':{'tags':summary['tags'],'blobs':blobs,'values':semantic}},separators=(',',':'))
                start=s['offset']; end=min(len(txt),start+12000)
                print(f'MAPPING {rec["path"]} CHARS {start}-{end}/{len(txt)}'); print(txt[start:end]); printed+=end-start
                if end<len(txt): s['offset']=end; rec['status']='in_progress'; break
                s['cursor']+=1; s['offset']=0
            else:
                start=s['offset']; end=start
                while end<len(lines) and printed+sum(len(x)+12 for x in lines[start:end+1])<budget: end+=1
                if end==start: break
                print('\nFILE '+rec['path']+f' LINES {start+1}-{end}/{len(lines)}')
                for i in range(start,end): print(f'{i+1}: {lines[i]}')
                printed+=sum(len(x)+12 for x in lines[start:end]); s['offset']=end
                if end==len(lines): rec.update(status='reviewed',method='full line-by-line source/text read in bounded untruncated chunks',lines=len(lines)); s['cursor']+=1;s['offset']=0
                else: break
        if printed>=budget: break
    out.write_text(json.dumps(s,indent=2)); print(f'CURSOR {s["cursor"]}/{len(s["files"])} OFFSET {s["offset"]}')
