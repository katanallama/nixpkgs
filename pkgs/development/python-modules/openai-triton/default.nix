{ lib
, buildPythonPackage
, stdenv
, fetchurl
, fetchFromGitHub
, cmake
, cudaPackages ? { }
, llvmPackages
, pybind11
, gtest
, zlib
, ncurses
, libxml2
, lit
, filelock
, torchWithRocm
, pytest
}:

let
  pname = "triton";
  version = "2.0.0";

  ptxas = "${cudaPackages.cuda_nvcc}/bin/ptxas";
in
buildPythonPackage {
  inherit pname version;

  format = "setuptools";

  src = fetchFromGitHub {
    owner = "openai";
    repo = "triton";
    rev = "v${version}";
    hash = "sha256-9GZzugab+Pdt74Dj6zjlEzjj4BcJ69rzMJmqcVMxsKU=";
  };

  patches = [
    # Prerequisite for llvm15 patch
    (fetchurl {
      url = "https://github.com/openai/triton/commit/2aba985daaa70234823ea8f1161da938477d3e02.patch";
      hash = "sha256-HEuLZFif++a/fKs3dyIhqSc+D2DPbzEXOSSR4nRWtgQ=";
    })
    (fetchurl {
      url = "https://github.com/openai/triton/commit/e3941f9d09cdd31529ba4a41018cfc0096aafea6.patch";
      hash = "sha256-sl8woykSLCq4ZJYzEQdCPWM8rzv+s4RTK7PuqsTcmy8=";
    })

    # Not using fetchurl because needed to remove binary diff for ptxas
    ./llvm15.patch
  ];

  postPatch = ''
    substituteInPlace python/setup.py \
      --replace \
        '= get_thirdparty_packages(triton_cache_path)' \
        '= os.environ["cmakeFlags"].split()'
    sed -i '/install_requires=/,/],/d' python/setup.py
  ''
  # A typo in setup.py?
  + ''
    substituteInPlace python/setup.py \
      --replace '"tests"' '"test"'
  ''
  # Circular dependency, cf. https://github.com/openai/triton/issues/1374
  + ''
    substituteInPlace python/setup.py --replace '"torch",' ""
  ''
  # Wiring triton=2.0.0 with llcmPackages_rocm.llvm=5.4.3
  # Revisit when updating either triton or llvm
  + ''
    substituteInPlace CMakeLists.txt \
      --replace "nvptx" "NVPTX" \
      --replace "LLVM 11" "LLVM"
    sed -i '/AddMLIR/a set(MLIR_TABLEGEN_EXE "${llvmPackages.mlir}/bin/mlir-tblgen")' CMakeLists.txt
    sed -i '/AddMLIR/a set(MLIR_INCLUDE_DIR ''${MLIR_INCLUDE_DIRS})' CMakeLists.txt
    find -iname '*.td' -exec \
      sed -i \
      -e '\|include "mlir/IR/OpBase.td"|a include "mlir/IR/AttrTypeBase.td"' \
      -e 's|include "mlir/Dialect/StandardOps/IR/Ops.td"|include "mlir/Dialect/Func/IR/FuncOps.td"|' \
      '{}' ';'
    substituteInPlace unittest/CMakeLists.txt --replace "include(GoogleTest)" "find_package(GTest REQUIRED)"
    sed -i 's/^include.*$//' unittest/CMakeLists.txt
  '' + ''
    sed -i '/LINK_LIBS/i NVPTXInfo' lib/Target/PTX/CMakeLists.txt
  ''
  + ''
    sed -i '/LINK_LIBS/i NVPTXCodeGen' lib/Target/PTX/CMakeLists.txt
  ''
  # # TritonMLIRIR already links MLIRIR. Not transitive?
  # + ''
  #   echo "target_link_libraries(TritonPTX PUBLIC MLIRIR)" >> lib/Target/PTX/CMakeLists.txt
  # ''
  # Already defined in llvm, when built with -DLLVM_INSTALL_UTILS
  + ''
    substituteInPlace bin/CMakeLists.txt \
      --replace "add_subdirectory(FileCheck)" ""

    rm cmake/FindLLVM.cmake
  '';

  nativeBuildInputs = [
    cmake
    (llvmPackages.llvm.override {
      llvmTargetsToBuild = [ "NATIVE" "NVPTX" ];
      # Upstream CI sets these too:
      # targetProjects = [ "mlir" ];
      extraCMakeFlags = [
        "-DLLVM_INSTALL_UTILS=ON"
      ];
    })
    llvmPackages.mlir
    lit
  ];

  buildInputs = [
    pybind11
    gtest
    zlib
    ncurses
    libxml2.dev
  ];

  propagatedBuildInputs = [
    filelock
  ];


  preConfigure =
    # Upstream's setup.py tries to write cache somewhere in ~/
    ''
      export HOME=$PWD
    ''
    # Upstream's github actions patch setup.cfg to write base-dir. May be redundant
    + ''
      echo "" >> python/setup.cfg
      echo "[build_ext]" >> python/setup.cfg
      echo "base-dir=$PWD" >> python/setup.cfg
    ''
    # There rest (including buildPhase) is relative to ./python/
    + ''
      cd python/
    ''
    # Work around download_and_copy_ptxas()
    + ''
      dst_cuda="$PWD/triton/third_party/cuda/bin"
      mkdir -p "$dst_cuda"
      ln -s "${ptxas}" "$dst_cuda/"
    '';

  # CMake is ran by setup.py instead
  dontUseCmakeConfigure = true;
  cmakeFlags = [
    "-DMLIR_DIR=${llvmPackages.mlir}/lib/cmake/mlir"

    # TODO: Probably redundant
    "-DLLVM_BUILD_LLVM_DYLIB=ON"
    # "-DLLVM_LINK_LLVM_DYLIB=ON"
  ];

  checkInputs = [
    cmake # ctest
  ];
  dontUseSetuptoolsCheck = true;
  checkPhase =
    # Requires torch (circular dependency) and probably needs GPUs:
    # ''
    #   (cd test/unit/ ; ${pytest}/bin/pytest)
    # ''
    # +

    # build/temp* refers to build_ext.build_temp (looked up in the build logs)
    ''
      (cd /build/source/python/build/temp* ; ctest)
    '';

  # Ultimately, torch is our test suite:
  passthru.tests = {
    inherit torchWithRocm;
  };

  meta = with lib; {
    description = "Development repository for the Triton language and compiler";
    homepage = "https://github.com/openai/triton/";
    platforms = lib.platforms.unix;
    license = licenses.mit;
    maintainers = with maintainers; [ ];
  };
}
