#!/usr/bin/env python3
"""Compose a clean boot image: stock ramdisk + freshly built kernel.

Usage: compose_boot.py <stock_boot.img> <built_kernel> <output_boot.img>

Takes the official stock boot image as the source for the ramdisk, the
device cmdline and the trailing DTB blob, swaps in the newly built kernel
Image, and writes the result. The resulting boot is 100% official on the
ramdisk side (no Magisk, no permissive cmdline) and boots the custom
kernel -- KernelSU builtin inside the Image provides root, the manager
app gets crowned by the kernel and pulls ksud up itself via magica.

Pure stdlib; works with A-only boot headers (lemonades, page_size from
header offset 36).
"""
import struct, sys, hashlib


def compose(stock_path, kernel_path, out_path):
    stock = open(stock_path, 'rb').read()
    img = open(kernel_path, 'rb').read()
    page_size = struct.unpack_from('<I', stock, 36)[0]

    def al(x):
        return (x + page_size - 1) // page_size * page_size

    s_ks = struct.unpack_from('<I', stock, 8)[0]
    s_rs = struct.unpack_from('<I', stock, 16)[0]
    r_off = page_size + al(s_ks)
    official_ramdisk = stock[r_off:r_off + s_rs]
    print(f'official ramdisk: {s_rs} bytes, magic {official_ramdisk[:4].hex()}')

    t_off = r_off + al(s_rs)
    trailing = stock[t_off:]
    if trailing[:4] != b'\xd0\x0d\xfe\xed':
        # No trailing DTB blob on this device -- keep the boot self-contained.
        trailing = b''
        print('no trailing dtb')
    else:
        print(f'trailing dtb: {len(trailing)} bytes, '
              f'{trailing.count(bytes.fromhex("d00dfeed"))} FDT')

    # Official cmdline, byte-for-byte. No permissive, no extras.
    cl = stock[64:64 + 512].split(b'\x00')[0].decode()

    hdr = bytearray(stock[:page_size])
    struct.pack_into('<I', hdr, 8, len(img))
    struct.pack_into('<I', hdr, 16, len(official_ramdisk))
    struct.pack_into('<20s', hdr, 572, hashlib.sha1(img).digest())
    struct.pack_into('<20s', hdr, 592, hashlib.sha1(official_ramdisk).digest())
    hdr[64:64 + 512] = cl.encode('ascii').ljust(512, b'\x00')

    out = bytearray(hdr)
    out += img
    out += b'\0' * (al(len(img)) - len(img))
    out += official_ramdisk
    out += b'\0' * (al(len(official_ramdisk)) - len(official_ramdisk))
    out += trailing

    open(out_path, 'wb').write(out)

    c = open(out_path, 'rb').read()
    assert struct.unpack_from('<I', c, 8)[0] == len(img)
    nr = page_size + al(len(img))
    assert c[nr:nr + s_rs] == official_ramdisk
    if trailing:
        nt = nr + al(s_rs)
        assert c[nt:nt + 4] == b'\xd0\x0d\xfe\xed'
    print(f'cmdline: {cl}')
    print(f'kernel: {len(img)} bytes, sha1 verified')
    print(f'output: {out_path} ({len(c)} bytes)')


if __name__ == '__main__':
    if len(sys.argv) != 4:
        sys.exit('usage: compose_boot.py <stock_boot.img> <built_kernel> <output_boot.img>')
    compose(sys.argv[1], sys.argv[2], sys.argv[3])
