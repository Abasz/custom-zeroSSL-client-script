#!/bin/bash

function createCertificateRequest() {
    if [ ! -f "$APACHE_CONF_DIR/$REQUEST" ]; then
    echo "No request certificate is available, creating one..."
    openssl req -new -newkey rsa:2048 -nodes -out "$APACHE_CONF_DIR/$REQUEST" -keyout "$APACHE_CONF_DIR/$PRIVATE_KEY" -subj "/C=HU/ST=/L=/O=/CN=$1"
    fi

    echo "Creating ZeroSSL certificiate reqest via Api"
    NEW_CERTIFICATE_DETAILS=$(curl --data certificate_domains="$1" --data certificate_validity_days=90 --data-urlencode "certificate_csr=$(sed ':a;N;$!ba;s/\n//g' "$APACHE_CONF_DIR/$REQUEST")" "https://api.zerossl.com/certificates?access_key=$ACCESS_KEY")

    ID=$(jq -r '.id' <<< "$NEW_CERTIFICATE_DETAILS")

    if [ "$(jq -r '.success' <<< "$NEW_CERTIFICATE_DETAILS")" = "false" ]; then
        echo "Error while creating new certificate: $(jq -r '.error.type' <<< "$NEW_CERTIFICATE_DETAILS")"
        exit 2
    fi
}

