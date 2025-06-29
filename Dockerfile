FROM alpine:3.20 AS base
RUN apk add --no-cache --virtual .build-deps \
    build-base yasm nasm autoconf automake cmake git libtool \
    pkgconfig ca-certificates wget meson ninja curl \
    libogg-dev fontconfig-dev zlib-dev curl-dev musl-dev \
    diffutils

ENV PREFIX="/ffmpeg_build"
ENV PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
ENV CFLAGS="-O3 -march=znver2 -mtune=znver2 -flto -ffunction-sections -fdata-sections -fomit-frame-pointer"
ENV CXXFLAGS="$CFLAGS"
ENV LDFLAGS="-static -flto -Wl,--gc-sections"
ENV OMP_NUM_THREADS=$(nproc)
ENV MKL_NUM_THREADS=$(nproc)

FROM base AS performance-core

WORKDIR /build/zlib
RUN curl -sSL https://zlib.net/zlib-1.3.1.tar.gz -o zlib.tar.gz && \
      tar --strip-components=1 -xzf zlib.tar.gz && \
      ./configure --prefix=$PREFIX --static && \
      CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" && make -j$(nproc) && make install

WORKDIR /build/x264
RUN git clone --depth=1 https://code.videolan.org/videolan/x264.git .
RUN apk add --no-cache bash perl && \
    file configure && \
    sed -i '1s|^.*$|#!/bin/bash|' configure && \
    chmod +x configure && \
    bash configure --prefix=$PREFIX --enable-static --disable-opencl --disable-cli \
    --enable-pic --bit-depth=all \
    --extra-cflags="$CFLAGS -DHAVE_MALLOC_H=1" --extra-ldflags="$LDFLAGS"
RUN make -j$(nproc) && make install

WORKDIR /build/x265
RUN git clone https://bitbucket.org/multicoreware/x265_git .
WORKDIR /build/x265/build/linux
RUN cmake -G "Unix Makefiles" ../../source \
  -DCMAKE_INSTALL_PREFIX=$PREFIX \
  -DENABLE_SHARED=OFF -DENABLE_CLI=OFF \
  -DENABLE_ASSEMBLY=ON -DHIGH_BIT_DEPTH=ON \
  -DMAIN12=ON -DENABLE_HDR10_PLUS=ON \
  -DCMAKE_C_FLAGS="$CFLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS"
RUN make -j$(nproc) && make install

WORKDIR /build/libvpx
RUN git clone --depth=1 https://chromium.googlesource.com/webm/libvpx .
RUN ./configure --prefix=$PREFIX --disable-examples --disable-unit-tests --enable-vp9-highbitdepth \
  --as=yasm --enable-vp8 --enable-vp9 --enable-static --disable-shared --enable-pic \
  --extra-cflags="$CFLAGS"
RUN make -j$(nproc) && make install

WORKDIR /build/aom
RUN git clone --depth=1 https://aomedia.googlesource.com/aom .
WORKDIR /build/aom/build
RUN cmake .. \
  -DCMAKE_INSTALL_PREFIX=$PREFIX \
  -DCMAKE_BUILD_TYPE=Release \
  -DCONFIG_RUNTIME_CPU_DETECT=OFF \
  -DAOM_TARGET_CPU=znver2 \
  -DENABLE_SHARED=OFF \
  -DCMAKE_C_FLAGS="$CFLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS" \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON
RUN make -j$(nproc) && make install

WORKDIR /build/fdk-aac
RUN git clone --depth=1 https://github.com/mstorsjo/fdk-aac.git .
RUN autoreconf -fiv && ./configure --prefix=$PREFIX --disable-shared --enable-static \
  CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS"
RUN make -j$(nproc) && make install

WORKDIR /build/lame
RUN wget https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz
RUN tar xzf lame-3.100.tar.gz --strip-components=1
RUN ./configure --prefix=$PREFIX --disable-shared --enable-static --enable-nasm \
  CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS"
RUN make -j$(nproc) && make install

WORKDIR /build/libogg
RUN wget https://downloads.xiph.org/releases/ogg/libogg-1.3.6.tar.gz
RUN tar xzf libogg-1.3.6.tar.gz --strip-components=1
RUN ./configure --prefix=$PREFIX --disable-shared --enable-static \
  CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS"
RUN make -j$(nproc) && make install

WORKDIR /build/libvorbis
RUN git clone --depth=1 https://github.com/xiph/vorbis.git .
RUN ./autogen.sh && ./configure --prefix=$PREFIX --disable-shared --enable-static \
  CFLAGS="$CFLAGS -Wno-error" LDFLAGS="$LDFLAGS"
RUN make -j$(nproc) && make install

WORKDIR /build/opus
RUN git clone --depth=1 https://github.com/xiph/opus.git .
RUN ./autogen.sh && ./configure --prefix=$PREFIX --disable-shared --enable-static \
  CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS"
RUN make -j$(nproc) && make install

