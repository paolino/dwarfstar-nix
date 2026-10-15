{
  lib,
  stdenv,
  fetchFromGitHub,
  rocmPackages,
  glibc,
  curl,
  makeWrapper,
  python3Packages,
  apple-sdk_15,
  # GPU target. Default is Strix Halo (Radeon 8050S/8060S, Ryzen AI MAX).
  # Override for other AMD GPUs, e.g. "gfx1100" (RDNA3 dGPU).
  rocmArch ? "gfx1151",
}:

let
  inherit (stdenv.hostPlatform) isDarwin isLinux;

  rocm = rocmPackages;

  # Unwrapped gcc, used to give the ROCm clang a C++/libstdc++ toolchain.
  gcc = stdenv.cc.cc;
  triple = stdenv.hostPlatform.config;
  gccInstallDir = "${gcc}/lib/gcc/${triple}/${gcc.version}";

  deviceLibs = "${rocm.rocm-device-libs}/amdgcn/bitcode";

  # Headers needed to compile ds4_rocm.cu.
  includePkgs = [
    rocm.clr
    rocm.hipblas
    rocm.hipblas-common
    rocm.hipblaslt
    rocm.rocblas
    rocm.hipcub
    rocm.rocwmma
    rocm.rocprim
  ];
  includeFlags = lib.concatMapStringsSep " " (p: "-I${p}/include") includePkgs;

  # Shared libs the final binaries link against / load at runtime.
  runtimeLibPkgs = [
    rocm.clr # libamdhip64
    rocm.hipblas
    rocm.hipblaslt
    rocm.rocblas
  ];
  linkFlags = lib.concatStringsSep " " (
    (map (p: "-L${p}/lib") runtimeLibPkgs) ++ (map (p: "-Wl,-rpath,${p}/lib") runtimeLibPkgs)
  );
