FROM alpine:3.20 AS builder

RUN apk add --no-cache \
  git cmake ninja make gperf build-base \
  linux-headers binutils patchelf upx \
  curl autoconf libtool automake sed perl

WORKDIR /deps/jemalloc
RUN curl -sSL https://github.com/jemalloc/jemalloc/releases/download/5.3.0/jemalloc-5.3.0.tar.bz2 -o jemalloc.tar.bz2 && \
    tar --strip-components=1 -xjf jemalloc.tar.bz2 && \
    ./configure --disable-shared --enable-static --with-pic && \
    make -j$(nproc) && make install

WORKDIR /deps/zlib
RUN curl -sSL https://zlib.net/zlib-1.3.1.tar.gz -o zlib.tar.gz && \
    tar --strip-components=1 -xzf zlib.tar.gz && \
    ./configure --static && \
    make -j$(nproc) && make install

WORKDIR /deps/openssl
RUN curl -sSL https://www.openssl.org/source/openssl-1.1.1w.tar.gz -o openssl.tar.gz && \
    tar --strip-components=1 -xzf openssl.tar.gz && \
    ./Configure linux-x86_64 \
      no-shared no-dso no-hw no-engine no-async no-tests no-pinshared \
      -fPIC -static \
      --prefix=/usr/local \
      --openssldir=/etc/ssl && \
    make -j$(nproc) && make install_sw

ENV CFLAGS="-Os -flto -ffunction-sections -fdata-sections -fomit-frame-pointer -fno-stack-protector -march=x86-64 -mtune=generic -DNDEBUG -DTD_HAVE_ATOMIC=1"
ENV CXXFLAGS="$CFLAGS -fno-rtti -fno-exceptions -fvisibility-inlines-hidden -std=c++17"
ENV LDFLAGS="-static -flto -Wl,--gc-sections -Wl,--strip-all -Wl,--as-needed -Wl,-z,norelro -Wl,-z,now -Wl,--build-id=none -L/usr/local/lib -lssl -lcrypto -ldl -lpthread -lz -ljemalloc"

WORKDIR /src
RUN git clone --recursive --depth=1 https://github.com/tdlight-team/tdlight-telegram-bot-api.git .

RUN sed -i '1i#define TD_OPTIMIZE_MEMORY 1\n#define TD_REQUEST_TIMEOUT 30\n#define TD_MAX_PENDING_UPDATES 50\n' telegram-bot-api/Client.cpp
RUN sed -i '4iadd_definitions(-DTD_OPTIMIZE_MEMORY=1 -DTD_MAX_PENDING_UPDATES=50 -DTD_REQUEST_TIMEOUT=30 -DTD_HAVE_ATOMIC=1 -DNDEBUG)\n' CMakeLists.txt

WORKDIR /src/build
RUN cmake .. \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="$CFLAGS" \
  -DCMAKE_CXX_FLAGS="$CXXFLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS" \
  -DCMAKE_FIND_LIBRARY_SUFFIXES=".a" \
  -DZLIB_LIBRARY=/usr/local/lib/libz.a \
  -DZLIB_INCLUDE_DIR=/usr/local/include \
  -DOPENSSL_CRYPTO_LIBRARY=/usr/local/lib/libcrypto.a \
  -DOPENSSL_SSL_LIBRARY=/usr/local/lib/libssl.a \
  -DOPENSSL_INCLUDE_DIR=/usr/local/include \
  -DOPENSSL_USE_STATIC_LIBS=TRUE \
  -DJEMALLOC_LIBRARY=/usr/local/lib/libjemalloc.a \
  -DJEMALLOC_INCLUDE_DIR=/usr/local/include \
  -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON \
  -DCMAKE_POLICY_DEFAULT_CMP0069=NEW \
  -DBUILD_SHARED_LIBS=OFF

RUN ninja -j$(nproc) telegram-bot-api
RUN strip --strip-all telegram-bot-api
RUN tar xvf telegram-bot-api.tar.gz telegram-bot-api

FROM scratch
COPY --from=builder /src/build/telegram-bot-api.tar.gz /telegram-bot-api.tar.gz
