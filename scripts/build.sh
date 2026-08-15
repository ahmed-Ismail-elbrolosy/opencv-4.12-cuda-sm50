#!/usr/bin/env bash
set -euo pipefail

readonly OPENCV_COMMIT="49486f61fb25722cbcf586b7f4320921d46fb38e"
readonly CONTRIB_COMMIT="d943e1d61c8bc556a13783e1546ee7c1a9e0b1cf"
readonly CUDA_VERSION="12.9.1"
readonly CUDA_RUNFILE="cuda_12.9.1_575.57.08_linux.run"
readonly CUDA_URL="https://developer.download.nvidia.com/compute/cuda/12.9.1/local_installers/${CUDA_RUNFILE}"
readonly CUDA_MD5="a52d6c204bd4268627dfdab8bfeeb0d1"
readonly LIBXML_VERSION="2.13.9"
readonly LIBXML_SHA256="a2c9ae7b770da34860050c309f903221c67830c86e4a7e760692b803df95143a"
readonly PREFIX="/opt/opencv-4.12.0-cuda12.9-sm50"
readonly PACKAGE_VERSION="4.12.0+cuda12.9-1"

readonly ROOT_DIR="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
readonly WORK_DIR="${RUNNER_TEMP:?RUNNER_TEMP is required}/opencv-cuda-build"
readonly CUDA_ROOT="${HOME}/cuda-12.9"
readonly SOURCE_DIR="${WORK_DIR}/src"
readonly BUILD_DIR="${WORK_DIR}/build"
readonly STAGE_DIR="${WORK_DIR}/stage"
readonly DIST_DIR="${ROOT_DIR}/dist"

assert_runner() {
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID}" != "ubuntu" || "${VERSION_ID}" != "26.04" || "$(uname -m)" != "x86_64" ]]; then
        printf 'Expected native Ubuntu 26.04 x86_64, got %s %s %s\n' \
            "${ID}" "${VERSION_ID}" "$(uname -m)" >&2
        exit 1
    fi
}

free_runner_space() {
    # The CUDA runfile needs about 26 GiB at peak. These hosted-runner caches
    # are unrelated to this native C++ build and are recreated with every VM.
    sudo rm -rf \
        /opt/ghc \
        /opt/hostedtoolcache/CodeQL \
        /usr/local/.ghcup \
        /usr/local/lib/android \
        /usr/share/dotnet
    df -h /
}

install_dependencies() {
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends \
        build-essential gcc-14 g++-14 gfortran-14 git cmake ninja-build \
        pkg-config python3.14-dev python3-numpy \
        libgtk-3-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
        libv4l-dev libavcodec-dev libavformat-dev libavutil-dev \
        libavdevice-dev libswscale-dev libjpeg-dev libpng-dev libtiff-dev \
        libwebp-dev libopenjp2-7-dev libopenexr-dev zlib1g-dev libtbb-dev \
        libeigen3-dev libopenblas-dev liblapacke-dev libdc1394-dev \
        patchelf zstd xz-utils dpkg-dev file curl ca-certificates
}

build_installer_libxml() {
    local archive="${WORK_DIR}/libxml2-${LIBXML_VERSION}.tar.xz"
    local source="${WORK_DIR}/libxml2-${LIBXML_VERSION}"
    local prefix="${WORK_DIR}/libxml2-compat"

    curl -fsSL -o "${archive}" \
        "https://download.gnome.org/sources/libxml2/2.13/libxml2-${LIBXML_VERSION}.tar.xz"
    printf '%s  %s\n' "${LIBXML_SHA256}" "${archive}" | sha256sum --check --strict
    tar -C "${WORK_DIR}" -xf "${archive}"
    (
        cd "${source}"
        ./configure --prefix="${prefix}" --without-python --without-lzma --without-zlib
        make -j"$(nproc)"
        make install
    )
}