in
stdenv.mkDerivation {
  pname = "ds4";
  version = "0-unstable-2026-09-20";

  src = fetchFromGitHub {
    owner = "antirez";
    repo = "ds4";
    rev = "0aaea5a238fb41a35106a551e73c8409dfb751ac";
    hash = "sha256-Bo/td1HwVjw6bwz3BDwTP+ZSudkVFCo2aIVK4axvmXg=";
  };

  # Tools that must be on PATH during the build:
  #  - hipcc:        compiles the .cu device code
  #  - llvm.clang:   the actual clang++ hipcc drives (HIP_CLANG_PATH)
  #  - llvm.lld:     provides ld.lld for the amdgcn device link
  #  - llvm.llvm:    provides llvm-objcopy used by clang-offload-bundler
  #  - makeWrapper:  to wrap the model downloader with curl
  nativeBuildInputs = [
    makeWrapper
  ]
  ++ lib.optionals isLinux [
    rocm.hipcc
    rocm.llvm.clang
    rocm.llvm.lld
    rocm.llvm.llvm
  ];

  buildInputs = lib.optionals isLinux includePkgs ++ lib.optional isDarwin apple-sdk_15;

  env = {
    # Let Nix choose portable CPU flags instead of Makefile's -mcpu=native.
    NATIVE_CPU_FLAG = "";
  }
  // lib.optionalAttrs isDarwin {
    MACOSX_DEPLOYMENT_TARGET = "15.0";
    NIX_CFLAGS_COMPILE = "-mmacosx-version-min=15.0";
  }
  // lib.optionalAttrs isLinux {
    # hipcc / the ROCm clang look these up from the environment.
    ROCM_PATH = "${rocm.clr}";
    HIP_PATH = "${rocm.clr}";
    HIP_CLANG_PATH = "${rocm.llvm.clang}/bin";
  };

  dontConfigure = isLinux;

  # download_model.sh derives ROOT from dirname $0, expecting a writable git
  # checkout: it defaults the GGUF directory to $ROOT/gguf and links
  # $ROOT/ds4flash.gguf to the model it just fetched. Installed via Nix, $0 is
  # in the read-only store, so the link fails with EACCES. Point ROOT at the
  # working directory instead, overridable with DS4_ROOT.
  #
  # Metal kernels are compiled from metal/*.metal on every startup, and
  # ds4_metal.m looks those files up relative to the working directory only, so
  # an installed binary aborts with "Metal source metal/flash_attn.metal not
  # found". Also look under $out/share/ds4; the entries already carry the
  # "metal/" prefix, so the install directory below stops at share/ds4.
  postPatch = ''
    substituteInPlace download_model.sh \
      --replace-fail 'ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)' \
        'ROOT=''${DS4_ROOT:-$PWD}'
  '' + lib.optionalString isDarwin ''

    substituteInPlace ds4_metal.m \
      --replace-fail '        [paths addObject:spec[1]];' \
        '        [paths addObject:[@"'"$out"'/share/ds4/" stringByAppendingString:spec[1]]];'
  '';

  buildPhase = ''
    runHook preBuild
    ${lib.optionalString isLinux ''
      # ds4's Makefile `strix-halo` target recursively re-pins DS4_LINK to hipcc,
      # whose bundled clang cannot host-link on NixOS (no bare ld/crt/dynamic-linker).
      # Build the device object with hipcc, then host-link with Nix's wrapped g++.
      make -B ds4 ds4-server ds4-bench ds4-eval ds4-agent \
        CORE_OBJS='ds4.o ds4_image.o ds4_distributed.o ds4_tp.o ds4_ssd.o ds4_rocm.o ds4_rocm_compat.o ds4_rocm_unavailable.o ds4_layer_pack.o $(ROCM_MMQ_OBJS)' \
        CC=cc \
        CFLAGS="-O3 -ffast-math -g -Wall -Wextra -std=c99 -D_GNU_SOURCE -fno-finite-math-only -DDS4_ROCM_BUILD" \
        HIPCC=hipcc \
        ROCM_CFLAGS="-O3 -ffast-math -g -fno-finite-math-only -pthread -D__HIP_PLATFORM_AMD__ -Wno-unused-command-line-argument --offload-arch=${rocmArch} --rocm-device-lib-path=${deviceLibs} --gcc-install-dir=${gccInstallDir} -idirafter ${glibc.dev}/include ${includeFlags}" \
        DS4_LINK="g++" \
        DS4_LINK_LIBS="-lm -pthread -lhipblas -lhipblaslt -lrocblas -lamdhip64 ${linkFlags}" \
        -j$NIX_BUILD_CORES
    ''}
    ${lib.optionalString isDarwin "make -j$NIX_BUILD_CORES"}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm755 ds4 ds4-server ds4-bench ds4-eval ds4-agent -t $out/bin

    ${lib.optionalString isDarwin ''
      # Every source named in ds4_metal.m is compiled at startup, and ds4
      # aborts if any one of them is missing.
      install -Dm644 metal/*.metal -t $out/share/ds4/metal

      # Catch a kernel source upstream adds or renames, rather than letting a
      # build through that only fails once it runs.
      required=$(grep -c '_SOURCE", *@"metal/' ds4_metal.m || true)
      installed=$(find $out/share/ds4/metal -name '*.metal' | grep -c . || true)
      if [ "''${required:-0}" -eq 0 ] || [ "''${installed:-0}" -lt "''${required:-0}" ]; then
        echo "ds4_metal.m asks for ''${required:-0} Metal sources, installed ''${installed:-0}" >&2
        exit 1
      fi
    ''}

    # Model downloader: curl handles smaller files, while the official
    # Hugging Face CLI and hf-xet provide resumable large-model downloads.
    install -Dm755 download_model.sh $out/bin/ds4-download-model
    wrapProgram $out/bin/ds4-download-model \
      --prefix PATH : ${
        lib.makeBinPath [
          curl
          python3Packages.huggingface-hub
          python3Packages.hf-xet
        ]
      }

    runHook postInstall
  '';

  meta = {
    description = "DwarfStar (antirez ds4): DeepSeek V4 inference runtime, ROCm/Strix Halo build";
    homepage = "https://github.com/antirez/ds4";
    license = lib.licenses.bsd2;
    platforms = [
      "x86_64-linux"
      "aarch64-darwin"
    ];
    mainProgram = "ds4";
  };
}
