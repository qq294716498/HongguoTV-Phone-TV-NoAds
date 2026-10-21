import unittest

from verify_windows_package import validate_aot_elf


def header(machine=62, bits=2, endian=1):
    data = bytearray(64)
    data[:7] = b'\x7fELF' + bytes([bits, endian, 1])
    data[18:20] = machine.to_bytes(2, 'little')
    return data


class WindowsAotTests(unittest.TestCase):
    def test_flutter_elf64_snapshot_is_x64_without_requiring_pe(self):
        self.assertEqual(validate_aot_elf(header())['machine'], 'AMD64')

    def test_arm_and_32_bit_snapshots_are_rejected(self):
        for value in [header(machine=183), header(machine=3), header(bits=1), header(endian=2)]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                validate_aot_elf(value)

    def test_truncated_or_foreign_data_is_rejected(self):
        for value in [b'\x7fELF', b'MZ' + bytes(62), bytes(64)]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                validate_aot_elf(value)


if __name__ == '__main__':
    unittest.main()
