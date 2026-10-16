#!/usr/bin/env python3
"""Read the partition table and Android v4 boot images out of the recovery image (read-only)."""
import gzip, hashlib, json, pathlib, struct, subprocess, zlib
R=pathlib.Path(__file__).resolve().parents[1]
out=R/'artifacts/mica/normal';out.mkdir(parents=True,exist_ok=True)
u=lambda b,o:struct.unpack_from('<I',b,o)[0]
align=lambda n,p:(n+p-1)//p*p
manifest={}
def save(n,b):
    (out/n).write_bytes(b)
    manifest[n]={'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
with (R/'artifacts/mica-recovery.raw').open('rb') as f:
    f.seek(512);h=f.read(512);assert h[:8]==b'EFI PART'
    hc=bytearray(h[:u(h,12)]);hc[16:20]=bytes(4);assert zlib.crc32(hc)==u(h,16)
    lba,count,size=struct.unpack_from('<QII',h,72);f.seek(lba*512);es=f.read(count*size)
    assert zlib.crc32(es)==u(h,88)
    parts={}
    for i in range(count):
        e=es[i*size:(i+1)*size]
        if not any(e[:16]):continue
        n=e[56:128].decode('utf-16le').rstrip('\0');s,t=struct.unpack_from('<QQ',e,32)
        parts[n]=[s*512,(t+1)*512]
    (R/'artifacts/mica/outer_gpt.json').write_text(json.dumps(parts,indent=2)+'\n')
    blobs={}
    for n in ['boot_a','init_boot_a','vendor_boot_a','vbmeta_a','pvmfw_a','recovery_a']:
        s,t=parts[n];f.seek(s);b=f.read(t-s);assert len(b)==t-s;save(n+'.bin',b);blobs[n]=b
    vb=blobs['vbmeta_a'];magic,maj,min_,auth_size,aux_size=struct.unpack_from('>4sIIQQ',vb,0)
    vb_size=256+auth_size+aux_size if magic==b'AVB0' else 7680
    vb_digest=hashlib.sha256(vb[:vb_size]).hexdigest()
    super_base=parts['super'][0];f.seek(super_base+12288);hdr=f.read(256);lp_parts={}
    if hdr[:4]==b'\x30\x50\x4c\x41':
        hdr_size=u(hdr,8);part_offset,part_num,part_entry_size=struct.unpack_from('<III',hdr,80)
        extents_offset,extents_num,extents_entry_size=struct.unpack_from('<III',hdr,92)
        tables_start=super_base+12288+hdr_size;f.seek(tables_start+extents_offset);extents=[]
        for _ in range(extents_num):num_sec,ttype,tdata,tsrc=struct.unpack('<QIQI',f.read(extents_entry_size));extents.append((num_sec,ttype,tdata,tsrc))
        f.seek(tables_start+part_offset)
        for _ in range(part_num):
            pdata=f.read(part_entry_size);name=pdata[:36].rstrip(b'\0').decode()
            attr,first_ext,num_ext,group=struct.unpack_from('<IIII',pdata,36)
            if num_ext>0:e=extents[first_ext];lp_parts[name]={'size':e[0]*512,'offset':super_base+e[2]*512}
    img_info={'vbmeta_size':vb_size,'vbmeta_digest':vb_digest,'vendor_offset':lp_parts.get('vendor_a',{}).get('offset',5647630336),'vendor_size':lp_parts.get('vendor_a',{}).get('size',392548352),'system_dlkm_offset':lp_parts.get('system_dlkm_a',{}).get('offset',8257536000),'system_dlkm_size':lp_parts.get('system_dlkm_a',{}).get('size',8482816)}
    (R/'artifacts/mica/image_info.json').write_text(json.dumps(img_info,indent=2)+'\n')
boot,init,v=[blobs[n] for n in ['boot_a','init_boot_a','vendor_boot_a']]
assert boot[:8]==init[:8]==b'ANDROID!' and u(boot,40)==u(init,40)==4
kernel=boot[4096:4096+u(boot,8)];save('kernel.payload',kernel)
if kernel.startswith(b'\x1f\x8b'):kernel=gzip.decompress(kernel)
elif kernel.startswith(bytes.fromhex('02214c18')):kernel=subprocess.check_output(['lz4','-d','-c'],input=kernel)
assert kernel[56:60]==b'ARM\x64',kernel[:64].hex()
save('kernel.Image',kernel)
marker=kernel.find(b'IKCFG_ST')
if marker>=0:save('kernel.config',zlib.decompressobj(31).decompress(kernel[marker+8:]))
i=4096+align(u(init,8),4096);save('init_ramdisk.bin',init[i:i+u(init,12)])
assert v[:8]==b'VNDRBOOT' and u(v,8)==4
page=u(v,12);vs=u(v,24);hs=u(v,2096);dtb=u(v,2100)
ts,count,es,bs=struct.unpack_from('<IIII',v,2112);start=align(hs,page);table=start+align(vs,page)+align(dtb,page)
info=[]
for j in range(count):
    e=v[table+j*es:table+(j+1)*es];size,off,kind=struct.unpack_from('<III',e)
    name=e[12:44].split(b'\0')[0].decode() or 'platform';assert name.replace('_','').isalnum()
    n=f'vendor_{j}_{name}.bin';save(n,v[start+off:start+off+size]);info.append({'file':n,'kind':kind,'bytes':size})
save('vendor_bootconfig.txt',v[table+align(ts,page):table+align(ts,page)+bs])
save('cmdline.txt',boot[44:1580].split(b'\0')[0]+b'\n'+v[28:2076].split(b'\0')[0]+b'\n')
(out/'fragments.json').write_text(json.dumps(info,indent=2)+'\n')
for n in ['init_ramdisk.bin']+[e['file'] for e in info]:
    b=(out/n).read_bytes()
    data=gzip.decompress(b) if b.startswith(b'\x1f\x8b') else subprocess.check_output(['lz4','-d','-c'],input=b)
    save(n.replace('.bin','.cpio'),data)
(out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps(info,indent=2));print((out/'cmdline.txt').read_text())
