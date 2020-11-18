# Custom ZeroSSL Client Script

**This is not an official ZeroSSL Client! For that please use the ZeroSSL-certbot**

I made a bash script for my self to interact with the ZeroSSL REST API supporting most of the methods provided there. I needed this as certbot client for some reason did not work properly. The script internally uses `curl`, and `jq`. Please note that if any of those are not installed the script will try to install them.

## Usage:

```shell
./zeroSSL-client.sh ACCESS_KEY [OPTIONS] [METHODS]
```

ZeroSSL API Access key is required argument anything else is optional. If no method is set the full request-validate-install process is carried out (with --wait-for-validation). In this case it is recommended to run it as a background job (or with `nohup`) so the script does not exist accidentally while waiting for validation.

Most of the methods may be set independently (e.g. validate and install, cancel and delete).

The Script needs to be run as root.

**Options:**

```shell
        --apache-dir PATH       Set apache directory (default: /etc/apache2
        --apache-conf PATH      Set apache conf file (default: sites-available/default-ssl.conf)
        --cert PATH             Set certificate file (default: ssl/certificate.cer)
        --ca_bundle PATH        Set CA Bundle file (default: ssl/ca_bundle.cer)
        -r, --request PATH      Set CSR file (default: ssl/request.csr)
        -k, --key PATH          Set Private key file (default: ssl/private.cer)
        --wait-for-validation   Wait for certificate issue after verification (default: false)
```

**Methods:**

```shell
        -n, --new DOMAIN_NAME   Request new certificate with domain name
        -v, --validate [ID]     Validate certificate, ID is optional with the --new flag
        -i, --install [ID]      Install certificate, ID is optional with the --new or --validate flag
        -c, --cancel ID         Cancel certificate with ID or IDs - quoted and items separated with a space
        -d, --delete ID         Delete certificate with ID or IDs - quoted and items separated with a space
                                (if used together with cancel IDs are passed on to this method automatically)
```
