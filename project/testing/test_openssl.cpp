
/* compilation:
   g++ -o test_openssl test_openssl.cpp -lssl -lcrypto
   g++ -o test_openssl test_openssl.cpp -I/opt/openssl/include /opt/openssl/lib64/libssl.a /opt/openssl/lib64/libcrypto.a -static/
*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <openssl/bio.h>
#include <openssl/err.h>
#include <openssl/ssl.h>
#include <openssl/rsa.h>
#include <openssl/pem.h>
#include <openssl/x509v3.h>
#include <openssl/provider.h>

/* No universal trust store location -- every OS/distro keeps its CA bundle
   somewhere different (and none of this is baked into curl/openssl
   themselves; see docs/why-static-linking.md). "cacert.pem" stays first so
   a file dropped next to the binary always wins over the system store. */
static const char *g_pszCaCandidates[] =
{
    "cacert.pem",
    "/etc/pki/tls/certs/ca-bundle.crt",   /* RHEL/UBI9/Fedora */
    "/etc/ssl/certs/ca-certificates.crt", /* Debian/Ubuntu */
    "/etc/ssl/cert.pem",                  /* Alpine */
    NULL
};

static const char *FindCaBundle()
{
    for (int i = 0; g_pszCaCandidates[i]; i++)
    {
        if (0 == access (g_pszCaCandidates[i], R_OK))
            return g_pszCaCandidates[i];
    }

    return NULL;
}

#define BuffSize 1024

#define MAX_STR       255
#define MAX_NAME     1024
#define MAX_SAN_STR  4096


typedef struct
{
    int   wIndex;
    int   wMaxDepth;
    int   wIgnoreCertError;

} CERT_VERIFY_STRUCT_TYPE;


#define PrintLogMessage printf

#define X509_GET_SUBJECT        1
#define X509_GET_ISSUER         2
#define X509_GET_NOT_BEFORE     3
#define X509_GET_NOT_AFTER      4


static int X509GetName (const X509 *pX509, int NameType, int wRetBufferLen, char *pszRetBuffer)
{
    const X509_NAME *pX509Name         = NULL;
    const X509_NAME_ENTRY *pX509Entry  = NULL;
    const ASN1_STRING *pAsnString      = NULL;
    char *pBuffer                = pszRetBuffer;
    const unsigned char *pName   = NULL;

    int wCount = 0;
    int index  = 0;
    int wLen   = 0;

    if (NULL == pszRetBuffer) return 0;
    if (0 == wRetBufferLen) return 0;
    *pszRetBuffer = '\0';

    switch (NameType)
    {
        case X509_GET_SUBJECT:
            pX509Name = X509_get_subject_name (pX509);
            break;

        case X509_GET_ISSUER:
            pX509Name = X509_get_issuer_name (pX509);

            break;

        default:
            return 0;
    } /* switch */

    if (pX509Name)
    {
        wCount = X509_NAME_entry_count (pX509Name);
       
        for (index = 0; index<wCount; index++)
        {
            pX509Entry = X509_NAME_get_entry (pX509Name, index);

            if (pX509Entry)
            {
                pAsnString = X509_NAME_ENTRY_get_data (pX509Entry);

                wLen = ASN1_STRING_length (pAsnString);
                if (wLen)
                {
                    pName = ASN1_STRING_get0_data (pAsnString);
                    if (pName)
                    {
                        if (pBuffer - pszRetBuffer + wLen + 2 >= wRetBufferLen)
                        {
                            /* LATER: Buffer is too small! */
                            goto Done;
                        }
    
                        if (index) *pBuffer++ = '/';

                        memcpy (pBuffer, pName, wLen);
                        pBuffer += wLen;
                        *pBuffer = '\0'; /* always terminate buffer */
                    }
                }
            }
        } /* for */
    }

Done:

    return 0;
}