install_cuda() {
    local runfile="${WORK_DIR}/${CUDA_RUNFILE}"
    local payload="${WORK_DIR}/cuda-payload"
    local temp_dir="${WORK_DIR}/cuda-tmp"
    local compat_lib="${WORK_DIR}/libxml2-compat/lib"

    curl -fL --retry 5 --retry-delay 5 -o "${runfile}" "${CUDA_URL}"
    printf '%s  %s\n' "${CUDA_MD5}" "${runfile}" | md5sum --check --strict
    sha256sum "${runfile}" | cut -d' ' -f1 > "${WORK_DIR}/cuda-runfile.sha256"
    chmod u+x "${runfile}"
    mkdir -p "${temp_dir}"
    "${runfile}" --nox11 --keep --noexec --target "${payload}" --tmpdir="${temp_dir}"

    (
        cd "${payload}"
        LD_LIBRARY_PATH="${compat_lib}" \
        CC=/usr/bin/gcc-14 \
        CXX=/usr/bin/g++-14 \
            ./cuda-installer --silent --toolkit --toolkitpath="${CUDA_ROOT}" \
            --no-man-page --override
    )

    "${CUDA_ROOT}/bin/nvcc" --version
    rm -rf "${runfile}" "${payload}" "${temp_dir}" \
        "${WORK_DIR}/libxml2-${LIBXML_VERSION}" \
        "${WORK_DIR}/libxml2-${LIBXML_VERSION}.tar.xz" \
        "${WORK_DIR}/libxml2-compat"
    df -h /
}

checkout_sources() {
    mkdir -p "${SOURCE_DIR}"
    git init "${SOURCE_DIR}/opencv"
    git -C "${SOURCE_DIR}/opencv" remote add origin https://github.com/opencv/opencv.git
    git -C "${SOURCE_DIR}/opencv" fetch --depth=1 origin "${OPENCV_COMMIT}"
    git -C "${SOURCE_DIR}/opencv" checkout --detach FETCH_HEAD

    git init "${SOURCE_DIR}/opencv_contrib"
    git -C "${SOURCE_DIR}/opencv_contrib" remote add origin https://github.com/opencv/opencv_contrib.git
    git -C "${SOURCE_DIR}/opencv_contrib" fetch --depth=1 origin "${CONTRIB_COMMIT}"
    git -C "${SOURCE_DIR}/opencv_contrib" checkout --detach FETCH_HEAD

    [[ "$(git -C "${SOURCE_DIR}/opencv" rev-parse HEAD)" == "${OPENCV_COMMIT}" ]]
    [[ "$(git -C "${SOURCE_DIR}/opencv_contrib" rev-parse HEAD)" == "${CONTRIB_COMMIT}" ]]
    export SOURCE_DATE_EPOCH
    SOURCE_DATE_EPOCH="$(git -C "${SOURCE_DIR}/opencv" show -s --format=%ct HEAD)"
}

