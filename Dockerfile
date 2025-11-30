FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install build dependencies
RUN apt-get update && apt-get install -y \
    wget \
    git \
    autoconf \
    automake \
    libtool \
    m4 \
    pkg-config \
    build-essential \
    texinfo \
    musl-tools \
    && rm -rf /var/lib/apt/lists/*

# Set up working directory
WORKDIR /build

# Download and build musl (matching what build_musl.jai does)
RUN wget https://musl.libc.org/releases/musl-1.2.5.tar.gz \
    && tar xzf musl-1.2.5.tar.gz \
    && cd musl-1.2.5 \
    && ./configure \
        --enable-wrapper=no \
        --prefix=/build/musl-out \
        --enable-optimize=yes \
        --enable-debug=no \
        --disable-shared \
    && make -j$(nproc) \
    && mkdir -p /build/musl-out \
    && cp lib/crt1.o /build/musl-out/ \
    && cp lib/crti.o /build/musl-out/ \
    && cp lib/crtn.o /build/musl-out/ \
    && cp lib/libc.a /build/musl-out/ \
    && cd ..

# Build xz (liblzma) with musl
RUN wget https://tukaani.org/xz/xz-5.4.5.tar.gz \
    && tar xzf xz-5.4.5.tar.gz \
    && cd xz-5.4.5 \
    && CC=musl-gcc CFLAGS="-static -O2" ./configure \
        --prefix=/build/xz-output \
        --enable-static \
        --disable-shared \
        --disable-xz \
        --disable-xzdec \
        --disable-lzmadec \
        --disable-lzmainfo \
        --disable-scripts \
        --disable-doc \
    && make -j$(nproc) \
    && make install \
    && cd .. \
    && rm -rf xz-5.4.5 xz-5.4.5.tar.gz

# Build libunwind with musl (disable tests to avoid linking issues)
RUN git clone --depth 1 https://github.com/libunwind/libunwind.git libunwind-src \
    && cd libunwind-src \
    && mkdir -p m4 \
    && autoreconf -fi \
    && libtoolize \
    && CC=musl-gcc CFLAGS="-static -O2" ./configure \
        --prefix=/build/libunwind-output \
        --enable-static \
        --disable-shared \
        --disable-minidebuginfo \
        --disable-zlibdebuginfo \
        --disable-tests \
    && make -j$(nproc) \
    && make install \
    && cd .. \
    && rm -rf libunwind-src

# Build libbacktrace with musl
RUN git clone --depth 1 https://github.com/ianlancetaylor/libbacktrace.git libbacktrace-src \
    && cd libbacktrace-src \
    && CC=musl-gcc CFLAGS="-static -O2" ./configure \
        --prefix=/build/libbacktrace-output \
        --enable-static \
        --disable-shared \
    && make -j$(nproc) \
    && make install \
    && cd .. \
    && rm -rf libbacktrace-src

# Create the library directories expected by build.jai
# Combine libunwind.a and libunwind-x86_64.a into one archive
RUN mkdir -p xz libunwind libbacktrace libgcc \
    && cp xz-output/lib/liblzma.a xz/ \
    && cp libbacktrace-output/lib/libbacktrace.a libbacktrace/ \
    && mkdir -p /tmp/unwind-objs && cd /tmp/unwind-objs \
    && ar x /build/libunwind-output/lib/libunwind.a \
    && ar x /build/libunwind-output/lib/libunwind-x86_64.a \
    && ar rcs /build/libunwind/libunwind.a *.o \
    && cd /build && rm -rf /tmp/unwind-objs \
    && cp /usr/lib/gcc/x86_64-linux-gnu/11/libgcc_eh.a libgcc/

# Jai compiler needs to be mounted at runtime
# Mount your jai installation to /jai
ENV PATH="/jai/bin:${PATH}"

# Copy source files (or mount at runtime)
COPY automate-claude.jai build.jai build_musl.jai ./
COPY modules/ ./modules/

# Default command - user should mount jai compiler and run
CMD ["bash", "-c", "jai build.jai && cp automate-claude /output/"]