static int X509GetDate (const X509 *pX509, int NameType, int wRetBufferLen, char *pszRetBuffer, struct tm *pretTM)
{
    const ASN1_TIME   *pTM = NULL;
    struct tm tTime  = {0};

    if (pszRetBuffer && wRetBufferLen)
        *pszRetBuffer = '\0';

    if (pretTM)
        memset (pretTM, 0, sizeof (struct tm));

    switch (NameType)
    {
        case X509_GET_NOT_BEFORE:
            pTM = X509_get0_notBefore(pX509);
            break;

        case X509_GET_NOT_AFTER:
            pTM = X509_get0_notAfter(pX509);
            break;

        default:
            return 0;
    } /* switch */

    if (pTM)
    {
        if (pretTM)
        {
            memcpy (pretTM, pTM, sizeof (struct tm));
        }

        if (0 == ASN1_TIME_to_tm(pTM, &tTime))
            goto Done;

        if (pszRetBuffer && wRetBufferLen)
        {
            sprintf (pszRetBuffer,
                     "%04u.%02u.%02u %02u:%02u:%02u",
                     tTime.tm_year+1900,
                     tTime.tm_mon,
                     tTime.tm_mday,
                     tTime.tm_hour,
                     tTime.tm_min,
                     tTime.tm_sec);
        }
    }

Done:
    return 0;
}

static int GetSanNames (X509* const pCert, int wRetBufferLen, char *pszRetBuffer)
{
    GENERAL_NAMES *pNames  = NULL;
    GENERAL_NAME  *pEntry  = NULL;
    unsigned char *pUtf8   = NULL;
    char          *pBuffer = pszRetBuffer;

    int wLenUtf8  = 0;
    int wLenSan   = 0;
    int wCountSan = 0;
    int i         = 0;
    int count     = 0;
    int index     = 0;

    if (NULL == pszRetBuffer) return 0;
    if (0 == wRetBufferLen) return 0;
    *pszRetBuffer = '\0';

    while ( index < 10 )
    {
        if (!pCert) break;

        pNames = (GENERAL_NAMES *) X509_get_ext_d2i (pCert, NID_subject_alt_name, NULL, &index );
        if (!pNames) break;

        count = sk_GENERAL_NAME_num(pNames);
        if (0 == count) break;

        for( i=0; i<count; ++i )
        {
            pEntry = sk_GENERAL_NAME_value (pNames, i);
            if (!pEntry) continue;

            if (GEN_DNS == pEntry->type)
            {
                wLenUtf8  = 0;
                wLenSan  = -1;
                pUtf8 = NULL;

                wLenUtf8 = ASN1_STRING_to_UTF8 (&pUtf8, pEntry->d.dNSName);
                if (pUtf8)
                    wLenSan = (int) strlen((const char*)pUtf8);
 
                if (wLenUtf8 != wLenSan)
                {
                    goto Done;
                }
 
                if (pUtf8 && wLenUtf8 && wLenSan && (wLenUtf8 == wLenSan))
                {
                    if (pBuffer - pszRetBuffer + wLenSan + 2 >= wRetBufferLen)
                    {
                        goto Done;
                    }

                    if (wCountSan)
                    {
                        *pBuffer++ = ',';
                        *pBuffer++ = ' ';
                    }

                    memcpy (pBuffer, pUtf8, wLenSan);
                    pBuffer += wLenSan;
                    *pBuffer = '\0'; /* always terminate buffer */

                    wCountSan++;
                }

                if (pUtf8)
                {
                    OPENSSL_free(pUtf8);
                    pUtf8 = NULL;
                }
            }
        } /* for */

        if (pNames)
        {
            GENERAL_NAMES_free(pNames);
            pNames = NULL;
        }

    } /* while */

Done:

    if (pNames)
        GENERAL_NAMES_free(pNames);

    if (pUtf8)
        OPENSSL_free(pUtf8);

    return wCountSan;
}

