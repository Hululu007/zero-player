"""Generate PDF/ZIP samples for publications_native_test.dart.

Install pypdf and pyzipper in a test environment before running. The generated
archive contains only a one-page synthetic PDF. Large PDF volumes exercise file
size, not rendering complexity. Allow 1.7 GiB in the destination.
"""

import argparse
import struct
import zipfile
import zlib
from pathlib import Path

import pyzipper
from pypdf import PdfWriter


def make_pdf(path: Path, size: int = 0, scanned: bool = False) -> None:
    with path.open('wb') as output:
        output.write(b'%PDF-1.7\n')
        offsets = [0]

        def object_bytes(contents: bytes) -> None:
            number = len(offsets)
            offsets.append(output.tell())
            output.write(f'{number} 0 obj\n'.encode())
            output.write(contents + b'\nendobj\n')

        object_bytes(b'<</Type/Catalog/Pages 2 0 R>>')
        object_bytes(b'<</Type/Pages/Count 1/Kids[3 0 R]>>')
        object_bytes(
            b'<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]'
            b'/Resources<</Font<</F1 4 0 R>>/XObject<</Scan 6 0 R>>>>/Contents 5 0 R>>'
        )
        object_bytes(b'<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>')
        contents = (
            b'q 250 0 0 250 70 120 cm /Scan Do Q'
            if scanned else b'BT /F1 18 Tf 70 710 Td (Publication text checkpoint) Tj ET'
        )
        object_bytes(f'<</Length {len(contents)}>>\nstream\n'.encode() + contents + b'\nendstream')
        image = zlib.compress(bytes(range(64)) * 32)
        object_bytes(
            b'<</Type/XObject/Subtype/Image/Width 64/Height 32/ColorSpace/DeviceGray'
            b'/BitsPerComponent 8/Filter/FlateDecode'
            + f'/Length {len(image)}>>\nstream\n'.encode() + image + b'\nendstream'
        )
        if size:
            offsets.append(output.tell())
            prefix = b'7 0 obj\n<</Length 0000000000>>\nstream\n'
            tail = b'\nendstream\nendobj\n'
            remaining = size - output.tell() - len(prefix) - len(tail) - len(xref_bytes(offsets, 0))
            output.write(prefix.replace(b'0000000000', f'{remaining:010}'.encode()))
            output.seek(remaining - 1, 1)
            output.write(b'\0' + tail)
        output.write(xref_bytes(offsets, output.tell()))
    if size and path.stat().st_size != size:
        raise ValueError('Unexpected PDF fixture size')


def xref_bytes(offsets: list[int], start: int) -> bytes:
    count = len(offsets)
    entries = b''.join(f'{offset:010} 00000 n \n'.encode() for offset in offsets[1:])
    return (
        f'xref\n0 {count}\n0000000000 65535 f \n'.encode() + entries
        + f'trailer\n<</Size {count}/Root 1 0 R>>\nstartxref\n{start:010}\n%%EOF\n'.encode()
    )


def make_archives(output: Path) -> None:
    source = output / 'fixture.pdf'
    for name, password in [('aes.zip', 'zip-key'), ('aes-utf8.zip', '汉字')]:
        with pyzipper.AESZipFile(
            output / name, 'w', compression=pyzipper.ZIP_DEFLATED, encryption=pyzipper.WZ_AES,
        ) as archive:
            archive.setpassword(password.encode())
            archive.write(source, 'nested/fixture.pdf')
    make_zipcrypto(output / 'zipcrypto.zip', source.read_bytes(), b'zip-key')


def make_zipcrypto(path: Path, data: bytes, password: bytes) -> None:
    keys = [0x12345678, 0x23456789, 0x34567890]

    def update(value: int) -> None:
        keys[0] = zlib.crc32(bytes([value]), keys[0] ^ 0xFFFFFFFF) ^ 0xFFFFFFFF
        keys[1] = ((keys[1] + (keys[0] & 255)) * 134775813 + 1) & 0xFFFFFFFF
        keys[2] = zlib.crc32(bytes([keys[1] >> 24]), keys[2] ^ 0xFFFFFFFF) ^ 0xFFFFFFFF

    for value in password:
        update(value)
    crc = zlib.crc32(data)
    plaintext = b'Fixture-ZP!' + bytes([crc >> 24]) + data
    encrypted = bytearray()
    for value in plaintext:
        temporary = keys[2] | 2
        encrypted.append(value ^ ((temporary * (temporary ^ 1)) >> 8 & 255))
        update(value)
    entry = b'fixture.pdf'
    sizes = (crc, len(encrypted), len(data), len(entry))
    body = struct.pack('<4s5H3I2H', b'PK\x03\x04', 20, 1, 0, 0, 0, *sizes, 0) + entry + encrypted
    central = struct.pack('<4s6H3I5H2I', b'PK\x01\x02', 20, 20, 1, 0, 0, 0, *sizes, 0, 0, 0, 0, 0, 0) + entry
    path.write_bytes(body + central + struct.pack('<4s4H2IH', b'PK\x05\x06', 0, 0, 1, 1, len(central), len(body), 0))
    with zipfile.ZipFile(path) as archive:
        if archive.read(entry.decode(), pwd=password) != data:
            raise ValueError('ZipCrypto fixture failed independent validation')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--small-only', action='store_true')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    make_pdf(args.output / 'fixture.pdf')
    make_pdf(args.output / 'fixture-scan.pdf', scanned=True)
    if not args.small_only:
        for size in (129, 511, 512):
            make_pdf(args.output / f'fixture-{size}.pdf', size << 20, scanned=size == 511)
        make_pdf(args.output / 'fixture-over.pdf', (512 << 20) + 1)
    writer = PdfWriter(clone_from=args.output / 'fixture.pdf')
    writer.encrypt('print-key', algorithm='RC4-128')
    writer.write(args.output / 'fixture-locked.pdf')
    make_archives(args.output)


if __name__ == '__main__':
    main()