WORKDIR /build/theora
RUN git clone --depth=1 https://github.com/xiph/theora.git .
RUN ./autogen.sh && \
    ./configure --prefix=$PREFIX --disable-shared --enable-static --disable-examples \
      CFLAGS="$CFLAGS -Wno-error" LDFLAGS="$LDFLAGS"
RUN make -j$(nproc) && make install
WORKDIR /build/xvidcore
RUN wget https://downloads.xvid.com/downloads/xvidcore-1.3.7.tar.gz
RUN tar xzf xvidcore-1.3.7.tar.gz
RUN cd xvidcore/build/generic && \
    ./configure --prefix=$PREFIX --disable-shared --enable-static CFLAGS="$CFLAGS -fPIC" && \
    make -j$(nproc) libxvidcore.a && \
    LIBXVIDCORE_A=$(find . -name 'libxvidcore.a' | head -n1) && \
    install -d $PREFIX/lib $PREFIX/include/xvid && \
    install -m644 "$LIBXVIDCORE_A" $PREFIX/lib/ && \
    cp -r ../../src/* $PREFIX/include/xvid/

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

FROM base AS support-core

WORKDIR /build/libwebp
RUN git clone --depth=1 https://github.com/webmproject/libwebp.git .
RUN ./autogen.sh && ./configure --prefix=$PREFIX --disable-shared --enable-static \
  CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" && make -j$(nproc) && make install

WORKDIR /build/fribidi
RUN wget https://github.com/fribidi/fribidi/releases/download/v1.0.16/fribidi-1.0.16.tar.xz
RUN tar -xf fribidi-1.0.16.tar.xz --strip-components=1
RUN ./configure --prefix=$PREFIX --disable-shared --enable-static --disable-docs \
  CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" && make -j$(nproc) && make install

WORKDIR /build/freetype
RUN git clone --depth=1 https://gitlab.freedesktop.org/freetype/freetype.git .
RUN ./autogen.sh && ./configure --prefix=$PREFIX --disable-shared --enable-static \
  CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" && make -j$(nproc) && make install
  
ENV PKG_CONFIG_PATH=$PREFIX/lib/x86_64-linux-gnu/pkgconfig:$PREFIX/lib/pkgconfig

WORKDIR /build/libpng
RUN wget https://download.sourceforge.net/libpng/libpng-1.6.43.tar.gz
RUN tar xzf libpng-1.6.43.tar.gz --strip-components=1
RUN export CFLAGS="$CFLAGS" && \
    export CPPFLAGS="-I$PREFIX/include" && \
    export LDFLAGS="-L$PREFIX/lib" && \
    export LIBS="-lz" && \
    ./configure \
      --prefix=$PREFIX \
      --disable-shared \
      --enable-static \
      --with-zlib-prefix=$PREFIX && \
    make LDFLAGS="-all-static" -j$(nproc) && make install

# Build Brotli with proper static linking
WORKDIR /build/brotli
RUN git clone --depth=1 https://github.com/google/brotli.git .
RUN mkdir out && cd out && \
    cmake -DCMAKE_INSTALL_PREFIX=$PREFIX \
          -DBUILD_SHARED_LIBS=OFF \
          -DCMAKE_C_FLAGS="$CFLAGS" \
          -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS" \
          -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
          .. && \
    make -j$(nproc) && make install

# Create proper pkg-config files for brotli if they don't exist
RUN if [ ! -f "$PREFIX/lib/pkgconfig/libbrotlidec.pc" ]; then \
    echo "prefix=/ffmpeg_build" > $PREFIX/lib/pkgconfig/libbrotlidec.pc && \
    echo "exec_prefix=\${prefix}" >> $PREFIX/lib/pkgconfig/libbrotlidec.pc && \
    echo "libdir=\${exec_prefix}/lib" >> $PREFIX/lib/pkgconfig/libbrotlidec.pc && \
    echo "includedir=\${prefix}/include" >> $PREFIX/lib/pkgconfig/libbrotlidec.pc && \
    echo "" >> $PREFIX/lib/pkgconfig/libbrotlidec.pc && \
    echo "Name: libbrotlidec" >> $PREFIX/lib/pkgconfig/libbrotlidec.pc && \
    echo "Description: Brotli decoder library" >> $PREFIX/lib/pkgconfig/libbrotlidec.pc && \
    echo "Version: 1.0.0" >> $PREFIX/lib/pkgconfig/libbrotlidec.pc && \
    echo "Libs: -L\${libdir} -lbrotlidec -lbrotlicommon" >> $PREFIX/lib/pkgconfig/libbrotlidec.pc && \
    echo "Cflags: -I\${includedir}" >> $PREFIX/lib/pkgconfig/libbrotlidec.pc; \
fi

RUN if [ ! -f "$PREFIX/lib/pkgconfig/libbrotlienc.pc" ]; then \
    echo "prefix=/ffmpeg_build" > $PREFIX/lib/pkgconfig/libbrotlienc.pc && \
    echo "exec_prefix=\${prefix}" >> $PREFIX/lib/pkgconfig/libbrotlienc.pc && \
    echo "libdir=\${exec_prefix}/lib" >> $PREFIX/lib/pkgconfig/libbrotlienc.pc && \
    echo "includedir=\${prefix}/include" >> $PREFIX/lib/pkgconfig/libbrotlienc.pc && \
    echo "" >> $PREFIX/lib/pkgconfig/libbrotlienc.pc && \
    echo "Name: libbrotlienc" >> $PREFIX/lib/pkgconfig/libbrotlienc.pc && \
    echo "Description: Brotli encoder library" >> $PREFIX/lib/pkgconfig/libbrotlienc.pc && \
    echo "Version: 1.0.0" >> $PREFIX/lib/pkgconfig/libbrotlienc.pc && \
    echo "Libs: -L\${libdir} -lbrotlienc -lbrotlicommon" >> $PREFIX/lib/pkgconfig/libbrotlienc.pc && \
    echo "Cflags: -I\${includedir}" >> $PREFIX/lib/pkgconfig/libbrotlienc.pc; \
fi

RUN sed -i 's|-lz|/ffmpeg_build/lib/libz.a|' $PREFIX/lib/pkgconfig/*.pc
RUN sed -i 's|-lpng16|/ffmpeg_build/lib/libpng16.a|' $PREFIX/lib/pkgconfig/*.pc

WORKDIR /build/harfbuzz
RUN git clone --depth=1 https://github.com/harfbuzz/harfbuzz.git .
RUN meson setup build \
  --prefix=$PREFIX \
  --default-library=static \
  --prefer-static \
  --buildtype=release \
  -Dtests=disabled \
  -Dbenchmark=disabled \
  -Dc_args="$CFLAGS" \
  -Dcpp_args="$CFLAGS"
RUN meson compile -C build && meson install -C build

WORKDIR /build/libass
RUN git clone --depth=1 https://github.com/libass/libass.git .
RUN ./autogen.sh && ./configure --prefix=$PREFIX --disable-shared --enable-static \
  CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" \
  --with-freetype-config=$PREFIX/bin/freetype-config
RUN make -j$(nproc) && make install

FROM base AS final-build
COPY --from=performance-core $PREFIX $PREFIX
COPY --from=support-core $PREFIX $PREFIX

RUN apk add --no-cache \
    build-base yasm nasm autoconf automake cmake git libtool \
    pkgconfig ca-certificates wget meson ninja curl \
    libogg-dev zlib-dev curl-dev musl-dev \
    diffutils gperf gettext gettext-dev

WORKDIR /build/expat
RUN wget https://github.com/libexpat/libexpat/releases/download/R_2_6_2/expat-2.6.2.tar.xz
RUN tar -xf expat-2.6.2.tar.xz --strip-components=1
RUN ./configure --prefix=$PREFIX --disable-shared --enable-static \
  CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS"
RUN make -j$(nproc) && make install
  
# Build fontconfig without brotli dependency
WORKDIR /build/fontconfig
RUN git clone --depth=1 https://gitlab.freedesktop.org/fontconfig/fontconfig.git .
RUN apk add --no-cache gettext gettext-dev

# Configure fontconfig, providing Brotli libs for its dependencies (like FreeType)
RUN ./autogen.sh && ./configure --prefix=$PREFIX --disable-shared --enable-static \
  --disable-brotli \
  --disable-cache-build \
  --with-add-fonts=/usr/share/fonts \
  CFLAGS="$CFLAGS -I$PREFIX/include" \
  LDFLAGS="$LDFLAGS -L$PREFIX/lib" \
  LIBS="-lexpat -lfreetype -lharfbuzz -lpng16 -lz -lfribidi -lbrotlidec -lbrotlicommon"

RUN make -j$(nproc) && make install

RUN ls -l $PREFIX/lib/pkgconfig/fontconfig.pc

WORKDIR /build/ffmpeg
RUN git clone --depth=1 https://github.com/FFmpeg/FFmpeg.git .

RUN export PKG_CONFIG_PATH="/ffmpeg_build/lib/pkgconfig" && \
  ./configure \
  --prefix=$PREFIX \
  --pkg-config-flags="--static" \
  --extra-cflags="$CFLAGS -mavx2 -mfma" \
  --extra-ldflags="$LDFLAGS -L/ffmpeg_build/lib" \
  --enable-gpl --enable-version3 --enable-nonfree \
  --enable-static --disable-shared \
  --disable-debug --disable-doc \
  --disable-ffplay --disable-ffprobe \
  --enable-libx264 --enable-libx265 \
  --enable-libvpx --enable-libaom \
  --enable-libfdk-aac --enable-libmp3lame \
  --extra-libs="-lmp3lame" \
  --enable-libvorbis --enable-libopus \
  --enable-libtheora --enable-libxvid \
  --enable-libwebp --enable-libass \
  --enable-avx2 --enable-fma3 \
  --enable-inline-asm --enable-x86asm
RUN make -j$(nproc) && make install && strip $PREFIX/bin/ffmpeg

FROM scratch
COPY --from=final-build /ffmpeg_build/bin/ffmpeg /ffmpeg