int CheckCertInfos (X509 *pCert, int wIndex)
{
    int   ret = 0;
    int   i   = 0;
    char  szSubject   [MAX_NAME+1]    = {0};
    char  szIssuer    [MAX_NAME+1]    = {0};
    char  szNotBefore [MAX_NAME+1]    = {0};
    char  szNotAfter  [MAX_NAME+1]    = {0};
    char  szSanNames  [MAX_SAN_STR+1] = {0};

    STACK_OF(OPENSSL_STRING) *pStackStr = NULL;

    X509GetName (pCert, X509_GET_SUBJECT,    MAX_NAME, szSubject);
    X509GetName (pCert, X509_GET_ISSUER,     MAX_NAME, szIssuer);
    X509GetDate (pCert, X509_GET_NOT_BEFORE, MAX_NAME, szNotBefore, NULL);
    X509GetDate (pCert, X509_GET_NOT_AFTER,  MAX_NAME, szNotAfter,  NULL);

    PrintLogMessage ("#%d: %s, Issuer: %s, NotBefore: %s, Not After: %s\n", 
        wIndex, szSubject, szIssuer, szNotBefore, szNotAfter);

    GetSanNames (pCert, MAX_SAN_STR, szSanNames);
    PrintLogMessage ("SAN: %s\n", szSanNames);

    return ret;
}

void DumpInfosSSL (const char *pszHeader, const char *pszInfo)
{
    if (pszInfo)
        PrintLogMessage ("%s: [%s]\n", pszHeader, pszInfo);
}

void PrintDelLine (int wCount, char DelChar)
{
    while (wCount--)
        PrintLogMessage ("%c", DelChar);
        
    PrintLogMessage ("\n");
}

static int VerifyCallback (int wPreverify, X509_STORE_CTX *pStoreCtx)
{
    char     szBuffer[256] = {0};
    X509     *pCert = 0;
    int      wErr   = 0;
    int      wDepth = 0;
    SSL      *pSSL  = NULL;
    SSL_CTX  *pCtx  = NULL;
    CERT_VERIFY_STRUCT_TYPE *pCtxData = NULL;

    pCert  = X509_STORE_CTX_get_current_cert (pStoreCtx);
    wErr   = X509_STORE_CTX_get_error (pStoreCtx);
    wDepth = X509_STORE_CTX_get_error_depth (pStoreCtx);

    pSSL = (SSL *) X509_STORE_CTX_get_ex_data (pStoreCtx, SSL_get_ex_data_X509_STORE_CTX_idx());

    if (pSSL)
    {
        pCtxData = (CERT_VERIFY_STRUCT_TYPE *) SSL_get_ex_data (pSSL, 1);
    }

    PrintDelLine (80, '*');

    if (pCtxData)
    {
        PrintLogMessage ("Cert #%d [%d] (Verify:%d)\n", pCtxData->wIndex, wDepth, wPreverify);
        pCtxData->wIndex++;
    }
    else
    {
        PrintLogMessage ("Cert (Verify:%d)\n", wPreverify);
    }

    X509_NAME_oneline (X509_get_subject_name(pCert), szBuffer, sizeof (szBuffer));
    PrintLogMessage ("subject= %s\n", szBuffer);

    X509_NAME_oneline (X509_get_issuer_name(pCert), szBuffer, sizeof (szBuffer));
    PrintLogMessage (" issuer= %s\n", szBuffer);

    if (pCtxData && (pCtxData->wMaxDepth) && (wDepth > pCtxData->wMaxDepth))
    {
        wPreverify = 0;
        wErr = X509_V_ERR_CERT_CHAIN_TOO_LONG;
        X509_STORE_CTX_set_error (pStoreCtx, wErr);
    }

    if (!wPreverify)
    {
        PrintLogMessage ("Verify Error: %d: [%s] Depth:%d [%s]\n", wErr, X509_verify_cert_error_string(wErr), wDepth, szBuffer);
        /* Overwrite error */
        
        if (pCtxData && pCtxData->wIgnoreCertError)
        {
            wPreverify = 1;
        }
    }

    return wPreverify;
 }

