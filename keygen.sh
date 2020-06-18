openssl ecparam -name prime256v1 -genkey -out key.pem
openssl req -new -x509 -key key.pem -out cert.pem -days 365