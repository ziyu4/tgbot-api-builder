FROM alpine:3.20 AS base
RUN apk add --no-cache --virtual .build-deps \
    build-base yasm nasm autoconf automake cmake git libtool \
    pkgconfig pkgconf ca-certificates wget meson ninja curl \
    libogg-dev fontconfig-dev zlib-dev curl-dev musl-dev \
    diffutils gperf gettext gettext-dev

ENV PREFIX="/usr/local"
ENV PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib/x86_64-linux-gnu/pkgconfig"
ENV CFLAGS="-O3 -march=znver2 -mtune=znver2 -flto -ffunction-sections -fdata-sections -fomit-frame-pointer -fPIC"
ENV CXXFLAGS="$CFLAGS"
ENV LDFLAGS="-static -flto"

FROM base AS build-core

WORKDIR /build/zlib
RUN curl -sSL https://zlib.net/zlib-1.3.1.tar.gz -o zlib.tar.gz && \
    tar --strip-components=1 -xzf zlib.tar.gz && \
    ./configure --prefix=$PREFIX --static && make -j$(nproc) && make install

# Build libogg first (required by libvorbis)
WORKDIR /build/libogg
RUN wget https://downloads.xiph.org/releases/ogg/libogg-1.3.6.tar.gz && \
    tar xzf libogg-1.3.6.tar.gz --strip-components=1 && \
    ./configure --prefix=$PREFIX --disable-shared --enable-static \
    CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" && \
    make -j$(nproc) && make install

# Build libvorbis (depends on libogg)
WORKDIR /build/libvorbis
RUN wget https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.gz && \
    tar xzf libvorbis-1.3.7.tar.gz --strip-components=1 && \
    ./configure --prefix=$PREFIX --disable-shared --enable-static \
    --with-ogg=$PREFIX \
    CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" \
    PKG_CONFIG_PATH="$PKG_CONFIG_PATH" && \
    make -j$(nproc) && make install

# Verify vorbis pkg-config files
RUN ls -la $PREFIX/lib/pkgconfig/vorbis* && \
    pkg-config --exists vorbis && \
    pkg-config --exists vorbisenc && \
    echo "Vorbis libraries found successfully"

WORKDIR /build/libvpx
RUN rm -rf * && \
    git clone --depth=1 https://chromium.googlesource.com/webm/libvpx . && \
    LDFLAGS="-lpthread" ./configure --prefix=$PREFIX \
      --disable-examples --disable-unit-tests --disable-tools --disable-docs \
      --enable-vp8 --enable-vp9 --enable-vp9-highbitdepth \
      --enable-static --disable-shared --enable-pic \
      --as=yasm \
      --disable-runtime-cpu-detect \
      --enable-postproc \
      --enable-vp9-postproc \
      --extra-cflags="$CFLAGS" && \
    make clean && make -j$(nproc) LDFLAGS="-lpthread" && make install

