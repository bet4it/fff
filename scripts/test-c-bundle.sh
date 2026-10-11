#!/usr/bin/env bash
set -euo pipefail

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
    echo "Usage: $0 <target>"
    exit 1
fi

DIST_DIR="fff-c-$TARGET"
DEMO_SRC="crates/fff-c/examples/demo.c"
OS_NAME="$(uname -s)"

echo "=== Verifying C developer bundle for target: $TARGET ==="

if [ ! -d "$DIST_DIR" ]; then
    echo "Error: Dist directory '$DIST_DIR' not found!"
    exit 1
fi

echo "Listing $DIST_DIR contents:"
find "$DIST_DIR" -type f

# 1. Verify pkg-config file if pkg-config tool exists and not on Windows (Strawberry Perl pkg-config is broken)
if [[ "$OS_NAME" != MINGW* && "$OS_NAME" != MSYS* && "$OS_NAME" != CYGWIN* && "$OS_NAME" != Windows* ]] && command -v pkg-config >/dev/null 2>&1; then
    echo "--- Testing pkg-config resolution ---"
    export PKG_CONFIG_PATH="$PWD/$DIST_DIR/lib/pkgconfig"
    pkg-config --validate fff_c
    echo "pkg-config Cflags: $(pkg-config --cflags fff_c)"
    echo "pkg-config Libs (dynamic): $(pkg-config --libs fff_c)"
    echo "pkg-config Libs (static): $(pkg-config --cflags --static --libs fff_c)"
fi

# 2. Compile and link demo programs
mkdir -p "$DIST_DIR/test-build"
cd "$DIST_DIR/test-build"

