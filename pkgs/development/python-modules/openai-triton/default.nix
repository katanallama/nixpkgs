{ lib
, buildPythonPackage
, python
, fetchurl
, fetchFromGitHub
, addOpenGLRunpath
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
, pythonRelaxDepsHook
}:

let
  pname = "triton";
  version = "2.0.0";

  inherit (cudaPackages) cuda_nvcc cuda_cudart backendStdenv;
  ptxas = "${cuda_nvcc}/bin/ptxas";
in
buildPythonPackage {
  inherit pname version;

  format = "setuptools";

  src = fetchFromGitHub {
    owner = "openai";
    repo = pname;
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
  ''
  # A typo in setup.py?
  # NOTE: Ok, now I'm disabling setuptools check anyway
  # + ''
  #   substituteInPlace python/setup.py \
  #     --replace '"tests"' '"test"'
  # ''
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
    sed -i '/LINK_LIBS/i NVPTXInfo' lib/Target/PTX/CMakeLists.txt
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
  ''
  +
  (
    let
      # Bash was getting weird without linting,
      # but basically upstream contains [cc, ..., "-lcuda", ...]
      # and we replace it with [..., "-lcuda", "-L/run/opengl-driver/lib", "-L$stubs", ...]
      old = [ "-lcuda" ];
      new = [ "-lcuda" "-L${addOpenGLRunpath.driverLink}" "-L${cuda_cudart}/lib/stubs/" ];

      quote = x: ''"${x}"'';
      oldStr = lib.concatMapStringsSep ", " quote old;
      newStr = lib.concatMapStringsSep ", " quote new;
    in
    ''
      substituteInPlace python/triton/compiler.py \
        --replace '${oldStr}' '${newStr}'
    ''
  )
  # Triton seems to be looking up cuda.h
  + ''
    sed -i 's|cu_include_dir = os.path.join.*$|cu_include_dir = "${cuda_cudart}/include"|' python/triton/compiler.py
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
    pythonRelaxDepsHook
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

  # Avoid GLIBCXX mismatch with other cuda-enabled python packages
  preConfigure =
    ''
      export CC="${backendStdenv.cc}/bin/cc";
      export CXX="${backendStdenv.cc}/bin/c++";
    ''
    # Upstream's setup.py tries to write cache somewhere in ~/
    + ''
      export HOME=$PWD
    ''
    # Upstream's github actions patch setup.cfg to write base-dir. May be redundant
    + ''
      echo "" >> python/setup.cfg
      echo "[build_ext]" >> python/setup.cfg
      echo "base-dir=$PWD" >> python/setup.cfg
    ''
    # The rest (including buildPhase) is relative to ./python/
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

  postFixup =
    let
      ptxasDestination = "$out/${python.sitePackages}/triton/third_party/cuda/bin/ptxas";
    in
    # Setuptools (?) strips runpath and +x flags. Let's just restore the symlink
    ''
      rm -f ${ptxasDestination}
      ln -s ${ptxas} ${ptxasDestination}
    '';

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

  pythonRemoveDeps = [
    # Circular dependency, cf. https://github.com/openai/triton/issues/1374
    "torch"

    # CLI tools without dist-info
    "cmake"
    "lit"
  ];

  meta = with lib; {
    description = "Development repository for the Triton language and compiler";
    homepage = "https://github.com/openai/triton/";
    platforms = lib.platforms.unix;
    license = licenses.mit;
    maintainers = with maintainers; [ ];
  };
}