configure_and_build() {
    local python_include python_library numpy_include
    python_include="$(python3.14 -c 'import sysconfig; print(sysconfig.get_path("include"))')"
    python_library="$(python3.14 -c 'import os, sysconfig; print(os.path.join(sysconfig.get_config_var("LIBDIR"), sysconfig.get_config_var("LDLIBRARY")))')"
    numpy_include="$(python3.14 -c 'import numpy; print(numpy.get_include())')"

    export CC=/usr/bin/gcc-14
    export CXX=/usr/bin/g++-14
    export CUDAHOSTCXX=/usr/bin/g++-14

    cmake -S "${SOURCE_DIR}/opencv" -B "${BUILD_DIR}" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_C_COMPILER=/usr/bin/gcc-14 \
        -DCMAKE_CXX_COMPILER=/usr/bin/g++-14 \
        -DCMAKE_INSTALL_RPATH="${PREFIX}/lib;/home/orca/.local/cuda-12.9/lib64" \
        -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=FALSE \
        -DOPENCV_EXTRA_MODULES_PATH="${SOURCE_DIR}/opencv_contrib/modules" \
        -DOPENCV_GENERATE_PKGCONFIG=ON \
        -DBUILD_SHARED_LIBS=ON \
        -DENABLE_CUDA_FIRST_CLASS_LANGUAGE=OFF \
        -DWITH_CUDA=ON \
        -DCUDA_TOOLKIT_ROOT_DIR="${CUDA_ROOT}" \
        -DCUDA_NVCC_EXECUTABLE="${CUDA_ROOT}/bin/nvcc" \
        -DCUDA_HOST_COMPILER=/usr/bin/g++-14 \
        -DCUDA_ARCH_BIN=5.0 \
        -DCUDA_ARCH_PTX= \
        "-DCUDA_NVCC_FLAGS=-I${ROOT_DIR}/compat/glibc-cuda-12.9" \
        -DWITH_CUBLAS=ON \
        -DWITH_CUFFT=ON \
        -DWITH_CUDNN=OFF \
        -DOPENCV_DNN_CUDA=OFF \
        -DWITH_NVCUVID=OFF \
        -DWITH_NVCUVENC=OFF \
        -DWITH_GSTREAMER=ON \
        -DWITH_V4L=ON \
        -DWITH_FFMPEG=ON \
        -DWITH_GTK=ON \
        -DWITH_GTK_2_X=OFF \
        -DWITH_TBB=ON \
        -DWITH_QT=OFF \
        -DWITH_OPENGL=OFF \
        -DWITH_IPP=OFF \
        -DENABLE_BUILD_HARDENING=ON \
        -DBUILD_opencv_python3=ON \
        -DOPENCV_PYTHON3_VERSION=3.14 \
        -DPYTHON3_EXECUTABLE=/usr/bin/python3.14 \
        -DPYTHON3_INCLUDE_DIR="${python_include}" \
        -DPYTHON3_LIBRARY="${python_library}" \
        -DPYTHON3_NUMPY_INCLUDE_DIRS="${numpy_include}" \
        -DPYTHON3_PACKAGES_PATH=lib/python3.14/site-packages \
        -DBUILD_opencv_world=OFF \
        -DBUILD_opencv_apps=ON \
        -DBUILD_JAVA=OFF \
        -DBUILD_DOCS=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DBUILD_TESTS=OFF \
        -DBUILD_PERF_TESTS=OFF

    cmake --build "${BUILD_DIR}" --parallel "$(nproc)"
    DESTDIR="${STAGE_DIR}" cmake --install "${BUILD_DIR}"

    mkdir -p "${STAGE_DIR}/usr/share/doc/opencv-cuda-sm50"
    install -m 0644 "${SOURCE_DIR}/opencv/LICENSE" \
        "${STAGE_DIR}/usr/share/doc/opencv-cuda-sm50/LICENSE.opencv"
    install -m 0644 "${SOURCE_DIR}/opencv_contrib/LICENSE" \
        "${STAGE_DIR}/usr/share/doc/opencv-cuda-sm50/LICENSE.opencv_contrib"
}