case "$OS_NAME" in
    Linux*)
        if [[ "$TARGET" == *"android"* ]]; then
            echo "--- Cross-compiling for Android ---"
            NDK_BIN="$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
            CC="$NDK_BIN/aarch64-linux-android24-clang"

            # Dynamic linking
            "$CC" -Wall -Wextra -I"../include" "../../$DEMO_SRC" -L"../lib" -lfff_c -o demo_dyn
            # Static linking
            "$CC" -Wall -Wextra -I"../include" "../../$DEMO_SRC" "../lib/libfff_c.a" -lz -lm -ldl -o demo_static

        elif [[ "$TARGET" == "x86_64-unknown-linux-gnu" ]]; then
            echo "--- Native Linux x86_64 (glibc) ---"
            # Dynamic linking
            gcc -Wall -Wextra -I"../include" "../../$DEMO_SRC" -L"../lib" -lfff_c -Wl,-rpath,"$PWD/../lib" -o demo_dyn
            echo "Running dynamic demo:"
            ./demo_dyn

            # Static linking
            gcc -Wall -Wextra -I"../include" "../../$DEMO_SRC" "../lib/libfff_c.a" -lpthread -ldl -lm -o demo_static
            echo "Running static demo:"
            ./demo_static

        elif [[ "$TARGET" == "x86_64-unknown-linux-musl" ]]; then
            echo "--- Linux x86_64 (musl) ---"
            CC="zig cc -target x86_64-linux-musl"

            # Dynamic linking
            $CC -Wall -Wextra -I"../include" "../../$DEMO_SRC" -L"../lib" -lfff_c -o demo_dyn

            # Static linking
            $CC -static -Wall -Wextra -I"../include" "../../$DEMO_SRC" "../lib/libfff_c.a" -lunwind -o demo_static
            echo "Running static musl demo:"
            ./demo_static

        elif [[ "$TARGET" == "aarch64-unknown-linux-gnu" ]]; then
            echo "--- Linux aarch64 (glibc) ---"
            if ! command -v aarch64-linux-gnu-gcc >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
                sudo apt-get update -qq && sudo apt-get install -y -qq gcc-aarch64-linux-gnu
            fi
            if command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
                CC=aarch64-linux-gnu-gcc
            elif command -v zig >/dev/null 2>&1; then
                CC="zig cc -target aarch64-linux-gnu.2.31"
            else
                echo "Cross compiler for aarch64-unknown-linux-gnu not found"
                exit 1
            fi

            $CC -Wall -Wextra -I"../include" "../../$DEMO_SRC" -L"../lib" -lfff_c -o demo_dyn
            $CC -Wall -Wextra -I"../include" "../../$DEMO_SRC" "../lib/libfff_c.a" -lpthread -ldl -lm -o demo_static

        elif [[ "$TARGET" == "aarch64-unknown-linux-musl" ]]; then
            echo "--- Linux aarch64 (musl) ---"
            CC="zig cc -target aarch64-linux-musl"
            $CC -Wall -Wextra -I"../include" "../../$DEMO_SRC" -L"../lib" -lfff_c -o demo_dyn
            $CC -static -Wall -Wextra -I"../include" "../../$DEMO_SRC" "../lib/libfff_c.a" -lunwind -o demo_static

        else
            echo "Unknown Linux target: $TARGET"
            exit 1
        fi
        ;;

    Darwin*)
        echo "--- macOS Darwin ---"
        if [[ "$TARGET" == "x86_64-apple-darwin" ]]; then
            ARCH_FLAGS="-target x86_64-apple-darwin"
        else
            ARCH_FLAGS="-target arm64-apple-darwin"
        fi

        # Dynamic linking
        clang $ARCH_FLAGS -Wall -Wextra -I"../include" "../../$DEMO_SRC" -L"../lib" -lfff_c -Wl,-rpath,"@executable_path/../lib" -o demo_dyn
        echo "Running dynamic demo:"
        ./demo_dyn

        # Static linking
        clang $ARCH_FLAGS -Wall -Wextra -I"../include" "../../$DEMO_SRC" "../lib/libfff_c.a" \
            -lpthread -ldl -lm -lz -liconv \
            -framework CoreServices -framework CoreFoundation -framework Security -framework SystemConfiguration \
            -o demo_static
        echo "Running static demo:"
        ./demo_static
        ;;

    MINGW*|MSYS*|CYGWIN*|Windows*)
        echo "--- Windows (MSVC) ---"
        CC=clang
        if [[ "$TARGET" == "aarch64-pc-windows-msvc" ]]; then
            TARGET_FLAG="--target=aarch64-pc-windows-msvc"
            IS_CROSS=1
        else
            TARGET_FLAG="--target=x86_64-pc-windows-msvc"
            IS_CROSS=0
        fi

        WIN_LIBS="-luserenv -lws2_32 -lbcrypt -lntdll -ladvapi32 -lsynchronization -lsecur32 -lshell32 -lole32"
        CRT_FLAGS="-D_DLL -Wl,-nodefaultlib:libcmt -Wl,-defaultlib:msvcrt -Wl,-defaultlib:ucrt"

        # Dynamic linking: link against import lib if available, or dll
        if [ -f "../lib/fff_c.dll.lib" ]; then
            $CC $TARGET_FLAG $CRT_FLAGS -Wall -Wextra -I"../include" "../../$DEMO_SRC" "../lib/fff_c.dll.lib" -o demo_dyn.exe
        else
            $CC $TARGET_FLAG $CRT_FLAGS -Wall -Wextra -I"../include" "../../$DEMO_SRC" -L"../lib" -lfff_c -o demo_dyn.exe
        fi

        # Static linking: link against static lib + win32 dependencies
        $CC $TARGET_FLAG $CRT_FLAGS -Wall -Wextra -I"../include" "../../$DEMO_SRC" "../lib/fff_c.lib" \
            $WIN_LIBS -o demo_static.exe

        if [ "$IS_CROSS" -eq 0 ]; then
            echo "Running dynamic demo on Windows:"
            cp "../lib/fff_c.dll" .
            ./demo_dyn.exe
            echo "Running static demo on Windows:"
            ./demo_static.exe
        fi
        ;;

    *)
        echo "Unknown OS: $OS_NAME"
        exit 1
        ;;
esac

echo "=== Verification SUCCESS for $TARGET ==="
