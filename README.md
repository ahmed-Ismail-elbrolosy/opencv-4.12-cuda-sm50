# OpenCV 4.12 with CUDA 12.9 for Maxwell

Traceable, timestamp-normalized native Ubuntu 26.04 build of OpenCV 4.12.0 and
opencv_contrib for the Quadro M1200 (`sm_50`). The workflow does not use a
container or an Ubuntu 24.04 repository. Exact runner and APT package versions
are recorded because the preview runner image and Ubuntu repositories evolve.

## Pinned Inputs

- Runner: native GitHub-hosted `ubuntu-26.04` x64 image
- OpenCV: `49486f61fb25722cbcf586b7f4320921d46fb38e`
- opencv_contrib: `d943e1d61c8bc556a13783e1546ee7c1a9e0b1cf`
- CUDA: 12.9 Update 1, NVCC 12.9.86
- CUDA runfile MD5: `a52d6c204bd4268627dfdab8bfeeb0d1`
- CUDA host compiler: GCC/G++ 14
- Install prefix: `/opt/opencv-4.12.0-cuda12.9-sm50`

The build enables CUDA, cuBLAS, cuFFT, GStreamer, V4L2, FFmpeg, GTK3, TBB,
and Python 3.14. cuDNN, NVCUVID/NVCUVENC, tests, examples, Java, and static
libraries are disabled.

## Build

Run the `Build OpenCV 4.12 CUDA sm_50` workflow manually. It produces:

- `opencv-cuda-sm50_4.12.0+cuda12.9-1_amd64.deb`
- `opencv-cuda-sm50-4.12.0+cuda12.9-1-amd64.tar.zst`
- `SHA256SUMS`
- `build-manifest.json`
- `provenance.intoto.json`
- `BUILD-INFO.txt`
- `APT-PACKAGES.txt`

The local provenance statement is digest-bound build metadata, not a signature.
GitHub attestations for private repositories require GitHub Enterprise Cloud.
If the repository is eligible, set the repository variable
`ENABLE_GITHUB_ATTESTATION` to `true`; a separate least-privilege job will then
attest the package checksums and upload the Sigstore bundle.

## Install

The Debian package is deliberately isolated from Ubuntu's OpenCV packages:

```bash
sudo apt install ./opencv-cuda-sm50_4.12.0+cuda12.9-1_amd64.deb
```

CUDA 12.9 must exist at `/home/orca/.local/cuda-12.9`. To use the Python module:

```bash
export PYTHONPATH=/opt/opencv-4.12.0-cuda12.9-sm50/lib/python3.14/site-packages
python3 -c 'import cv2; print(cv2.getBuildInformation())'
```

No global OpenCV or CUDA compatibility links are created.