void openssl_connect (const char *pszAddressAndPort, const char *pszHostname)
{
    char    request[BuffSize]  = {0};
    char    response[BuffSize] = {0};
    char    *pBioStr = NULL;
    SSL     *pSSL    = NULL;
    SSL_CTX *pCtx    = NULL;
    X509    *pCert   = NULL;
    BIO     *pBio    = NULL;

    long    lVerifyFlag = 0;
    long    lRet        = 0;
    int     n   = 0;
    int     ret = 0;
    int     max_chars = 80;

    const SSL_METHOD *pMethod     = NULL;
    const BIO_ADDR   *pBioRetAddr = NULL;
    const char       *pszCaBundle = NULL;

    CERT_VERIFY_STRUCT_TYPE CertVerifyInfo = {0};

    CertVerifyInfo.wIgnoreCertError = 0;
    CertVerifyInfo.wMaxDepth = 20;

    if (NULL == pszAddressAndPort)
        return;

    pMethod = TLS_client_method();

    if (NULL == pMethod)
    {
        PrintLogMessage ("Cannot set TLS Client Mode\n");
        goto Done;
    }

    pCtx = SSL_CTX_new (pMethod);

    if (NULL == pCtx)
    {
        PrintLogMessage ("Cannot set new SSL context\n");
        goto Done;
    }

    lRet = SSL_CTX_set_session_cache_mode (pCtx, SSL_SESS_CACHE_CLIENT);

    pszCaBundle = FindCaBundle();

    if (pszCaBundle)
    {
        if (SSL_CTX_load_verify_locations (pCtx, pszCaBundle, NULL))
            PrintLogMessage ("Loaded CA bundle: %s\n", pszCaBundle);
        else
            PrintLogMessage ("Cannot load certificates from %s\n", pszCaBundle);
    }
    else
    {
        PrintLogMessage ("No CA bundle found in any known location -- falling back to OpenSSL default paths\n");
        SSL_CTX_set_default_verify_paths (pCtx);
    }

    SSL_CTX_set_verify (pCtx, SSL_VERIFY_PEER, VerifyCallback);

    pBio = BIO_new_ssl_connect (pCtx);
    if (NULL == pBio)
    {
        PrintLogMessage ("Cannot set new SSL connection\n");
        goto Done;
    }

    BIO_get_ssl (pBio, &pSSL);

    if (NULL == pSSL)
    {
        PrintLogMessage ("Cannot get SSL connection\n");
        goto Done;
    }

    ret = SSL_set_ex_data (pSSL, 1, &CertVerifyInfo);

    if (1 != ret)
    {
        PrintLogMessage ("Cannot get SSL valdiation callback data\n");
        goto Done;
    }

    SSL_set_mode (pSSL, SSL_MODE_AUTO_RETRY);
    BIO_set_conn_hostname (pBio, pszAddressAndPort);

    if (pszHostname && *pszHostname)
    {
        SSL_set_tlsext_host_name (pSSL, pszHostname);
    }

    if (BIO_do_connect (pBio) <= 0)
    {
        PrintLogMessage ("Cannot connect to [%s]\n", pszAddressAndPort);
        goto Done;
    }

    PrintLogMessage ("\n");

    pCert = SSL_get_peer_certificate (pSSL);

    if (pCert)
    {
        PrintDelLine (80, '-');
        CheckCertInfos (pCert, 0);

        X509_free (pCert);
        pCert = NULL;
    }

    lVerifyFlag = SSL_get_verify_result (pSSL);

    if (lVerifyFlag == X509_V_OK)
    {
        PrintLogMessage ("Certificate Validation OK\n");
    }
    else
    {
        PrintLogMessage ("Warning: Cannot verify certificate - error (%i)\n", (int) lVerifyFlag);
    }

    PrintDelLine(max_chars, '-');
    DumpInfosSSL ("SNI-Host     ", pszHostname);
    DumpInfosSSL ("Address      ", pszAddressAndPort);
    PrintDelLine(max_chars, '-');
    DumpInfosSSL ("TLS-Version  ", SSL_get_cipher_version (pSSL));
    DumpInfosSSL ("CipherName   ", SSL_get_cipher_name (pSSL));
    PrintDelLine(max_chars, '-');
    DumpInfosSSL ("ConnHostname ", BIO_get_conn_hostname (pBio));
    DumpInfosSSL ("ConnPort     ", BIO_get_conn_port (pBio));

    pBioRetAddr = BIO_get_conn_address (pBio);

    if (pBioRetAddr)
    {
        pBioStr = BIO_ADDR_hostname_string (pBioRetAddr, 0);
        DumpInfosSSL ("Hostname     ", pBioStr);
        if (pBioStr) OPENSSL_free(pBioStr);

        pBioStr = BIO_ADDR_hostname_string (pBioRetAddr, 1);
        DumpInfosSSL ("Address      ", pBioStr);
        if (pBioStr) OPENSSL_free(pBioStr);
    }

    PrintDelLine(0, '-');

    sprintf (request, "GET / HTTP/1.1\x0D\x0AHost: %s\x0D\x0AConnection: Close\x0D\x0A\x0D\x0A", pszAddressAndPort);

    BIO_puts (pBio, request);

    while (1)
    {
        PrintDelLine(max_chars, '=');
        memset(response, '\0', sizeof(response));
        n = BIO_read (pBio, response, BuffSize);
        if (n <= 0) break;
        puts (response);
    }

Done:

    if (pBio)
    {
        BIO_free_all (pBio);
        pBio = NULL;
    }

    if (pCtx)
    {
        SSL_CTX_free (pCtx);
        pCtx = NULL;
    }
}

