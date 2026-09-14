"""Read the simulator entitlement section from the actual thin Mach-O binary.

The field layouts are defined by Apple's mach-o/loader.h. The capture builds for
one active simulator architecture. Fail closed on another format or missing
section instead of treating a source .xcent file as proof of the built binary.
"""

from pathlib import Path
import plistlib
import struct
import sys


def read_entitlements(data):
    assert len(data) >= 32, "Mach-O header is truncated."
    assert data[:4] == b"\xcf\xfa\xed\xfe", "Expected a thin, little-endian 64-bit simulator binary."
    architecture = struct.unpack_from("<I", data, 4)[0]
    assert architecture in (0x0100000C, 0x01000007), "Expected arm64 or x86_64."
    count, command_bytes = struct.unpack_from("<II", data, 16)
    command_end = 32 + command_bytes
    assert command_end <= len(data), "Load commands extend beyond the binary."
    offset = 32
    matches = []
    for _ in range(count):
        assert offset + 8 <= command_end, "Truncated load command."
        command, size = struct.unpack_from("<II", data, offset)
        assert size >= 8 and offset + size <= command_end, "Invalid load-command length."
        if command == 0x19:  # LC_SEGMENT_64
            assert size >= 72, "Truncated segment command."
            sections = struct.unpack_from("<I", data, offset + 64)[0]
            assert 72 + sections * 80 <= size, "Truncated section table."
            for index in range(sections):
                section = offset + 72 + index * 80
                name = data[section:section + 16].split(b"\0", 1)[0]
                segment = data[section + 16:section + 32].split(b"\0", 1)[0]
                if name == b"__entitlements" and segment == b"__TEXT":
                    length = struct.unpack_from("<Q", data, section + 40)[0]
                    start = struct.unpack_from("<I", data, section + 48)[0]
                    assert length > 0 and start + length <= len(data), "Invalid entitlement section bounds."
                    matches.append(plistlib.loads(data[start:start + length].rstrip(b"\0")))
        offset += size
    assert offset == command_end, "Load-command count and byte length disagree."
    assert len(matches) == 1, "Expected exactly one embedded simulator entitlement section."
    assert matches[0].get("com.apple.developer.carplay-charging") is True, "Built app lacks CarPlay charging entitlement."
    return matches[0]


if __name__ == "__main__":
    binary, destination = map(Path, sys.argv[1:])
    entitlements = read_entitlements(binary.read_bytes())
    destination.write_bytes(plistlib.dumps(entitlements))
    print("Verified CarPlay charging entitlement directly in built simulator Mach-O section.")
