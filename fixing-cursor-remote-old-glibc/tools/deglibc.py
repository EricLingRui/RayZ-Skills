#!/root/miniconda3/bin/python
import sys, struct
# Redirect any .gnu.version_r reference to GLIBC_2.28+ down to an existing
# lower version string already present in .dynstr, so the loader stops
# requiring the newer glibc version node. Symbol resolution is handled
# separately (fcntl64 == fcntl on this ABI); we only relax the version check.
path = sys.argv[1]
LOWER = b"GLIBC_2.14"   # present in verneed and in system libc 2.17
TARGETS = [b"GLIBC_2.28", b"GLIBC_2.29", b"GLIBC_2.30", b"GLIBC_2.31",
           b"GLIBC_2.32", b"GLIBC_2.33", b"GLIBC_2.34"]

def elf_hash(name):
    h = 0
    for c in name:
        h = (h << 4) + c
        g = h & 0xf0000000
        if g:
            h ^= g >> 24
        h &= ~g
        h &= 0xffffffff
    return h

LOWER_HASH = elf_hash(LOWER)
with open(path, "rb") as f:
    data = bytearray(f.read())

e_shoff = struct.unpack_from("<Q", data, 0x28)[0]
e_shentsize = struct.unpack_from("<H", data, 0x3a)[0]
e_shnum = struct.unpack_from("<H", data, 0x3c)[0]
e_shstrndx = struct.unpack_from("<H", data, 0x3e)[0]

def sh(i):
    o = e_shoff + i * e_shentsize
    vals = struct.unpack_from("<IIQQQQIIQQ", data, o)
    return dict(name=vals[0], typ=vals[1], off=vals[4], size=vals[5],
                link=vals[6], ent=vals[9])

shstr = sh(e_shstrndx)

def secname(i):
    p = shstr["off"] + sh(i)["name"]
    e = data.index(b"\x00", p)
    return data[p:e]

dynstr = verr = None
for i in range(e_shnum):
    n = secname(i)
    if n == b".dynstr":
        dynstr = sh(i)
    elif n == b".gnu.version_r":
        verr = sh(i)

if not dynstr or not verr:
    print("no dynstr/verneed")
    sys.exit(1)

def stroff(s):
    base = dynstr["off"]
    end = base + dynstr["size"]
    idx = data.find(s + b"\x00", base, end)
    return -1 if idx < 0 else idx - base

lower_off = stroff(LOWER)
if lower_off < 0:
    print("ERROR: lower version string not found in dynstr")
    sys.exit(1)

changed = 0
off = verr["off"]
end = off + verr["size"]
p = off
while p < end:
    vn_version, vn_cnt, vn_file, vn_aux, vn_next = struct.unpack_from("<HHIII", data, p)
    ap = p + vn_aux
    for _ in range(vn_cnt):
        vna_hash, vna_flags, vna_other, vna_name, vna_next = struct.unpack_from("<IHHII", data, ap)
        strpos = dynstr["off"] + vna_name
        cur = data[strpos:data.index(b"\x00", strpos)]
        if cur in TARGETS:
            struct.pack_into("<I", data, ap, LOWER_HASH)      # vna_hash
            struct.pack_into("<I", data, ap + 8, lower_off)   # vna_name
            changed += 1
        if vna_next == 0:
            break
        ap += vna_next
    if vn_next == 0:
        break
    p += vn_next

with open(path, "wb") as f:
    f.write(data)
print("redirected %d version refs -> %s" % (changed, LOWER.decode()))