int print_version()
{
    OSSL_PROVIDER *defprov = NULL;
    OSSL_PROVIDER *baseprov = NULL;

    printf("OpenSSL compile-time information:\n");
    printf("  Version      : %s\n", OPENSSL_VERSION_TEXT);
    printf("  Version num  : 0x%lx\n",
           (unsigned long)OPENSSL_VERSION_NUMBER);

    printf("\nOpenSSL runtime information:\n");
    printf("  Version      : %s\n",
           OpenSSL_version(OPENSSL_VERSION));
    printf("  Version num  : 0x%lx\n",
           OpenSSL_version_num());
    printf("  Built on     : %s\n",
           OpenSSL_version(OPENSSL_BUILT_ON));
    printf("  Platform     : %s\n",
           OpenSSL_version(OPENSSL_PLATFORM));
    printf("  Compiler     : %s\n",
           OpenSSL_version(OPENSSL_CFLAGS));
    printf("  OPENSSLDIR   : %s\n",
           OpenSSL_version(OPENSSL_DIR));
    printf("  ENGINESDIR   : %s\n",
           OpenSSL_version(OPENSSL_ENGINES_DIR));
    printf("  MODULESDIR   : %s\n",
           OpenSSL_version(OPENSSL_MODULES_DIR));

    printf("\nVersion components:\n");
    printf("  Major        : %u\n", OPENSSL_VERSION_MAJOR);
    printf("  Minor        : %u\n", OPENSSL_VERSION_MINOR);
    printf("  Patch        : %u\n", OPENSSL_VERSION_PATCH);

    printf("\nProvider availability:\n");
    printf("  default      : %s\n",
           OSSL_PROVIDER_available(NULL, "default") ? "yes" : "no");
    printf("  base         : %s\n",
           OSSL_PROVIDER_available(NULL, "base") ? "yes" : "no");
    printf("  legacy       : %s\n",
           OSSL_PROVIDER_available(NULL, "legacy") ? "yes" : "no");
    printf("  fips         : %s\n",
           OSSL_PROVIDER_available(NULL, "fips") ? "yes" : "no");

    printf("\nProvider load test:\n");

    defprov = OSSL_PROVIDER_load(NULL, "default");
    printf("  default      : %s\n",
           defprov ? "loaded" : "FAILED");

    baseprov = OSSL_PROVIDER_load(NULL, "base");
    printf("  base         : %s\n",
           baseprov ? "loaded" : "FAILED");

    OSSL_PROVIDER_unload(baseprov);
    OSSL_PROVIDER_unload(defprov);

    return 0;
}

int main(int argc, char *argv[])
{
    print_version();
    printf ("\n");

    if (argc < 2)
        return 0;

    SSL_library_init();
    SSL_load_error_strings();

    PrintLogMessage ("Trying an HTTPS connection to %s...\n", argv[1]);

    if (argc > 2)
        openssl_connect (argv[1], argv[2]);
    else
        openssl_connect (argv[1], "");

    return 0;
}

