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