verify_build() {
    local staged_prefix="${STAGE_DIR}${PREFIX}"
    local cuda_library="${staged_prefix}/lib/libopencv_cudaarithm.so.4.12.0"
    local python_path="${staged_prefix}/lib/python3.14/site-packages"

    "${BUILD_DIR}/bin/opencv_version" --verbose | tee "${DIST_DIR}/BUILD-INFO.txt"
    grep -Eq 'NVIDIA CUDA:[[:space:]]+YES' "${DIST_DIR}/BUILD-INFO.txt"
    grep -Eq 'NVIDIA GPU arch:[[:space:]]+50' "${DIST_DIR}/BUILD-INFO.txt"
    grep -Eq 'GStreamer:[[:space:]]+YES' "${DIST_DIR}/BUILD-INFO.txt"
    grep -Eq 'v4l/v4l2:[[:space:]]+YES' "${DIST_DIR}/BUILD-INFO.txt"
    grep -Eq 'FFMPEG:[[:space:]]+YES' "${DIST_DIR}/BUILD-INFO.txt"
    grep -Eq 'GUI:[[:space:]]+GTK3' "${DIST_DIR}/BUILD-INFO.txt"
    grep -Eq 'Parallel framework:[[:space:]]+TBB' "${DIST_DIR}/BUILD-INFO.txt"

    "${CUDA_ROOT}/bin/cuobjdump" --list-elf "${cuda_library}" | tee "${DIST_DIR}/CUDA-CUBINS.txt"
    grep -q 'sm_50.cubin' "${DIST_DIR}/CUDA-CUBINS.txt"
    readelf -d "${cuda_library}" | tee "${DIST_DIR}/CUDA-LIBRARY-DYNAMIC.txt"
    grep -Fq "${PREFIX}/lib" "${DIST_DIR}/CUDA-LIBRARY-DYNAMIC.txt"
    grep -Fq '/home/orca/.local/cuda-12.9/lib64' "${DIST_DIR}/CUDA-LIBRARY-DYNAMIC.txt"

    if LD_LIBRARY_PATH="${staged_prefix}/lib:${CUDA_ROOT}/lib64" ldd "${cuda_library}" | grep -q 'not found'; then
        printf 'Unresolved dependency in %s\n' "${cuda_library}" >&2
        exit 1
    fi

    PYTHONPATH="${python_path}" \
    LD_LIBRARY_PATH="${staged_prefix}/lib:${CUDA_ROOT}/lib64" \
        python3.14 -c 'import cv2; assert cv2.__version__ == "4.12.0"; print(cv2.__version__); print(cv2.cuda.getCudaEnabledDeviceCount())'
}

generate_dependencies() {
    local staged_prefix="${STAGE_DIR}${PREFIX}"
    local dependency_output
    local -a elf_files=()
    local candidate

    mkdir -p "${WORK_DIR}/debian"
    printf 'Source: opencv-cuda-sm50\n\nPackage: opencv-cuda-sm50\nArchitecture: amd64\n' \
        > "${WORK_DIR}/debian/control"

    while IFS= read -r -d '' candidate; do
        if file "${candidate}" | grep -q 'ELF'; then
            elf_files+=("${candidate}")
        fi
    done < <(find "${staged_prefix}" -type f -print0)

    dependency_output="$({
        cd "${WORK_DIR}"
        dpkg-shlibdeps --ignore-missing-info -O \
            -l"${staged_prefix}/lib" \
            -l"${CUDA_ROOT}/lib64" \
            -l"${CUDA_ROOT}/targets/x86_64-linux/lib" \
            "${elf_files[@]}"
    } 2> "${DIST_DIR}/dpkg-shlibdeps.log")"
    dependency_output="${dependency_output#shlibs:Depends=}"
    if [[ -n "${dependency_output}" ]]; then
        printf 'python3 (>= 3.14~), python3-numpy, %s\n' "${dependency_output}"
    else
        printf 'python3 (>= 3.14~), python3-numpy\n'
    fi
}

