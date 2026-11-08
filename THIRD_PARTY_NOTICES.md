# Third-Party Register Data

The application source license does not relicense the bundled register data.
`Resources/Registers/registers.dat` contains mechanically transformed CMSIS-SVD
register definitions, not hardware test results. Shared definitions can differ
from the peripherals bonded out or enabled on a particular package or core.

## Sources and Licenses

- STMicroelectronics CMSIS-SVD definitions in the original Keil and
  STMicroelectronics Device Family Packs: Apache-2.0 where explicitly declared
  by the SVD, or by a complete pack-wide Apache license referenced by its PDSC.
- STMicroelectronics STM32H7P DFP: BSD-3-Clause, as explicitly declared by that
  pack's PDSC and its original `LICENSE.md`.
- STM32F1 replacements: the six STMicroelectronics Apache-2.0 SVDs distributed
  in [stm32duino/stm32_svd 1.22.0](https://github.com/stm32duino/stm32_svd/tree/1.22.0/svd/STM32F1xx).
  Legacy Keil F1 SVD names are explicitly mapped to these replacement files.
  The old F1 and MP1 SVDs without explicit redistribution authorization are not
  included. The old F1 pack is used only for its device-to-SVD name mapping.

Original copyright and license declarations are retained in
`Resources/Registers/notices/`. Complete upstream license and notice files are
retained in `Resources/Registers/licenses/`, including the full Apache-2.0 text
and the original H7P BSD license/copyright statements. Do not label these data
files MIT or remove their notices from binary distributions.

`Resources/Registers/sources.json` records each included profile's original
pack URL and SHA-256, PDSC SHA-256, SVD URL and SHA-256, license basis, original
notices, and explicit F1 replacement mapping. `coverage.json` lists actual
coverage, rejected files, unsupported definitions and missing mappings.

## Transformation

The offline generator uses the separately installed `cmsis-svd==0.6` parser to
expand inheritance and arrays. It retains peripheral instance names, register
names, byte addresses, sizes, access properties, descriptions and read-action
warnings. Bit-field descriptions and enumerations are omitted.
If upstream supplies no effective access declaration, `access` is `unknown`;
this is not interpreted as readable permission. Original specified access values
are retained without guessing from the register's name or address. Identical
duplicate register rows are removed; conflicting definitions are excluded and
reported. Profiles are independently compressed with Apple's Foundation LZFSE
API. Index hashes describe the uncompressed generated JSON bytes, not the SVD
XML or compressed block. This is a modified representation of the upstream data.

Reproduce on macOS using a Python environment with `cmsis-svd==0.6`, the original
downloaded pack archives and research manifests:

```sh
python scripts/build-register-db.py --self-test \
  --source-dir /path/to/source-archives --output Resources/Registers
```

No family-level fallback or guessed addresses are generated. A device is listed
only when its own pack PDSC maps it to an accepted profile. Missing data is not a
claim that the hardware lacks the peripheral, and inclusion is not certification
that reading a register is free of hardware side effects.

Verify the packed database without parsing source archives or starting the app:

```sh
swift scripts/pack-register-db.swift --verify Resources/Registers
```