WORKDIR /build/xvidcore
RUN wget https://downloads.xvid.com/downloads/xvidcore-1.3.7.tar.gz && \
    tar xzf xvidcore-1.3.7.tar.gz && \
    cd xvidcore/build/generic && \
    ./configure --prefix=$PREFIX --disable-shared --enable-static CFLAGS="$CFLAGS" && \
    make -j$(nproc) libxvidcore.a && \
    LIBXVIDCORE_A=$(find . -name 'libxvidcore.a' | head -n1) && \
    install -d $PREFIX/lib $PREFIX/include/xvid && \
    install -m644 "$LIBXVIDCORE_A" $PREFIX/lib/ && \
    cp -r ../../src/* $PREFIX/include/xvid/
    
# Create xvid pkg-config file
RUN echo "prefix=$PREFIX" > $PREFIX/lib/pkgconfig/xvid.pc && \
    echo "exec_prefix=\${prefix}" >> $PREFIX/lib/pkgconfig/xvid.pc && \
    echo "libdir=\${exec_prefix}/lib" >> $PREFIX/lib/pkgconfig/xvid.pc && \
    echo "includedir=\${prefix}/include" >> $PREFIX/lib/pkgconfig/xvid.pc && \
    echo "" >> $PREFIX/lib/pkgconfig/xvid.pc && \
    echo "Name: xvid" >> $PREFIX/lib/pkgconfig/xvid.pc && \
    echo "Description: Xvid MPEG-4 video codec" >> $PREFIX/lib/pkgconfig/xvid.pc && \
    echo "Version: 1.3.7" >> $PREFIX/lib/pkgconfig/xvid.pc && \
    echo "Libs: -L\${libdir} -lxvidcore" >> $PREFIX/lib/pkgconfig/xvid.pc && \
    echo "Cflags: -I\${includedir}/xvid" >> $PREFIX/lib/pkgconfig/xvid.pc

WORKDIR /build/x264
RUN git clone --depth=1 https://code.videolan.org/videolan/x264.git . && \
    apk add --no-cache bash perl && \
    sed -i '1s|^.*$|#!/bin/bash|' configure && chmod +x configure && \
    bash configure --prefix=$PREFIX --enable-static --disable-opencl --disable-cli --enable-pic \
    --extra-cflags="$CFLAGS -DHAVE_MALLOC_H=1" --extra-ldflags="$LDFLAGS" && \
    make -j$(nproc) && make install

WORKDIR /build/x265
RUN git clone https://bitbucket.org/multicoreware/x265_git . && \
    cd build/linux && \
    cmake -G "Unix Makefiles" ../../source \
    -DCMAKE_INSTALL_PREFIX=$PREFIX -DENABLE_SHARED=OFF -DENABLE_CLI=OFF \
    -DENABLE_ASSEMBLY=ON -DHIGH_BIT_DEPTH=ON -DMAIN12=ON -DENABLE_HDR10_PLUS=ON \
    -DCMAKE_C_FLAGS="$CFLAGS" -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS" && \
    make -j$(nproc) && make install

WORKDIR /build/aom
RUN git clone --depth=1 https://aomedia.googlesource.com/aom . && \
    mkdir -p build && cd build && \
    cmake .. -DCMAKE_INSTALL_PREFIX=$PREFIX -DCMAKE_BUILD_TYPE=Release \
    -DCONFIG_RUNTIME_CPU_DETECT=OFF -DAOM_TARGET_CPU=znver2 -DENABLE_SHARED=OFF \
    -DCMAKE_C_FLAGS="$CFLAGS" -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON && \
    make -j$(nproc) && make install

WORKDIR /build/fdk-aac
RUN git clone --depth=1 https://github.com/mstorsjo/fdk-aac.git . && \
    autoreconf -fiv && \
    ./configure --prefix=$PREFIX --disable-shared --enable-static \
    CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" && \
    make -j$(nproc) && make install

WORKDIR /build/lame
RUN wget https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz && \
    tar xzf lame-3.100.tar.gz --strip-components=1 && \
    ./configure --prefix=$PREFIX --disable-shared --enable-static --enable-nasm \
    CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" && \
    make -j$(nproc) && make install

# Create lame pkg-config file
RUN echo "prefix=$PREFIX" > $PREFIX/lib/pkgconfig/mp3lame.pc && \
    echo "exec_prefix=\${prefix}" >> $PREFIX/lib/pkgconfig/mp3lame.pc && \
    echo "libdir=\${exec_prefix}/lib" >> $PREFIX/lib/pkgconfig/mp3lame.pc && \
    echo "includedir=\${prefix}/include" >> $PREFIX/lib/pkgconfig/mp3lame.pc && \
    echo "" >> $PREFIX/lib/pkgconfig/mp3lame.pc && \
    echo "Name: lame" >> $PREFIX/lib/pkgconfig/mp3lame.pc && \
    echo "Description: LAME MP3 encoder" >> $PREFIX/lib/pkgconfig/mp3lame.pc && \
    echo "Version: 3.100" >> $PREFIX/lib/pkgconfig/mp3lame.pc && \
    echo "Libs: -L\${libdir} -lmp3lame" >> $PREFIX/lib/pkgconfig/mp3lame.pc && \
    echo "Cflags: -I\${includedir}/lame" >> $PREFIX/lib/pkgconfig/mp3lame.pc

WORKDIR /build/libwebp
RUN git clone --depth=1 https://github.com/webmproject/libwebp.git . && \
    ./autogen.sh && \
    ./configure --prefix=$PREFIX \
      --disable-shared \
      --enable-static \
      CFLAGS="$CFLAGS -I$PREFIX/include" \
      LDFLAGS="$LDFLAGS -L$PREFIX/lib" && \
    make -j$(nproc) && make install

RUN echo "=== Patching FFmpeg configure to force libvpx detection ===" && \
    cp configure configure.orig && \
    sed -i '/check_lib libvpx "vpx\/vpx_decoder.h vpx\/vp8dx.h vpx\/vp8cx.h" vpx_codec_version -lvpx/c\
enabled libvpx && echo "libvpx enabled (forced)" || die "ERROR: libvpx not found"' configure && \
    echo 'enable libvpx' >> configure && \
    echo 'add_extralibs -lvpx -lm' >> configure

WORKDIR /build/ffmpeg
RUN git clone --depth=1 https://github.com/FFmpeg/FFmpeg.git .

RUN PKG_CONFIG="pkg-config --static" ./configure \
    --prefix=$PREFIX \
    --pkg-config-flags="--static" \
    --enable-gpl --enable-version3 --enable-nonfree \
    --enable-static --disable-shared \
    --disable-debug --disable-doc \
    --disable-ffplay --disable-ffprobe \
    --enable-libx264 --enable-libx265 \
    --enable-libvpx \
    --enable-libaom \
    --enable-libfdk-aac --enable-libmp3lame \
    --enable-libvorbis --enable-libxvid \
    --enable-lto --enable-avx2 \
    --enable-fma3 --enable-libwebp \
    --enable-inline-asm --enable-x86asm \
    --extra-cflags="$CFLAGS -mavx2 -mfma -I$PREFIX/include" \
    --extra-ldflags="$LDFLAGS -L$PREFIX/lib" \
    --extra-libs="-lpthread -lm -lz" 

RUN make -j$(nproc) && make install && strip $PREFIX/bin/ffmpeg

FROM scratch
COPY --from=build-core /usr/local/bin/ffmpeg /ffmpeg