package_build() {
    local package_base="opencv-cuda-sm50_${PACKAGE_VERSION}_amd64"
    local tarball="${DIST_DIR}/opencv-cuda-sm50-${PACKAGE_VERSION}-amd64.tar.zst"
    local deb="${DIST_DIR}/${package_base}.deb"
    local dependencies installed_size

    dependencies="$(generate_dependencies)"
    installed_size="$(du -sk "${STAGE_DIR}${PREFIX}" | cut -f1)"

    tar --sort=name --owner=0 --group=0 --numeric-owner \
        --mtime="@${SOURCE_DATE_EPOCH}" --zstd -cf "${tarball}" \
        -C "${STAGE_DIR}" ./opt ./usr/share/doc/opencv-cuda-sm50

    mkdir -p "${STAGE_DIR}/DEBIAN"
    cat > "${STAGE_DIR}/DEBIAN/control" <<EOF
Package: opencv-cuda-sm50
Version: ${PACKAGE_VERSION}
Section: libs
Priority: optional
Architecture: amd64
Maintainer: A. Ismail Elbrolosy <113461435+ahmed-Ismail-elbrolosy@users.noreply.github.com>
Installed-Size: ${installed_size}
Depends: ${dependencies}
Description: OpenCV 4.12 with CUDA 12.9 for Maxwell sm_50
 Isolated OpenCV and opencv_contrib build for Ubuntu 26.04 with CUDA,
 GStreamer, V4L2, FFmpeg, GTK3, TBB, and Python 3.14 support.
 Requires CUDA 12.9 at /home/orca/.local/cuda-12.9.
EOF
    dpkg-deb --root-owner-group --build "${STAGE_DIR}" "${deb}"

    (
        cd "${DIST_DIR}"
        sha256sum --binary "$(basename "${deb}")" "$(basename "${tarball}")" > SHA256SUMS
        sha256sum --check SHA256SUMS
    )
}

write_manifest() {
    local runner_os
    # shellcheck disable=SC1091
    source /etc/os-release
    runner_os="${PRETTY_NAME}"

    jq -n \
        --arg opencv_commit "${OPENCV_COMMIT}" \
        --arg contrib_commit "${CONTRIB_COMMIT}" \
        --arg cuda_version "${CUDA_VERSION}" \
        --arg cuda_url "${CUDA_URL}" \
        --arg cuda_md5 "${CUDA_MD5}" \
        --arg cuda_sha256 "$(<"${WORK_DIR}/cuda-runfile.sha256")" \
        --arg libxml_version "${LIBXML_VERSION}" \
        --arg libxml_sha256 "${LIBXML_SHA256}" \
        --arg nvcc_version "$("${CUDA_ROOT}/bin/nvcc" --version | grep release | tr -s ' ')" \
        --arg runner_os "${runner_os}" \
        --arg runner_kernel "$(uname -r)" \
        --arg runner_image "${ImageVersion:-unknown}" \
        --arg prefix "${PREFIX}" \
        --arg python_version "$(python3.14 --version)" \
        --arg cmake_version "$(cmake --version | grep '^cmake version')" \
        --arg gcc_version "$(gcc-14 -dumpfullversion)" \
        '{
            schema: 1,
            sources: {opencv: $opencv_commit, opencv_contrib: $contrib_commit},
            cuda: {toolkit: $cuda_version, nvcc: $nvcc_version, architecture: "sm_50", url: $cuda_url, publishedMd5: $cuda_md5, observedSha256: $cuda_sha256},
            installerCompatibilityLibrary: {name: "libxml2", version: $libxml_version, sha256: $libxml_sha256, scope: "installer process only"},
            runner: {os: $runner_os, kernel: $runner_kernel, image: $runner_image},
            toolchain: {gcc: $gcc_version, cmake: $cmake_version, python: $python_version},
            install_prefix: $prefix,
            features: ["CUDA", "cuBLAS", "cuFFT", "GStreamer", "V4L2", "FFmpeg", "GTK3", "TBB", "Python 3.14"]
        }' > "${DIST_DIR}/build-manifest.json"
}

main() {
    assert_runner
    mkdir -p "${WORK_DIR}" "${DIST_DIR}"
    free_runner_space
    install_dependencies
    build_installer_libxml
    install_cuda
    checkout_sources
    configure_and_build
    verify_build
    package_build
    write_manifest
    dpkg-query -W -f='${binary:Package}\t${Version}\n' | sort > "${DIST_DIR}/APT-PACKAGES.txt"
    if [[ -f "${BUILD_DIR}/CMakeDownloadLog.txt" ]]; then
        cp "${BUILD_DIR}/CMakeDownloadLog.txt" "${DIST_DIR}/CMakeDownloadLog.txt"
    fi
    df -h /
}

main "$@"
