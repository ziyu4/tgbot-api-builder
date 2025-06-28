FROM debian:stable-slim AS base
RUN apt-get update && apt-get install -y --no-install-recommends \
  build-essential yasm nasm autoconf automake cmake git libtool \
  pkg-config ca-certificates wget meson ninja-build

ENV PREFIX="/ffmpeg_build"
ENV PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
ENV CFLAGS="-O3 -march=znver2 -mtune=znver2 -flto -ffunction-sections -fdata-sections -fomit-frame-pointer"
ENV CXXFLAGS="$CFLAGS"
ENV LDFLAGS="-static -flto -Wl,--gc-sections"

FROM base AS performance-core

WORKDIR /build/x264
RUN git clone --depth=1 https://code.videolan.org/videolan/x264.git .
RUN ./configure --prefix=$PREFIX --enable-static --disable-opencl --disable-cli \
  --extra-cflags="$CFLAGS" --extra-ldflags="$LDFLAGS"
RUN make -j$(nproc) && make install

WORKDIR /build/x265
RUN git clone https://bitbucket.org/multicoreware/x265_git .
WORKDIR /build/x265/build/linux
RUN cmake -G "Unix Makefiles" ../../source \
  -DCMAKE_INSTALL_PREFIX=$PREFIX \
  -DENABLE_SHARED=OFF -DENABLE_CLI=OFF \
  -DCMAKE_C_FLAGS="$CFLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS"
RUN make -j$(nproc) && make install

WORKDIR /build/libvpx
RUN git clone --depth=1 https://chromium.googlesource.com/webm/libvpx .
RUN ./configure --prefix=$PREFIX --disable-examples --disable-unit-tests --enable-vp9-highbitdepth \
  --as=yasm --enable-vp8 --enable-vp9 --enable-static --disable-shared \
  --extra-cflags="$CFLAGS"
RUN make -j$(nproc) && make install

WORKDIR /build/aom
RUN git clone --depth=1 https://aomedia.googlesource.com/aom .
WORKDIR /build/aom/build
RUN cmake .. \
  -DCMAKE_INSTALL_PREFIX=$PREFIX \
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
RUN ./configure --prefix=$PREFIX --disable-shared --enable-static \
  CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS"
RUN make -j$(nproc) && make install

WORKDIR /build/libvorbis
RUN git clone --depth=1 https://github.com/xiph/vorbis.git .
RUN ./autogen.sh && ./configure --prefix=$PREFIX --disable-shared --enable-static \
  CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS"
RUN make -j$(nproc) && make install

WORKDIR /build/opus
RUN git clone --depth=1 https://github.com/xiph/opus.git .
RUN ./autogen.sh && ./configure --prefix=$PREFIX --disable-shared --enable-static \
  CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS"
RUN make -j$(nproc) && make install

WORKDIR /build/theora
RUN git clone --depth=1 https://github.com/xiph/theora.git .
RUN ./autogen.sh && ./configure --prefix=$PREFIX --disable-shared --enable-static \
  CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS"
RUN make -j$(nproc) && make install

WORKDIR /build/xvidcore
RUN wget https://downloads.xvid.com/downloads/xvidcore-1.3.7.tar.gz
RUN tar xzf xvidcore-1.3.7.tar.gz && cd xvidcore/build/generic && \
  ./configure --prefix=$PREFIX --disable-shared --enable-static \
  CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" && make -j$(nproc) && make install

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

WORKDIR /build/harfbuzz
RUN git clone --depth=1 https://github.com/harfbuzz/harfbuzz.git .
RUN meson setup build --prefix=$PREFIX --default-library=static --buildtype=release \
  -Dc_args="$CFLAGS" -Dcpp_args="$CFLAGS"
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

WORKDIR /build/ffmpeg
RUN git clone --depth=1 https://github.com/FFmpeg/FFmpeg.git .
RUN ./configure \
  --prefix=$PREFIX \
  --pkg-config-flags="--static" \
  --extra-cflags="$CFLAGS" \
  --extra-ldflags="$LDFLAGS" \
  --enable-gpl \
  --enable-version3 \
  --enable-nonfree \
  --enable-static \
  --disable-shared \
  --disable-debug \
  --disable-doc \
  --disable-ffplay \
  --disable-ffprobe \
  --enable-libx264 \
  --enable-libx265 \
  --enable-libvpx \
  --enable-libaom \
  --enable-libfdk-aac \
  --enable-libmp3lame \
  --enable-libvorbis \
  --enable-libopus \
  --enable-libtheora \
  --enable-libxvid \
  --enable-libwebp \
  --enable-libass
RUN make -j$(nproc) && make install && strip $PREFIX/bin/ffmpeg

FROM scratch
COPY --from=final-build /ffmpeg_build/bin/ffmpeg /ffmpeg⏎