function deleteCertificate() {
    local DELETE_RESPONSE
    DELETE_RESPONSE=$(curl -X DELETE https://api.zerossl.com/certificates/"$1"?access_key="$ACCESS_KEY")

    if [ "$(jq -r '.success' <<< "$DELETE_RESPONSE")" != "1" ]; then
        echo "Error while deleteing certificate: $(jq -r '.error.type' <<< "$DELETE_RESPONSE")"
        exit 2
    fi
}

function cancelCertificate() {
    local CANCEL_RESPONSE
    CANCEL_RESPONSE=$(curl https://api.zerossl.com/certificates/"$1"/cancel?access_key="$ACCESS_KEY")

    if [ "$(jq -r '.success' <<< "$CANCEL_RESPONSE")" != "1" ]; then
        echo "Error while cancelling certificate: $(jq -r '.error.type' <<< "$CANCEL_RESPONSE")"
        exit 2
    fi
}

function validateCertificate() {
    ID=$(jq -r '.id' <<< "$1")
    COMMON_NAME="$(jq -r '.common_name' <<< "$1")"
    VALIDATION_URL="$(jq -r ".validation.other_methods[\"$COMMON_NAME\"].file_validation_url_https" <<< "$1")"

    echo "Validating certificate with ID: $ID"
    echo "Validation URL: $VALIDATION_URL"

    echo "Creating txt file for validation"
    TEXT_FILE_NAME=$(sed "s/https:\/\/$COMMON_NAME\/.well-known\/pki-validation\///Ig" <<< "$VALIDATION_URL")
    jq -r ".validation.other_methods[\"$COMMON_NAME\"].file_validation_content[]" <<< "$1" > "$TEXT_FILE_NAME"

    echo "Adding apache2 entry"
    APACHE_CONFIG="Alias /.well-known/pki-validation/ \"$CURRENT_DIR/\"\n\
    <Directory \"$CURRENT_DIR/\">\n\
    Require all denied\n\
    <FilesMatch \".txt$\">\n\
    Require all granted\n\
    </FilesMatch>\n\
    </Directory>\n"
    cp "$APACHE_CONF_DIR/$APACHE_CONF_FILE_NAME" "$APACHE_CONF_DIR/$APACHE_CONF_FILE_NAME.bak"
    sed -i "/^<virtualhost.*/Ia \\\n $APACHE_CONFIG" "$APACHE_CONF_DIR/$APACHE_CONF_FILE_NAME"

    sleep 5
    service apache2 restart
    sleep 5

    echo "Requesting HTTPS validation from API"
    VALIDATION_RESPONSE=$(curl --data validation_method=HTTPS_CSR_HASH https://api.zerossl.com/certificates/"$ID"/challenges?access_key="$ACCESS_KEY")
    VALIDATION_STATUS=$(jq -r '.status' <<< "$VALIDATION_RESPONSE")

    if [ "$VALIDATION_STATUS" != "pending_validation" ]; then
        echo "Error occured while validating request: $(jq '.error.type' <<< "$VALIDATION_RESPONSE")"
        jq '.' <<< "$VALIDATION_RESPONSE" > error.log
        cleanup
        exit 2
    fi

    echo "Status: $VALIDATION_STATUS"
    echo "Validation request was successfull, validation is pending..."

    CHECK_COUNTER=0
    while [ "$WAIT_FOR_VALIDATION" = "true" ] && [ "$VALIDATION_STATUS" = "pending_validation" ] && [ $CHECK_COUNTER -le 15 ]
    do
        echo "Checking certificate status in a minute..."
        sleep $((180 + "$CHECK_COUNTER" * 30))
        ((CHECK_COUNTER++))

        local checking_status
        checking_status=$(curl https://api.zerossl.com/certificates/"$ID"?access_key="$ACCESS_KEY")

        VALIDATION_STATUS=$(jq -r '.status' <<< "$checking_status")
        echo "Status: $VALIDATION_STATUS"

        if [ "$VALIDATION_STATUS" = "cancelled" ]; then
            echo "Exiting as certificate status is $VALIDATION_STATUS"
            cleanup
            exit 2
        fi

        if [ "$(jq -r '.success' <<< "$checking_status")" = "false" ]; then
            echo "Error occured while validating request: $(jq '.error.type' <<< "$checking_status")"
            jq '.' <<< "$checking_status" > error.log
            cleanup
            exit 2
        fi
    done

    if [ "$VALIDATION_STATUS" = "issued" ]; then
        echo "Certificate has been issued"
    fi
}

function installCertificate() {
    echo "Installing certificate with ID: $1"
    CERTIFICATES=$(curl api.zerossl.com/certificates/"$1"/download/return?access_key="$ACCESS_KEY")

    if [ "$(jq -r '.success' <<< "$CERTIFICATES")" = "false" ]; then
        echo "Error while downloading new certificate: $(jq -r '.error.type' <<< "$CERTIFICATES")"
        cleanup
        exit 2
    fi

    echo "Installing new certificates"
    jq -r '.["certificate.crt"]' <<< "$CERTIFICATES" > "$APACHE_CONF_DIR/$CERTIFICATE_FILE"
    jq -r '.["ca_bundle.crt"]' <<< "$CERTIFICATES" > "$APACHE_CONF_DIR/$CA_BUNDLE_FILE"
}

function cleanup() {
    echo "Cleaining up..."

    if [ -f "$APACHE_CONF_DIR/$APACHE_CONF_FILE_NAME.bak" ]; then
        echo "Resetting apache2 settings"
        mv "$APACHE_CONF_DIR/$APACHE_CONF_FILE_NAME.bak" "$APACHE_CONF_DIR/$APACHE_CONF_FILE_NAME"
    fi

    if [ -f "$CURRENT_DIR/$TEXT_FILE_NAME" ]; then
        echo "Removing unncessary files"
        rm "$CURRENT_DIR/$TEXT_FILE_NAME"
    fi

    service apache2 restart

    exit
}

function usage() {
    echo "Usage: zeroSSL-client.sh ACCESS_KEY [OPTIONS] [METHODS]"
    echo "Options:"
    echo "      --apache-dir PATH       Set apache directory (default: /etc/apache2/)"
    echo "      --apache-conf PATH      Set apache conf file (default: sites-available/default-ssl.conf)"
    echo "      --cert PATH             Set certificate file (default: ssl/certificate.cer)"
    echo "      --ca_bundle PATH        Set CA Bundle file (default: ssl/ca_bundle.cer)"
    echo "      -r, --request PATH      Set CSR file (default: ssl/request.csr)"
    echo "      -k, --key PATH          Set Private key file (default: ssl/private.cer)"
    echo "      --wait-for-validation   Wait for certificate issue after verification (default: false)"
    echo "Methods:"
    echo "      -n, --new               Request new certificate"
    echo "      -v, --validate [ID]     Validate certificate, ID is optional with the --new flag"
    echo "      -i, --install [ID]      Install certificate, ID is optional with the --new or --validate flag"
    echo "      -c, --cancel ID         Cancel certificate with ID or IDs - quoted and items separated with a space"
    echo "      -d, --delete ID         Delete certificate with ID or IDs - quoted and items separated with a space"
    echo "                              (if used together with cancel IDs are passed on to this method automatically)"
}

for arg in "$@"; do
    case "$arg" in
    -h|--help)
        usage
        exit
    ;;
    esac
done

trap cleanup SIGHUP SIGINT SIGTERM

if [ -z "$1" ] || [ "${1:0:1}" = "-" ]; then
    echo "ACCESS_KEY is missing"
    usage
fi

if [ -z "$(which curl)" ]; then \
    echo "curl is not installed, installing..."
    sudo apt install -y curl
fi

if [ -z "$(which jq)" ]; then \
    echo "jq is not installed, installing..."
    sudo apt install -y jq
fi

APACHE_CONF_DIR=/etc/apache2/
APACHE_CONF_FILE_NAME=sites-available/default-ssl.conf
REQUEST=ssl/request.csr
PRIVATE_KEY=ssl/private.key
CERTIFICATE_FILE=ssl/certificate.crt
CA_BUNDLE_FILE=ssl/ca_bundle.crt

CURRENT_DIR=$(pwd)
WAIT_FOR_VALIDATION="false"

ACCESS_KEY=$1
shift

args=("$@")

for i in "${!args[@]}"; do
    case "${args[$i]}" in
        --wait-for-validation)
                WAIT_FOR_VALIDATION="true"
                unset "args[$i]"
        ;;
        --apache-dir)
            if [ -n "${args[$i+1]}" ] && [ "${args[$i+1]:0:1}" != "-" ]; then
                APACHE_CONF_DIR=${args[$i+1]}
                unset "args[$i]"
                unset "args[$i+1]"
            else
                echo "Error: Argument for ${args[$i+1]} is missing" >&2
                exit 1
            fi
        ;;
        --apache-conf-file)
            if [ -n "${args[$i+1]}" ] && [ "${args[$i+1]:0:1}" != "-" ]; then
                APACHE_CONF_DIR="${args[$i+1]}"
                unset "args[$i]"
                unset "args[$i+1]"
            else
                echo "Error: Argument for ${args[$i+1]} is missing" >&2
                exit 1
            fi
        ;;
        --cert-file)
            if [ -n "${args[$i+1]}" ] && [ "${args[$i+1]:0:1}" != "-" ]; then
                CERTIFICATE_FILE=${args[$i+1]}
                unset "args[$i]"
                unset "args[$i+1]"
            else
                echo "Error: Argument for ${args[$i+1]} is missing" >&2
                exit 1
            fi
        ;;
        --ca_bundle)
            if [ -n "${args[$i+1]}" ] && [ "${args[$i+1]:0:1}" != "-" ]; then
                CA_BUNDLE_FILE=${args[$i+1]}
                unset "args[$i]"
                unset "args[$i+1]"
            else
                echo "Error: Argument for ${args[$i+1]} is missing" >&2
                exit 1
            fi
        ;;
        -r|--request)
            if [ -n "${args[$i+1]}" ] && [ "${args[$i+1]:0:1}" != "-" ]; then
                REQUEST="${args[$i+1]}"
                unset "args[$i]"
                unset "args[$i+1]"
            else
                echo "Error: Argument for ${args[$i+1]} is missing" >&2
                exit 1
            fi
        ;;
        -k|--key)
            if [ -n "${args[$i+1]}" ] && [ "${args[$i+1]:0:1}" != "-" ]; then
                PRIVATE_KEY="${args[$i+1]}"
                unset "args[$i]"
                unset "args[$i+1]"
            else
                echo "Error: Argument for ${args[$i+1]} is missing" >&2
                exit 1
            fi
        ;;
    esac
