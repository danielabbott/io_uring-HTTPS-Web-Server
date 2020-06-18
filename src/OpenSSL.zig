pub const openssl = @cImport({
    @cDefine("OPENSSL_API_COMPAT", "0x10100000L");
    @cInclude("openssl/ssl.h");
    @cInclude("openssl/err.h");
    @cInclude("openssl/tls1.h");
    @cInclude("openssl/cryptoerr.h");
});
