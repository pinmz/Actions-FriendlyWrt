#!/usr/bin/env python3
"""Recover the OpenWrt APK v3 ECDSA public key from packages.adb.

OpenWrt 25.12 signs APK v3 files with a prime256v1 (NIST P-256) ECDSA
key. APK v3 stores a 128-bit key ID and an ECDSA signature in its SIG
block. ECDSA public-key recovery yields a small set of candidates; the
embedded APK key ID identifies the original public key.

This recovers only the public key. It cannot recover the private key.
No third-party Python modules are required.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import struct
import sys
import zlib
from pathlib import Path
from typing import Iterator, Optional

# NIST P-256 / prime256v1 parameters.
FIELD_P = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
CURVE_A = FIELD_P - 3
CURVE_B = 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B
ORDER_N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
GENERATOR = (
    0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296,
    0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5,
)

ADB_MAGIC = 0x2E424441  # "ADB." as little-endian uint32
ADB_BLOCK_ADB = 0
ADB_BLOCK_SIG = 1
ADB_BLOCK_EXT = 3
APK_DIGEST_SHA512 = 0x04

Point = Optional[tuple[int, int]]


class RecoveryError(Exception):
    pass


def inverse(value: int, modulus: int) -> int:
    return pow(value % modulus, -1, modulus)


def point_neg(point: Point) -> Point:
    if point is None:
        return None
    return point[0], (-point[1]) % FIELD_P


def point_add(left: Point, right: Point) -> Point:
    if left is None:
        return right
    if right is None:
        return left

    x1, y1 = left
    x2, y2 = right

    if x1 == x2 and (y1 + y2) % FIELD_P == 0:
        return None

    if left == right:
        if y1 == 0:
            return None
        slope = ((3 * x1 * x1 + CURVE_A) * inverse(2 * y1, FIELD_P)) % FIELD_P
    else:
        slope = ((y2 - y1) * inverse(x2 - x1, FIELD_P)) % FIELD_P

    x3 = (slope * slope - x1 - x2) % FIELD_P
    y3 = (slope * (x1 - x3) - y1) % FIELD_P
    return x3, y3


def scalar_multiply(scalar: int, point: Point) -> Point:
    scalar %= ORDER_N
    result: Point = None
    addend = point

    while scalar:
        if scalar & 1:
            result = point_add(result, addend)
        addend = point_add(addend, addend)
        scalar >>= 1

    return result


def read_der_length(data: bytes, offset: int) -> tuple[int, int]:
    if offset >= len(data):
        raise RecoveryError("truncated DER length")

    first = data[offset]
    offset += 1
    if first < 0x80:
        return first, offset

    count = first & 0x7F
    if count == 0 or count > 4 or offset + count > len(data):
        raise RecoveryError("invalid DER length")
    return int.from_bytes(data[offset : offset + count], "big"), offset + count


def read_der_integer(data: bytes, offset: int) -> tuple[int, int]:
    if offset >= len(data) or data[offset] != 0x02:
        raise RecoveryError("expected DER INTEGER")
    length, offset = read_der_length(data, offset + 1)
    end = offset + length
    if length == 0 or end > len(data):
        raise RecoveryError("invalid DER INTEGER")
    return int.from_bytes(data[offset:end], "big", signed=False), end


def parse_ecdsa_der(signature: bytes) -> tuple[int, int]:
    if not signature or signature[0] != 0x30:
        raise RecoveryError("ECDSA signature is not a DER SEQUENCE")

    length, offset = read_der_length(signature, 1)
    end = offset + length
    if end != len(signature):
        raise RecoveryError("invalid or trailing ECDSA DER data")

    r, offset = read_der_integer(signature, offset)
    s, offset = read_der_integer(signature, offset)
    if offset != end or not (1 <= r < ORDER_N) or not (1 <= s < ORDER_N):
        raise RecoveryError("invalid ECDSA r/s values")
    return r, s


def iter_adb_blocks(data: bytes, offset: int = 8) -> Iterator[tuple[int, bytes]]:
    while offset < len(data):
        if offset + 4 > len(data):
            raise RecoveryError("truncated ADB block header")

        type_size = struct.unpack_from("<I", data, offset)[0]
        encoded_type = type_size >> 30

        if encoded_type == ADB_BLOCK_EXT:
            if offset + 16 > len(data):
                raise RecoveryError("truncated extended ADB block header")
            block_type = type_size & 0x3FFFFFFF
            header_size = 16
            raw_size = struct.unpack_from("<Q", data, offset + 8)[0]
        else:
            block_type = encoded_type
            header_size = 4
            raw_size = type_size & 0x3FFFFFFF

        if raw_size < header_size:
            raise RecoveryError("invalid ADB block size")

        payload_start = offset + header_size
        payload_end = offset + raw_size
        if payload_end > len(data):
            raise RecoveryError("ADB block extends past end of file")

        yield block_type, data[payload_start:payload_end]
        offset += (raw_size + 7) & ~7


def point_bytes(point: tuple[int, int]) -> bytes:
    x, y = point
    return b"\x04" + x.to_bytes(32, "big") + y.to_bytes(32, "big")


def apk_key_id(point: tuple[int, int]) -> bytes:
    # apk-tools uses SHA-512(i2d_PublicKey())[:16]. For an EC key,
    # i2d_PublicKey() is the uncompressed SEC1 point below.
    return hashlib.sha512(point_bytes(point)).digest()[:16]


def verify_ecdsa(point: tuple[int, int], digest: bytes, r: int, s: int) -> bool:
    z = int.from_bytes(digest, "big") >> max(0, len(digest) * 8 - ORDER_N.bit_length())
    w = inverse(s, ORDER_N)
    candidate = point_add(
        scalar_multiply((z * w) % ORDER_N, GENERATOR),
        scalar_multiply((r * w) % ORDER_N, point),
    )
    return candidate is not None and candidate[0] % ORDER_N == r


def recover_candidates(digest: bytes, r: int, s: int) -> Iterator[tuple[int, int]]:
    # OpenSSL truncates the SHA-512 digest to the curve order bit length.
    z = int.from_bytes(digest, "big") >> max(0, len(digest) * 8 - ORDER_N.bit_length())
    r_inverse = inverse(r, ORDER_N)
    max_j = (FIELD_P - 1 - r) // ORDER_N

    seen: set[tuple[int, int]] = set()
    for j in range(max_j + 1):
        x = r + j * ORDER_N
        alpha = (pow(x, 3, FIELD_P) + CURVE_A * x + CURVE_B) % FIELD_P
        y = pow(alpha, (FIELD_P + 1) // 4, FIELD_P)
        if y * y % FIELD_P != alpha:
            continue

        for candidate_y in (y, (-y) % FIELD_P):
            ephemeral = (x, candidate_y)
            public = scalar_multiply(
                r_inverse,
                point_add(
                    scalar_multiply(s, ephemeral),
                    point_neg(scalar_multiply(z, GENERATOR)),
                ),
            )
            if public is None or public in seen:
                continue
            seen.add(public)
            if verify_ecdsa(public, digest, r, s):
                yield public


def public_key_pem(point: tuple[int, int]) -> bytes:
    # SubjectPublicKeyInfo for id-ecPublicKey + prime256v1, followed by the
    # uncompressed SEC1 point. Both lengths are fixed for P-256.
    prefix = bytes.fromhex(
        "3059301306072a8648ce3d020106082a8648ce3d030107034200"
    )
    der = prefix + point_bytes(point)
    encoded = base64.b64encode(der).decode("ascii")
    lines = [encoded[i : i + 64] for i in range(0, len(encoded), 64)]
    return (
        "-----BEGIN PUBLIC KEY-----\n"
        + "\n".join(lines)
        + "\n-----END PUBLIC KEY-----\n"
    ).encode("ascii")


def decompress_adb(data: bytes) -> bytes:
    if data.startswith(b"ADB."):
        return data
    if data.startswith(b"ADBd"):
        try:
            return zlib.decompress(data[4:], -zlib.MAX_WBITS)
        except zlib.error as error:
            raise RecoveryError(f"invalid ADB deflate stream: {error}") from error
    if data.startswith(b"ADBc"):
        if len(data) < 6:
            raise RecoveryError("truncated ADB compression header")
        algorithm, level = data[4], data[5]
        if algorithm == 0:
            return data[6:]
        if algorithm == 1:
            try:
                return zlib.decompress(data[6:], -zlib.MAX_WBITS)
            except zlib.error as error:
                raise RecoveryError(f"invalid ADB deflate stream: {error}") from error
        if algorithm == 2:
            raise RecoveryError(
                "zstd-compressed ADB is not supported by Python's standard library; "
                "decompress it with apk adbsign --compression none first"
            )
        raise RecoveryError(f"unknown ADB compression algorithm: {algorithm}")
    raise RecoveryError("not an APK v3 ADB file: missing ADB magic")


def recover_from_file(input_path: Path) -> list[tuple[bytes, tuple[int, int]]]:
    data = decompress_adb(input_path.read_bytes())
    if len(data) < 8:
        raise RecoveryError("file is too small to be an APK v3 ADB file")

    magic, schema = struct.unpack_from("<II", data, 0)
    if magic != ADB_MAGIC:
        raise RecoveryError("not an APK v3 ADB file: missing ADB. magic")

    adb_payload: Optional[bytes] = None
    signature_payloads: list[bytes] = []
    for block_type, payload in iter_adb_blocks(data):
        if block_type == ADB_BLOCK_ADB and adb_payload is None:
            adb_payload = payload
        elif block_type == ADB_BLOCK_SIG:
            signature_payloads.append(payload)

    if adb_payload is None:
        raise RecoveryError("ADB data block was not found")
    if not signature_payloads:
        raise RecoveryError("ADB signature block was not found")

    adb_digest = hashlib.sha512(adb_payload).digest()
    recovered: list[tuple[bytes, tuple[int, int]]] = []

    for signature_payload in signature_payloads:
        if len(signature_payload) < 19:
            continue

        sign_version = signature_payload[0]
        hash_algorithm = signature_payload[1]
        key_id = signature_payload[2:18]
        signature = signature_payload[18:]

        if sign_version != 0 or hash_algorithm != APK_DIGEST_SHA512:
            continue

        r, s = parse_ecdsa_der(signature)
        signed_data = struct.pack("<I", schema) + signature_payload[:18] + adb_digest
        signature_digest = hashlib.sha512(signed_data).digest()

        matches = [
            point
            for point in recover_candidates(signature_digest, r, s)
            if apk_key_id(point) == key_id
        ]
        if len(matches) == 1:
            recovered.append((key_id, matches[0]))
        elif len(matches) > 1:
            raise RecoveryError(
                f"multiple public keys matched APK key ID {key_id.hex()}"
            )

    if not recovered:
        raise RecoveryError(
            "no recoverable prime256v1/SHA-512 signature matched its APK key ID"
        )
    return recovered


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Recover an OpenWrt APK v3 ECDSA public key from packages.adb"
    )
    parser.add_argument("packages_adb", type=Path, help="path to packages.adb")
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=Path("recovered-public-key.pem"),
        help="output PEM path (default: recovered-public-key.pem)",
    )
    args = parser.parse_args()

    try:
        recovered = recover_from_file(args.packages_adb)
        unique: dict[bytes, tuple[int, int]] = {key_id: point for key_id, point in recovered}
        if len(unique) != 1:
            raise RecoveryError(
                "the ADB file contains multiple signing keys; recover them separately"
            )

        key_id, point = next(iter(unique.items()))
        args.output.write_bytes(public_key_pem(point))
        print(f"Recovered APK key ID: {key_id.hex()}")
        print(f"Public key written to: {args.output}")
        print(f"PEM SHA-256: {hashlib.sha256(args.output.read_bytes()).hexdigest()}")
        return 0
    except (OSError, RecoveryError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
