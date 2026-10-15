# dwarfstar-nix

A Nix flake that builds [DwarfStar (`ds4`)](https://github.com/antirez/ds4) — antirez's
DeepSeek-V4 inference runtime — with its **ROCm backend for AMD Strix Halo** (`gfx1151`:
Ryzen AI MAX, Radeon 8050S/8060S).

`ds4` is its own vertical engine (not llama.cpp/ollama), hand-tuned for one model family on
one platform. Its upstream build instructions assume Ubuntu + apt; this flake packages the
ROCm build for Nix/NixOS so you get the binaries with one command and no manual ROCm setup,
and upstream's Metal build for Apple Silicon (`aarch64-darwin`).

## Requirements

Both targets need Nix with flakes enabled (`experimental-features = nix-command flakes`).

`x86_64-linux` (ROCm):

- An AMD **Strix Halo** machine (Ryzen AI MAX APU, Radeon 8050S/8060S = `gfx1151`) with
  ≥96 GB unified RAM (128 GB recommended).
- ROCm device access: your user must be in the `render` group and able to open `/dev/kfd`:
  ```sh
  sudo usermod -aG render,video "$USER"   # then log out and back in
  ```

`aarch64-darwin` (Metal):

- An Apple Silicon Mac with ≥64 GB unified RAM (128 GB recommended).
- macOS 15 (Sequoia) or later: the package builds with `-mmacosx-version-min=15.0`.

## Quick start

### 1. Download the model (~81 GB)

DeepSeek-V4-Flash, 2-bit quant — fits 96/128 GB machines. Run this from the directory where
you want the model stored; it writes `./gguf/…` and symlinks `./ds4flash.gguf`.

```sh
nix shell github:paolino/dwarfstar-nix -c ds4-download-model q2-imatrix
```

### 2. Run a prompt

```sh
nix run github:paolino/dwarfstar-nix -- \
  -m ./ds4flash.gguf --rocm --ssd-streaming -p "Hello, who are you?"
```

Add `--nothink` for terse answers; omit it for full reasoning. On Apple Silicon pass
`--metal` instead of `--rocm` (same for `ds4-server` below).

### 3. Or run the server (OpenAI-style API)

```sh
nix shell github:paolino/dwarfstar-nix -c \
  ds4-server -m ./ds4flash.gguf --rocm --ssd-streaming --ctx 100000
```

## Performance: `--ssd-streaming` and the GTT aperture

The 81 GB model exceeds the default ~62 GB GPU-visible (GTT) memory on Strix Halo, so the
commands above use `--ssd-streaming` (experts streamed/cached, no kernel changes needed).
It just works, at modest speed (~6 tok/s generation).

For full-residency speed, enlarge the GTT aperture via kernel params and reboot, then drop
`--ssd-streaming`:

```text
amd_iommu=off amdgpu.gttsize=126976 ttm.pages_limit=32505856 ttm.page_pool_size=32505856
```

(On NixOS: `boot.kernelParams = [ "amdgpu.gttsize=126976" … ];` then `nixos-rebuild switch` + reboot.)

## Other GPUs

On Linux the default target is `gfx1151`. The flake also exposes `#ds4-gfx1100` (RDNA3
dGPU), or build for any arch:

```sh
nix build github:paolino/dwarfstar-nix#ds4 --override-input nixpkgs nixpkgs   # default gfx1151
# or override rocmArch in package.nix for another target
```

## Flake outputs

- `packages.x86_64-linux.default` / `.ds4` — the ROCm build (gfx1151)
- `packages.x86_64-linux.ds4-gfx1100` — RDNA3 variant
- `packages.aarch64-darwin.default` / `.ds4` — the Metal build (Apple Silicon)
- `apps.x86_64-linux.default` / `apps.aarch64-darwin.default` — runs `ds4`
- `devShells.x86_64-linux.default` — build env + `rocminfo`/`rocm-smi`
- `devShells.aarch64-darwin.default` — build env, no ROCm packages

Binaries: `ds4`, `ds4-server`, `ds4-bench`, `ds4-eval`, `ds4-agent`, and `ds4-download-model`.

## How the build works

`ds4`'s `strix-halo` Makefile target drives everything through `hipcc`, whose bundled clang
can't host-link on NixOS (no bare `ld`/crt/dynamic-linker). This flake splits the build:
device code (`*.cu`) is compiled by `hipcc` (with the gcc toolchain, glibc headers and ROCm
device-libs spelled out explicitly), and the final host link is done by the Nix-wrapped
`g++`, which handles crt, the dynamic linker and rpaths. See `package.nix`.

`aarch64-darwin` has no ROCm to work around: plain `make` builds upstream's Metal backend,
and the `metal/*.metal` kernels it compiles on every start-up — looked up relative to the
working directory — are installed under `share/ds4/metal`, with `ds4_metal.m` patched to
find them there. `rocmArch`, `#ds4-gfx1100` and the ROCm devShell packages stay Linux-only.

## Credits & license

`ds4` / DwarfStar is by [Salvatore Sanfilippo (antirez)](https://github.com/antirez/ds4),
BSD-2-Clause. This packaging (flake glue) is MIT — see `LICENSE`.
