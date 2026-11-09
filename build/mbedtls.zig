const std = @import("std");
const log = std.log.scoped(.ziglibgit2_build_mbedtls);
const mod = @import("module.zig");

/// mbedTLS 3.6, the crypto library libssh2 is built against.
///
/// Only `mbedcrypto` is built. libssh2's mbedTLS backend uses the cipher,
/// digest, bignum, PK and DRBG APIs, all of which live there; the X.509 and
/// TLS libraries are never referenced. HTTPS does not go through mbedTLS at
/// all — it uses Zig's `std.crypto.tls` (see `src/tls_stream.zig`).
///
/// The configuration is upstream's default `include/mbedtls/mbedtls_config.h`,
/// unmodified and without `MBEDTLS_CONFIG_FILE`.
pub const MbedTls = struct {
    const Self = @This();

    /// The name of the package in `build.zig.zon`.
    pub const dep_name = "mbedtls";

    /// `src_crypto`, verbatim from `library/CMakeLists.txt:13-95`.
    ///
    /// `3rdparty/everest` and `3rdparty/p256-m` are left out: their sources
    /// compile to nothing unless `MBEDTLS_ECDH_VARIANT_EVEREST_ENABLED` or
    /// `MBEDTLS_PSA_P256M_DRIVER_ENABLED` is set, and the default config sets
    /// neither.
    const src_crypto = [_][]const u8{
        "aes.c",
        "aesni.c",
        "aesce.c",
        "aria.c",
        "asn1parse.c",
        "asn1write.c",
        "base64.c",
        "bignum.c",
        "bignum_core.c",
        "bignum_mod.c",
        "bignum_mod_raw.c",
        "block_cipher.c",
        "camellia.c",
        "ccm.c",
        "chacha20.c",
        "chachapoly.c",
        "cipher.c",
        "cipher_wrap.c",
        "constant_time.c",
        "cmac.c",
        "ctr_drbg.c",
        "des.c",
        "dhm.c",
        "ecdh.c",
        "ecdsa.c",
        "ecjpake.c",
        "ecp.c",
        "ecp_curves.c",
        "entropy.c",
        "entropy_poll.c",
        "error.c",
        "gcm.c",
        "hkdf.c",
        "hmac_drbg.c",
        "lmots.c",
        "lms.c",
        "md.c",
        "md5.c",
        "memory_buffer_alloc.c",
        "nist_kw.c",
        "oid.c",
        "padlock.c",
        "pem.c",
        "pk.c",
        "pk_ecc.c",
        "pk_wrap.c",
        "pkcs12.c",
        "pkcs5.c",
        "pkparse.c",
        "pkwrite.c",
        "platform.c",
        "platform_util.c",
        "poly1305.c",
        "psa_crypto.c",
        "psa_crypto_aead.c",
        "psa_crypto_cipher.c",
        "psa_crypto_client.c",
        "psa_crypto_driver_wrappers_no_static.c",
        "psa_crypto_ecp.c",
        "psa_crypto_ffdh.c",
        "psa_crypto_hash.c",
        "psa_crypto_mac.c",
        "psa_crypto_pake.c",
        "psa_crypto_rsa.c",
        "psa_crypto_random.c",
        "psa_crypto_se.c",
        "psa_crypto_slot_management.c",
        "psa_crypto_storage.c",
        "psa_its_file.c",
        "psa_util.c",
        "ripemd160.c",
        "rsa.c",
        "rsa_alt_helpers.c",
        "sha1.c",
        "sha256.c",
        "sha512.c",
        "sha3.c",
        "threading.c",
        "timing.c",
        "version.c",
        "version_features.c",
    };

    /// Creates the module that compiles `mbedcrypto`.
    ///
    /// - `cfg`: the shared build configuration.
    /// - Returns: a C-only module; importing it into a library's module graph
    ///   bundles its objects into that library.
    pub fn createModule(cfg: *const mod.Config) *std.Build.Module {
        if (cfg.verbose) log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        const dep = cfg.dependency(dep_name);
        const root = cfg.createCModule();

        // `library/CMakeLists.txt:350-353`: public `include/`, private `library/`.
        root.addIncludePath(dep.path("include"));
        root.addIncludePath(dep.path("library"));

        root.addCSourceFiles(.{
            .root = dep.path("library"),
            .files = &src_crypto,
            // `CMakeLists.txt:201`.
            .flags = &.{"-std=c99"},
        });

        // `library/CMakeLists.txt:225-227`.
        if (cfg.isWindows()) {
            root.linkSystemLibrary("ws2_32", .{});
            root.linkSystemLibrary("bcrypt", .{});
        }

        return root;
    }

    /// Returns the public include directory, for packages built against it.
    ///
    /// - `cfg`: the shared build configuration.
    /// - Returns: the lazy path of mbedTLS's `include/`.
    pub fn includePath(cfg: *const mod.Config) std.Build.LazyPath {
        return cfg.dependency(dep_name).path("include");
    }
};
