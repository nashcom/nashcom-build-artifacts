
/* compilation:
   g++ -o test_curl test_curl.cpp -lcurl
   g++ -o test_curl test_curl.cpp -I/opt/curl/include /opt/curl/lib64/libcurl.a /opt/openssl/lib64/libssl.a /opt/openssl/lib64/libcrypto.a -lz -static
*/

#include <cstdio>
#include <cstring>
#include <unistd.h>
#include <curl/curl.h>

#define PrintLogMessage printf

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

void PrintDelLine (int wCount, char DelChar)
{
    while (wCount--)
        PrintLogMessage ("%c", DelChar);

    PrintLogMessage ("\n");
}

/* WriteCallback: discards the response body, just counts bytes -- this is
   a link/connectivity smoke test, not a content check. */
static size_t WriteCallback (char *pData, size_t wSize, size_t wNMemb, void *pUserData)
{
    size_t *pwTotal = (size_t *) pUserData;
    size_t  wBytes   = wSize * wNMemb;

    if (pwTotal)
        *pwTotal += wBytes;

    return wBytes;
}

void print_version()
{
    curl_version_info_data *pInfo = curl_version_info (CURLVERSION_NOW);

    PrintLogMessage ("curl compile-time information:\n");
    PrintLogMessage ("  Version      : %s\n", LIBCURL_VERSION);

    PrintLogMessage ("\ncurl runtime information:\n");
    PrintLogMessage ("  Version      : %s\n", pInfo->version);
    PrintLogMessage ("  SSL Version  : %s\n", pInfo->ssl_version ? pInfo->ssl_version : "(none)");
    PrintLogMessage ("  Libz Version : %s\n", pInfo->libz_version ? pInfo->libz_version : "(none)");
    PrintLogMessage ("  Host         : %s\n", pInfo->host);

    PrintLogMessage ("\nProtocols:\n  ");
    for (int i = 0; pInfo->protocols[i]; i++)
        PrintLogMessage ("%s ", pInfo->protocols[i]);
    PrintLogMessage ("\n");

    PrintLogMessage ("\nFeature flags:\n");
    PrintLogMessage ("  SSL          : %s\n", (pInfo->features & CURL_VERSION_SSL)        ? "yes" : "no");
    PrintLogMessage ("  libz         : %s\n", (pInfo->features & CURL_VERSION_LIBZ)       ? "yes" : "no");
    PrintLogMessage ("  AsynchDNS    : %s\n", (pInfo->features & CURL_VERSION_ASYNCHDNS)  ? "yes" : "no");
    PrintLogMessage ("  IPv6         : %s\n", (pInfo->features & CURL_VERSION_IPV6)       ? "yes" : "no");
}

int curl_connect (const char *pszUrl)
{
    CURL       *pCurl     = NULL;
    CURLcode    retCode    = CURLE_OK;
    long        lHttpCode  = 0;
    double      dTotalTime = 0;
    size_t      wBytesBody = 0;
    const char *pszCaBundle = NULL;

    pCurl = curl_easy_init();

    if (NULL == pCurl)
    {
        PrintLogMessage ("Cannot init curl easy handle\n");
        return 1;
    }

    pszCaBundle = FindCaBundle();

    if (pszCaBundle)
    {
        PrintLogMessage ("Loaded CA bundle: %s\n", pszCaBundle);
        curl_easy_setopt (pCurl, CURLOPT_CAINFO, pszCaBundle);
    }
    else
    {
        PrintLogMessage ("No CA bundle found in any known location -- falling back to libcurl default paths\n");
    }

    curl_easy_setopt (pCurl, CURLOPT_URL, pszUrl);
    curl_easy_setopt (pCurl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt (pCurl, CURLOPT_WRITEFUNCTION, WriteCallback);
    curl_easy_setopt (pCurl, CURLOPT_WRITEDATA, &wBytesBody);
    curl_easy_setopt (pCurl, CURLOPT_USERAGENT, "test_curl/1.0");
    curl_easy_setopt (pCurl, CURLOPT_TIMEOUT, 15L);

    retCode = curl_easy_perform (pCurl);

    if (CURLE_OK != retCode)
    {
        PrintLogMessage ("curl_easy_perform failed: %s\n", curl_easy_strerror (retCode));
        curl_easy_cleanup (pCurl);
        return 1;
    }

    curl_easy_getinfo (pCurl, CURLINFO_RESPONSE_CODE, &lHttpCode);
    curl_easy_getinfo (pCurl, CURLINFO_TOTAL_TIME, &dTotalTime);

    PrintDelLine (80, '-');
    PrintLogMessage ("URL          : %s\n", pszUrl);
    PrintLogMessage ("HTTP status  : %ld\n", lHttpCode);
    PrintLogMessage ("Body bytes   : %zu\n", wBytesBody);
    PrintLogMessage ("Total time   : %.3fs\n", dTotalTime);
    PrintDelLine (80, '-');

    curl_easy_cleanup (pCurl);

    return (lHttpCode >= 200 && lHttpCode < 400) ? 0 : 1;
}

int main (int argc, char *argv[])
{
    int ret = 0;

    print_version();
    PrintLogMessage ("\n");

    if (argc < 2)
        return 0;

    curl_global_init (CURL_GLOBAL_DEFAULT);

    PrintLogMessage ("Trying an HTTPS connection to %s...\n", argv[1]);
    ret = curl_connect (argv[1]);

    curl_global_cleanup();

    return ret;
}
