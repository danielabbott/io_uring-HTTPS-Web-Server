
## Dependencies
- Zig 0.6.0 compiler
- Linux 5.6+
- OpenSSL 1.1.1
- liburing 0.6

## Configuration
There is 1 mandatory configuration file (files.csv) and 2 optional configuration files (settings.conf and extra_headers.http).

### files.csv
An example files.csv is included in the root directory of the repository.
The first field of each record is the URL, the second is the path to the file, and the third is the MIME type.

### settings.conf
```
# 0 = auto (= number of CPU cores)
threads: 0
statistics: on
http port: 80
https port: 443

# Paths to .pem files
cert: cert.pem
cert key: key.pem
```
Default settings are as above.

### extra_headers.http
Contains the extra headers that are added on HTTP responses.
The default is in Config.zig.