done

for i in "${!args[@]}"; do
    case "${args[$i]}" in
        -c|--cancel)
            if [ -n "${args[$i+1]}" ] && [ "${args[$i+1]:0:1}" != "-" ]; then
                read -r -a IDS <<< "${args[$i+1]}"
                INDEX=0
                for ITEM in "${IDS[@]}"; do
                    echo "Cancelling: $ITEM"
                    cancelCertificate "$ITEM"
                    ((INDEX++))

                    if [ "$INDEX" -ne ${#IDS[@]} ]; then
                        echo "Waiting for 10 sec before next cancel request"
                        sleep 10
                    fi
                done
                unset "args[$i]"
                unset "args[$i+1]"
            else
                echo "Error: Argument for ${args[$i]} (Certificate ID) is missing" >&2
                exit 1
            fi

            if [ ${#args[@]} -eq 0 ]; then
                cleanup
                exit 1
            fi
        ;;
    esac
done

for i in "${!args[@]}"; do
    case "${args[$i]}" in
        -d|--delete)
            if { [ -n "${args[$i+1]}" ] && [ "${args[$i+1]:0:1}" != "-" ]; } || [ ${#IDS[@]} -ne 0 ]; then

                if [ ${#IDS[@]} -eq 0 ]; then
                    read -r -a IDS <<< "${args[$i+1]}"
                fi

                INDEX=0
                for ITEM in "${IDS[@]}"; do
                    echo "Deleteing: $ITEM"
                    deleteCertificate "$ITEM"
                    ((INDEX++))

                    if [ "$INDEX" -ne ${#IDS[@]} ]; then
                        echo "Waiting for 10 sec before next delete request"
                        sleep 10
                    fi
                done
                unset "args[$i]"
                unset "args[$i+1]"
            else
                echo "Error: Argument for ${args[$i]} (Certificate ID) is missing or add --cancel flag with IDs" >&2
                exit 1
            fi

            if [ ${#args[@]} -eq 0 ]; then
                cleanup
                exit 1
            fi
        ;;
    esac
done

for i in "${!args[@]}"; do
    case "${args[$i]}" in
        -c|--new)
           if [ -n "${args[$i+1]}" ] && [ "${args[$i+1]:0:1}" != "-" ]; then
                createCertificateRequest "${args[$i]}"
                unset "args[$i]"
                unset "args[$i+1]"

                if [ ${#args[@]} -eq 0 ]; then
                    cleanup
                    exit 1
                fi
            else
                echo "Error: Argument for ${args[$i]} (Certificate ID) is missing or add --create flag" >&2
                exit 1
            fi
        ;;
    esac
done

for i in "${!args[@]}"; do
    case "${args[$i]}" in
        -v|--validate)
           if { [ -n "${args[$i+1]}" ] && [ "${args[$i+1]:0:1}" != "-" ]; } || [ -n "$NEW_CERTIFICATE_DETAILS" ]; then
                validateCertificate "${NEW_CERTIFICATE_DETAILS:="$(curl https://api.zerossl.com/certificates/"${args[$i+1]}"?access_key="$ACCESS_KEY")"}"

                unset "args[$i]"
                if [ "${args[$i+1]:0:1}" != "-" ]; then
                    unset "args[$i+1]"
                fi

                if [ ${#args[@]} -eq 0 ]; then
                    cleanup
                    exit 1
                fi
            else
                echo "Error: Argument for ${args[$i]} (Certificate ID) is missing or add --create flag" >&2
                exit 1
            fi
        ;;
    esac
done

for i in "${!args[@]}"; do
    case "${args[$i]}" in
        -i|--install)
                if { [ -n "${args[$i+1]}" ] && [ "${args[$i+1]:0:1}" != "-" ]; } || [ -n "$ID" ]; then
                installCertificate "${ID:="$(curl https://api.zerossl.com/certificates/"${args[$i+1]}"?access_key="$ACCESS_KEY" | jq -r '.id')"}"

                unset "args[$i]"
                if [ "${args[$i+1]:0:1}" != "-" ]; then
                    unset "args[$i+1]"
                fi

                if [ ${#args[@]} -eq 0 ]; then
                    cleanup
                    exit 1
                fi
            else
                echo "Error: Argument for ${args[$i]} (Certificate ID) is missing" >&2
                exit 1
            fi
        ;;
    esac
done

createCertificateRequest

echo "Processing API response"
WAIT_FOR_VALIDATION=true
validateCertificate "$NEW_CERTIFICATE_DETAILS"
installCertificate "$ID"
cleanup