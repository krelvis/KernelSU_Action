#!/usr/bin/env python3
"""Compose a clean boot image: stock ramdisk + freshly built kernel.

Usage: compose_boot.py <stock_boot.img> <built_kernel> <output_boot.img> [ksud_binary]

Takes the official stock boot image as the source for the ramdisk, the
device cmdline and the trailing DTB blob, swaps in the newly built kernel
Image, and writes the result. The resulting boot is 100% official on the
ramdisk side (no Magisk, no permissive cmdline) and boots the custom
kernel -- KernelSU builtin inside the Image provides root, the manager
app gets crowned by the kernel and pulls ksud up itself via magica.

If an optional 4th argument (a ksud aarch64 binary) is given, it is
planted into the ramdisk as /ksud (mode 0755, cpio newc). The kernel-side
ksud bootstrap patch (patches/ksu/sukisu_ksud_bootstrap.diff) then copies
it to /data/adb/ksud during the first boot, so a FRESH device (factory
reset / first flash) reaches root without any external root provider.
Without it the boot is identical to the old plain clean boot.

Pure stdlib; works with A-only boot headers (lemonades, page_size from
header offset 36).
"""
import struct, sys, hashlib, gzip, lzma

NEWC_MAGIC = b'070701'


def _newc_entry(name: bytes, data: bytes, ino: int, mode: int, mtime: int = 0) -> bytes:
    """Build one cpio newc (SVR4) entry, 4-byte aligned like mkbootfs."""
    namesz = len(name) + 1  # NUL-terminated
    hdr = NEWC_MAGIC + b''.join(b'%08X' % v for v in (
        ino, mode, 0, 0, 1, mtime, len(data), 0, 0, 0, 0, namesz, 0))
    assert len(hdr) == 110
    entry = hdr + name + b'\x00'
    entry += b'\x00' * ((-len(entry)) % 4)
    entry += data
    entry += b'\x00' * ((-len(data)) % 4)
    return entry


def _cpio_inject_ksud(ramdisk_gz: bytes, ksud: bytes) -> bytes:
    """Insert /ksud into a gzip'd cpio newc ramdisk, just before TRAILER!!!."""
    data = gzip.decompress(ramdisk_gz)

    off = 0
    trailer_off = None
    max_ino = 0
    while off + 110 <= len(data):
        if data[off:off + 6] != NEWC_MAGIC:
            raise SystemExit(f'bad cpio magic at offset {off}; ramdisk is not newc?')
        (ino, mode, _uid, _gid, _nlink, _mtime, fsize, _dm, _dn, _rm, _rn,
         namesz, _check) = (int(data[off + 6 + i * 8: off + 6 + (i + 1) * 8], 16)
                            for i in range(13))
        name = data[off + 110: off + 110 + namesz - 1]
        max_ino = max(max_ino, ino)
        if name == b'TRAILER!!!':
            trailer_off = off
            break
        if name == b'ksud':
            print('ramdisk already contains a ksud entry; skipping injection')
            return ramdisk_gz
        entry_len = 110 + namesz
        entry_len += (-entry_len) % 4
        entry_len += fsize
        entry_len += (-fsize) % 4
        off += entry_len

    if trailer_off is None:
        raise SystemExit('cpio TRAILER!!! not found; ramdisk is corrupt')

    entry = _newc_entry(b'ksud', ksud, max_ino + 1, 0o100755)
    new = data[:trailer_off] + entry + data[trailer_off:]
    print(f'ramdisk: injected /ksud ({len(ksud)} bytes, entry {len(entry)} bytes)')
    # The lemonades boot partition is exactly 96 MiB and the raw kernel is
    # ~15 MiB larger than stock, so the ~3 MiB ramdisk budget left after the
    # 52 MiB trailing DTB cannot fit the gzip'd 5.9 MB result. The kernel
    # (and stock) both carry CONFIG_RD_LZMA=y, and lib/decompress_lzma.c
    # understands the LZMA_ALONE header, so compress with lzma1/8M-dict
    # instead -- roughly half the size of gzip for the embedded ELF.
    out_lzma = lzma.compress(
        new, format=lzma.FORMAT_ALONE,
        filters=[{'id': lzma.FILTER_LZMA1, 'preset': 9 | lzma.PRESET_EXTREME,
                  'dict_size': 8 * 1024 * 1024}])
    print(f'ramdisk: lzma-compressed {len(new)} -> {len(out_lzma)} bytes')
    return out_lzma


def compose(stock_path, kernel_path, out_path, ksud_path=None):
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

    if ksud_path:
        ksud = open(ksud_path, 'rb').read()
        if ksud[:4] != b'\x7fELF' or ksud[18] != 0xb7:
            raise SystemExit('ksud binary is not an aarch64 ELF; refusing to inject')
        official_ramdisk = _cpio_inject_ksud(official_ramdisk, ksud)

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

    # The lemonades boot partition is exactly the size of the stock boot
    # image; fastboot would fail with "Volume Full" past it.
    if len(out) > len(stock):
        raise SystemExit(
            f'FATAL: composed boot {len(out)} bytes exceeds the boot '
            f'partition budget {len(stock)} bytes (stock image size)')

    c = open(out_path, 'rb').read()
    assert struct.unpack_from('<I', c, 8)[0] == len(img)
    nr = page_size + al(len(img))
    assert c[nr:nr + len(official_ramdisk)] == official_ramdisk
    if trailing:
        nt = nr + al(len(official_ramdisk))
        assert c[nt:nt + 4] == b'\xd0\x0d\xfe\xed'
    print(f'cmdline: {cl}')
    print(f'kernel: {len(img)} bytes, sha1 verified')
    print(f'ramdisk: {len(official_ramdisk)} bytes')
    print(f'output: {out_path} ({len(c)} bytes)')


if __name__ == '__main__':
    if len(sys.argv) not in (4, 5):
        sys.exit('usage: compose_boot.py <stock_boot.img> <built_kernel> <output_boot.img> [ksud_binary]')
    compose(*sys.argv[1:])
